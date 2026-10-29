import AppKit
import ApplicationKit
import Models
import SwiftUI

/// 选择 kubeconfig 文件、挑一个 context、预览集群信息，然后命名导入或替换已有连接。
struct ConnectionImportSheet: View {
    enum Mode: Identifiable {
        case new
        case replace(K8sConnection)

        var id: String {
            switch self {
            case .new: "new"
            case .replace(let connection): "replace-\(connection.id)"
            }
        }
    }

    let mode: Mode
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var fileName: String?
    @State private var document: KubeconfigDocument?
    @State private var context = ""
    @State private var preview: KubeconfigPreview?
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("kubeconfig") {
                        HStack {
                            Text(fileName ?? "未选择").foregroundStyle(fileName == nil ? .secondary : .primary)
                            Button("选择文件…") { choose() }
                        }
                    }
                    if let document, document.contexts.count > 1 {
                        Picker("context", selection: $context) {
                            ForEach(document.contexts, id: \.self) { Text($0).tag($0) }
                        }
                    }
                } header: {
                    Text(title)
                } footer: {
                    Text("文件内容只保存到钥匙串，不写日志，也不出现在命令行参数里。")
                }
                if let preview {
                    Section("预览") {
                        LabeledContent("集群地址", value: preview.server)
                        LabeledContent("默认 namespace", value: preview.namespace.isEmpty ? "—" : preview.namespace)
                        LabeledContent("证书到期") {
                            if let date = preview.certificateExpiresAt {
                                Text(date, format: .dateTime.year().month().day())
                            } else {
                                Text("—")
                            }
                        }
                        ForEach(preview.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                if case .new = mode {
                    Section {
                        TextField("连接名", text: $name, prompt: Text("例如 测试环境、正式环境"))
                            .accessibilityIdentifier("connection-name")
                    } footer: {
                        Text("配置里用 k8s: \(name.isEmpty ? "连接名" : name) 引用。")
                    }
                }
                if let error {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .accessibilityIdentifier("connection-import-confirm")
            }
            .padding(16)
        }
        .frame(width: 520, height: 460)
        .onChange(of: context) { makePreview() }
    }

    private var title: String {
        switch mode {
        case .new: "导入 k8s 连接"
        case .replace(let connection): "替换「\(connection.name)」的 kubeconfig"
        }
    }

    private var actionTitle: String {
        if case .new = mode { "导入" } else { "替换" }
    }

    private var canSave: Bool {
        guard preview != nil, !saving else { return false }
        if case .new = mode { return K8sConnection.normalizedName(name) != nil }
        return true
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".kube")
        panel.prompt = "选择"
        panel.message = "选择从阿里云容器服务等处下载的 kubeconfig 文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil
        preview = nil
        Task {
            do {
                let document = try await Task.detached { try KubeconfigDocument.read(url) }.value
                self.document = document
                fileName = url.lastPathComponent
                let initial = document.currentContext.flatMap { document.contexts.contains($0) ? $0 : nil } ?? document.contexts.first ?? ""
                if initial == context { makePreview() } else { context = initial }
            } catch {
                document = nil
                fileName = nil
                self.error = String(describing: error)
            }
        }
    }

    private func makePreview() {
        guard let document, !context.isEmpty else { preview = nil; return }
        let context = context
        Task {
            do {
                preview = try await Task.detached { try document.preview(context: context) }.value
                error = nil
            } catch {
                preview = nil
                self.error = String(describing: error)
            }
        }
    }

    private func save() {
        guard let preview, let service = model.service else { return }
        saving = true
        let name = name
        Task {
            defer { saving = false }
            do {
                switch mode {
                case .new: _ = try await service.importConnection(name: name, preview: preview)
                case .replace(let connection): try await service.replaceConnection(connection.id, preview: preview)
                }
                dismiss()
            } catch {
                self.error = String(describing: error)
            }
        }
    }
}
