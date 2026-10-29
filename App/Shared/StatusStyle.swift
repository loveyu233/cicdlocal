import AppKit
import Models
import Runner
import SwiftUI

extension RunStatus {
    var symbol: String {
        switch self {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .waiting: "hand.raised.fill"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .canceled: "stop.circle"
        case .interrupted: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .queued, .canceled: .secondary
        case .running: .accentColor
        case .waiting, .interrupted: .orange
        case .succeeded: .green
        case .failed: .red
        }
    }
}

extension StageStatus {
    var symbol: String {
        switch self {
        case .pending: "circle.dashed"
        case .running: "arrow.triangle.2.circlepath"
        case .waiting: "hand.raised.fill"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .canceled: "stop.circle"
        case .skipped: "arrow.uturn.forward.circle"
        case .expired: "clock.badge.xmark"
        }
    }

    var tint: Color {
        switch self {
        case .pending, .canceled, .skipped, .expired: .secondary
        case .running: .accentColor
        case .waiting: .orange
        case .succeeded: .green
        case .failed: .red
        }
    }
}

/// 状态图标：运行中旋转、等待确认轻微跳动，状态变化时替换动画；遵守「减少动态效果」。
struct StatusSymbol: View {
    let symbol: String
    let tint: Color
    var active = false
    var waiting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
            .symbolRenderingMode(.hierarchical)
            .symbolEffect(.rotate, isActive: active && !reduceMotion)
            .symbolEffect(.pulse, isActive: waiting && !reduceMotion)
            .contentTransition(.symbolEffect(.replace))
    }
}

extension StatusSymbol {
    init(_ status: RunStatus) {
        self.init(symbol: status.symbol, tint: status.tint, active: status == .running, waiting: status == .waiting)
    }

    init(_ status: StageStatus) {
        self.init(symbol: status.symbol, tint: status.tint, active: status == .running, waiting: status == .waiting)
    }
}

/// 耗时：进行中每秒刷新，数字变化用数字过渡。
struct ElapsedText: View {
    let start: Date?
    let end: Date?

    var body: some View {
        if let start {
            TimelineView(.periodic(from: start, by: 1)) { context in
                Text(Self.format((end ?? context.date).timeIntervalSince(start)))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return seconds < 3600
            ? String(format: "%d:%02d", seconds / 60, seconds % 60)
            : String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

extension Run {
    /// 镜像标签（冒号后面的部分），列表里显示用。
    var imageTag: String? {
        if let plan, let decoded = try? JSONDecoder().decode(RunPlan.self, from: Data(plan.utf8)), decoded.images.count > 1 {
            return "\(decoded.images.count) 个镜像"
        }
        guard let image, let colon = image.lastIndex(of: ":"), !image[colon...].contains("/") else { return nil }
        return String(image[image.index(after: colon)...])
    }
    /// 提交说明的第一行，列表里显示用。
    var commitSubject: String? {
        commitMessage?.split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
