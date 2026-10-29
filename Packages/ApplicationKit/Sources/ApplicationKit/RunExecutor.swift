import Foundation
import GitKit
import LogKit
import Models
import Platform
import Runner
import Storage

/// 推送或重新运行时读配置得到的结果。
enum PreparedRun {
    /// 不需要运行：没有配置文件，或分支不在配置里。
    case ignored(String)
    /// 排队的运行；配置有错时是一个直接失败、没有阶段的运行，界面上能看到原因。
    case run(Run, [RunStage])
}

extension ApplicationService {
    public static let confirmedMessage = "已确认，排队等待替换"
    static let reusedImageMessage = "沿用已推送的镜像，不重新构建"

    /// 运行的镜像已经推送过（构建成功，或本身就是重新替换），且有替换目标，可以重新替换。
    public static func canRedeploy(_ run: Run, stages: [RunStage]) -> Bool {
        guard run.status.isFinished || run.status == .waiting,
              let json = run.plan, let plan = try? JSONDecoder().decode(RunPlan.self, from: Data(json.utf8)),
              plan.version == 2, plan.isDeployable else { return false }
        let builds = stages.filter { $0.kind == .build }
        return builds.count == plan.images.count && builds.allSatisfy {
            $0.status == .succeeded || ($0.status == .skipped && $0.message == reusedImageMessage)
        }
    }

    private func stages(for plan: RunPlan, redeploy: Bool = false) -> [RunStage] {
        var result = [RunStage(id: .unsaved, runID: .unsaved, ordinal: 0, kind: .test, title: "测试",
                              status: redeploy || plan.tests.isEmpty ? .skipped : .pending,
                              message: redeploy ? "重新替换，不重新测试" : (plan.tests.isEmpty ? "没有测试命令" : nil))]
        for image in plan.images {
            result.append(RunStage(id: .unsaved, runID: .unsaved, ordinal: result.count, kind: .build,
                                   title: "构建 \(image.name)", targetKey: image.stageKey,
                                   status: redeploy ? .skipped : .pending, message: redeploy ? Self.reusedImageMessage : nil))
        }
        for target in plan.targets {
            result.append(RunStage(id: .unsaved, runID: .unsaved, ordinal: result.count, kind: .deploy,
                                   title: "替换 \(target.batch) · \(target.build)", targetKey: target.stageKey))
        }
        return result
    }

    // MARK: - 创建运行

    /// 读取提交里的 `.local.cicd.yml`，在执行任何命令之前一次性校验：格式、分支、k8s 连接名。
    func prepare(project: Project, repository: GitRepository, sha: CommitSHA, branch: String,
                 refUpdateID: RefUpdateID?, rerunOf: RunID?) async throws -> PreparedRun {
        let now = Date()
        var run = Run(id: .unsaved, projectID: project.id, refUpdateID: refUpdateID, rerunOf: rerunOf,
                      branch: branch, commit: sha, createdAt: now)
        run.commitMessage = try? await repository.commitMessage(sha)
        func failed(_ message: String) -> PreparedRun {
            run.status = .failed
            run.message = message
            run.finishedAt = now
            return .run(run, [])
        }
        let config: LocalConfig
        do {
            guard let data = try await repository.fileContents(LocalConfig.path, at: sha, limit: LocalConfig.maximumBytes) else {
                return .ignored("没有 \(LocalConfig.path)，未运行")
            }
            config = try LocalConfig.parse(data)
        } catch let error as ConfigError {
            return failed("配置错误：\(error)")
        } catch let error as GitError {
            return failed("配置错误：\(error)")
        }
        guard let plan = config.plan(branch: branch, variables: RunVariables(date: now, commit: sha.rawValue, branch: branch)) else {
            return .ignored("分支 \(branch) 未在配置中，未运行")
        }
        run.image = plan.summary
        run.plan = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        let known = Set(try await database.connections().map(\.name))
        if let missing = plan.targets.map(\.k8s).first(where: { !known.contains($0) }) {
            return failed("k8s 连接「\(missing)」不存在，请先在设置中导入并命名")
        }
        return .run(run, stages(for: plan))
    }

