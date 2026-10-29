import AppKit
import Models
import SwiftUI

/// 使用原生系统菜单，主窗口继续负责完整日志和部署确认。
struct StatusBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("打开本地 CI", systemImage: "macwindow") { openMain() }
            .accessibilityIdentifier("status-open-main")
        if model.starting {
            Text("正在启动…")
        } else if model.startupError != nil || model.menuBarError != nil {
            Button("状态读取失败，查看详情…", systemImage: "exclamationmark.triangle") {
                openMain()
                model.errorMessage = model.menuBarError ?? model.startupError
            }
        } else {
            Section {
                Text("运行中 \(model.menuBar.runningCount) · 排队 \(model.menuBar.queuedCount)")
                Text("等待确认 \(model.menuBar.waitingCount) · 最新失败 \(model.menuBar.failureCount)")
            }
            Section("项目与运行") {
                if model.projects.isEmpty { Text("尚未添加项目") }
                ForEach(model.projects) { project in
                    Menu {
                        Text(project.hookMode == .none ? "未监听推送" : "正在监听推送")
                        Button("打开项目概览", systemImage: "folder") {
                            model.selectedProject = project.id
                            model.detail = .overview
                            openMain()
                        }
                        Divider()
                        let runs = model.menuBar.runs.filter { $0.projectID == project.id }
                        if runs.isEmpty { Text("暂无运行记录") }
                        ForEach(runs) { run in
                            Menu {
                                runActions(run)
                            } label: {
                                Label(shortTitle("#\(run.id.rawValue) \(run.branch) · \(run.commit.short) · \(run.status.title)"), systemImage: run.status.symbol)
                            }
                        }
                    } label: {
                        Label(shortTitle(project.name), systemImage: project.hookMode == .none ? "folder" : "antenna.radiowaves.left.and.right")
                    }
                }
            }
        }
        Divider()
        Button("设置…", systemImage: "gearshape") {
            NSApp.activate()
            openSettings()
        }
        .accessibilityIdentifier("status-open-settings")
        Button("退出本地 CI", systemImage: "power") { NSApp.terminate(nil) }
    }

    @ViewBuilder private func runActions(_ run: Run) -> some View {
        Button("查看运行与日志", systemImage: "doc.text") { show(run) }
        if let stage = model.menuBar.waitingStages[run.id] {
            Button("查看并确认替换…", systemImage: "hand.raised") { show(run, stage: stage) }
        }
        if let image = run.image {
            Button("复制镜像地址", systemImage: "doc.on.doc") { copyToPasteboard(image) }
        }
        if !run.status.isFinished {
            Button("取消此运行", systemImage: "stop.circle") {
                show(run)
                model.perform("cancel-\(run.id)") { try await $0.cancel(run.id) }
            }
            .disabled(model.isBusy("cancel-\(run.id)"))
        }
        if run.status.isFinished || run.status == .waiting {
            Button("重新运行", systemImage: "arrow.clockwise") {
                show(run)
                model.perform("rerun-\(run.id)") { service in
                    if let id = try await service.rerun(run.id) { model.show(run: id) }
                }
            }
            .disabled(model.isBusy("rerun-\(run.id)"))
        }
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate()
    }

    private func show(_ run: Run, stage: RunStageID? = nil) {
        openMain()
        model.show(run: run.id, stage: stage)
    }

    private func shortTitle(_ value: String) -> String {
        value.count > 30 ? String(value.prefix(29)) + "…" : value
    }
}

extension AppModel {
    /// 静态图标避免菜单栏持续动画；准确数量在菜单内展示。
    var menuBarSymbol: String {
        if startupError != nil || menuBarError != nil { return "exclamationmark.triangle" }
        if menuBar.runningCount > 0 { return "arrow.triangle.2.circlepath" }
        if menuBar.waitingCount > 0 { return "hand.raised" }
        if menuBar.failureCount > 0 { return "exclamationmark.circle" }
        if menuBar.queuedCount > 0 { return "clock" }
        return "shippingbox"
    }
}
