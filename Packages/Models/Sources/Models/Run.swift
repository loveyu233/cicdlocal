import Foundation

/// 一次运行：某个分支推送后按 `.local.cicd.yml` 执行的测试 → 构建推送 → 替换。
public struct Run: Identifiable, Hashable, Sendable, Codable {
    public var id: RunID
    public var projectID: ProjectID
    /// 由推送触发时对应的引用更新；重新运行时为空。
    public var refUpdateID: RefUpdateID?
    /// 重新运行时指向原来的运行。
    public var rerunOf: RunID?
    public var branch: String
    public var commit: CommitSHA
    /// 提交说明；读取失败或早期版本创建的运行为空。
    public var commitMessage: String?
    /// 变量展开后的镜像地址汇总；多镜像的逐项信息和 digest 保存在执行计划里。
    public var image: String?
    /// 运行开始前固定下来的执行计划（JSON），重新运行和确认替换都按它执行，不再读取配置文件。
    public var plan: String?
    public var status: RunStatus
    /// 配置错误、HEAD 不一致等不执行任何命令的原因，或者最终的失败摘要。
    public var message: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: RunID,
        projectID: ProjectID,
        refUpdateID: RefUpdateID? = nil,
        rerunOf: RunID? = nil,
        branch: String,
        commit: CommitSHA,
        commitMessage: String? = nil,
        image: String? = nil,
        plan: String? = nil,
        status: RunStatus = .queued,
        message: String? = nil,
        createdAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.refUpdateID = refUpdateID
        self.rerunOf = rerunOf
        self.branch = branch
        self.commit = commit
        self.commitMessage = commitMessage
        self.image = image
        self.plan = plan
        self.status = status
        self.message = message
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public enum RunStatus: String, CaseIterable, Hashable, Sendable, Codable {
    case queued
    case running
    /// 命令都执行完了，还有需要确认的替换目标。
    case waiting
    case succeeded
    case failed
    case canceled
    /// App 退出时正在运行，重启后标记。
    case interrupted

    public var title: String {
        switch self {
        case .queued: "排队中"
        case .running: "运行中"
        case .waiting: "等待确认"
        case .succeeded: "成功"
        case .failed: "失败"
        case .canceled: "已取消"
        case .interrupted: "已中断"
        }
    }

    /// 不会再变化（等待确认的运行还会变化）。
    public var isFinished: Bool { [.succeeded, .failed, .canceled, .interrupted].contains(self) }

    /// 按阶段状态汇总运行状态；还有阶段没执行完时返回 nil。
    public static func settled(_ stages: [StageStatus]) -> RunStatus? {
        if stages.contains(.running) { return nil }
        if stages.contains(.waiting) { return .waiting }
        if stages.contains(.pending) { return nil }
        if stages.contains(.failed) { return .failed }
        if stages.contains(.canceled) { return .canceled }
        return .succeeded
    }
}

/// 固定三类阶段：测试一条、构建推送每个镜像一条、替换每个目标一条。
public struct RunStage: Identifiable, Hashable, Sendable, Codable {
    public var id: RunStageID
    public var runID: RunID
    /// 仅用于显示和日志目录排序，不推导镜像或目标绑定。
    public var ordinal: Int
    public var kind: StageKind
    public var title: String
    /// 执行计划中的构建或替换目标标识，不能通过序号推导绑定。
    public var targetKey: String?
    public var status: StageStatus
    public var message: String?
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(
        id: RunStageID,
        runID: RunID,
        ordinal: Int,
        kind: StageKind,
        title: String,
        targetKey: String? = nil,
        status: StageStatus = .pending,
        message: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.ordinal = ordinal
        self.kind = kind
        self.title = title
        self.targetKey = targetKey
        self.status = status
        self.message = message
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

}

public enum StageKind: String, CaseIterable, Hashable, Sendable, Codable {
    case test
    case build
    case deploy

    public var title: String {
        switch self {
        case .test: "测试"
        case .build: "构建推送"
        case .deploy: "替换"
        }
    }
}

public enum StageStatus: String, CaseIterable, Hashable, Sendable, Codable {
    case pending
    case running
    /// 需要在 App 里确认替换。
    case waiting
    case succeeded
    case failed
    case canceled
    /// 没有测试命令、前一阶段失败或用户选择跳过。
    case skipped
    /// 早期版本：同一目标有更新的运行时，旧的等待确认会过期。现在不再产生，只用于显示旧记录。
    case expired

    public var title: String {
        switch self {
        case .pending: "未开始"
        case .running: "运行中"
        case .waiting: "等待确认"
        case .succeeded: "成功"
        case .failed: "失败"
        case .canceled: "已取消"
        case .skipped: "已跳过"
        case .expired: "已过期"
        }
    }

    public var isFinished: Bool { ![.pending, .running, .waiting].contains(self) }
}
