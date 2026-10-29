import Foundation

/// 一次 `git push`，由 pre-push 钩子写入 spool。每个被推送的引用对应一条 `RefUpdate`。
public struct PushEvent: Identifiable, Hashable, Sendable, Codable {
    public var id: PushEventID
    public var projectID: ProjectID
    /// spool 文件中的事件 ID（钩子生成的 UUID），用于重复扫描时识别同一事件。
    public var spoolEventID: String
    public var remoteName: String
    /// 远端 URL。保存前去掉其中的用户名和密码。
    public var remoteURL: String
    public var receivedAt: Date

    public init(
        id: PushEventID,
        projectID: ProjectID,
        spoolEventID: String,
        remoteName: String,
        remoteURL: String,
        receivedAt: Date
    ) {
        self.id = id
        self.projectID = projectID
        self.spoolEventID = spoolEventID
        self.remoteName = remoteName
        self.remoteURL = remoteURL
        self.receivedAt = receivedAt
    }
}
