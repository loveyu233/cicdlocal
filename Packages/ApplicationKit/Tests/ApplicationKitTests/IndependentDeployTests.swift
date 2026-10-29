import Foundation
import Models
import Runner
import Testing
@testable import ApplicationKit

extension Fixture {
    static let independent = """
        test: []
        build:
          parallel: 2
          images:
            - {name: alpha, image: 'r.invalid/alpha:${SHA}', command: 'echo build-alpha >> "$RECORD"'}
            - {name: beta, image: 'r.invalid/beta:${SHA}', command: 'echo build-beta >> "$RECORD"'}
        deploy:
          - name: 测试存储
            branches: [dev]
            k8s: 测试环境
            confirm: true
            targets:
              - {build: alpha, namespace: ns, deployment: alpha, container: app}
          - name: 测试推理
            branches: [dev]
            k8s: 测试环境
            confirm: true
            targets:
              - {build: beta, namespace: ns, deployment: beta, container: app}
          - name: 正式存储
            branches: [dev]
            k8s: 正式环境
            confirm: true
            targets:
              - {build: alpha, namespace: ns, deployment: alpha, container: app}
          - name: 正式推理
            branches: [dev]
            k8s: 正式环境
            confirm: true
            targets:
              - {build: beta, namespace: ns, deployment: beta, container: app}
        """
}

@Suite("按镜像独立部署", .serialized)
struct IndependentDeployTests {
    @Test("自动批次也只等待自身镜像，不需要等待全部构建")
    func automaticEarlyDeploy() async throws {
        let config = Fixture.independent.replacingOccurrences(of: "    confirm: true\n", with: "")
            .replacingOccurrences(of: "echo build-alpha >> \"$RECORD\"",
                                 with: "while [ ! -f \"$RECORD.release\" ]; do sleep 0.02; done")
        try await Fixture.with(config: config) { f in
            let id = try #require(try await f.push("dev").runID)
            try await f.until("推理自动部署完成") { try await f.stages(id)[6].status == .succeeded }
            #expect(try await f.stages(id)[1].status == .running)
            try Data().write(to: URL(fileURLWithPath: f.record.path + ".release"))
            #expect(try await f.wait(id, for: [.succeeded]).status == .succeeded)
        }
    }

    @Test("同一 Deployment 的跨批次容器替换仍互斥，允许先点击排队")
    func workloadExclusion() async throws {
        let config = Fixture.independent.replacingOccurrences(of: "deployment: beta, container: app", with: "deployment: alpha, container: worker")
        try await Fixture.with(config: config) { f in
            let healthy = try String(contentsOf: f.bin.appending(path: "kubectl"), encoding: .utf8)
            try Fixture.tool(f.bin, "kubectl", """
                if [ "$1 $2" = 'set image' ]; then
                  touch "$RECORD.started.$CICD_BUILD"
                  if [ "$CICD_BUILD" = alpha ]; then
                    while [ ! -f "$RECORD.release" ]; do sleep 0.02; done
                  fi
                fi
                \(healthy)
                """)
            let id = try #require(try await f.push("dev").runID)
            _ = try await f.wait(id, for: [.waiting])
            let stages = try await f.stages(id)
            try await f.service.confirm(stages[3].id, runID: id)
            try await f.until("第一个容器已开始替换") { FileManager.default.fileExists(atPath: f.record.path + ".started.alpha") }
            try await f.service.confirm(stages[4].id, runID: id)
            try await Task.sleep(for: .milliseconds(250))
            #expect(!FileManager.default.fileExists(atPath: f.record.path + ".started.beta"))
            #expect(try await f.stages(id)[4].message == ApplicationService.confirmedMessage)
            try Data().write(to: URL(fileURLWithPath: f.record.path + ".release"))
            _ = try await f.wait(id, for: [.waiting])
            #expect(try await f.stages(id)[3].status == .succeeded)
            #expect(try await f.stages(id)[4].status == .succeeded)
        }
    }

