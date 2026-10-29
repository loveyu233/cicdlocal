import AppKit
import ApplicationKit
import Models
import Observation
import Storage
import SwiftUI

/// 中栏选中的条目：项目概览或某个运行。
enum Detail: Hashable {
    case overview
    case run(RunID)
}

/// 整个 App 共用的状态：服务、项目和连接列表、当前选择、错误提示。
@Observable
@MainActor
final class AppModel {
    static let shared = AppModel()

    private(set) var service: ApplicationService?
    private(set) var startupError: String?
    private(set) var starting = true
    private(set) var projects: [Project] = []
    private(set) var connections: [K8sConnection] = []
    private(set) var menuBar = MenuBarSnapshot()
    private(set) var menuBarError: String?
    var requestedStage: RunStageID?
    private(set) var stageRequestID = UUID()
    var selectedProject: ProjectID? {
        didSet { if oldValue != selectedProject { detail = .overview } }
    }
    var detail: Detail? = .overview
    var errorMessage: String?
    /// 在后台标记的操作，避免重复点击。
    private(set) var busy: Set<String> = []
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private var observers: [Task<Void, Never>] = []

    var project: Project? { projects.first { $0.id == selectedProject } }

    func start() async {
        guard service == nil else { return }
        defer { starting = false }
        do {
            // 第一次发通知会等用户回应系统授权提示；不能让运行队列等它，否则之后的确认替换一直排不上。
            let service = try AppLaunchEnvironment.makeService { notice in
                Task { await Notifier.shared.deliver(notice) }
            }
            try await service.recover()
            self.service = service
            observe(service)
        } catch {
            startupError = String(describing: error)
        }
    }

    func shutdown() async {
        observers.forEach { $0.cancel() }
        observers = []
        await service?.shutdown()
    }

    private func observe(_ service: ApplicationService) {
        observers.append(Task { [weak self] in
            do {
                for try await snapshot in service.database.observeMenuBar() { self?.menuBar = snapshot }
            } catch { self?.menuBarError = "菜单栏状态读取失败：\(error)" }
        })
        observers.append(Task { [weak self] in
            do {
                for try await projects in service.database.observeProjects() {
                    guard let self else { return }
                    self.projects = projects
                    if selectedProject.map({ id in !projects.contains { $0.id == id } }) ?? true {
                        selectedProject = projects.first?.id
                    }
                }
            } catch { self?.errorMessage = "读取项目列表失败：\(error)" }
        })
        observers.append(Task { [weak self] in
            do {
                for try await connections in service.database.observeConnections() { self?.connections = connections }
            } catch { self?.errorMessage = "读取 k8s 连接失败：\(error)" }
        })
    }

    // MARK: - 操作

    /// 在后台执行一个服务调用，出错时弹出提示。`key` 相同的操作同一时间只执行一个。
    func perform(_ key: String, _ action: @escaping @MainActor (ApplicationService) async throws -> Void) {
        guard let service, busy.insert(key).inserted else { return }
        Task {
            defer { busy.remove(key) }
            do { try await action(service) } catch { errorMessage = String(describing: error) }
        }
    }

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "添加项目"
        panel.message = "选择一个 Git 仓库。推送命中 .local.cicd.yml 里的分支时会在这个目录执行。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("add-project") { service in
            let project = try await service.addProject(path: url.path)
            self.selectedProject = project.id
            self.detail = .overview
        }
    }

    /// 通知或链接打开某个运行。
    func show(run id: RunID, stage: RunStageID? = nil) {
        openMainWindow?()
        NSApp.activate()
        guard let service else { return }
        Task {
            guard let run = try? await service.database.run(id) else { return }
            selectedProject = run.projectID
            requestedStage = stage
            detail = .run(id)
            stageRequestID = UUID()
        }
    }
}

/// 应用内的钩子程序，开启推送监听时写进仓库的 Git 配置。
enum HookHelperLocation {
    static func url() throws -> URL {
        guard let executable = Bundle.main.executableURL else { throw ApplicationError("无法定位应用内的钩子程序") }
        let helper = executable.deletingLastPathComponent().appending(path: "localcicd-hook")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ApplicationError("应用内的钩子程序缺失，请重新安装本地 CI")
        }
        return helper
    }
}
