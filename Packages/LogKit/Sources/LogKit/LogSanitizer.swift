import Foundation

public struct LogError: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// 每一路输出独立持有解析状态，先去除终端控制序列，再跨块脱敏和解码 UTF-8。
public struct LogSanitizer: Sendable {
    private var terminal = TerminalTextFilter()
    private var redactor: StreamingRedactor
    private var utf8 = UTF8Chunks()

    public init(secrets: [String] = []) throws {
        let secrets = CredentialRedaction.expand(secrets)
        let normalized = secrets.map {
            var filter = TerminalTextFilter()
            return String(decoding: filter.append(Data($0.utf8)), as: UTF8.self)
        }
        redactor = try StreamingRedactor(secrets: secrets + normalized)
    }

    public mutating func append(_ data: Data) -> String {
        utf8.append(redactor.append(terminal.append(data)))
    }

    public mutating func finish() -> String {
        let tail = utf8.append(redactor.finish())
        return tail + utf8.finish()
    }
}

private struct StreamingRedactor: Sendable {
    private let patterns: [UInt8: [[UInt8]]]
    private var pending: [UInt8] = []
    private let replacement = Array("[已隐藏]".utf8)

    init(secrets: [String]) throws {
        let unique = Set(secrets.filter { !$0.isEmpty })
        guard unique.count <= 1_000, unique.allSatisfy({ $0.utf8.count <= 65_536 }) else {
            throw LogError("用于日志脱敏的变量过多或单项超过 64 KiB，已阻止执行以免泄漏")
        }
        patterns = Dictionary(grouping: unique.map { Array($0.utf8) }, by: { $0[0] })
            .mapValues { $0.sorted { $0.count > $1.count } }
    }

    mutating func append(_ data: Data) -> Data {
        pending.append(contentsOf: data)
        return drain(final: false)
    }

    mutating func finish() -> Data { drain(final: true) }

    private mutating func drain(final: Bool) -> Data {
        var output = Data()
        var index = 0
        while index < pending.count {
            if let candidates = patterns[pending[index]] {
                let suffix = pending[index...]
                // 只保留可能组成敏感值的前缀，普通日志立即输出，不为长凭据延迟全部日志。
                if !final, candidates.contains(where: { $0.count > suffix.count && $0.starts(with: suffix) }) { break }
                if let matched = candidates.first(where: { suffix.starts(with: $0) }) {
                    output.append(contentsOf: replacement)
                    index += matched.count
                    continue
                }
            }
            output.append(pending[index])
            index += 1
        }
        if index > 0 { pending.removeFirst(index) }
        return output
    }
}

private struct UTF8Chunks: Sendable {
    private var pending = Data()

    mutating func append(_ data: Data) -> String {
        pending.append(data)
        guard !pending.isEmpty else { return "" }
        var start = pending.endIndex - 1
        var continuations = 0
        while start > pending.startIndex, (pending[start] & 0xC0) == 0x80, continuations < 3 {
            start -= 1
            continuations += 1
        }
        let lead = pending[start]
        let required: Int
        switch lead {
        case 0xC2...0xDF: required = 2
        case 0xE0...0xEF: required = 3
        case 0xF0...0xF4: required = 4
        default: required = 1
        }
        let end = pending.endIndex - start < required ? start : pending.endIndex
        let text = String(decoding: pending[..<end], as: UTF8.self)
        pending.removeSubrange(pending.startIndex..<end)
        return text
    }

    mutating func finish() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}

/// ANSI CSI、OSC（含超链接）和短转义仅作为日志数据处理，不交给终端执行。
private struct TerminalTextFilter: Sendable {
    private enum State: Sendable { case text, escape, csi, osc, oscEscape, intermediate }
    private var state = State.text
    private var previousCR = false

    mutating func append(_ data: Data) -> Data {
        var output = Data()
        for byte in data {
            switch state {
            case .text:
                if byte == 0x1B { state = .escape }
                else if byte == 13 {
                    output.append(10)
                    previousCR = true
                } else if byte == 10 {
                    if !previousCR { output.append(byte) }
                    previousCR = false
                } else {
                    if byte >= 32 || byte == 9 { output.append(byte) }
                    previousCR = false
                }
            case .escape:
                switch byte {
                case 0x5B: state = .csi
                case 0x5D: state = .osc
                case 0x20...0x2F: state = .intermediate
                default: state = .text
                }
            case .csi:
                if (0x40...0x7E).contains(byte) { state = .text }
                else if byte == 0x1B { state = .escape }
            case .osc:
                if byte == 7 { state = .text }
                else if byte == 0x1B { state = .oscEscape }
            case .oscEscape:
                state = byte == 0x5C ? .text : .osc
            case .intermediate:
                if (0x30...0x7E).contains(byte) { state = .text }
            }
        }
        return output
    }
}
