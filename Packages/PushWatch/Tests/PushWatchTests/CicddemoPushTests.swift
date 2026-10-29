import Foundation
import GitKit
import HookProtocol
import Models
import Platform
import Storage
import Testing
@testable import PushWatch

@Suite("cicddemo 本地推送监听", .enabled(if: ProcessInfo.processInfo.environment["LOCALCICD_PUSH_TEST_ROOT"] != nil), .serialized)
struct CicddemoPushTests {
    @Test("部分成功、强制重推、共享 worktree 和监听写入失败")
    func boundaries() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOCALCICD_PUSH_TEST_ROOT"]))
        let helper = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOCALCICD_HOOK_HELPER"]))
        let source = try #require(ProcessInfo.processInfo.environment["LOCALCICD_TEST_SOURCE"])
        guard URL(fileURLWithPath: source).lastPathComponent == "cicddemo",
            root.resolvingSymlinksInPath() == root, root.deletingLastPathComponent().lastPathComponent == ".test-repos",
            root.lastPathComponent.hasPrefix("cicddemo-push-"),
            try String(contentsOf: root.appendingPathComponent("source"), encoding: .utf8) == source
        else { throw HookFailure("推送测试只能使用 cicddemo 的隔离副本") }
        let repository = try await GitRepository.open(root.appendingPathComponent("工作 副本'"))
        _ = try await git(repository, ["config", "core.hooksPath", "/dev/null"])
        let database = try AppDatabase.inMemory()
        let project = try await database.createProject(Project(id: .unsaved, name: "cicddemo", repositoryPath: repository.root.path, createdAt: Date()))
        let installer = HookInstaller(directory: root.appendingPathComponent("边界监听"))
        let originalConfig = try Data(contentsOf: repository.commonDirectory.appendingPathComponent("config"))
        let plan = try await installer.preview(repository: repository)
        #expect(plan.commands.count == 6)
        #expect(!FileManager.default.fileExists(atPath: plan.root.path))
        #expect(try Data(contentsOf: repository.commonDirectory.appendingPathComponent("config")) == originalConfig)
        let installed = try await installer.install(repository: repository, projectID: project.id.rawValue, helper: helper, plan: plan)
        #expect(installed.hooks == plan.hooks)
        #expect(installed.installation.id == plan.id)
        #expect(try await installer.isIntact(installed, repository: repository))
        let confirmation = PushConfirmation(database: database)
        let remote = root.appendingPathComponent("remote.git")
        let updateHook = remote.appendingPathComponent("hooks/update")
        try Data("#!/bin/sh\nif test \"$1\" = refs/heads/reject-partial; then exit 1; fi\nexit 0\n".utf8).write(to: updateHook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: updateHook.path)
        let partial = try await git(repository, ["push", "origin", "HEAD:refs/heads/accept-partial", "HEAD:refs/heads/reject-partial"], success: false)
        #expect(!partial.result.succeeded)
        var records = try await confirmation.scan(installed)
        #expect(records.flatMap(\.updates).first { $0.remoteRef == "refs/heads/accept-partial" }?.confirmation == .confirmed)
        #expect(records.flatMap(\.updates).first { $0.remoteRef == "refs/heads/reject-partial" }?.confirmation == .unconfirmable)
        try FileManager.default.removeItem(at: updateHook)

        let newer = try await repository.resolve()
        let older = try await repository.resolve("HEAD^")
        _ = try await git(repository, ["push", "origin", "\(newer):refs/heads/force-target"])
        for _ in 0..<2 {
            _ = try await git(repository, ["push", "--force", "origin", "\(older):refs/heads/force-target"])
            _ = try await git(repository, ["push", "origin", "\(newer):refs/heads/force-target"])
        }
        records = try await confirmation.scan(installed)
        let repeated = records.flatMap(\.updates).filter { $0.remoteRef == "refs/heads/force-target" && $0.oldSHA == newer && $0.newSHA == older }
        #expect(repeated.count == 2)
        #expect(repeated.allSatisfy { $0.confirmation == .confirmed })
        #expect(Set(repeated.map(\.dedupKey)).count == 2)