    /// 处理一次确认成功的分支推送。
    func dispatch(_ update: RefUpdate, project: Project) async throws {
        guard let branch = update.branch else { return }
        let repository = try await GitRepository.open(URL(fileURLWithPath: project.repositoryPath))
        let sha = try await repository.resolve(update.newSHA.rawValue)
        try await database.setResolvedCommit(sha, for: update.id)
        switch try await prepare(project: project, repository: repository, sha: sha, branch: branch, refUpdateID: update.id, rerunOf: nil) {
        case .ignored(let reason):
            try await database.recordPushDispatch(update.id, runID: nil, message: reason)
        case .run(let run, let stages):
            guard let created = try await database.createRun(run, stages: stages, dispatchMessage: run.message ?? "已创建运行") else { return }
            await started(created, project: project)
        }
    }

    /// 按原运行的提交重新读取配置并排队，镜像标签里的 ${TIME} 取新的时间。
    @discardableResult
    public func rerun(_ id: RunID) async throws -> RunID? {
        guard !stopping, let original = try await database.run(id) else { throw ApplicationError("运行已不存在") }
        guard original.status.isFinished || original.status == .waiting else { throw ApplicationError("运行还没有结束") }
        let project = try await project(original.projectID)
        let repository = try await GitRepository.open(URL(fileURLWithPath: project.repositoryPath))
        switch try await prepare(project: project, repository: repository, sha: original.commit, branch: original.branch,
                                 refUpdateID: nil, rerunOf: id) {
        case .ignored(let reason):
            throw ApplicationError(reason)
        case .run(let run, let stages):
            guard let created = try await database.createRun(run, stages: stages) else { return nil }
            await started(created, project: project)
            return created.id
        }
    }

    /// 重新替换：沿用原运行已推送的镜像和执行计划，跳过测试和构建，只执行替换阶段。
    /// 用于回滚到旧版本；替换目标和是否需要确认都按原运行的计划。
    @discardableResult
    public func redeploy(_ id: RunID) async throws -> RunID? {
        guard !stopping, let original = try await database.run(id) else { throw ApplicationError("运行已不存在") }
        guard original.status.isFinished || original.status == .waiting else { throw ApplicationError("运行还没有结束") }
        guard Self.canRedeploy(original, stages: try await database.stages(runID: id)) else {
            throw ApplicationError("这个运行没有成功推送镜像，无法重新替换")
        }
        let plan = try decodePlan(original)
        let known = Set(try await database.connections().map(\.name))
        if let missing = plan.targets.map(\.k8s).first(where: { !known.contains($0) }) {
            throw ApplicationError("k8s 连接「\(missing)」不存在，请先在设置中导入并命名")
        }
        let project = try await project(original.projectID)
        var run = Run(id: .unsaved, projectID: project.id, refUpdateID: nil, rerunOf: id, branch: original.branch,
                      commit: original.commit, commitMessage: original.commitMessage, createdAt: Date())
        run.image = original.image
        run.plan = original.plan
        let stages = stages(for: plan, redeploy: true)
        guard let created = try await database.createRun(run, stages: stages) else { return nil }
        await started(created, project: project)
        return created.id
    }

    /// 删除一个已结束或等待确认的运行，连同它的日志。不影响已推送的镜像和集群。
    public func deleteRun(_ id: RunID) async throws {
        guard let run = try await database.run(id) else { return }
        guard run.status.isFinished || run.status == .waiting, current[run.projectID]?.run != id,
              confirmations[run.projectID]?.contains(where: { $0.run == id }) != true
        else { throw ApplicationError("运行还在执行，请先取消") }
        try await database.deleteRun(id)
        let directory = paths.runLogs(run: id.rawValue)
        if AppPaths.isInside(directory, root: paths.logsRoot) { try? FileManager.default.removeItem(at: directory) }
    }

