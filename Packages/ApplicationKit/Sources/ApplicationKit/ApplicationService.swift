import Foundation
import GitKit
import LogKit
import Models
import Platform
import PushWatch
import Runner
import Storage

public struct ApplicationError: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// 需要提醒用户的事件：只有等待确认和失败两种。
public struct RunNotice: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case waiting, failed }
    public var kind: Kind
    public var runID: RunID
    public var projectName: String
    public var branch: String
    public var message: String
}

/// 原生界面只调用这个服务：管理项目、监听推送、按 `.local.cicd.yml` 执行三阶段运行、管理 k8s 连接。
///
/// 同一项目同一时间只执行一个运行或一次确认替换，其余排队；不同项目互不影响。
public actor ApplicationService {
    public nonisolated let database: AppDatabase
    public nonisolated let paths: AppPaths
    let instanceLock: InstanceLock
    let secrets: any SecretStore
    /// 每次执行前读取登录 shell 的环境；测试里替换成固定 PATH。
    let environment: @Sendable () async throws -> ShellEnvironment
    /// 在项目队列里被等待，必须很快返回；需要等用户的操作（例如通知授权）要自己放到别的任务里。
    let notify: @Sendable (RunNotice) async -> Void

    // 推送监听
    var pushLoop: Task<Void, Never>?
    var pushScanning = false
    var pushRescanRequested = false
    var pushWatchers: [ProjectID: SpoolWatcher] = [:]
    var pushIdleWaiters: [CheckedContinuation<Void, Never>] = []
    var pushIntegrityChecked: [ProjectID: Date] = [:]
    var pushIntegrityIssues: [ProjectID: String] = [:]
    var pushProblems: [ProjectID: String] = [:]
    var pushMutations: Set<ProjectID> = []

    // 每个项目一条执行队列
    var workers: [ProjectID: Task<Void, Never>] = [:]
    var wake: [ProjectID: Bool] = [:]
    var current: [ProjectID: (run: RunID, task: Task<Void, Never>)] = [:]
    var confirmations: [ProjectID: [(run: RunID, stage: RunStageID)]] = [:]
    var canceling: Set<RunID> = []
    var liveLogs: [RunStageID: JobLogStore] = [:]
    var stopping = false
    /// 内部观察时长，测试可缩短；不作为用户配置项。
    var deploymentSettleDuration: Duration = .seconds(60)

    public init(
        paths: AppPaths,
        secrets: any SecretStore,
        environment: @escaping @Sendable () async throws -> ShellEnvironment = { try await ShellEnvironment.capture() },
        notify: @escaping @Sendable (RunNotice) async -> Void = { _ in }
    ) throws {
        try paths.createDirectories()
        guard let lock = try InstanceLock.acquire(at: paths.instanceLock) else {
            throw ApplicationError("已有一个本地 CI 实例正在使用此数据目录，请切换到已有窗口")
        }
        instanceLock = lock
        self.paths = paths
        self.secrets = secrets
        self.environment = environment
        self.notify = notify
        database = try AppDatabase.open(at: paths.database)
    }

    /// 启动时调用：上次退出时没跑完的运行标为已中断，继续执行排队的运行并开始监听推送。
    public func recover() async throws {
        stopping = false
        _ = try await database.recoverInterruptedRuns()
        // 上次点了确认但还没执行就退出了：确认只在内存里排队，需要重新确认。
        for project in try await database.projects() {
            for run in try await database.runs(projectID: project.id, limit: 1_000) where run.status == .waiting || run.status == .interrupted {
                for var stage in try await database.stages(runID: run.id) where stage.status == .waiting && stage.message == Self.confirmedMessage {
                    stage.message = "上次确认未执行，请重新确认"
                    try await database.updateStage(stage)
                }
                // 先前串行执行留下的后批也可独立确认；恢复只开放按钮，不自动替换。
                if let plan = try? decodePlan(run) {
                    let stages = try await database.stages(runID: run.id)
                    for batch in plan.batches where batch.confirm && Self.batchReady(batch, plan: plan, stages: stages) {
                        let keys = Set(batch.targets.map(\.stageKey))
                        let members = stages.filter { keys.contains($0.targetKey ?? "") }
                        if members.count == batch.targets.count && members.allSatisfy({ $0.status == .pending }) {
                            try await database.waitForBatch(run.id, ids: members.map(\.id), message: "等待确认批次「\(batch.name)」")
                        }
                    }
                }
            }
        }
        for id in try await database.projectsWithQueuedRuns() { ensureWorker(id) }
        startPushObservation()
    }

    /// 退出前调用：终止正在执行的命令。被终止的运行下次启动时标为已中断。
    public func shutdown() async {
        stopping = true
        pushLoop?.cancel()
        await pushLoop?.value
        pushLoop = nil
        pushWatchers.removeAll()
        if pushScanning { await withCheckedContinuation { pushIdleWaiters.append($0) } }
        for entry in current.values { entry.task.cancel() }
        let running = Array(workers.values)
        for worker in running { await worker.value }
    }

    // MARK: - 项目

    public func addProject(path: String) async throws -> Project {
        let repository = try await GitRepository.open(URL(fileURLWithPath: path))
        guard try await !database.projects().contains(where: { $0.repositoryPath == repository.root.path }) else {
            throw ApplicationError("此仓库已经添加，请在侧栏选择它")
        }
        return try await database.createProject(Project(id: .unsaved, name: repository.root.lastPathComponent,
                                                        repositoryPath: repository.root.path, createdAt: Date()))
    }

    /// 移除项目：停止它的运行、卸载推送监听、删除运行记录和日志。不改动仓库里的文件。
    public func removeProject(_ id: ProjectID) async throws {
        guard !stopping, pushMutations.insert(id).inserted else { throw ApplicationError("此项目正在变更，请稍后再试") }
        defer { pushMutations.remove(id) }
        let project = try await project(id)
        confirmations[id] = nil
        if let entry = current[id] { entry.task.cancel() }
        await workers[id]?.value
        if let installed = try installedHooks(id) {
            try await HookInstaller(directory: paths.hooks).uninstall(installed,
                repository: GitRepository.open(URL(fileURLWithPath: project.repositoryPath)))
        }
        pushWatchers[id] = nil
        pushProblems[id] = nil
        let runs = try await database.runs(projectID: id, limit: 1_000)
        try await database.deleteProject(id)
        for run in runs {
            let directory = paths.runLogs(run: run.id.rawValue)
            if AppPaths.isInside(directory, root: paths.logsRoot) { try? FileManager.default.removeItem(at: directory) }
        }
    }

    /// 重命名项目；名称留空时恢复为仓库文件夹名。
    @discardableResult
    public func renameProject(_ id: ProjectID, to name: String) async throws -> Project {
        let project = try await project(id)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 100 else { throw ApplicationError("项目名称不能超过 100 个字符") }
        let resolved = trimmed.isEmpty ? URL(fileURLWithPath: project.repositoryPath).lastPathComponent : trimmed
        return try await database.renameProject(id, to: resolved)
    }

    public func currentBranch(projectID: ProjectID) async throws -> String? {
        try await GitRepository.open(URL(fileURLWithPath: project(projectID).repositoryPath)).currentBranch()
    }

    func project(_ id: ProjectID) async throws -> Project {
        guard let project = try await database.project(id) else { throw ApplicationError("项目已被移除") }
        return project
    }

    // MARK: - 日志

    /// 正在执行的阶段的日志；阶段结束后返回 nil，改用 `storedLog`。
    public func liveLog(_ stageID: RunStageID) -> JobLogStore? { liveLogs[stageID] }

    /// 已结束阶段的日志；没有日志（未执行、已跳过）时返回 nil。
    public nonisolated func storedLog(run: RunID, ordinal: Int) throws -> String? {
        let directory = paths.stageLog(run: run.rawValue, ordinal: ordinal)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return try JobLogStore.read(directory: directory)
    }
}
