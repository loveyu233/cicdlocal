import SwiftUI

/// 三栏主窗口：项目 → 运行 → 运行详情或项目概览。
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            ProjectSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } content: {
            Group {
                if let project = model.project, let service = model.service {
                    RunListView(project: project, service: service)
                } else {
                    Color.clear
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            detail
        }
        .alert("操作没有完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear { model.openMainWindow = { [openWindow] in openWindow(id: "main") } }
    }

    @ViewBuilder private var detail: some View {
        if let error = model.startupError {
            ContentUnavailableView {
                Label("本地 CI 无法启动", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else if model.starting {
            ProgressView("正在启动…")
        } else if let project = model.project, let service = model.service {
            switch model.detail {
            case .run(let id):
                RunDetailView(runID: id, project: project, service: service)
                    .id(id)
            case .overview, nil:
                ProjectOverviewView(project: project, service: service)
                    .id(project.id)
            }
        } else {
            ContentUnavailableView {
                Label("还没有项目", systemImage: "folder.badge.plus")
            } description: {
                Text("添加一个 Git 仓库并开启推送监听。之后每次 git push，命中 .local.cicd.yml 里的分支就会自动测试、构建推送、替换镜像。")
            } actions: {
                Button("添加项目…") { model.addProject() }
                    .buttonStyle(.glassProminent)
                    .disabled(model.service == nil)
                    .accessibilityIdentifier("add-project")
            }
        }
    }
}