        let linked = root.appendingPathComponent("其他 worktree")
        _ = try await git(repository, ["worktree", "add", "--detach", linked.path, newer.rawValue])
        let linkedRepository = try await GitRepository.open(linked)
        _ = try await git(linkedRepository, ["push", "origin", "HEAD:refs/heads/unregistered-worktree"])
        #expect(try await confirmation.scan(installed).count == records.count)
        _ = try await git(repository, ["worktree", "remove", linked.path])

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: installed.installation.spoolPath)
        let allowed = try await git(repository, ["push", "origin", "HEAD:refs/heads/spool-failed"])
        #expect(allowed.result.succeeded)
        #expect(allowed.errorString.contains("监听记录失败"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installed.installation.spoolPath)
        #expect(try await confirmation.scan(installed).count == records.count)
        let editedKey = "hook.\(installed.hooks[0].name).parallel"
        _ = try await git(repository, ["config", editedKey, "true"])
        #expect(try await !installer.isIntact(installed, repository: repository))
        await #expect(throws: GitError.self) { try await installer.uninstall(installed, repository: repository) }
        #expect(try await git(repository, ["config", "--get", editedKey]).outputString == "true\n")
        _ = try await git(repository, ["config", "--unset", editedKey])
        try await installer.uninstall(installed, repository: repository)
    }

    @Test("保留原钩子，逐引用确认、拒绝、dry-run、连续推送和卸载")
    func lifecycle() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOCALCICD_PUSH_TEST_ROOT"]))
        let helper = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LOCALCICD_HOOK_HELPER"]))
        let source = try #require(ProcessInfo.processInfo.environment["LOCALCICD_TEST_SOURCE"])
        guard URL(fileURLWithPath: source).lastPathComponent == "cicddemo",
            root.resolvingSymlinksInPath() == root, root.deletingLastPathComponent().lastPathComponent == ".test-repos",
            root.lastPathComponent.hasPrefix("cicddemo-push-"),
            try String(contentsOf: root.appendingPathComponent("source"), encoding: .utf8) == source
        else { throw HookFailure("推送测试只能使用 cicddemo 的隔离副本") }
        let repository = try await GitRepository.open(root.appendingPathComponent("工作 副本'"))
        let database = try AppDatabase.inMemory()
        let project = try await database.createProject(Project(
            id: .unsaved, name: "cicddemo", repositoryPath: repository.root.path, createdAt: Date()))
        let hooks = root.appendingPathComponent("原 钩子'")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let prepush = hooks.appendingPathComponent("pre-push")
        let original = Data("""
        #!/bin/sh
        cat > .git/original-stdin
        printf '%s\\n' "$0" "$1" "$2" > .git/original-arguments
        if test -f .git/reject-push; then exit 23; fi
        exit 0

        """.utf8)
        try original.write(to: prepush)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: prepush.path)
        _ = try await git(repository, ["config", "core.hooksPath", hooks.path])
        let installer = HookInstaller(directory: root.appendingPathComponent("监听 安装'"))
        let installed = try await installer.install(repository: repository, projectID: project.id.rawValue, helper: helper)
        #expect(try await installer.install(repository: repository, projectID: project.id.rawValue, helper: helper) == installed)
        #expect(try await installer.isIntact(installed, repository: repository))
        let confirmation = PushConfirmation(database: database)

        let first = try await repository.resolve()
        _ = try await git(repository, ["push", "origin", "HEAD:refs/heads/target"])
        var records = try await confirmation.scan(installed)
        #expect(records.count == 1)
        #expect(records.first?.updates.first?.confirmation == .confirmed)
        #expect(records.first?.updates.first?.newSHA == first)
        #expect(records.first?.updates.first?.remoteRef == "refs/heads/target")
        #expect(try String(contentsOf: repository.gitDirectory.appendingPathComponent("original-arguments"), encoding: .utf8).hasPrefix(prepush.path + "\norigin\n"))
        #expect(try String(contentsOf: repository.gitDirectory.appendingPathComponent("original-stdin"), encoding: .utf8).contains("refs/heads/target"))

        _ = try await git(repository, ["commit", "--allow-empty", "-m", "第二次隔离推送"])
        let second = try await repository.resolve()
        _ = try await git(repository, ["push", "--dry-run", "origin", "HEAD:refs/heads/dry-only"])
        records = try await confirmation.scan(installed)
        #expect(records.flatMap(\.updates).first { $0.remoteRef == "refs/heads/dry-only" }?.confirmation == .unconfirmable)
        try Data().write(to: repository.gitDirectory.appendingPathComponent("reject-push"))
        let rejected = try await git(repository, ["push", "origin", "HEAD:refs/heads/rejected"], success: false)
        #expect(!rejected.result.succeeded)
        records = try await confirmation.scan(installed)
        #expect(records.flatMap(\.updates).first { $0.remoteRef == "refs/heads/rejected" }?.confirmation == .unconfirmable)
        try FileManager.default.removeItem(at: repository.gitDirectory.appendingPathComponent("reject-push"))

        _ = try await git(repository, ["push", "origin", "HEAD:refs/heads/target", "HEAD:refs/heads/another"])
        _ = try await git(repository, ["commit", "--allow-empty", "-m", "连续推送的新提交"])
        let third = try await repository.resolve()
        _ = try await git(repository, ["push", "origin", "HEAD:refs/heads/target"])
        // 扫描发生在远端已经继续前进之后，前一次的成功仍由本地证据准确确认。
        records = try await confirmation.scan(installed)
        let targetUpdates = records.flatMap(\.updates).filter { $0.remoteRef == "refs/heads/target" && $0.confirmation == .confirmed }
        #expect(Set(targetUpdates.map(\.newSHA)) == Set([first, second, third]))
        #expect(records.contains { $0.updates.count == 2 && $0.updates.allSatisfy { $0.confirmation == .confirmed } })
        #expect(try await confirmation.scan(installed).count == records.count)

        _ = try await git(repository, ["push", "origin", ":refs/heads/another"])
        records = try await confirmation.scan(installed)
        #expect(records.flatMap(\.updates).contains { $0.kind == .delete && !$0.createsRun })
        _ = try await git(repository, ["push", "--no-verify", "origin", "HEAD:refs/heads/no-verify"])
        #expect(try await confirmation.scan(installed).count == records.count)
        #expect(try Data(contentsOf: prepush) == original)

        _ = try await git(repository, ["tag", "ordinary-tag"])
        _ = try await git(repository, ["push", "origin", "refs/tags/ordinary-tag"])
        let ordinaryTag = try await waitConfirmation(confirmation, installed: installed, ref: "refs/tags/ordinary-tag")
        #expect(ordinaryTag.confirmedBy == .lsRemote)
        let remoteURL = root.appendingPathComponent("remote.git").path
        _ = try await git(repository, ["push", remoteURL, "HEAD:refs/heads/url-target"])
        #expect(try await waitConfirmation(confirmation, installed: installed, ref: "refs/heads/url-target").confirmedBy == .lsRemote)

        _ = try await git(repository, ["tag", "dry-tag"])
        _ = try await git(repository, ["push", "--dry-run", "origin", "refs/tags/dry-tag"])
        let external = try await CommandRunner().capture(Command(executable: repository.executable,
            arguments: ["-C", remoteURL, "update-ref", "refs/tags/dry-tag", third.rawValue],
            environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]))
        #expect(external.result.succeeded)
        records = try await confirmation.scan(installed)
        #expect(records.flatMap(\.updates).first { $0.remoteRef == "refs/tags/dry-tag" }?.confirmation == .unconfirmable)

        try await installer.uninstall(installed, repository: repository)
        #expect(try Data(contentsOf: prepush) == original)
        let configuredPath = try await git(repository, ["config", "--get", "core.hooksPath"])
        #expect(configuredPath.outputString.trimmingCharacters(in: .newlines) == hooks.path)
        #expect(try await !installer.isIntact(installed, repository: repository))
    }

    private func waitConfirmation(_ confirmation: PushConfirmation, installed: InstalledHooks, ref: String) async throws -> RefUpdate {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let records = try await confirmation.scan(installed)
            if let update = records.flatMap(\.updates).first(where: { $0.remoteRef == ref }), update.confirmation == .confirmed { return update }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HookFailure("未取得普通推送的补充确认：\(ref)")
    }

    private func git(_ repository: GitRepository, _ arguments: [String], success: Bool = true) async throws -> CapturedCommand {
        let result = try await CommandRunner().capture(Command(
            executable: repository.executable, arguments: ["-C", repository.root.path] + arguments,
            environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"]))
        if success && !result.result.succeeded { throw HookFailure("隔离 Git 操作失败：\(result.errorString)") }
        return result
    }
}
