import AppKit

/// 仅为显示着色，不用日志文字推断运行结果。状态仍由执行器的结构化结果决定。
/// 容器诊断块以 kubectl logs 命令开始，到下一条本地消息或命令结束；兼容已保存的纯文本日志。
struct LogTextStyler {
    private var completedLength = 0
    private var containerOutput = false
    private static let errorLine = try! NSRegularExpression(
        pattern: #"(?i)^\s*(?:(?:\d{4}-\d{2}-\d{2}[T ][\d:.+Z-]+|\[[^\]\r\n]+\])\s*)*(?:(?:error|fatal|panic|exception)\b|错误[：:]|失败[：:])|\"(?:level|severity)\"\s*:\s*\"(?:error|fatal|panic)\""#)

    mutating func apply(to storage: NSTextStorage) {
        let text = storage.string as NSString
        var cursor = completedLength
        while cursor < text.length {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: cursor, length: 0))
            let range = NSRange(location: start, length: end - start)
            let line = text.substring(with: NSRange(location: start, length: contentsEnd - start))
            let command = line.hasPrefix("$ ")
            let local = line.hasPrefix("[本地]")
            let isContainerCommand = line.hasPrefix("$ kubectl logs ")
            let inContainer = !command && !local && containerOutput
            let error = !command && !local && Self.errorLine.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
            storage.addAttribute(.foregroundColor, value: inContainer || error ? NSColor.systemRed : NSColor.labelColor, range: range)
            // 未收到换行的尾行，下次从头重算，避免分块到达的「Er」+「ror」漏着色。
            if end > contentsEnd {
                if command || local { containerOutput = isContainerCommand }
                completedLength = end
            }
            cursor = end
        }
    }
}