    @Test("后一个镜像先完成可先部署最后一批，完全不等待前一个构建或部署")
    func deployWhileBuilding() async throws {
        let config = Fixture.independent.replacingOccurrences(of: "echo build-alpha >> \"$RECORD\"",
            with: "while [ ! -f \"$RECORD.release\" ]; do sleep 0.02; done; echo build-alpha >> \"$RECORD\"")
        try await Fixture.with(config: config) { f in
            let id = try #require(try await f.push("dev").runID)
            try await f.until("推理独立就绪") { try await f.stages(id)[6].status == .waiting }
            let stages = try await f.stages(id)
            #expect(stages[1].status == .running && stages[3].status == .pending)
            await #expect(throws: ApplicationError.self) { try await f.service.confirm(stages[3].id, runID: id) }
            try await f.service.confirm(stages[6].id, runID: id)
            await #expect(throws: (any Error).self) { try await f.service.confirm(stages[6].id, runID: id) }
            try await f.until("正式推理已成功，存储仍在构建") { try await f.stages(id)[6].status == .succeeded }
            #expect(try await f.stages(id)[1].status == .running)
            #expect(try await f.stages(id)[4].status == .waiting)
            #expect(try await f.service.database.run(id)?.status == .running)
            try Data().write(to: URL(fileURLWithPath: f.record.path + ".release"))
            _ = try await f.wait(id, for: [.waiting])
            for index in [5, 4, 3] { try await f.service.skip(stages[index].id, runID: id) }
            #expect(try await f.wait(id, for: [.succeeded]).status == .succeeded)
        }
    }

    @Test("两个不同部署批次点击后真实重叠，前批健康检查不会挡住后批")
    func batchesOverlap() async throws {
        try await Fixture.with(config: Fixture.independent) { f in
            let healthy = try String(contentsOf: f.bin.appending(path: "kubectl"), encoding: .utf8)
            try Fixture.tool(f.bin, "kubectl", """
                if [ "$1 $2" = 'set image' ]; then
                  touch "$RECORD.deploy.$CICD_BUILD"
                  for n in $(seq 1 200); do
                    [ -f "$RECORD.deploy.alpha" ] && [ -f "$RECORD.deploy.beta" ] && break
                    sleep 0.02
                  done
                  [ -f "$RECORD.deploy.alpha" ] && [ -f "$RECORD.deploy.beta" ] || exit 8
                fi
                \(healthy)
                """)
            let id = try #require(try await f.push("dev").runID)
            _ = try await f.wait(id, for: [.waiting])
            let stages = try await f.stages(id)
            try await f.service.confirm(stages[4].id, runID: id)
            try await f.until("后批已开始") { FileManager.default.fileExists(atPath: f.record.path + ".deploy.beta") }
            try await f.service.confirm(stages[3].id, runID: id)
            _ = try await f.wait(id, for: [.waiting])
            #expect(try await f.stages(id)[3].status == .succeeded)
            #expect(try await f.stages(id)[4].status == .succeeded)
            #expect(try await f.stages(id).suffix(2).allSatisfy { $0.status == .waiting })
        }
    }

    @Test("单服务构建失败只阻止自身批次，其他服务仍能确认并完成")
    func failedDependencyIsolation() async throws {
        let config = Fixture.independent.replacingOccurrences(of: "echo build-alpha >> \"$RECORD\"", with: "exit 4")
        try await Fixture.with(config: config) { f in
            let id = try #require(try await f.push("dev").runID)
            let run = try await f.wait(id, for: [.waiting])
            #expect(run.finishedAt == nil && run.message?.contains("构建") == true)
            let stages = try await f.stages(id)
            #expect(stages[3].status == .skipped && stages[5].status == .skipped)
            #expect(stages[4].status == .waiting && stages[6].status == .waiting)
            try await f.service.confirm(stages[6].id, runID: id)
            _ = try await f.wait(id, for: [.waiting])
            #expect(try await f.stages(id)[6].status == .succeeded)
            try await f.service.skip(stages[4].id, runID: id)
            #expect(try await f.wait(id, for: [.failed]).status == .failed)
            #expect(!f.recorded().contains("deployment/alpha"))
        }
    }

    @Test("取消同时终止构建和已经独立启动的部署进程组")
    func cancelBuildAndDeploy() async throws {
        let config = Fixture.independent.replacingOccurrences(of: "echo build-alpha >> \"$RECORD\"",
            with: "sleep 30 & echo $! > \"$RECORD.build.pid\"; wait")
        try await Fixture.with(config: config) { f in
            try Fixture.tool(f.bin, "kubectl", "sleep 30 & echo $! > \"$RECORD.deploy.pid\"; wait")
            let id = try #require(try await f.push("dev").runID)
            try await f.until("推理镜像就绪") { try await f.stages(id)[4].status == .waiting }
            let stages = try await f.stages(id)
            try await f.service.confirm(stages[4].id, runID: id)
            let paths = ["build", "deploy"].map { f.record.path + "." + $0 + ".pid" }
            try await f.until("构建与部署进程均启动") { paths.allSatisfy { FileManager.default.fileExists(atPath: $0) } }
            try await f.service.cancel(id)
            #expect(try await f.wait(id, for: [.canceled]).status == .canceled)
            for path in paths {
                let pid = try #require(Int32(String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
                #expect(kill(pid, 0) != 0)
            }
        }
    }
}
