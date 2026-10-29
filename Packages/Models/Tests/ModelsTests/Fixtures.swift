import Foundation
@testable import Models

/// 测试用的固定数据。时间取整秒，避免 JSON 往返时的精度误差。
enum Fixtures {
    static let date = Date(timeIntervalSince1970: 1_790_000_000)
    static let sha1 = CommitSHA(rawValue: "0123456789abcdef0123456789abcdef01234567")!
    static let sha2 = CommitSHA(rawValue: "89abcdef0123456789abcdef0123456789abcdef")!

    static let refUpdate = RefUpdate(
        id: .init(3), pushEventID: .init(2), dedupKey: "1|origin|refs/heads/main|\(sha1)|\(sha2)",
        remoteRef: "refs/heads/main", oldSHA: sha1, newSHA: sha2, isForced: false,
        confirmation: .pending, confirmedBy: nil)
}
