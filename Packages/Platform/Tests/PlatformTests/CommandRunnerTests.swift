import Darwin
import Foundation
import Testing
@testable import Platform

@Suite("参数化子进程与进程组清理")
struct CommandRunnerTests {
    let runner = CommandRunner()

    @Test("参数不经过 Shell 展开，输入、工作目录和环境分别传入")
    func argumentsAndInput() async throws {
        let literal = "$(不执行) `不执行` 中文 带空格"
        let result = try await runner.capture(Command(
            executable: "/usr/bin/printf", arguments: ["%s", literal], inheritEnvironment: false))
        #expect(result.result.succeeded)
        #expect(result.outputString == literal)
        let input = Data("跨块中文输入\n".utf8)
        let echo = try await runner.capture(Command(executable: "/bin/cat", input: input))
        #expect(echo.stdout == input)
        let env = try await runner.capture(Command(
            executable: "/usr/bin/env", environment: ["LOCALCICD_UNIT_TEST": "中文值"], inheritEnvironment: false))
        #expect(env.outputString == "LOCALCICD_UNIT_TEST=中文值\n")
    }

    @Test("退出码、信号、缺少程序分别处理")
    func statuses() async throws {
        let failed = try await runner.capture(Command(executable: "/bin/sh", arguments: ["-c", "exit 7"]))
        #expect(failed.result.exitCode == 7)
        #expect(failed.result.stopReason == nil)
        let signal = try await runner.capture(Command(executable: "/bin/sh", arguments: ["-c", "kill -TERM $$"]))
        #expect(signal.result.signal == SIGTERM)
        await #expect(throws: CommandError.self) {
            _ = try await runner.capture(Command(executable: "/不存在的人工测试程序"))
        }
    }

    @Test("同时消费两路大量输出，采集上限明确报错")
    func outputAndLimit() async throws {
        let script = #"awk 'BEGIN { for(i=0;i<10000;i++) { print "输出"; print "错误" > "/dev/stderr" } }'"#
        let result = try await runner.capture(Command(executable: "/bin/sh", arguments: ["-c", script]))
        #expect(result.stdout.count == 70_000)
        #expect(result.stderr.count == 70_000)
        await #expect(throws: CommandError.self) {
            _ = try await runner.capture(Command(executable: "/bin/sh", arguments: ["-c", script]), limit: 1_024)
        }
    }

    @Test("取消会等待 TERM/KILL 清理整个进程组，包含忽略 TERM 的孙进程")
    func cancellation() async throws {
        let (stream, continuation) = AsyncStream.makeStream(of: Int32.self)
        let command = Command(executable: "/bin/sh", arguments: ["-c", #"trap '' TERM; (trap '' TERM; exec /bin/sleep 30) & wait"#], terminationGrace: .milliseconds(100))
        let task = Task {
            try await runner.run(command, onStarted: { pid in continuation.yield(pid); continuation.finish() })
        }
        var iterator = stream.makeAsyncIterator()
        let pid = try #require(await iterator.next())
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = try await task.value
        #expect(result.stopReason == .canceled)
        #expect(ProcessGroup.liveMembers(pid).isEmpty)
    }

    @Test("超时是结构化原因，组长正常退出遗留后台进程也会清理")
    func timeoutAndBackground() async throws {
        let timeout = try await runner.capture(Command(
            executable: "/bin/sleep", arguments: ["30"], timeout: .milliseconds(100), terminationGrace: .milliseconds(100)))
        #expect(timeout.result.stopReason == .timeout)
        let started = ContinuousClock.now
        let orphan = try await runner.capture(Command(
            executable: "/bin/sh", arguments: ["-c", "(trap '' TERM; sleep 30) & exit 0"],
            timeout: .seconds(5), terminationGrace: .milliseconds(100)))
        #expect(orphan.result.succeeded)
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}
