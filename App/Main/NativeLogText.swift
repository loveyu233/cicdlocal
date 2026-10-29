import AppKit
import SwiftUI

/// 整段日志放在一个只读文本区里：按窗口宽度自动换行，可以跨行连续选择、复制，⌘F 查找。
/// 实时输出只追加新增部分，不打断正在进行的选择和阅读。
struct NativeLogText: NSViewRepresentable {
    let text: String
    var autoScroll = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.setAccessibilityLabel("阶段日志滚动区")
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 12, height: 10)
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineBreakMode = .byWordWrapping
        view.font = Self.font
        view.textColor = .labelColor
        view.setAccessibilityLabel("阶段日志")
        view.setAccessibilityIdentifier("stage-log-text")
        return scroll
    }

    /// 日志是填充剩余空间的滚动区；内容长度不能成为窗口的最小尺寸。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0,
               height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 0)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        let previous = context.coordinator.text
        guard previous != text else { return }
        context.coordinator.text = text
        storage.beginEditing()
        if !previous.isEmpty, text.utf8.starts(with: previous.utf8) {
            let appended = String(decoding: text.utf8.dropFirst(previous.utf8.count), as: UTF8.self)
            storage.append(NSAttributedString(string: appended, attributes: Self.attributes))
        } else {
            storage.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
            context.coordinator.styler = LogTextStyler()
        }
        context.coordinator.styler.apply(to: storage)
        storage.endEditing()
        if autoScroll, storage.length > 0 {
            view.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        }
    }

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private static let attributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.15
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }()

    final class Coordinator {
        var text = ""
        var styler = LogTextStyler()
    }
}
