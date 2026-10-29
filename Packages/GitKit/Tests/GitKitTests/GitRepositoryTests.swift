import Foundation
import Models
import Platform
import Testing
@testable import GitKit

/// 在临时目录里建一个仓库，只验证读取，不碰任何真实项目。
@Suite("GitRepository")
struct GitRepositoryTests {
    @Test("解析提交、分支和工作区状态")
    func resolvesHeadBranchAndDirtyState() async throws {
        try await withRepository { repository, directory in
            let head = try await repository.resolve()
            #expect(try await repository.resolve("main") == head)
            #expect(try await repository.currentBranch() == "main")
            #expect(try await repository.isDirty() == false)

            try Data("改动".utf8).write(to: directory.appending(path: "README.md"))
            #expect(try await repository.isDirty())

            await #expect(throws: GitError.self) { try await repository.resolve("不存在") }
        }
    }

    @Test("读取提交中的文件，而不是工作区里的文件")
    func readsFileAtCommit() async throws {
        try await withRepository { repository, directory in
            let first = try await repository.resolve()
            try Data("test:\n  - echo 2\n".utf8).write(to: directory.appending(path: ".local.cicd.yml"))
            try await git(repository, ["commit", "-qam", "第二次"])
            let second = try await repository.resolve()
            try Data("工作区".utf8).write(to: directory.appending(path: ".local.cicd.yml"))

            #expect(try await repository.fileContents(".local.cicd.yml", at: first) == Data("test:\n  - echo 1\n".utf8))
            #expect(try await repository.fileContents(".local.cicd.yml", at: second) == Data("test:\n  - echo 2\n".utf8))
            #expect(try await repository.fileContents("缺少.yml", at: second) == nil)
            #expect(try await repository.fileContents("sub/inner.txt", at: second) == Data("内部".utf8))
        }
    }

    @Test("拒绝符号链接、目录、超大文件和越界路径")
    func rejectsUnsafeFiles() async throws {
        try await withRepository { repository, directory in
            try FileManager.default.createSymbolicLink(
                atPath: directory.appending(path: "link.yml").path, withDestinationPath: "/etc/hosts")
            try Data(repeating: 0x61, count: 64 * 1_024 + 1).write(to: directory.appending(path: "big.yml"))
            try await git(repository, ["add", "link.yml", "big.yml"])
            try await git(repository, ["commit", "-qm", "危险文件"])
            let head = try await repository.resolve()

            for path in ["link.yml", "sub", "big.yml", "../x", "/etc/hosts", "sub/../README.md", ".git/config", ""] {
                await #expect(throws: GitError.self, "\(path)") { try await repository.fileContents(path, at: head) }
            }
            #expect(try await repository.fileContents("big.yml", at: head, limit: 128 * 1_024)?.count == 64 * 1_024 + 1)
        }
    }

    // MARK: 辅助

    @Test("读取提交说明：完整多行、去掉首尾空白，过长时截断")
    func commitMessage() async throws {
        try await withRepository { repository, directory in
            #expect(try await repository.commitMessage(try await repository.resolve()) == "初始")
            try Data("test:\n  - echo 2\n".utf8).write(to: directory.appending(path: ".local.cicd.yml"))
            try await git(repository, ["commit", "-qam", "修复登录\n\n详细说明第二行\n"])
            let sha = try await repository.resolve()
            #expect(try await repository.commitMessage(sha) == "修复登录\n\n详细说明第二行")
            #expect(try await repository.commitMessage(sha, limit: 4) == "修复登录…")
        }
    }

    private func withRepository(_ body: (GitRepository, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gitkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appending(path: "sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = try GitRepository.locateGit()
        let initialize = try await CommandRunner().capture(
            GitRepository.command(git: git, directory: directory.path, arguments: ["init", "-q", "-b", "main"]))
        try #require(initialize.result.succeeded)

        let repository = try await GitRepository.open(directory)
        try await self.git(repository, ["config", "user.name", "测试"])
        try await self.git(repository, ["config", "user.email", "test@example.invalid"])
        try await self.git(repository, ["config", "commit.gpgsign", "false"])
        try Data("说明".utf8).write(to: directory.appending(path: "README.md"))
        try Data("test:\n  - echo 1\n".utf8).write(to: directory.appending(path: ".local.cicd.yml"))
        try Data("内部".utf8).write(to: directory.appending(path: "sub/inner.txt"))
        try await self.git(repository, ["add", "."])
        try await self.git(repository, ["commit", "-qm", "初始"])
        try await body(repository, directory)
    }

    @discardableResult
    private func git(_ repository: GitRepository, _ arguments: [String]) async throws -> CapturedCommand {
        let result = try await repository.run(arguments)
        #expect(result.result.succeeded, "git \(arguments.joined(separator: " ")): \(result.errorString)")
        return result
    }
}
