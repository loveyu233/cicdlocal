import ApplicationKit
import Models
import SwiftUI

/// k8s 连接：导入 kubeconfig 并命名，配置里的 `k8s:` 按这个名字引用。kubeconfig 只存在钥匙串里。
struct ConnectionsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: K8sConnectionID?
    @State private var importing: ConnectionImportSheet.Mode?
    @State private var renaming: K8sConnection?
    @State private var newName = ""
    @State private var deleting: K8sConnection?
    @State private var deletingReferences: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            table
            Divider()
            HStack(spacing: 8) {
                Button("导入", systemImage: "plus") { importing = .new }
                    .accessibilityIdentifier("import-connection")
                Button("删除", systemImage: "minus") { selected.map(prepareDelete) }
                    .disabled(selected == nil)
                Menu("更多", systemImage: "ellipsis") {
                    if let connection = selected { actions(connection) }
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(selected == nil)
                Spacer()
                Text("配置里写 k8s: 连接名 来选择替换到哪个环境")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(8)
        }
        .sheet(item: $importing) { mode in
            ConnectionImportSheet(mode: mode)
        }
        .alert("重命名连接", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { connection in
            TextField("连接名", text: $newName)
            Button("重命名") {
                let name = newName
                model.perform("rename-\(connection.id)") { _ = try await $0.renameConnection(connection.id, to: name) }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("引用旧名字的项目配置需要同步修改，否则替换时会提示连接不存在。")
        }
        .confirmationDialog("删除「\(deleting?.name ?? "")」？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { connection in
            Button("删除连接", role: .destructive) {
                model.perform("delete-\(connection.id)") { try await $0.deleteConnection(connection.id) }
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            if deletingReferences.isEmpty {
                Text("钥匙串里保存的 kubeconfig 一并删除。")
            } else {
                Text("这些项目的配置还在使用它：\(deletingReferences.joined(separator: "、"))。删除后这些项目替换到这个环境时会失败。")
            }
        }
    }

    private var selected: K8sConnection? { model.connections.first { $0.id == selection } }

    private var table: some View {
        Table(model.connections, selection: $selection) {
            TableColumn("名称") { Text($0.name).fontWeight(.medium) }
                .width(min: 80, ideal: 100)
            TableColumn("集群地址") { Text($0.metadata.server).lineLimit(1).truncationMode(.middle) }
                .width(min: 140, ideal: 200)
            TableColumn("context") { Text($0.metadata.context).lineLimit(1) }
                .width(min: 80, ideal: 100)
            TableColumn("证书到期") { connection in
                if let date = connection.metadata.certificateExpiresAt {
                    Text(date, format: .dateTime.year().month().day())
                        .foregroundStyle(date < Date().addingTimeInterval(14 * 86_400) ? Color.orange : Color.primary)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 90)
            TableColumn("导入时间") { Text($0.metadata.importedAt, format: .dateTime.year().month().day()) }
                .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: K8sConnectionID.self) { ids in
            if let connection = model.connections.first(where: { ids.contains($0.id) }) { actions(connection) }
        }
        .overlay {
            if model.connections.isEmpty {
                ContentUnavailableView {
                    Label("还没有 k8s 连接", systemImage: "server.rack")
                } description: {
                    Text("导入测试环境、正式环境等 kubeconfig 并分别命名。")
                } actions: {
                    Button("导入 kubeconfig…") { importing = .new }
                }
            }
        }
        .accessibilityIdentifier("connection-table")
    }

    @ViewBuilder private func actions(_ connection: K8sConnection) -> some View {
        Button("重命名…") {
            newName = connection.name
            renaming = connection
        }
        Button("替换 kubeconfig…") { importing = .replace(connection) }
        Divider()
        Button("删除…", role: .destructive) { prepareDelete(connection) }
    }

    private func prepareDelete(_ connection: K8sConnection) {
        model.perform("references-\(connection.id)") { service in
            deletingReferences = try await service.projectsReferencing(connectionName: connection.name)
            deleting = connection
        }
    }
}
