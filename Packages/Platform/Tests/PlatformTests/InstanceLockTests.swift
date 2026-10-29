import Foundation
import Testing
@testable import Platform

@Suite("单实例")
struct InstanceLockTests {
    private func tempLockURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "localcicd-\(UUID().uuidString).lock")
    }

    @Test("同一锁文件只能被持有一次，释放后可再次获取")
    func exclusive() throws {
        let url = tempLockURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var first = try InstanceLock.acquire(at: url)
        #expect(first != nil)
        // flock 按打开的文件描述加锁，同一进程再次 open 也会冲突，可以模拟第二个实例。
        #expect(try InstanceLock.acquire(at: url) == nil)
        first = nil
        #expect(try InstanceLock.acquire(at: url) != nil)
    }

    @Test("另一个进程持有时获取失败；该进程退出后自动释放")
    func otherProcess() async throws {
        let url = tempLockURL()
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)

        // /usr/bin/lockf 对文件加 flock 后执行命令；-k 保留文件。
        let holder = Process()
        holder.executableURL = URL(filePath: "/usr/bin/lockf")
        holder.arguments = ["-k", url.path(percentEncoded: false), "/bin/sleep", "30"]
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }

        // 等待 lockf 拿到锁。
        var blocked = false
        for _ in 0..<50 {
            if try InstanceLock.acquire(at: url) == nil { blocked = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(blocked, "另一个进程持有锁时应当获取失败")

        holder.terminate()
        holder.waitUntilExit()
        // sleep 被 lockf 代为等待，lockf 被终止后锁随进程释放；子进程 sleep 也可能继承描述，
        // 所以给一点时间让它们都退出。
        var acquired: InstanceLock?
        for _ in 0..<100 {
            acquired = try InstanceLock.acquire(at: url)
            if acquired != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(acquired != nil, "持有者退出后应当能获取锁")
    }

    @Test("锁文件中写入当前 PID")
    func writesPID() throws {
        let url = tempLockURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let lock = try InstanceLock.acquire(at: url)
        #expect(lock != nil)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "\(ProcessInfo.processInfo.processIdentifier)\n")
    }

    @Test("目录不存在时报错")
    func missingDirectory() {
        let url = URL(filePath: "/nonexistent-\(UUID().uuidString)/instance.lock")
        #expect(throws: InstanceLockError.self) { try InstanceLock.acquire(at: url) }
    }
}
