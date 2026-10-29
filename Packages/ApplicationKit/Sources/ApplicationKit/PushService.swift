import Foundation
import GitKit
import HookProtocol
import Models
import PushWatch
import Storage

public struct ProjectPushStatus: Sendable, Equatable {
    public var installed: Bool
    public var intact: Bool
    public var message: String
}

/// 推送监听：钩子程序在 git push 成功后写入 spool，这里确认推送确实到达远端后按分支创建运行。
extension ApplicationService {
    public func pushStatus(projectID: ProjectID) async throws -> ProjectPushStatus {
        let project = try await project(projectID)
        guard let installed = try installedHooks(projectID) else {
            return ProjectPushStatus(installed: false, intact: false, message: "未开启推送监听")
        }
        let repository = try await GitRepository.open(URL(fileURLWithPath: project.repositoryPath))
        let intact = try await HookInstaller(directory: paths.hooks).isIntact(installed, repository: repository)
        return ProjectPushStatus(installed: true, intact: intact, message: pushProblems[projectID] ??
            (intact ? "正在监听 git push" : "监听文件或 Git 配置已变化，请关闭后重新开启"))
    }

    public func previewPushListening(path: String) async throws -> HookInstallPlan {
        try await HookInstaller(directory: paths.hooks).preview(repository: GitRepository.open(URL(fileURLWithPath: path)))
    }

    public func enablePushListening(projectID: ProjectID, helper: URL, plan: HookInstallPlan? = nil) async throws {
        guard !stopping, pushMutations.insert(projectID).inserted else { throw ApplicationError("推送监听正在变更，请稍后再试") }
        defer { pushMutations.remove(projectID) }
        let project = try await project(projectID)
        let repository = try await GitRepository.open(URL(fileURLWithPath: project.repositoryPath))
        let installed = try await HookInstaller(directory: paths.hooks).install(repository: repository, projectID: projectID.rawValue, helper: helper, plan: plan)
        try await database.setHookMode(.configHook, projectID: projectID)
        pushWatchers[projectID] = try watcher(installed)
        pushProblems[projectID] = nil
        pushIntegrityIssues[projectID] = nil
    }

    public func disablePushListening(projectID: ProjectID) async throws {
        guard !stopping, pushMutations.insert(projectID).inserted else { throw ApplicationError("推送监听正在变更，请稍后再试") }
        defer { pushMutations.remove(projectID) }
        let project = try await project(projectID)
        if let installed = try installedHooks(projectID) {
            try await HookInstaller(directory: paths.hooks).uninstall(installed,
                repository: GitRepository.open(URL(fileURLWithPath: project.repositoryPath)))
        }
        try await database.setHookMode(.none, projectID: projectID)
        pushWatchers[projectID] = nil
        pushProblems[projectID] = nil
        pushIntegrityIssues[projectID] = nil
    }

    func startPushObservation() {
        guard pushLoop == nil else { return }
        pushLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scanPushEvents()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    /// 只读本机 spool，不请求远端。App 没开着时的推送在下次启动后补处理。
    public func scanPushEvents() async {
        guard !stopping else { return }
        guard !pushScanning else { pushRescanRequested = true; return }
        pushScanning = true
        pushRescanRequested = false
        defer {
            pushScanning = false
            let waiters = pushIdleWaiters
            pushIdleWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if pushRescanRequested, !stopping {
                Task { [weak self] in await self?.scanPushEvents() }
            }
        }
        guard let projects = try? await database.projects() else { return } // 下次扫描重试
        for project in projects where project.hookMode != .none && !pushMutations.contains(project.id) {
            do {
                guard let installed = try installedHooks(project.id) else { continue }
                if Date().timeIntervalSince(pushIntegrityChecked[project.id] ?? .distantPast) >= 60 {
                    let repository = try await GitRepository.open(URL(fileURLWithPath: project.repositoryPath))
                    let intact = try await HookInstaller(directory: paths.hooks).isIntact(installed, repository: repository)
                    pushIntegrityIssues[project.id] = intact ? nil : "监听文件或 Git 配置已变化，请关闭后重新开启；不会自动覆盖"
                    pushIntegrityChecked[project.id] = Date()
                    pushWatchers[project.id] = nil
                }
                if pushWatchers[project.id] == nil { pushWatchers[project.id] = try watcher(installed) }
                try await processInstallation(installed, project: project)
                pushProblems[project.id] = pushIntegrityIssues[project.id]
            } catch {
                pushProblems[project.id] = "处理推送事件失败：\(error)"
            }
        }
    }

    func installedHooks(_ id: ProjectID) throws -> InstalledHooks? {
        let file = paths.hooks.appendingPathComponent("project-\(id.rawValue)/installation.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try HookSpool.read(InstalledHooks.self, url: file)
    }

    private func watcher(_ installed: InstalledHooks) throws -> SpoolWatcher {
        try SpoolWatcher(directory: URL(fileURLWithPath: installed.installation.spoolPath)) { [weak self] in
            Task { await self?.scanPushEvents() }
        }
    }

    private func processInstallation(_ installed: InstalledHooks, project: Project) async throws {
        guard installed.installation.projectID == project.id.rawValue, installed.installation.repositoryPath == project.repositoryPath else {
            throw ApplicationError("推送监听记录与当前项目不一致")
        }
        let confirmation = PushConfirmation(database: database)
        for record in try await confirmation.scan(installed) {
            for update in record.updates where update.createsRun {
                guard !stopping else { return }
                if try await database.pushDispatch(update.id) != nil { continue }
                do {
                    try await dispatch(update, project: project)
                } catch {
                    try await database.recordPushDispatch(update.id, runID: nil, message: "未自动执行：\(error)")
                }
            }
            try await confirmation.archiveCompleted(record, installed: installed)
        }
    }
}
