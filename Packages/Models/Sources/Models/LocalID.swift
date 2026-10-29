/// 本地自增 ID，带实体类型标记，防止把运行 ID 传给需要项目 ID 的地方。
///
/// 界面显示为 `L-18`，前缀 `L-` 表示“本地”。
public struct LocalID<Entity>: RawRepresentable, Hashable, Comparable, Sendable, Codable,
    CustomStringConvertible
{
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }

    /// 尚未写入数据库的占位 ID。仓储插入时忽略它，由数据库分配真实 ID。
    public static var unsaved: Self { Self(0) }

    public var isUnsaved: Bool { rawValue == 0 }

    /// 界面显示的形式，例如 `L-18`。
    public var display: String { "L-\(rawValue)" }

    public var description: String { display }

    /// 解析界面形式 `L-18`；也接受纯数字。
    public init?(display text: String) {
        let digits = text.hasPrefix("L-") ? text.dropFirst(2) : Substring(text)
        guard let value = Int64(digits), value > 0 else { return nil }
        self.rawValue = value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    // 编码为单个整数，与数据库列一致。
    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public typealias ProjectID = LocalID<Project>
public typealias PushEventID = LocalID<PushEvent>
public typealias RefUpdateID = LocalID<RefUpdate>
public typealias RunID = LocalID<Run>
public typealias RunStageID = LocalID<RunStage>
public typealias K8sConnectionID = LocalID<K8sConnection>
