import Foundation
import Models
import Platform
import Runner
import Testing
@testable import ApplicationKit

/// 只由 scripts/test-cicddemo.py 启用：在 cicddemo 隔离副本上用登录 shell 真实执行 go 测试、docker 构建推送
/// （推到脚本启动的 127.0.0.1 临时仓库），替换阶段用假 kubectl。结果写到验证目录的 result.json，由脚本核对。
@Suite("cicddemo 真实三阶段", .enabled(if: ProcessInfo.processInfo.environment["LOCALCICD_CICDDEMO_ROOT"] != nil))
struct CicddemoAcceptanceTests {
    @Test("push main：测试、构建推送、替换测试环境")
    func pushMain() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOCALCICD_CICDDEMO_ROOT"]))
        let repository = root.appending(path: "repository")
        let source = try #require(ProcessInfo.processInfo.environment["LOCALCICD_TEST_SOURCE"])
        guard URL(fileURLWithPath: source).lastPathComponent == "cicddemo",
            root.resolvingSymlinksInPath() == root, root.deletingLastPathComponent().lastPathComponent == ".test-repos",
            root.lastPathComponent.hasPrefix("cicddemo-accept-"),
            try String(contentsOf: repository.appending(path: ".git/localcicd-test-source"), encoding: .utf8)
                == source
        else { throw ApplicationError("验收只能使用 cicddemo 的隔离副本") }

        // 和 App 一样读登录 shell 的环境，只把假 kubectl 所在目录放到 PATH 最前面。
        let bin = root.appending(path: "bin").path
        let service = try ApplicationService(
            paths: AppPaths(applicationSupport: root.appending(path: "support")), secrets: InMemorySecretStore(),
            environment: {
                var environment = try await ShellEnvironment.capture()
                environment.variables["PATH"] = bin + ":" + (environment.variables["PATH"] ?? "/usr/bin:/bin")
                return environment
            })
        do {
            let project = try await service.addProject(path: repository.path)
            let preview = try KubeconfigDocument.read(root.appending(path: "kube/staging.yaml")).preview(context: "staging")
            _ = try await service.importConnection(name: "测试环境", preview: preview)

            let sha = try #require(CommitSHA(rawValue: try String(contentsOf: root.appending(path: "pushed-sha"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
            let event = PushEvent(id: .unsaved, projectID: project.id, spoolEventID: UUID().uuidString, remoteName: "origin",
                                  remoteURL: root.appending(path: "remote.git").absoluteString, receivedAt: Date())
            let update = RefUpdate(id: .unsaved, pushEventID: .unsaved, dedupKey: "", remoteRef: "refs/heads/main",
                                   oldSHA: .zero, newSHA: sha, confirmation: .confirmed, confirmedBy: .reflog)
            guard case .recorded(_, let updates) = try await service.database.recordPushEvent(event, refUpdates: [update]) else {
                throw ApplicationError("推送事件重复")
            }
            try await service.dispatch(updates[0], project: project)
            let runID = try #require(try await service.database.pushDispatch(updates[0].id)?.runID)

            var run = try #require(try await service.database.run(runID))
            for _ in 0..<1_200 where [.queued, .running].contains(run.status) {
                try await Task.sleep(for: .milliseconds(500))
                run = try #require(try await service.database.run(runID))
            }
            let stages = try await service.database.stages(runID: runID)
            let logs = try stages.map { try service.storedLog(run: runID, ordinal: $0.ordinal) ?? "" }
            let plan = try JSONDecoder().decode(RunPlan.self, from: Data(try #require(run.plan).utf8))
            let result: [String: Any] = [
                "images": plan.images.map { ["name": $0.name, "image": $0.image, "digest": $0.digest ?? "", "reference": $0.reference ?? ""] },
                "status": run.status.rawValue, "message": run.message ?? "", "image": run.image ?? "", "sha": run.commit.rawValue,
                "stages": stages.map { ["ordinal": $0.ordinal, "kind": $0.kind.rawValue, "status": $0.status.rawValue, "message": $0.message ?? ""] },
                "logs": logs,
            ]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appending(path: "result.json"))
            #expect(run.status == .succeeded, "\(run.message ?? "")")
        } catch {
            await service.shutdown()
            throw error
        }
        await service.shutdown()
    }
}
