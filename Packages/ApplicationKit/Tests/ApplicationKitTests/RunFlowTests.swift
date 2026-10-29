import Foundation
import Models
import Platform
import Runner
import Storage
import Testing
@testable import ApplicationKit

/// 收集服务发出的提醒。
actor NoticeBox {
    private(set) var notices: [RunNotice] = []
    func append(_ notice: RunNotice) { notices.append(notice) }
}

/// 一个临时 Git 仓库、假 docker / kubectl 和一份独立的应用数据目录。
final class Fixture: Sendable {
    static let token = "kube-secret-token-123"
    static let config = """
        test:
          - echo "test $CICD_BRANCH $CICD_IMAGE" >> "$RECORD"
          - test -f Dockerfile
        build:
          images:
            - name: app
              image: registry.example.invalid/demo:${BRANCH}-${SHA}
              dockerfile: Dockerfile
        deploy:
          - name: 测试发布
            branches: [dev]
            k8s: 测试环境
            targets:
              - {build: app, namespace: demo, deployment: demo, container: app}
          - name: 正式发布
            branches: [main]
            k8s: 正式环境
            confirm: true
            targets:
              - {build: app, namespace: demo, deployment: demo, container: app}
        """

    let root: URL
    let service: ApplicationService
    let notices = NoticeBox()
    let project: Project
    var repository: URL { root.appending(path: "repo") }
    var bin: URL { root.appending(path: "bin") }
    var record: URL { root.appending(path: "record.txt") }

