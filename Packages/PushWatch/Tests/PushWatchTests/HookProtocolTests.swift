import Darwin
import Foundation
import HookProtocol
import Testing
@testable import PushWatch

@Suite("推送钩子协议")
struct HookProtocolTests {
    let sha = String(repeating: "a", count: 40)
    let zero = String(repeating: "0", count: 40)

    @Test("多引用、目标改名和删除按 Git 输入原样解析")
    func refs() throws {
        let refs = try HookRef.parse(Data("refs/heads/local \(sha) refs/heads/dev \(zero)\n(delete) \(zero) refs/tags/old \(sha)\n".utf8))
        #expect(refs.count == 2)
        #expect(refs[0].remoteRef == "refs/heads/dev")
        #expect(refs[1].newSHA == zero)
        #expect(throws: HookFailure.self) {
            try HookRef.parse(Data("HEAD \(sha) refs/heads/dev \(zero)\nHEAD \(sha) refs/heads/dev \(zero)\n".utf8))
        }
        #expect(throws: HookFailure.self) { try HookRef.parse(Data("HEAD \(sha) refs/heads/../main \(zero)\n".utf8)) }
    }

    @Test("fetch refspec 支持通配与排除，歧义和标签不假造映射")
    func mappings() {
        #expect(HookRuntime.trackingRef(remoteRef: "refs/heads/dev", refspecs: ["+refs/heads/*:refs/remotes/origin/*"]) == "refs/remotes/origin/dev")
        #expect(HookRuntime.trackingRef(remoteRef: "refs/heads/private/x", refspecs: ["+refs/heads/*:refs/remotes/origin/*", "^refs/heads/private/*"]) == nil)
        #expect(HookRuntime.trackingRef(remoteRef: "refs/tags/v1", refspecs: ["+refs/heads/*:refs/remotes/origin/*"]) == nil)
        #expect(HookRuntime.trackingRef(remoteRef: "refs/heads/dev", refspecs: ["refs/heads/dev:refs/remotes/a/dev", "refs/heads/dev:refs/remotes/b/dev"]) == nil)
    }

    @Test("远端凭据从持久化记录中移除")
    func sanitized() {
        #expect(HookIntent.sanitizeRemote("https://name:token@example.invalid/a.git?token=x#secret") == "https://example.invalid/a.git")
        #expect(HookIntent.sanitizeRemote("name@example.invalid:a.git") == "example.invalid:a.git")
        #expect(HookIntent.sanitizeRemote("origin") == "origin")
        #expect(HookInstaller.quote("/目录/a'b") == "'/目录/a'\\''b'")
    }

    @Test("只有明确非 dry-run 的直接 push 可以使用退出证据，别名不猜测")
    func dryRun() {
        #expect(PushExitObserver.permitsConfirmation(arguments: ["git", "-C", "/仓库", "push", "origin", "main"]))
        #expect(PushExitObserver.permitsConfirmation(arguments: ["git", "-c", "x=y", "push", "--force", "origin", "main"]))
        for arguments in [
            ["git", "push", "-n", "origin"], ["git", "push", "-vn", "origin"],
            ["git", "push", "--dry-run", "origin"], ["git", "push", "--dry", "origin"],
            ["git", "publish", "origin"], ["git", "-C", "push", "status"],
        ] { #expect(!PushExitObserver.permitsConfirmation(arguments: arguments)) }
    }

    @Test("spool 限权、原子覆盖和符号链接拒绝")
    func spool() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try HookSpool(root: directory)
        try spool.write(["value": 1], name: "record.json")
        try spool.write(["value": 2], name: "record.json")
        #expect(try spool.read([String: Int].self, name: "record.json") == ["value": 2])
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("link.json").path, withDestinationPath: "record.json")
        #expect(throws: HookFailure.self) { try spool.read([String: Int].self, name: "link.json") }
        #expect(throws: HookFailure.self) { try spool.write(["x": 1], name: "../outside.json") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }.isEmpty)
    }
}
