import Foundation

/// 推送中的单个引用更新。每个确认成功的分支推送最多创建一次运行，按 `dedupKey` 去重。
public struct RefUpdate: Identifiable, Hashable, Sendable, Codable {
    public var id: RefUpdateID
    public var pushEventID: PushEventID
    /// 仓储写入时生成的事件 ID 与引用序号组合键。
    /// 同一事件重复投递只处理一次；新事件允许再次推送相同提交。
    public var dedupKey: String
    /// 远端引用全名，例如 `refs/heads/main`、`refs/tags/v1.0`。
    public var remoteRef: String
    public var oldSHA: CommitSHA
    public var newSHA: CommitSHA
    public var isForced: Bool
    public var confirmation: RefUpdateConfirmation
    /// 确认来源；未确认时为空。
    public var confirmedBy: ConfirmationLayer?
    public var confirmationReason: String?
    /// 标签引用可指向附注标签对象；这里记录剥离后的提交，不改变原始推送对象 ID。
    public var resolvedCommitSHA: CommitSHA?

    public init(
        id: RefUpdateID,
        pushEventID: PushEventID,
        dedupKey: String,
        remoteRef: String,
        oldSHA: CommitSHA,
        newSHA: CommitSHA,
        isForced: Bool = false,
        confirmation: RefUpdateConfirmation = .pending,
        confirmedBy: ConfirmationLayer? = nil,
        confirmationReason: String? = nil,
        resolvedCommitSHA: CommitSHA? = nil
    ) {
        self.id = id
        self.pushEventID = pushEventID
        self.dedupKey = dedupKey
        self.remoteRef = remoteRef
        self.oldSHA = oldSHA
        self.newSHA = newSHA
        self.isForced = isForced
        self.confirmation = confirmation
        self.confirmedBy = confirmedBy
        self.confirmationReason = confirmationReason
        self.resolvedCommitSHA = resolvedCommitSHA
    }

    public var kind: RefUpdateKind {
        if newSHA.isZero { return .delete }
        if oldSHA.isZero { return .create }
        return .update
    }

    public var isTag: Bool { remoteRef.hasPrefix("refs/tags/") }

    /// 去掉 `refs/heads/`、`refs/tags/` 前缀后的名字。
    public var shortRefName: String {
        for prefix in ["refs/heads/", "refs/tags/"] where remoteRef.hasPrefix(prefix) {
            return String(remoteRef.dropFirst(prefix.count))
        }
        return remoteRef
    }

    /// 推送的分支名；标签和其他引用不触发运行。
    public var branch: String? {
        remoteRef.hasPrefix("refs/heads/") ? String(remoteRef.dropFirst("refs/heads/".count)) : nil
    }

    /// 确认推送成功的分支（不含删除）才可能创建运行，是否真的运行还要看配置里有没有这个分支。
    public var createsRun: Bool { confirmation == .confirmed && kind != .delete && branch != nil }
}

public enum RefUpdateKind: String, CaseIterable, Hashable, Sendable, Codable {
    case create
    case update
    case delete
}

/// 推送结果的确认状态。
public enum RefUpdateConfirmation: String, CaseIterable, Hashable, Sendable, Codable {
    case pending
    case confirmed
    /// 远端拒绝，不触发。
    case rejected
    /// 无法确认（例如网络中断），不触发。
    case unconfirmable
}

/// 推送结果的确认来源。
public enum ConfirmationLayer: String, CaseIterable, Hashable, Sendable, Codable {
    /// A 层：reference-transaction 钩子记录。
    case referenceTransaction = "reference_transaction"
    /// B 层：跟踪引用 reflog 中的 “update by push”（权威）。
    case reflog
    /// C 层：`git ls-remote` 核对。
    case lsRemote = "ls_remote"
}
