import AppKit
import SwiftUI

/// 只编译日志组件，用人工文本验证，不启动主 App、不读取项目或连接集群。
@MainActor func copyToPasteboard(_ text: String) {}

private struct LogFixture: View {
    var message: String?
    var text: String
    var body: some View {
        VStack(spacing: 0) {
            if let message { ResultBanner(message: message, failed: true) }
            NativeLogText(text: text, autoScroll: false)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@main
struct LogUIRegression {
    @MainActor static func main() {
        _ = NSApplication.shared
        let error = #"Error: Custom { kind: Other, error: "读取应用配置失败，请检查 config/config.json" }"#
        let long = String(repeating: "Pod demo-7b547476c5-zmf88 容器 demo Error（本次退出：Error，退出码 1）\n\(error)\n", count: 20)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for size in [CGSize(width: 600, height: 400), CGSize(width: 900, height: 650), CGSize(width: 480, height: 320)] {
                let host = NSHostingView(rootView: LogFixture(message: nil, text: "正常启动\n"))
                host.sizingOptions = [.minSize]
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                window.setContentSize(size)
                settle(host)
                let initial = window.frame.size
                host.rootView = LogFixture(message: long, text: "$ kubectl logs demo -n ns -c app\n\(error)\n" + String(repeating: "日志明细\n", count: 300))
                settle(host)
                require(abs(window.frame.height - initial.height) < 2 && abs(window.frame.width - initial.width) < 2,
                        "错误出现后窗口尺寸改变：\(initial) → \(window.frame.size)")
                // 模拟手动缩小，再触发追加输出和重排，不能回弹。
                let smaller = CGSize(width: size.width - 40, height: size.height - 40)
                window.setContentSize(smaller)
                host.rootView.text += "追加的容器诊断输出\n"
                settle(host)
                require(abs(window.contentLayoutRect.height - smaller.height) < 2, "缩小窗口后高度回弹")
                let textView = findTextView(host)
                require(textView?.string.contains(error) == true, "完整日志必须可读可选")
                if let view = textView, let storage = view.textStorage {
                    let location = (storage.string as NSString).range(of: error).location
                    require(storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor == .systemRed, "实际 NSTextView 中的容器错误应为红色")
                    if let scroll = view.enclosingScrollView {
                        let rect = scroll.convert(scroll.bounds, to: host)
                        require(rect.height >= smaller.height - 100, "日志滚动区必须占满摘要下方的剩余高度，不能缩在中间")
                        let bottomGap = host.isFlipped ? host.bounds.maxY - rect.maxY : rect.minY - host.bounds.minY
                        require(abs(bottomGap) < 2, "日志底部必须贴住容器底部，不能留下空白")
                    } else { require(false, "日志必须处于滚动区内") }
                    let usedWidth = view.textContainer?.size.width ?? .infinity
                    require(usedWidth <= smaller.width, "文本容器不能横向撑出窗口")
                    require(view.isSelectable && !view.isEditable, "日志应保持只读且可选择")
                }
                // 不使用 close：测试窗口未显示，释放它即可，避免 AppKit 的关闭释放行为。
                window.contentView = nil
                print("通过：\(appearance.rawValue)，\(Int(size.width))×\(Int(size.height))，错误出现与缩放后尺寸稳定")
            }
        }
        verifyStageStrip()
        verifyStyling(error)
        print("日志布局与着色回归全部通过")
    }

    @MainActor static func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12))
        view.layoutSubtreeIfNeeded()
    }

    @MainActor static func findTextView(_ view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap(findTextView).first
    }

    @MainActor static func verifyStageStrip() {
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            StageStrip {
                ForEach(0..<100) { index in
                    Button("替换 批次名称很长时也不能撑大窗口 · 服务 \(index)") {}
                        .lineLimit(1).padding(6)
                }
            }
            NativeLogText(text: "日志内容", autoScroll: false)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        })
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.setContentSize(CGSize(width: 480, height: 400))
        settle(host)
        settle(host)
        require(window.contentLayoutRect.height == 400, "大量阶段不能撑大窗口")
        if let scroll = findTextView(host)?.enclosingScrollView {
            require(scroll.frame.height >= 250, "大量阶段仍须保留日志空间")
        } else { require(false, "阶段下方日志区不存在") }
        window.contentView = nil
        print("通过：100 个长名称阶段受高度约束，日志区保留剩余空间")
    }

    @MainActor static func verifyStyling(_ error: String) {
        var styler = LogTextStyler()
        let storage = NSTextStorage(string: "正常信息\nEr")
        styler.apply(to: storage)
        storage.append(NSAttributedString(string: "ror: 配置缺失 🌟\n"))
        styler.apply(to: storage)
        let partialError = (storage.string as NSString).range(of: "Error:")
        require(storage.attribute(.foregroundColor, at: partialError.location, effectiveRange: nil) as? NSColor == .systemRed,
                "跨分块到达的错误行必须重新着色")
        let history = "正常信息\n$ kubectl logs demo --previous\n\(error)\n    配置路径和调用栈\n[本地] 诊断结束\n普通输出\n0 errors\n"
        let historical = NSTextStorage(string: history)
        var historicalStyler = LogTextStyler()
        historicalStyler.apply(to: historical)
        for value in [error, "    配置路径和调用栈"] {
            let range = (history as NSString).range(of: value)
            require(historical.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor == .systemRed, "容器诊断块应保留红色")
        }
        for value in ["正常信息", "$ kubectl", "[本地]", "普通输出", "0 errors"] {
            let range = (history as NSString).range(of: value)
            require(historical.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor == .labelColor, "普通消息或命令不应误染红")
        }
        let incremental = NSTextStorage()
        var incrementalStyler = LogTextStyler()
        for character in history {
            incremental.append(NSAttributedString(string: String(character)))
            incrementalStyler.apply(to: incremental)
        }
        for index in 0..<historical.length {
            require(incremental.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
                    == historical.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor,
                    "逐字实时追加与历史整段读取的颜色必须一致")
        }
        require(incremental.string == history, "着色不能改变日志内容")
        print("通过：实时分块、历史读取、多行容器输出、普通行恢复、Unicode 和原文保留")
    }

    static func require(_ condition: Bool, _ message: String) {
        guard condition else { fputs("失败：\(message)\n", stderr); exit(1) }
    }
}
