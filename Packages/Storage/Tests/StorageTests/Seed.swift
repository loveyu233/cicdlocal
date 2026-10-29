import Foundation
import Models
@testable import Storage

/// 测试数据。时间取整秒：GRDB 以毫秒精度的文本存储日期，整秒可以精确往返。
enum Sample {
    static let date = Date(timeIntervalSince1970: 1_790_000_000)
    static let later = Date(timeIntervalSince1970: 1_790_000_060)
    static let sha1 = CommitSHA(rawValue: "0123456789abcdef0123456789abcdef01234567")!
    static let sha2 = CommitSHA(rawValue: "89abcdef0123456789abcdef0123456789abcdef")!

    static func project(_ name: String = "cicddemo") -> Project {
        Project(id: .unsaved, name: name, repositoryPath: "/tmp/\(name)", hookMode: .configHook, createdAt: date)
    }

    static func pushEvent(projectID: ProjectID, spoolID: String = "6F1C0A9E-1111-4C1E-9D52-8E0A3E7B1F00")
        -> PushEvent
    {
        PushEvent(
            id: .unsaved, projectID: projectID, spoolEventID: spoolID, remoteName: "origin",
            remoteURL: "git@example.com:demo/cicddemo.git", receivedAt: date)
    }

    static func refUpdate(ref: String = "refs/heads/main") -> RefUpdate {
        RefUpdate(
            id: .unsaved, pushEventID: .unsaved, dedupKey: "", remoteRef: ref,
            oldSHA: sha1, newSHA: sha2, isForced: false, confirmation: .pending, confirmedBy: nil)
    }

    static func run(projectID: ProjectID, refUpdateID: RefUpdateID? = nil, branch: String = "main") -> Run {
        Run(
            id: .unsaved, projectID: projectID, refUpdateID: refUpdateID, branch: branch, commit: sha2,
            image: "registry.example.invalid/demo:20260922.1013", plan: #"{"targets":[]}"#, createdAt: date)
    }

    /// 测试、构建推送和给出的替换目标。
    static func stages(targets: [String] = ["测试环境/demo/cicddemo/cicddemo"]) -> [RunStage] {
        [
            RunStage(id: .unsaved, runID: .unsaved, ordinal: 0, kind: .test, title: StageKind.test.title),
            RunStage(id: .unsaved, runID: .unsaved, ordinal: 1, kind: .build, title: StageKind.build.title),
        ]
            + targets.enumerated().map { index, key in
                RunStage(
                    id: .unsaved, runID: .unsaved, ordinal: index + 2, kind: .deploy, title: "替换到 \(key)",
                    targetKey: key)
            }
    }

    static func metadata() -> KubeconfigMetadata {
        KubeconfigMetadata(
            context: "test-context", server: "https://cluster-one.example.invalid:6443", namespace: "demo",
            certificateExpiresAt: later, byteCount: 2_048, importedAt: date)
    }

    static func connection(_ name: String = "测试环境") -> K8sConnection {
        K8sConnection(id: .unsaved, name: name, account: K8sConnection.newAccount(), metadata: metadata(), createdAt: date)
    }
}

/// 一条完整的「推送 → 运行 → 阶段」数据。
struct Seeded {
    var project: Project
    var event: PushEvent
    var refUpdate: RefUpdate
    var run: Run
    var stages: [RunStage]
}

extension AppDatabase {
    func seed(projectName: String = "cicddemo", targets: [String] = ["测试环境/demo/cicddemo/cicddemo"])
        async throws -> Seeded
    {
        let project = try await createProject(Sample.project(projectName))
        guard
            case .recorded(let event, let updates) = try await recordPushEvent(
                Sample.pushEvent(projectID: project.id, spoolID: "spool-\(projectName)"),
                refUpdates: [Sample.refUpdate()])
        else { throw SeedError() }
        guard
            let run = try await createRun(
                Sample.run(projectID: project.id, refUpdateID: updates[0].id), stages: Sample.stages(targets: targets))
        else { throw SeedError() }
        return Seeded(project: project, event: event, refUpdate: updates[0], run: run, stages: try await stages(runID: run.id))
    }
}

struct SeedError: Error {}

/// 每个测试一个独立的临时目录，结束后删除。
struct TemporaryDirectory: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "localcicd-storage-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
