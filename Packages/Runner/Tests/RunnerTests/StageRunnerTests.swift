import Foundation
import LogKit
import Testing
@testable import Runner

/// 每个测试一个临时目录：project/ 当作项目根，bin/ 放假 docker、kubectl，logs/ 放阶段日志。
struct Sandbox {
    let root: URL
    var project: URL { root.appending(path: "project") }
    var bin: URL { root.appending(path: "bin") }
    var record: URL { root.appending(path: "record.txt") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "runner-\(UUID().uuidString)").resolvingSymlinksInPath()
        for directory in [project, bin] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }

    func tool(_ name: String, _ body: String) throws {
        let url = bin.appending(path: name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func shell(_ extra: [String: String] = [:]) -> ShellEnvironment {
        ShellEnvironment(shell: "/bin/sh", variables: ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": root.path].merging(extra) { $1 })
    }

    func stage(variables: [String: String] = [:]) -> StageRunner {
        StageRunner(root: project, shell: shell(), variables: variables)
    }

    func log(_ name: String = "stage", secrets: [String] = []) throws -> JobLogStore {
        try JobLogStore(directory: root.appending(path: "logs/\(name)"), allowedRoot: root, secrets: secrets)
    }

    func text(_ log: JobLogStore) async throws -> String {
        try await log.finish()
        return try JobLogStore.read(directory: await log.directory)
    }

    func recorded() throws -> String { (try? String(contentsOf: record, encoding: .utf8)) ?? "" }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("本机执行器")
struct StageRunnerTests {
    @Test("在项目目录逐条执行，能读到 CICD 变量，stdin 为空；失败即停止")
    func sequence() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let stage = box.stage(variables: ["CICD_SHA": "0b827ae2"])
        let log = try box.log()
        let record = box.record.path
        let ok = try await stage.test([
            "pwd > '\(record)'",
            "echo \"$CICD_SHA\" >> '\(record)'",
            "cat >> '\(record)'; echo 输出到日志",
            "echo 出错了 >&2; exit 3",
            "echo 不应执行 >> '\(record)'",
        ], log: log)
        #expect(!ok)
        // /var 是 /private/var 的符号链接，pwd 输出真实路径。
        let recorded = try box.recorded()
        #expect(recorded.hasSuffix("\(box.root.lastPathComponent)/project\n0b827ae2\n"), "\(recorded)")
        let text = try await box.text(log)
        #expect(text.contains("$ pwd > "))
        #expect(text.contains("输出到日志"))
        #expect(text.contains("出错了"))
        #expect(text.contains("命令失败，退出码 3"))
        #expect(!text.contains("不应执行"))
    }

    @Test("取消时终止整个进程组并抛出取消")
    func cancellation() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let stage = box.stage()
        let log = try box.log()
        let pidFile = box.root.appending(path: "child.pid").path
        let task = Task { try await stage.run("sleep 30 & echo $! > '\(pidFile)'; wait", log: log) }
        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: pidFile), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(10))
        let pid = try #require(Int32(String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) != 0, "子进程 sleep 应随进程组一起结束")
    }

    @Test("dockerfile 形式：docker build 后 docker push，参数不经过 shell")
    func dockerfile() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.tool("docker", "echo \"docker $*\" >> '\(box.record.path)'")
        try "FROM scratch\n".write(to: box.project.appending(path: "Dockerfile"), atomically: true, encoding: .utf8)
        let plan = RunPlan.Image(name: "app", image: "127.0.0.1:5000/demo:1;rm", build: .dockerfile(path: "./Dockerfile", platform: "linux/amd64"))
        let log = try box.log()
        #expect(try await box.stage().build(plan, log: log))
        #expect(try box.recorded() == """
            docker build --platform linux/amd64 -f Dockerfile -t 127.0.0.1:5000/demo:1;rm .
            docker push 127.0.0.1:5000/demo:1;rm

            """)
    }

    @Test("dockerfile 通过符号链接指向项目外时不构建")
    func dockerfileOutside() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.tool("docker", "echo docker >> '\(box.record.path)'")
        try "FROM scratch\n".write(to: box.root.appending(path: "Outside"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: box.project.appending(path: "Dockerfile"), withDestinationURL: box.root.appending(path: "Outside"))
        let plan = RunPlan.Image(name: "app", image: "a",
                           build: .dockerfile(path: "Dockerfile", platform: nil))
        let log = try box.log()
        #expect(try await !box.stage().build(plan, log: log))
        #expect(try box.recorded().isEmpty)
        #expect(try await box.text(log).contains("指向项目外"))
    }

    @Test("执行前校验全部构建路径，拒绝目录和 FIFO，不执行命令")
    func validateBuildFiles() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let fifo = box.project.appending(path: "Dockerfile")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let image = RunPlan.Image(name: "app", image: "r.invalid/app:v1", build: .dockerfile(path: "Dockerfile", platform: nil))
        #expect(throws: ConfigError.self) { try box.stage().validate([image]) }
        let directory = RunPlan.Image(name: "app", image: "r.invalid/app:v1", build: .dockerfile(path: ".", platform: nil))
        #expect(throws: ConfigError.self) { try box.stage().validate([directory]) }
        #expect(try box.recorded().isEmpty)
    }

    @Test("command 形式原样交给 shell；找不到 docker 时给出原因")
    func command() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let plan = RunPlan.Image(name: "app", image: "a:1",
                           build: .command("echo \"$CICD_IMAGE\" > '\(box.record.path)'"))
        #expect(try await box.stage(variables: ["CICD_IMAGE": plan.image]).build(plan, log: box.log("command")))
        #expect(try box.recorded() == "a:1\n")
        try "FROM scratch\n".write(to: box.project.appending(path: "Dockerfile"), atomically: true, encoding: .utf8)
        var missing = plan
        missing.build = .dockerfile(path: "Dockerfile", platform: nil)
        let log = try box.log("missing")
        #expect(try await !box.stage().build(missing, log: log))
        #expect(try await box.text(log).contains("找不到 docker"))
    }

    @Test("登录 shell 环境：跳过启动脚本的输出，去掉 PWD 等临时变量")
    func shellEnvironment() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.tool("noisy-shell", "echo 欢迎信息; printf '\\0'; exec /bin/sh \"$@\"")
        let environment = try await ShellEnvironment.capture(shell: box.bin.appending(path: "noisy-shell").path)
        #expect(environment.variables["PATH"]?.isEmpty == false)
        #expect(environment.variables["PWD"] == nil)
        #expect(environment.variables.keys.allSatisfy { !$0.contains("欢迎") })
        let real = try await ShellEnvironment.capture(shell: "/bin/zsh")
        #expect(real.which("sh") == "/bin/sh")
    }
}
