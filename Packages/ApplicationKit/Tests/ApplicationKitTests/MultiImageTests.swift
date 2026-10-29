import Foundation
import Models
import Platform
import Runner
import Storage
import Testing
@testable import ApplicationKit

extension Fixture {
    static let multi = """
        test: ["test -z \\\"$CICD_IMAGE\\\""]
        build:
          parallel: 2
          images:
            - {name: alpha, image: 'r.invalid/alpha:${SHA}', command: 'echo build-alpha >> "$RECORD"'}
            - {name: beta, image: 'r.invalid/beta:${SHA}', command: 'echo build-beta >> "$RECORD"'}
        deploy:
          - name: 测试发布
            branches: [dev]
            k8s: 测试环境
            parallel: 2
            targets:
              - {build: alpha, namespace: ns, deployment: alpha, container: app}
              - {build: beta, namespace: ns, deployment: beta, container: app}
          - name: 正式发布
            branches: [dev]
            k8s: 正式环境
            parallel: 2
            confirm: true
            targets:
              - {build: alpha, namespace: ns, deployment: alpha, container: app}
              - {build: beta, namespace: ns, deployment: beta, container: app}
        """

    func plan(_ id: RunID) async throws -> RunPlan {
        let run = try #require(try await service.database.run(id))
        return try JSONDecoder().decode(RunPlan.self, from: Data(try #require(run.plan).utf8))
    }

    func until(_ description: String, _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while try await !condition() {
            guard ContinuousClock.now < deadline else { throw ApplicationError("超时：\(description)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@Suite("多镜像与部署批次", .serialized)
struct MultiImageTests {
    @Test("并行构建实际重叠，digest 分别保存，整个批次确认并按冻结镜像回滚")
    func parallelAndRedeploy() async throws {
        try await Fixture.with(config: Fixture.multi) { f in
            // 两个构建必须同时到达屏障才放行，顺序执行会超时失败。
            try Fixture.tool(f.bin, "docker", """
                [ "$1" = buildx ] || exit 9
                touch "$RECORD.$CICD_BUILD"
                for n in $(seq 1 100); do
                  if [ -f "$RECORD.alpha" ] && [ -f "$RECORD.beta" ]; then
                    if [ "$CICD_BUILD" = alpha ]; then echo '{"digest":"sha256:\(String(repeating: "a", count: 64))"}';
                    else echo '{"digest":"sha256:\(String(repeating: "b", count: 64))"}'; fi
                    exit 0
                  fi
                  sleep 0.02
                done
                exit 8
                """)
            let id = try #require(try await f.push("dev").runID)
            #expect(try await f.wait(id, for: [.waiting, .failed]).status == .waiting)
            let stages = try await f.stages(id)
            #expect(stages.map(\.status) == [.succeeded, .succeeded, .succeeded, .succeeded, .succeeded, .waiting, .waiting])
            let plan = try await f.plan(id)
            #expect(plan.images.map(\.digest) == ["sha256:" + String(repeating: "a", count: 64), "sha256:" + String(repeating: "b", count: 64)])
            #expect(f.recorded().contains("app=r.invalid/alpha@sha256:" + String(repeating: "a", count: 64)))
            #expect(f.recorded().contains("app=r.invalid/beta@sha256:" + String(repeating: "b", count: 64)))
            try await f.service.confirm(stages[6].id, runID: id)
            await #expect(throws: (any Error).self) { try await f.service.confirm(stages[5].id, runID: id) }
            #expect(try await f.wait(id, for: [.succeeded, .failed]).status == .succeeded)
            #expect(try await f.stages(id).allSatisfy { $0.status == .succeeded })
            // 改变当前提交及仓库返回值，重新替换仍只使用此前持久化的摘要。
            try Fixture.git(f.repository, "commit", "-q", "--allow-empty", "-m", "后续提交")
            try Fixture.tool(f.bin, "docker", "echo 不应调用 >> \"$RECORD\"; exit 1")
            try Data().write(to: f.record)
            let again = try #require(try await f.service.redeploy(id))
            #expect(try await f.wait(again, for: [.waiting, .failed]).status == .waiting)
            #expect(try await f.plan(again).images == plan.images)
            #expect(!f.recorded().contains("不应调用") && !f.recorded().contains("build-"))
            let waiting = try #require(try await f.stages(again).last)
            try await f.service.skip(waiting.id, runID: again)
            #expect(try await f.wait(again, for: [.succeeded, .failed]).status == .succeeded)
            #expect(try await f.stages(again).suffix(2).allSatisfy { $0.status == .skipped })
        }
    }

    @Test("构建失败不影响其他构建，引用失败镜像的整批部署跳过")
    func buildFailure() async throws {
        let config = Fixture.multi
            .replacingOccurrences(of: "echo build-alpha >> \"$RECORD\"", with: "sleep 0.1; exit 3")
            .replacingOccurrences(of: "echo build-beta >> \"$RECORD\"", with: "sleep 0.3; echo beta-finished >> \"$RECORD\"")
        try await Fixture.with(config: config) { f in
            let id = try #require(try await f.push("dev").runID)
            #expect(try await f.wait(id, for: [.failed]).status == .failed)
            let stages = try await f.stages(id)
            #expect(stages[1].status == .failed && stages[2].status == .succeeded)
            #expect(stages.dropFirst(3).allSatisfy { $0.status == .skipped })
            #expect(f.recorded().contains("beta-finished") && !f.recorded().contains("kubectl"))
            await #expect(throws: ApplicationError.self) { try await f.service.redeploy(id) }
        }
    }

    @Test("摘要查询失败不能开始部署；缺失 Dockerfile 在公共测试前拒绝")
    func validationAndDigest() async throws {
        try await Fixture.with(config: Fixture.multi) { f in
            try Fixture.tool(f.bin, "docker", "echo 仓库拒绝访问 >&2; exit 1")
            let id = try #require(try await f.push("dev").runID)
            #expect(try await f.wait(id, for: [.failed]).message?.contains("核验失败") == true)
            #expect(!f.recorded().contains("kubectl"))
        }
        let missing = Fixture.multi.replacingOccurrences(of: "command: 'echo build-beta >> \"$RECORD\"'", with: "dockerfile: missing.Dockerfile")
        try await Fixture.with(config: missing) { f in
            let id = try #require(try await f.push("dev").runID)
            #expect(try await f.wait(id, for: [.failed]).message?.contains("missing.Dockerfile") == true)
            #expect(f.recorded().isEmpty)
        }
    }

    @Test("部署并发实际重叠，部分失败保留成功目标，其他批次仍可确认")
    func deployFailure() async throws {
        try await Fixture.with(config: Fixture.multi) { f in
            let path = f.bin.appending(path: "kubectl")
            let healthy = try String(contentsOf: path, encoding: .utf8)
            try Fixture.tool(f.bin, "kubectl", """
                if [ "$1 $2" = 'set image' ]; then
                  touch "$RECORD.deploy.$CICD_BUILD"
                  for n in $(seq 1 100); do
                    [ -f "$RECORD.deploy.alpha" ] && [ -f "$RECORD.deploy.beta" ] && break
                    sleep 0.02
                  done
                  [ -f "$RECORD.deploy.alpha" ] && [ -f "$RECORD.deploy.beta" ] || exit 8
                  [ "$CICD_BUILD" = alpha ] && { echo 模拟替换拒绝 >&2; exit 2; }
                fi
                \(healthy)
                """)
            let id = try #require(try await f.push("dev").runID)
            let run = try await f.wait(id, for: [.waiting])
            #expect(run.message?.contains("已成功替换的目标保留") == true)
            let stages = try await f.stages(id)
            #expect(stages[3].status == .failed && stages[4].status == .succeeded)
            #expect(stages.suffix(2).allSatisfy { $0.status == .waiting })
            try await f.service.skip(stages[5].id, runID: id)
            #expect(try await f.wait(id, for: [.failed]).status == .failed)
        }
    }

    @Test("前批等待时可先确认后批；错误运行 ID 不能操作其他运行")
    func orderedConfirmation() async throws {
        let config = Fixture.multi.replacingOccurrences(of: "name: 测试发布", with: "name: 测试发布\n    confirm: true")
        try await Fixture.with(config: config) { f in
            let id = try #require(try await f.push("dev").runID)
            _ = try await f.wait(id, for: [.waiting])
            let stages = try await f.stages(id)
            #expect(stages.dropFirst(3).allSatisfy { $0.status == .waiting })
            try await f.service.confirm(stages[5].id, runID: id)
            _ = try await f.wait(id, for: [.waiting])
            #expect(try await f.stages(id).suffix(2).allSatisfy { $0.status == .succeeded })
            #expect(try await f.stages(id)[3].status == .waiting)
            let other = try #require(try await f.push("dev").runID)
            _ = try await f.wait(other, for: [.waiting])
            await #expect(throws: ApplicationError.self) { try await f.service.confirm(stages[3].id, runID: other) }
            try await f.service.skip(stages[3].id, runID: id)
            _ = try await f.wait(id, for: [.succeeded])
            #expect(try await f.stages(id)[4].status == .skipped)
            #expect(f.recorded().contains("kubectl"))
        }
    }

    @Test("取消并行构建终止两个进程组，后续部署不执行")
    func cancelParallel() async throws {
        let config = Fixture.multi.replacingOccurrences(of: "echo build-alpha >> \"$RECORD\"", with: "sleep 30 & echo $! > \"$RECORD.alpha.pid\"; wait")
            .replacingOccurrences(of: "echo build-beta >> \"$RECORD\"", with: "sleep 30 & echo $! > \"$RECORD.beta.pid\"; wait")
        try await Fixture.with(config: config) { f in
            let id = try #require(try await f.push("dev").runID)
            let paths = ["alpha", "beta"].map { f.record.path + "." + $0 + ".pid" }
            try await f.until("两个构建均开始") { paths.allSatisfy { FileManager.default.fileExists(atPath: $0) } }
            try await f.service.cancel(id)
            #expect(try await f.wait(id, for: [.canceled, .failed]).status == .canceled)
            for path in paths {
                let pid = try #require(Int32(String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
                #expect(kill(pid, 0) != 0)
            }
            #expect(!f.recorded().contains("kubectl"))
        }
    }
}
