import Models
import SwiftUI

struct ProjectSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedProject) {
            Section("项目") {
                ForEach(model.projects) { project in
                    ProjectRow(project: project).tag(project.id)
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("project-list")
        .toolbar {
            ToolbarItem {
                Button("添加项目", systemImage: "plus") { model.addProject() }
                    .help("添加项目（⇧⌘O）")
                    .disabled(model.service == nil)
            }
        }
    }
}

private struct ProjectRow: View {
    let project: Project

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).lineLimit(1)
                Text(project.hookMode == .none ? "未监听推送" : "正在监听推送")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: project.hookMode == .none ? "folder" : "dot.radiowaves.left.and.right")
                .foregroundStyle(project.hookMode == .none ? Color.secondary : Color.green)
        }
        .labelStyle(CenteredIconLabelStyle())
        .help(project.repositoryPath)
    }
}

/// 系统 Label 把图标对齐到第一行文字；两行标题时改为上下居中。图标大小和间距按侧栏默认值。
private struct CenteredIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.title2).frame(width: 24)
            configuration.title
        }
    }
}