    init(config: String = Fixture.config, connections: [String] = ["测试环境", "正式环境"]) async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "localcicd-flow-\(UUID().uuidString)").resolvingSymlinksInPath()
        let repository = root.appending(path: "repo"), bin = root.appending(path: "bin"), record = root.appending(path: "record.txt")
        for directory in [repository, bin] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Self.tool(bin, "docker", """
            echo "docker $*" >> "$RECORD"
            if [ "$1" = buildx ]; then echo '{"digest":"sha256:\(String(repeating: "a", count: 64))"}'; fi
            """)
        let fixtureScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scripts/fixtures/healthy-kubectl.sh")
        let healthyCluster = try String(contentsOf: fixtureScript, encoding: .utf8)
        try Self.tool(bin, "kubectl", """
            echo "kubectl $*" >> "$RECORD"
            grep -q \(Self.token) "$KUBECONFIG" && echo "kubeconfig ok" >> "$RECORD"
            # 模拟 kubectl 在输出里带出令牌，阶段日志里必须已脱敏。
            [ "$1" = set ] && echo "token: \(Self.token)"
            \(healthyCluster)
            """)
        try Self.git(repository, "init", "-q", "-b", "main")
        try Data(config.utf8).write(to: repository.appending(path: ".local.cicd.yml"))
        try Data("FROM scratch\n".utf8).write(to: repository.appending(path: "Dockerfile"))
        try Self.git(repository, "add", ".")
        try Self.git(repository, "commit", "-q", "-m", "初始提交")

        let notices = notices
        let variables = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": root.path, "RECORD": record.path]
        service = try ApplicationService(paths: AppPaths(applicationSupport: root.appending(path: "support")), secrets: InMemorySecretStore(),
                                         environment: { ShellEnvironment(shell: "/bin/sh", variables: variables) },
                                         notify: { await notices.append($0) })
        await service.shortenDeploymentObservation()
        project = try await service.addProject(path: repository.path)
        let kubeconfig = root.appending(path: "kubeconfig")
        try """
            apiVersion: v1
            kind: Config
            contexts: [{name: a, context: {cluster: a, user: a}}]
            clusters: [{name: a, cluster: {server: 'https://127.0.0.1:6443'}}]
            users: [{name: a, user: {token: \(Self.token)}}]
            """.write(to: kubeconfig, atomically: true, encoding: .utf8)
        let preview = try KubeconfigDocument.read(kubeconfig).preview(context: "a")
        for name in connections { try await service.importConnection(name: name, preview: preview) }
    }

    /// 测试结束（包括失败）后停止服务、删除临时目录。
    static func with(config: String = Fixture.config, connections: [String] = ["测试环境", "正式环境"],
                     _ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture(config: config, connections: connections)
        do { try await body(fixture) } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    func close() async {
        await service.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    static func tool(_ bin: URL, _ name: String, _ body: String) throws {
        let url = bin.appending(path: name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @discardableResult
    static func git(_ directory: URL, _ arguments: String...) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=测试", "-c", "user.email=test@example.invalid",
                             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ApplicationError("git \(arguments.joined(separator: " ")) 失败") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func head() throws -> CommitSHA { try #require(CommitSHA(rawValue: Self.git(repository, "rev-parse", "HEAD"))) }

    /// 模拟一次已确认成功的推送：和推送监听确认后走同一个入口。
    @discardableResult
    func push(_ branch: String, sha: CommitSHA? = nil) async throws -> PushDispatch {
        let event = PushEvent(id: .unsaved, projectID: project.id, spoolEventID: UUID().uuidString, remoteName: "origin",
                              remoteURL: "file:///remote.git", receivedAt: Date())
        let update = RefUpdate(id: .unsaved, pushEventID: .unsaved, dedupKey: "", remoteRef: "refs/heads/\(branch)",
                               oldSHA: .zero, newSHA: try sha ?? head(), confirmation: .confirmed, confirmedBy: .reflog)
        guard case .recorded(_, let updates) = try await service.database.recordPushEvent(event, refUpdates: [update]) else {
            throw ApplicationError("推送事件重复")
        }
        try await service.dispatch(updates[0], project: project)
        return try #require(try await service.database.pushDispatch(updates[0].id))
    }

    /// 等到运行进入给定状态且项目队列空闲。
    func wait(_ id: RunID, for statuses: Set<RunStatus>) async throws -> Run {
        for _ in 0..<400 {
            if let run = try await service.database.run(id), statuses.contains(run.status), await service.workers[project.id] == nil {
                return run
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ApplicationError("运行 #\(id.rawValue) 没有进入 \(statuses)")
    }

    func stages(_ id: RunID) async throws -> [RunStage] { try await service.database.stages(runID: id) }

    func recorded() -> String { (try? String(contentsOf: record, encoding: .utf8)) ?? "" }
}

@Suite("推送驱动的三阶段运行", .serialized)
struct RunFlowTests {
    @Test("dev 自动走完测试、构建推送、替换；kubeconfig 不进日志")
    func automatic() async throws {
        try await Fixture.with() { fixture in
            let sha = try fixture.head()
            let short = String(sha.rawValue.prefix(12))
            let dispatch = try await fixture.push("dev")
            let runID = try #require(dispatch.runID)
            let run = try await fixture.wait(runID, for: [.succeeded, .failed])
            #expect(run.status == .succeeded, "\(run.message ?? "")")
            #expect(run.image == "registry.example.invalid/demo:dev-\(short)")
            let stages = try await fixture.stages(run.id)
            #expect(stages.map(\.status) == [.succeeded, .succeeded, .succeeded])
            #expect(stages[0].message == "测试通过")
            #expect(stages[1].message == "已推送并核验 registry.example.invalid/demo:dev-\(short)")
            #expect(stages[2].message?.contains("1 个目标 Pod 已就绪") == true)

            let lines = fixture.recorded().split(separator: "\n").map(String.init)
            #expect(lines.contains("docker push registry.example.invalid/demo:dev-\(short)"))
            #expect(lines.contains("kubectl set image deployment/demo app=registry.example.invalid/demo@sha256:\(String(repeating: "a", count: 64)) -n demo"))
            #expect(lines.contains("kubectl rollout status deployment/demo -n demo --timeout=10m"))
            #expect(lines.contains("kubectl get replicasets -n demo -o json -l app=demo"))
            #expect(lines.contains("kubectl get pods -n demo -o json -l app=demo"))
            let deployLog = try #require(try fixture.service.storedLog(run: run.id, ordinal: 2))
            #expect(deployLog.contains("测试环境"))
            #expect(!deployLog.contains(Fixture.token))
            #expect(try fixture.service.storedLog(run: run.id, ordinal: 0)?.contains("test -f Dockerfile") == true)
            #expect(await fixture.notices.notices.isEmpty, "成功不发提醒")

            let rerun = try #require(try await fixture.service.rerun(run.id))
            let again = try await fixture.wait(rerun, for: [.succeeded, .failed])
            #expect(again.status == .succeeded)
            #expect(again.rerunOf == run.id)
        }
    }

    @Test("替换失败时运行和阶段显示原因，原因里的凭据已脱敏")
    func deployFailureReason() async throws {
        try await Fixture.with() { fixture in
            try Fixture.tool(fixture.bin, "kubectl", """
                echo "error: 令牌 \(Fixture.token) 没有权限修改 deployment" >&2
                exit 1
                """)
            let runID = try #require(try await fixture.push("dev").runID)
            let run = try await fixture.wait(runID, for: [.succeeded, .failed])
            let reason = "kubectl set image 失败：error: 令牌 [已隐藏] 没有权限修改 deployment"
            #expect(run.status == .failed)
            #expect(run.message?.contains(reason) == true)
            #expect(try await fixture.stages(runID).last?.message == reason)
            #expect(await fixture.notices.notices.first?.message.contains(reason) == true)
        }
    }

    @Test("Pod 崩溃的事件与双份日志落盘，阶段和运行原因脱敏后持久保存")
    func podFailureEvidence() async throws {
        try await Fixture.with() { fixture in
            let tool = fixture.bin.appending(path: "kubectl")
            let original = try String(contentsOf: tool, encoding: .utf8)
            let failure = """
                case "$1 $2" in
                  'get pods') cat <<JSON
                {"items":[{"metadata":{"name":"demo-crash","uid":"pod-crash","ownerReferences":[{"uid":"rs-1","kind":"ReplicaSet","controller":true}]},"spec":{"containers":[{"name":"app","image":"$CICD_IMAGE"}]},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"False"}],"containerStatuses":[{"name":"app","ready":false,"restartCount":3,"state":{"waiting":{"reason":"CrashLoopBackOff"}},"lastState":{"terminated":{"exitCode":1}}}]}}]}
                JSON
                    exit 0 ;;
                  'get events') echo '{"items":[{"type":"Warning","reason":"Failed","message":"连接数据库失败，令牌 \(Fixture.token)"}]}'; exit 0 ;;
                  logs*) echo 'error: 数据库认证失败，令牌 \(Fixture.token)'; exit 0 ;;
                esac
                """
            try Fixture.tool(fixture.bin, "kubectl", failure + "\n" + original)
            let id = try #require(try await fixture.push("dev").runID)
            let run = try await fixture.wait(id, for: [.failed, .succeeded])
            #expect(run.status == .failed)
            #expect(run.message?.contains("CrashLoopBackOff") == true)
            #expect(run.message?.contains("[已隐藏]") == true)
            #expect(run.message?.contains(Fixture.token) == false)
            let stages = try await fixture.stages(id)
            #expect(stages.last?.status == .failed)
            #expect(stages.last?.message?.contains(Fixture.token) == false)
            let log = try #require(try fixture.service.storedLog(run: id, ordinal: 2))
            #expect(log.contains("当前日志") && log.contains("上一次运行的日志"))
            #expect(log.contains("数据库认证失败") && log.contains("连接数据库失败"))
            #expect(!log.contains(Fixture.token))
            #expect(await fixture.notices.notices.count == 1)
        }
    }

    @Test("main 停在等待确认，确认后替换；跳过不执行 kubectl")
    func confirmation() async throws {
        try await Fixture.with() { fixture in
            let first = try #require(try await fixture.push("main").runID)
            var run = try await fixture.wait(first, for: [.waiting, .failed])
            #expect(run.status == .waiting)
            var deploy = try #require(try await fixture.stages(first).last)
            #expect(deploy.status == .waiting)
            #expect(deploy.message == "等待确认批次「正式发布」")
            #expect(!fixture.recorded().contains("kubectl"))
            #expect(await fixture.notices.notices.map(\.kind) == [.waiting])

            try await fixture.service.confirm(deploy.id, runID: first)
            run = try await fixture.wait(first, for: [.succeeded, .failed])
            #expect(run.status == .succeeded)
            deploy = try #require(try await fixture.stages(first).last)
            #expect(deploy.message?.contains("1 个目标 Pod 已就绪") == true)
            #expect(fixture.recorded().contains("kubectl set image deployment/demo app=registry.example.invalid/demo@sha256:\(String(repeating: "a", count: 64)) -n demo"))
            await #expect(throws: ApplicationError.self) { try await fixture.service.confirm(deploy.id, runID: first) }

            try Data().write(to: fixture.record)
            let second = try #require(try await fixture.push("main").runID)
            _ = try await fixture.wait(second, for: [.waiting])
            let waiting = try #require(try await fixture.stages(second).last)
            try await fixture.service.skip(waiting.id, runID: second)
            run = try await fixture.wait(second, for: [.succeeded])
            #expect(try await fixture.stages(second).last?.status == .skipped)
            #expect(!fixture.recorded().contains("kubectl"))
        }
    }

    @Test("有更新的运行后，旧的等待仍可确认，确认后替换回旧镜像")
    func olderStillConfirmable() async throws {
        try await Fixture.with() { fixture in
            let old = try #require(try await fixture.push("main").runID)
            let oldRun = try await fixture.wait(old, for: [.waiting])
            #expect(oldRun.commitMessage == "初始提交")
            try Fixture.git(fixture.repository, "commit", "-q", "--allow-empty", "-m", "第二个提交")
            let new = try #require(try await fixture.push("main").runID)
            let newRun = try await fixture.wait(new, for: [.waiting])
            #expect(newRun.commitMessage == "第二个提交")
            #expect(oldRun.image != newRun.image)

            let waiting = try #require(try await fixture.stages(old).last)
            #expect(waiting.status == .waiting)
            try await fixture.service.confirm(waiting.id, runID: old)
            #expect(try await fixture.wait(old, for: [.succeeded, .failed]).status == .succeeded)
            #expect(fixture.recorded().contains("kubectl set image deployment/demo app=registry.example.invalid/demo@sha256:\(String(repeating: "a", count: 64)) -n demo"))
            #expect(try await fixture.stages(new).last?.status == .waiting)
        }
    }

    @Test("重新替换沿用旧镜像：HEAD 已变也能执行，不测试不构建，按原计划确认")
    func redeploy() async throws {
        try await Fixture.with() { fixture in
            let first = try #require(try await fixture.push("dev").runID)
            let original = try await fixture.wait(first, for: [.succeeded, .failed])
            #expect(original.status == .succeeded)
            let mainID = try #require(try await fixture.push("main").runID)
            _ = try await fixture.wait(mainID, for: [.waiting])
            try await fixture.service.skip(try #require(try await fixture.stages(mainID).last).id, runID: mainID)
            _ = try await fixture.wait(mainID, for: [.succeeded])
            try Fixture.git(fixture.repository, "commit", "-q", "--allow-empty", "-m", "第二个提交")
            try Data().write(to: fixture.record)

            let id = try #require(try await fixture.service.redeploy(first))
            let run = try await fixture.wait(id, for: [.succeeded, .failed])
            #expect(run.status == .succeeded, "\(run.message ?? "")")
            #expect(run.rerunOf == first && run.image == original.image && run.commit == original.commit)
            #expect(run.commitMessage == "初始提交")
            let stages = try await fixture.stages(id)
            #expect(stages.map(\.status) == [.skipped, .skipped, .succeeded])
            #expect(stages[1].message == "沿用已推送的镜像，不重新构建")
            let lines = fixture.recorded().split(separator: "\n").map(String.init)
            #expect(!lines.contains { $0.hasPrefix("docker") || $0.hasPrefix("test ") })
            #expect(lines.contains("kubectl set image deployment/demo app=registry.example.invalid/demo@sha256:\(String(repeating: "a", count: 64)) -n demo"))
            // 重新替换得到的运行也能再次重新替换。
            let twice = try #require(try await fixture.service.redeploy(id))
            #expect(try await fixture.wait(twice, for: [.succeeded, .failed]).image == original.image)

            // 需要确认的目标重新替换时仍停在等待确认。
            let again = try #require(try await fixture.service.redeploy(mainID))
            #expect(try await fixture.wait(again, for: [.waiting, .failed]).status == .waiting)
            #expect(try await fixture.stages(again).map(\.status) == [.skipped, .skipped, .waiting])

            // HEAD 已变时重新构建不执行；没有成功推送镜像的运行不能重新替换。
            let rebuilt = try #require(try await fixture.service.rerun(first))
            #expect(try await fixture.wait(rebuilt, for: [.succeeded, .failed]).status == .failed)
            await #expect(throws: ApplicationError.self) { try await fixture.service.redeploy(rebuilt) }
        }
    }

    @Test("删除运行连同日志；正在执行的运行不能删除；重命名项目，留空恢复文件夹名")
    func deleteAndRename() async throws {
        try await Fixture.with() { fixture in
            let id = try #require(try await fixture.push("dev").runID)
            _ = try await fixture.wait(id, for: [.succeeded, .failed])
            let logs = fixture.service.paths.runLogs(run: id.rawValue)
            #expect(FileManager.default.fileExists(atPath: logs.path))
            try await fixture.service.deleteRun(id)
            #expect(try await fixture.service.database.run(id) == nil)
            #expect(!FileManager.default.fileExists(atPath: logs.path))

            #expect(try await fixture.service.renameProject(fixture.project.id, to: "  演示服务 ").name == "演示服务")
            #expect(try await fixture.service.renameProject(fixture.project.id, to: " ").name == "repo")
        }
    }

    @Test("未列出的分支不运行；HEAD 不是推送的提交时不执行任何命令")
    func notRun() async throws {
        try await Fixture.with() { fixture in
            let ignored = try await fixture.push("feature")
            #expect(ignored.runID == nil)
            #expect(ignored.message == "分支 feature 未在配置中，未运行")
            #expect(try await fixture.service.database.runs(projectID: fixture.project.id).isEmpty)

            try Fixture.git(fixture.repository, "checkout", "-q", "-b", "dev")
            try Fixture.git(fixture.repository, "commit", "-q", "--allow-empty", "-m", "第二个提交")
            let pushed = try fixture.head()
            try Fixture.git(fixture.repository, "checkout", "-q", "main")
            let runID = try #require(try await fixture.push("dev", sha: pushed).runID)
            let run = try await fixture.wait(runID, for: [.failed])
            #expect(run.message == "工作区当前不是提交 \(pushed.short)，未运行。回滚请用「重新替换」")
            #expect(fixture.recorded().isEmpty)
            #expect(await fixture.notices.notices.map(\.kind) == [.failed])
        }
    }

    @Test("配置引用了未导入的 k8s 连接、或配置有错时，直接失败并说明原因")
    func invalid() async throws {
        try await Fixture.with(connections: ["测试环境"]) { fixture in
            let missingID = try #require(try await fixture.push("main").runID)
            let missing = try #require(try await fixture.service.database.run(missingID))
            #expect(missing.status == .failed)
            #expect(missing.message == "k8s 连接「正式环境」不存在，请先在设置中导入并命名")
            let overview = try await fixture.service.projectOverview(projectID: fixture.project.id)
            #expect(overview.missingConnections == ["正式环境"])

            try Data("build:\n  image: a\n  dockerfile: Dockerfile\n  command: make push\ndeploy: []\n".utf8)
                .write(to: fixture.repository.appending(path: ".local.cicd.yml"))
            try Fixture.git(fixture.repository, "commit", "-q", "-am", "错误配置")
            let brokenID = try #require(try await fixture.push("dev").runID)
            let broken = try #require(try await fixture.service.database.run(brokenID))
            #expect(broken.status == .failed)
            #expect(broken.message?.hasPrefix("配置错误：") == true)
            #expect(try await fixture.stages(broken.id).isEmpty)
            #expect(fixture.recorded().isEmpty)
        }
    }

    @Test("取消正在执行的测试会终止命令")
    func cancel() async throws {
        try await Fixture.with(config: Fixture.config.replacingOccurrences(
            of: "  - test -f Dockerfile", with: "  - echo started >> \"$RECORD\"; sleep 30")) { fixture in
            let id = try #require(try await fixture.push("dev").runID)
            let clock = ContinuousClock()
            let start = clock.now
            while !fixture.recorded().contains("started") {
                try await Task.sleep(for: .milliseconds(25))
                guard clock.now - start < .seconds(10) else { Issue.record("测试命令没有开始"); return }
            }
            await #expect(throws: ApplicationError.self) { try await fixture.service.deleteRun(id) }
            try await fixture.service.cancel(id)
            let run = try await fixture.wait(id, for: [.canceled, .failed])
            #expect(run.status == .canceled)
            #expect(clock.now - start < .seconds(10))
            #expect(!fixture.recorded().contains("docker"))
        }
    }
}

// 仅缩短包测试的稳定观察，真实 App 仍使用 60 秒。
extension ApplicationService {
    func shortenDeploymentObservation() { deploymentSettleDuration = .zero }
}