    private func started(_ run: Run, project: Project) async {
        if run.status == .queued {
            ensureWorker(project.id)
        } else {
            await notify(RunNotice(kind: .failed, runID: run.id, projectName: project.name, branch: run.branch,
                                   message: run.message ?? "运行失败"))
        }
    }

    // MARK: - 用户操作

    /// 一个目标按钮代表整个等待批次；数据库一次性迁移全部目标，拒绝重复确认并核验该批次自身镜像。
    public func confirm(_ stageID: RunStageID, runID: RunID) async throws {
        try await changeWaitingBatch(stageID, runID: runID, skip: false)
    }

    public func skip(_ stageID: RunStageID, runID: RunID) async throws {
        try await changeWaitingBatch(stageID, runID: runID, skip: true)
    }

    private func changeWaitingBatch(_ stageID: RunStageID, runID: RunID, skip: Bool) async throws {
        guard !stopping, let run = try await database.run(runID), [.waiting, .running, .queued, .interrupted].contains(run.status) else {
            throw ApplicationError("运行不能继续确认部署")
        }
        let plan = try decodePlan(run)
        let stages = try await database.stages(runID: runID)
        guard let stage = stages.first(where: { $0.id == stageID }), let batch = plan.batch(key: stage.targetKey) else {
            throw ApplicationError("阶段不属于这个运行的部署批次")
        }
        let keys = Set(batch.targets.map(\.stageKey))
        let members = stages.filter { keys.contains($0.targetKey ?? "") }
        guard members.count == batch.targets.count, Self.batchReady(batch, plan: plan, stages: stages) else {
            throw ApplicationError("该批次引用的镜像尚未全部构建并核验成功")
        }
        let dependencies = Set(batch.targets.map(\.build)).compactMap { plan.image(named: $0)?.stageKey }
        try await database.changeWaitingBatch(runID, ids: members.map(\.id), dependencies: dependencies,
                                              skip: skip, confirmedMessage: Self.confirmedMessage)
        if !skip { confirmations[run.projectID, default: []].append((runID, stageID)) }
        ensureWorker(run.projectID)
    }

    /// 取消排队、运行中或等待确认的运行。正在执行的命令会连同子进程一起终止。
    public func cancel(_ runID: RunID) async throws {
        guard let run = try await database.run(runID), !run.status.isFinished else { return }
        if let entry = current[run.projectID], entry.run == runID {
            entry.task.cancel()
            return
        }
        canceling.insert(runID)
        confirmations[run.projectID]?.removeAll { $0.run == runID }
        try await database.closeRun(runID, status: .canceled, message: "已取消")
    }

    // MARK: - 项目队列

    func ensureWorker(_ id: ProjectID) {
        guard !stopping else { return }
        wake[id] = true
        guard workers[id] == nil else { return }
        workers[id] = Task { await self.drain(id) }
    }

    /// 先处理已确认的替换，再按创建顺序执行排队的运行，直到没有可做的事。
    private func drain(_ id: ProjectID) async {
        var attempted: Set<RunID> = []
        while !stopping {
            wake[id] = false
            if let next = confirmations[id]?.first {
                confirmations[id]?.removeFirst()
                let task = Task { await self.executeConfirmation(next.run, stageID: next.stage) }
                current[id] = (next.run, task)
                await task.value
                current[id] = nil
                continue
            }
            let run = try? await database.nextQueuedRun(projectID: id)
            guard let run, attempted.insert(run.id).inserted else {
                if wake[id] == true || confirmations[id]?.isEmpty == false { continue }
                break
            }
            let task = Task { await self.execute(run.id) }
            current[id] = (run.id, task)
            await task.value
            current[id] = nil
            canceling.remove(run.id)
        }
        workers[id] = nil
    }

