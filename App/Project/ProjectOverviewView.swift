import AppKit
import ApplicationKit
import Models
import PushWatch
import Runner
import SwiftUI

/// 项目概览：仓库状态、推送监听开关和 `.local.cicd.yml` 的检查结果。
struct ProjectOverviewView: View {
    let project: Project
    let service: ApplicationService
    @Environment(AppModel.self) private var model
    @State private var overview: ProjectOverview?
    @State private var overviewError: String?
    @State private var status: ProjectPushStatus?
    @State private var installPlan: HookInstallPlan?
    @State private var confirmRemove = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var reload = 0

    private struct LoadKey: Equatable {
        var project: Project
        var connections: [String]
        var reload: Int
    }

    var body: some View {
        Form {
            repositorySection
            listeningSection
            configSection
            if let config = overview?.config { targetsSection(config) }
            Section {
                Button("移除项目…", role: .destructive) { confirmRemove = true }
            } footer: {
                Text("只从本地 CI 移除，不删除仓库里的任何文件；会先关闭推送监听。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(project.name)
        .navigationSubtitle("项目概览")
        .toolbar {
            ToolbarItem {
                Button("刷新", systemImage: "arrow.clockwise") { reload += 1 }
                    .help("重新读取仓库和配置")
            }
        }
        .task(id: LoadKey(project: project, connections: model.connections.map(\.name), reload: reload)) { await load() }
        .sheet(item: $installPlan) { plan in
            EnableListeningSheet(plan: plan) { enable(plan) }
        }
        .confirmationDialog("移除「\(project.name)」？", isPresented: $confirmRemove) {
            Button("移除项目", role: .destructive) {
                model.perform("remove-\(project.id)") { try await $0.removeProject(project.id) }
            }
        } message: {
            Text("运行记录和日志一并删除，仓库文件不受影响。")
        }
        .alert("重命名项目", isPresented: $renaming) {
            TextField("项目名称", text: $newName)
                .accessibilityIdentifier("rename-project-field")
            Button("重命名") { rename() }
                .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) {}
        } message: {
            Text("只改本地 CI 里显示的名字，不影响仓库。留空恢复为文件夹名「\(folderName)」。")
        }
    }

    // MARK: - 分区

    private var repositorySection: some View {
        Section("仓库") {
            LabeledContent("名称") {
                HStack(spacing: 6) {
                    Text(project.name).textSelection(.enabled)
                    Button("重命名…") {
                        newName = project.name
                        renaming = true
                    }
                    .disabled(model.isBusy("rename-\(project.id)"))
                    .accessibilityIdentifier("rename-project")
                }
            }
            LabeledContent("路径") {
                HStack(spacing: 6) {
                    Text(project.repositoryPath)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                    Button("在访达中显示", systemImage: "arrow.right.circle") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.repositoryPath)])
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("在访达中显示")
                }
            }
            if let overview {
                LabeledContent("当前分支", value: overview.branch ?? "（分离的 HEAD）")
                LabeledContent("当前提交") { Text(overview.commit.short).monospaced().textSelection(.enabled) }
            } else if let overviewError {
                Label(overviewError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var listeningSection: some View {
        Section {
            Toggle(isOn: Binding(get: { status?.installed ?? (project.hookMode != .none) }, set: setListening)) {
                Text("推送监听")
                Text(status?.message ?? "正在检查…")
            }
            .disabled(model.isBusy("hook-\(project.id)"))
            .accessibilityIdentifier("push-listening-toggle")
            if let status, status.installed, !status.intact {
                Label(status.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } footer: {
            Text("开启后，每次 git push 成功都会读取推送提交里的 .local.cicd.yml；分支不在配置里时什么都不做。")
        }
    }

    @ViewBuilder private var configSection: some View {
        Section(LocalConfig.path) {
            if let overview {
                if let problem = overview.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else if let config = overview.config {
                    Label("配置有效（当前提交）", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    LabeledContent("测试") {
                        Text(config.test.isEmpty ? "不运行测试" : config.test.joined(separator: "\n"))
                            .monospaced(!config.test.isEmpty)
                            .multilineTextAlignment(.trailing)
                    }
                    ForEach(config.build.images, id: \.name) { image in
                        LabeledContent("镜像 · \(image.name)") { Text(image.image).monospaced().textSelection(.enabled) }
                    }
                    LabeledContent("构建") {
                        Text(config.build.images.map { "\($0.name)：\(buildSummary($0))" }.joined(separator: "\n"))
                            .monospaced()
                            .multilineTextAlignment(.trailing)
                    }
                }
                if !overview.missingConnections.isEmpty {
                    HStack {
                        Label("还没有导入 k8s 连接：\(overview.missingConnections.joined(separator: "、"))",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        SettingsLink { Text("导入连接…") }
                    }
                }
            } else if overviewError == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private func targetsSection(_ config: LocalConfig) -> some View {
        Section {
            ForEach(Array(config.targets.enumerated()), id: \.offset) { _, target in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(target.branch)
                        .fontWeight(.medium)
                        .frame(minWidth: 80, alignment: .leading)
                    Image(systemName: "arrow.forward").foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(target.batch) · \(target.k8s) · \(target.build)")
                        Text("\(target.namespace) / \(target.deployment) / \(target.container)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(target.confirm ? "需确认" : "自动",
                          systemImage: target.confirm ? "hand.raised.fill" : "bolt.fill")
                        .foregroundStyle(target.confirm ? Color.orange : Color.green)
                        .font(.callout)
                }
            }
        } header: {
            Text("替换目标")
        } footer: {
            Text("推送到左边的分支后替换右边的服务镜像；未列出的分支什么都不做。")
        }
    }

    // MARK: - 操作

    private var folderName: String { URL(fileURLWithPath: project.repositoryPath).lastPathComponent }

    private func rename() {
        let id = project.id, name = newName
        model.perform("rename-\(id)") { try await $0.renameProject(id, to: name) }
    }

    private func buildSummary(_ build: LocalConfig.Build) -> String {
        if let command = build.command { return command }
        let platform = build.platform.map { " --platform \($0)" } ?? ""
        return "docker build\(platform) -f \(build.dockerfile ?? "Dockerfile")\ndocker push"
    }

    private func load() async {
        do {
            overview = try await service.projectOverview(projectID: project.id)
            overviewError = nil
        } catch {
            overview = nil
            overviewError = "无法读取仓库：\(error)"
        }
        status = try? await service.pushStatus(projectID: project.id)
    }

    private func setListening(_ on: Bool) {
        let id = project.id, path = project.repositoryPath
        model.perform("hook-\(id)") { service in
            if on {
                installPlan = try await service.previewPushListening(path: path)
            } else {
                try await service.disablePushListening(projectID: id)
                reload += 1
            }
        }
    }

    private func enable(_ plan: HookInstallPlan) {
        let id = project.id
        model.perform("hook-\(id)") { service in
            try await service.enablePushListening(projectID: id, helper: HookHelperLocation.url(), plan: plan)
            reload += 1
        }
    }
}

/// 开启推送监听前的确认。命令很长，放在可折叠、可滚动的区域里，按钮始终在窗口内。
private struct EnableListeningSheet: View {
    let plan: HookInstallPlan
    let onEnable: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showCommands = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("开启推送监听").font(.headline)
            Text("将在这个仓库的本地 Git 配置里登记 pre-push 和 reference-transaction 两个钩子，原有钩子照常执行；随时可以关闭。")
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("将执行的命令", isExpanded: $showCommands) {
                ScrollView {
                    Text(plan.commands.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("开启") {
                    dismiss()
                    onEnable()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("enable-listening-confirm")
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
