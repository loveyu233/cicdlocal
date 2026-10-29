/// Git 对象 ID：40 位（SHA-1）或 64 位（SHA-256）小写十六进制。
public struct CommitSHA: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    /// 全零 SHA，pre-push 用它表示“远端没有该引用”或“删除引用”。
    public static let zero = CommitSHA(unchecked: String(repeating: "0", count: 40))

    public init?(rawValue: String) {
        let lower = rawValue.lowercased()
        guard lower.count == 40 || lower.count == 64,
              lower.allSatisfy({ $0.isHexDigit && $0.isASCII })
        else { return nil }
        self.rawValue = lower
    }

    private init(unchecked: String) {
        rawValue = unchecked
    }

    /// 前 8 位，用于界面显示；配置里的 `${SHA}` 使用前 12 位。
    public var short: String { String(rawValue.prefix(8)) }

    public var isZero: Bool { rawValue.allSatisfy { $0 == "0" } }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let sha = CommitSHA(rawValue: text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "不是合法的提交 SHA：\(text)")
        }
        self = sha
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