    // MARK: - 执行

    private func execute(_ runID: RunID, resume: Bool = false) async {
        guard !canceling.contains(runID), let queued = try? await database.run(runID),
              queued.status == .queued || (resume && [.waiting, .interrupted].contains(queued.status)),
              let project = try? await database.project(queued.projectID) else { return }
        var run = queued
        do {
            try Task.checkCancellation()
            run.status = .running
            run.startedAt = run.startedAt ?? Date()
            run.finishedAt = nil
            try await database.updateRun(run)
            let plan = try decodePlan(run)
            let allStages = try await database.stages(runID: runID)
            var root = URL(fileURLWithPath: project.repositoryPath)
            var warning: String?
            if allStages.contains(where: { $0.kind != .deploy && $0.status == .pending }) {
                let repository = try await GitRepository.open(root)
                guard try await repository.resolve() == run.commit else {
                    try await fail(run, project: project, message: "工作区当前不是提交 \(run.commit.short)，未运行。回滚请用「重新替换」")
                    return
                }
                warning = try await repository.isDirty() ? "工作区有未提交的改动，按当前文件执行" : nil
                root = repository.root
            }
            let shell = try await environment()
            let runner = StageRunner(root: root, shell: shell, variables: plan.environment)
            if allStages.contains(where: { $0.kind == .build && $0.status == .pending }) { try runner.validate(plan.images) }
            if let test = allStages.first(where: { $0.kind == .test && $0.status == .pending }) {
                let result = try await perform(test, run: run, warning: warning, success: "测试通过") { log in
                    StageResult(succeeded: try await runner.test(plan.tests, log: log))
                }
                guard result?.succeeded == true else {
                    try await fail(run, project: project, message: "测试失败，详见日志")
                    return
                }
            }
            try await scheduleIndependent(run: run, project: project, root: root, shell: shell, warning: warning)
        } catch { await interrupted(run, project: project, error: error) }
    }

    private func executeConfirmation(_ runID: RunID, stageID: RunStageID) async {
        await execute(runID, resume: true)
    }

    func build(_ stage: RunStage, plan: RunPlan, run: Run, root: URL, shell: ShellEnvironment,
                       warning: String?) async throws -> Bool {
        guard let image = plan.images.first(where: { $0.stageKey == stage.targetKey }) else { throw ApplicationError("构建阶段与计划不一致") }
        let runner = StageRunner(root: root, shell: shell, variables: plan.variables.environment(image: image.image, build: image.name))
        let database = database
        let result = try await perform(stage, run: run, warning: warning, success: "已推送并核验 \(image.image)") { log in
            guard try await runner.build(image, log: log) else { return .failed("构建推送失败，详见日志") }
            guard let digest = try await runner.resolveDigest(image.image, log: log) else { return .failed("镜像 digest 核验失败，详见日志") }
            try await database.transformPlan(run.id) { json in
                var latest = try JSONDecoder().decode(RunPlan.self, from: Data(json.utf8))
                guard let index = latest.images.firstIndex(where: { $0.name == image.name }) else { throw ApplicationError("保存摘要时找不到构建项") }
                latest.images[index].digest = digest
                return String(decoding: try JSONEncoder().encode(latest), as: UTF8.self)
            }
            return StageResult(succeeded: true)
        }
        return result?.succeeded == true
    }

    /// 运行的失败说明：替换到哪个环境失败，加上阶段给出的原因（例如 Pod 崩溃和日志里的报错）。
    static func deployFailure(_ target: LocalConfig.Target, _ result: StageResult) -> String {
        "替换到「\(target.k8s)」失败" + (result.message.map { "：\($0)" } ?? "，详见日志")
    }

