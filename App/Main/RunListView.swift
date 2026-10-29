import ApplicationKit
import Models
import Storage
import SwiftUI

/// 中栏：项目概览入口和最近的运行。
struct RunListView: View {
    let project: Project
    let service: ApplicationService
    @Environment(AppModel.self) private var model
    @State private var runs: [Run] = []

    var body: some View {
        @Bindable var model = model
        List(selection: $model.detail) {
            Label("项目概览", systemImage: "doc.text.magnifyingglass")
                .tag(Detail.overview)
                .accessibilityIdentifier("project-overview-row")
            Section("运行") {
                ForEach(runs) { run in
                    RunRow(run: run).tag(Detail.run(run.id))
                }
            }
        }
        .accessibilityIdentifier("run-list")
        .overlay {
            if runs.isEmpty {
                ContentUnavailableView {
                    Label("还没有运行", systemImage: "arrow.up.circle")
                } description: {
                    Text("开启推送监听后，git push 到配置里的分支就会出现在这里。")
                }
                .padding(.top, 40)
            }
        }
        .navigationTitle(project.name)
        .task(id: project.id) {
            runs = []
            do {
                for try await runs in service.database.observeRuns(projectID: project.id, limit: 100) {
                    withAnimation(.snappy) { self.runs = runs }
                }
            } catch {
                model.errorMessage = "读取运行列表失败：\(error)"
            }
        }
    }
}

private struct RunRow: View {
    let run: Run

    var body: some View {
        // 图标对整行上下居中；分支和提交号按文字基线对齐。
        HStack(spacing: 10) {
            StatusSymbol(run.status)
                .font(.title3)
                .frame(width: 22)
                .help(run.status.title)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(run.branch).fontWeight(.medium).lineLimit(1)
                    Text(run.commit.short)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if run.rerunOf != nil {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("重新运行或重新替换")
                    }
                }
                if let subject = run.commitSubject {
                    Text(subject)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(run.commitMessage ?? subject)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let tag = run.imageTag {
                        Text(tag).font(.caption.monospaced())
                    } else {
                        Text(run.status.title).font(.caption)
                    }
                    Spacer(minLength: 4)
                    Text(run.createdAt, format: .relative(presentation: .named))
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("run-row")
    }
}
