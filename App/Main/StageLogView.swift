import ApplicationKit
import Models
import SwiftUI

/// 一个阶段的日志：运行中实时追加，结束后读取保存的日志。
struct StageLogView: View {
    let stage: RunStage
    let service: ApplicationService
    @State private var text = ""
    @State private var live = false
    @State private var truncated = false
    @State private var loaded = false
    @State private var error: String?

    private struct LoadKey: Equatable {
        var id: RunStageID
        var status: StageStatus
    }

    var body: some View {
        VStack(spacing: 0) {
            if let result {
                result
                Divider()
            }
            NativeLogText(text: text)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .overlay { placeholder }
            Divider()
            HStack(spacing: 12) {
                Text(live ? "实时输出" : "历史日志")
                if truncated {
                    Text("日志达到保存上限，后续输出已截断").foregroundStyle(.orange)
                }
                Spacer()
                Button("拷贝日志", systemImage: "doc.on.doc") { copyToPasteboard(text) }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderless)
                    .disabled(text.isEmpty)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: LoadKey(id: stage.id, status: stage.status)) { await load() }
    }

    /// 替换阶段结束后的结论放在日志上方：失败时是哪个 Pod 怎么失败的和日志里的报错，成功时是确认了什么。
    /// 测试、构建失败只有「失败，详见日志」，原因就在日志末尾，不重复显示。
    private var result: ResultBanner? {
        let failed = stage.status == .failed
        guard let message = stage.message, failed || (stage.status == .succeeded && stage.kind == .deploy),
              !message.hasSuffix("详见日志") else { return nil }
        return ResultBanner(message: message, failed: failed)
    }

    @ViewBuilder private var placeholder: some View {
        if let error {
            ContentUnavailableView("无法读取日志", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if loaded, text.isEmpty {
            switch stage.status {
            case .pending:
                ContentUnavailableView("尚未开始", systemImage: "circle.dashed")
            case .waiting:
                // 未确认的等待由运行详情显示确认面板，走到这里的是已确认、排队中的阶段。
                ContentUnavailableView("已确认", systemImage: "clock", description: Text("排队等待替换，开始后这里显示 kubectl 的输出。"))
            case .skipped, .expired, .canceled:
                ContentUnavailableView(stage.status.title, systemImage: stage.status.symbol, description: stage.message.map(Text.init))
            default:
                ContentUnavailableView("没有日志", systemImage: "doc.plaintext")
            }
        }
    }

    private func load() async {
        error = nil
        if stage.status == .running {
            // 阶段刚切到运行中时日志可能还没创建，稍等片刻。
            for _ in 0..<50 {
                if let store = await service.liveLog(stage.id) {
                    live = true
                    loaded = true
                    for await snapshot in await store.updates() {
                        text = snapshot.text
                        truncated = snapshot.truncated
                        if snapshot.finished { break }
                    }
                    live = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
        }
        live = false
        let service = service, runID = stage.runID, ordinal = stage.ordinal
        do {
            let stored = try await Task.detached { try service.storedLog(run: runID, ordinal: ordinal) }.value
            guard !Task.isCancelled else { return }
            text = stored ?? ""
            truncated = false
        } catch {
            self.error = String(describing: error)
        }
        loaded = true
    }
}
