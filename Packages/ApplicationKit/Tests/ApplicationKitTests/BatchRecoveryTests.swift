import Foundation
import Models
import Platform
import Runner
import Storage
import Testing
@testable import ApplicationKit

@Suite("批次持久化与限流", .serialized)
struct BatchRecoveryTests {
    private struct Saved: Sendable {
        let root: URL
        let id: RunID
        let secrets: any SecretStore
        let images: [RunPlan.Image]
    }

    /// 返回前释放原服务和实例锁，随后真正重新打开数据库。
    private func prepareWaiting(config: String = Fixture.multi, legacyPending: Bool = false) async throws -> Saved {
        let f = try await Fixture(config: config)
        let id = try #require(try await f.push("dev").runID)
        _ = try await f.wait(id, for: [.waiting])
        let plan = try await f.plan(id)
        if legacyPending {
            var last = try #require(try await f.stages(id).last)
            last.status = .pending
            last.message = nil
            try await f.service.database.updateStage(last)
        }
        await f.service.shutdown()
        return Saved(root: f.root, id: id, secrets: await f.service.secrets, images: plan.images)
    }

    @Test("恢复旧版串行遗留的后批，未执行的确认需重新确认且可逆序部署")
    func recoverIndependentWaiting() async throws {
        let saved = try await prepareWaiting(config: Fixture.independent, legacyPending: true)
        let root = saved.root
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try ApplicationService(paths: AppPaths(applicationSupport: root.appending(path: "support")), secrets: saved.secrets,
            environment: { ShellEnvironment(shell: "/bin/sh", variables: ["PATH": "\(root.appending(path: "bin").path):/usr/bin:/bin",
                                                                          "HOME": root.path, "RECORD": root.appending(path: "record.txt").path]) })
        do {
            // 模拟上次已点击但尚未执行的确认，不能在重启时静默部署。
            var stage = try await service.database.stages(runID: saved.id)[3]
            stage.message = ApplicationService.confirmedMessage
            try await service.database.updateStage(stage)
            await service.shortenDeploymentObservation()
            try await service.recover()
            let stages = try await service.database.stages(runID: saved.id)
            #expect(stages.dropFirst(3).allSatisfy { $0.status == .waiting })
            #expect(stages[3].message == "上次确认未执行，请重新确认")
            try await service.confirm(stages[6].id, runID: saved.id)
            let deadline = ContinuousClock.now + .seconds(10)
            while try await service.database.stages(runID: saved.id)[6].status != .succeeded {
                if ContinuousClock.now > deadline { throw ApplicationError("独立恢复批次未完成") }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(try await service.database.stages(runID: saved.id)[3].status == .waiting)
        } catch { await service.shutdown(); throw error }
        await service.shutdown()
    }

    @Test("重开数据库后整批等待及两个摘要仍在，可一次确认全部目标")
    func restart() async throws {
        let saved = try await prepareWaiting()
        let root = saved.root
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try ApplicationService(paths: AppPaths(applicationSupport: root.appending(path: "support")), secrets: saved.secrets,
            environment: { ShellEnvironment(shell: "/bin/sh", variables: ["PATH": "\(root.appending(path: "bin").path):/usr/bin:/bin",
                                                                          "HOME": root.path, "RECORD": root.appending(path: "record.txt").path]) })
        do {
            await service.shortenDeploymentObservation()
            try await service.recover()
            let run = try #require(try await service.database.run(saved.id))
            #expect(run.status == .waiting)
            let plan = try JSONDecoder().decode(RunPlan.self, from: Data(try #require(run.plan).utf8))
            #expect(plan.images == saved.images)
            let stages = try await service.database.stages(runID: saved.id)
            #expect(stages.suffix(2).allSatisfy { $0.status == .waiting })
            try await service.confirm(try #require(stages.last).id, runID: saved.id)
            let deadline = ContinuousClock.now + .seconds(10)
            while try await service.database.run(saved.id)?.status != .succeeded {
                if ContinuousClock.now > deadline { throw ApplicationError("恢复后的批次未完成") }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch { await service.shutdown(); throw error }
        await service.shutdown()
    }

    @Test("并发上限为二，单个构建失败后其他独立构建继续")
    func boundedFailure() async throws {
        let config = Fixture.multi
            .replacingOccurrences(of: "command: 'echo build-alpha >> \"$RECORD\"'", with: "command: 'sleep 0.1; exit 1'")
            .replacingOccurrences(of: "command: 'echo build-beta >> \"$RECORD\"'", with: "command: 'sleep 0.3; echo beta-finished >> \"$RECORD\"'")
            .replacingOccurrences(of: "deploy:\n", with: "    - {name: gamma, image: 'r.invalid/gamma:${SHA}', command: 'echo gamma-started >> \"$RECORD\"'}\ndeploy:\n")
            .replacingOccurrences(of: "  - name: 正式发布", with: "      - {build: gamma, namespace: ns, deployment: gamma, container: app}\n  - name: 正式发布")
        try await Fixture.with(config: config) { f in
            let id = try #require(try await f.push("dev").runID)
            _ = try await f.wait(id, for: [.failed])
            #expect(f.recorded().contains("beta-finished"))
            #expect(f.recorded().contains("gamma-started") && !f.recorded().contains("kubectl"))
            let builds = try await f.stages(id).filter { $0.kind == .build }
            #expect(builds.map(\.status) == [.failed, .succeeded, .succeeded])
        }
    }
}