    /// 执行一个替换目标。阶段已不在 `from` 状态时返回 nil。
    func deploy(_ stage: RunStage, target: LocalConfig.Target, image: String, run: Run, runner: StageRunner,
                        from: Set<StageStatus> = [.pending]) async throws -> StageResult? {
        // 先取出 kubeconfig 登记为敏感值，kubectl 输出里出现其中的令牌或证书时也会脱敏。
        var kubeconfig: Data?
        if let connection = try await database.connection(named: target.k8s) {
            kubeconfig = try await secrets.value(account: connection.account).map(KubeconfigDocument.kubectlReadable)
        }
        let observationDuration = deploymentSettleDuration
        return try await perform(stage, run: run, from: from, secrets: kubeconfig.map { [String(decoding: $0, as: UTF8.self)] } ?? [],
                                 success: "替换完成") { log in
            guard let kubeconfig else {
                try await log.message("k8s 连接「\(target.k8s)」不存在或钥匙串里没有它的配置，请在设置中重新导入")
                return .failed("k8s 连接「\(target.k8s)」不存在或钥匙串里没有它的配置")
            }
            var deployer = KubeDeployer(stage: runner, temporaryDirectory: self.paths.temporary)
            deployer.settleDuration = observationDuration
            return try await deployer.deploy(target, image: image, kubeconfig: kubeconfig, log: log)
        }
    }

    /// 把阶段从 `from` 改为运行中，写一份阶段日志，按结果改为成功或失败。阶段已不在 `from` 状态时返回 nil。
    /// 阶段给出的说明和日志一样脱敏后才保存。
    private func perform(_ stage: RunStage, run: Run, from: Set<StageStatus> = [.pending], warning: String? = nil,
                         secrets: [String] = [], success: String,
                         body: (JobLogStore) async throws -> StageResult) async throws -> StageResult? {
        guard try await database.transitionStage(stage.id, from: from, to: .running) != nil else { return nil }
        let log = try JobLogStore(directory: paths.stageLog(run: run.id.rawValue, ordinal: stage.ordinal), allowedRoot: paths.logsRoot,
                                 secrets: secrets)
        liveLogs[stage.id] = log
        defer { liveLogs[stage.id] = nil }
        var result: StageResult
        do {
            if let warning { try await log.message(warning) }
            result = try await body(log)
        } catch {
            if !(error is CancellationError) { try? await log.message("执行出错：\(error)") }
            if error is CancellationError { try? await log.finish(); throw error }
            result = .failed("执行出错：\(error)")
        }
        try await log.finish()
        if let message = result.message {
            var sanitizer = try LogSanitizer(secrets: secrets)
            result.message = (sanitizer.append(Data(message.utf8)) + sanitizer.finish()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await database.transitionStage(stage.id, from: [.running], to: result.succeeded ? .succeeded : .failed,
                                               message: result.message ?? (result.succeeded ? success : "失败，详见日志"))
        return result
    }

    private func fail(_ run: Run, project: Project, message: String) async throws {
        try await database.closeRun(run.id, status: .failed, message: message)
        await notify(RunNotice(kind: .failed, runID: run.id, projectName: project.name, branch: run.branch, message: message))
    }

    /// 取消或出错。App 正在退出时保留运行中的状态，下次启动标为已中断。
    private func interrupted(_ run: Run, project: Project, error: any Error) async {
        if error is CancellationError {
            guard !stopping else { return }
            // 当前任务已被取消，GRDB 的异步写入会直接抛出取消；换一个没有取消的任务收尾。
            let database = database
            _ = await Task { try? await database.closeRun(run.id, status: .canceled, message: "已取消") }.value
        } else {
            try? await fail(run, project: project, message: "\(error)")
        }
    }

    func decodePlan(_ run: Run) throws -> RunPlan {
        guard let plan = run.plan, let decoded = try? JSONDecoder().decode(RunPlan.self, from: Data(plan.utf8)), decoded.version == 2 else {
            throw ApplicationError("此记录不是新版执行计划；请提交新版 .local.cicd.yml 后创建运行")
        }
        return decoded
    }

}
