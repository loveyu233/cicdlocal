import Foundation
import Models
import Platform

public struct GitError: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// 只读仓库入口。所有内容读取均绑定对象，不切分支、不改索引、不运行用户钩子。
public struct GitRepository: Sendable {
    public let root: URL
    public let executable: String
    public let gitDirectory: URL
    public let commonDirectory: URL
    let runner = CommandRunner()

    public static func open(_ directory: URL, executable: String? = nil) async throws -> GitRepository {
        let git = try executable ?? locateGit()
        let path = directory.standardizedFileURL.resolvingSymlinksInPath()
        func read(_ argument: String) async throws -> String {
            let result = try await CommandRunner().capture(command(git: git, directory: path.path, arguments: ["rev-parse", argument]))
            guard result.result.succeeded else { throw GitError("所选目录不是可读取的本地 Git 仓库") }
            return trimLineEnding(result.outputString)
        }
        let bare = try await read("--is-bare-repository")
        guard bare == "false" else { throw GitError("请选择带工作目录的 Git 仓库，不支持添加裸仓库") }
        let root = URL(fileURLWithPath: try await read("--show-toplevel")).resolvingSymlinksInPath()
        let gitDirectory = URL(fileURLWithPath: try await read("--absolute-git-dir")).resolvingSymlinksInPath()
        let common = try await CommandRunner().capture(command(git: git, directory: root.path, arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"]))
        guard common.result.succeeded else { throw GitError("无法识别仓库共享目录") }
        return GitRepository(root: root, executable: git, gitDirectory: gitDirectory, commonDirectory: URL(fileURLWithPath: trimLineEnding(common.outputString)).resolvingSymlinksInPath())
    }

    public var isLinkedWorktree: Bool { gitDirectory != commonDirectory }

    public func resolve(_ ref: String = "HEAD") async throws -> CommitSHA {
        guard !ref.isEmpty, !ref.utf8.contains(0) else { throw GitError("引用名称不能为空或包含空字节") }
        let result = try await run(["rev-parse", "--verify", "--end-of-options", "\(ref)^{commit}"])
        guard result.result.succeeded, let sha = CommitSHA(rawValue: Self.trimLineEnding(result.outputString)), !sha.isZero else {
            throw GitError("指定引用无法解析为本地提交")
        }
        return sha
    }

    public func currentBranch() async throws -> String? {
        let result = try await run(["symbolic-ref", "--quiet", "--short", "HEAD"])
        if result.result.exitCode == 1 { return nil }
        guard result.result.succeeded else { throw GitError("无法读取当前分支") }
        return Self.trimLineEnding(result.outputString)
    }

    public func isDirty() async throws -> Bool {
        let result = try await run(["status", "--porcelain=v1", "-z", "--untracked-files=normal"])
        guard result.result.succeeded else { throw GitError("无法检查工作目录状态") }
        return !result.stdout.isEmpty
    }

    /// 提交说明，去掉首尾空白；超过 `limit` 个字符的部分截掉。
    public func commitMessage(_ sha: CommitSHA, limit: Int = 2_000) async throws -> String {
        let result = try await run(["log", "-1", "--no-color", "--format=%B", "--end-of-options", sha.rawValue], limit: 64 * 1_024)
        guard result.result.succeeded else { throw GitError("无法读取提交 \(sha.short) 的说明") }
        let text = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// 读取提交中某个文件的内容；文件不存在返回 nil。
    ///
    /// 只接受普通文件：符号链接、子模块、目录和超过 `limit` 字节的文件都抛出错误，
    /// 防止配置借符号链接指向项目外的内容。
    public func fileContents(_ path: String, at sha: CommitSHA, limit: Int = 64 * 1_024) async throws -> Data? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0),
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" })
        else { throw GitError("文件路径必须是项目内的相对路径") }

        let listing = try await run(["--literal-pathspecs", "ls-tree", "-z", "--full-tree", sha.rawValue, "--", path])
        guard listing.result.succeeded else { throw GitError("无法读取提交 \(sha.short) 的文件列表") }
        let entries = listing.stdout.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
        guard let entry = entries.first(where: { $0.hasSuffix("\t\(path)") }) else { return nil }
        let fields = entry.prefix(while: { $0 != "\t" }).split(separator: " ")
        guard fields.count == 3 else { throw GitError("无法识别 \(path) 的文件类型") }
        switch (fields[0], fields[1]) {
        case ("120000", _): throw GitError("\(path) 是符号链接，请改为普通文件")
        case ("100644", "blob"), ("100755", "blob"): break
        default: throw GitError("\(path) 不是普通文件")
        }
        let object = String(fields[2])

        let size = try await run(["cat-file", "-s", object])
        guard size.result.succeeded, let bytes = Int(Self.trimLineEnding(size.outputString)) else {
            throw GitError("无法读取 \(path) 的大小")
        }
        guard bytes <= limit else { throw GitError("\(path) 超过 \(limit / 1_024) KiB") }
        let blob = try await run(["cat-file", "blob", object], limit: bytes + 1_024)
        guard blob.result.succeeded, blob.stdout.count == bytes else { throw GitError("无法读取 \(path) 的内容") }
        return blob.stdout
    }

    func run(_ arguments: [String], limit: Int = 4 * 1_024 * 1_024) async throws -> CapturedCommand {
        try await runner.capture(Self.command(git: executable, directory: root.path, arguments: arguments), limit: limit)
    }

    static func command(git: String, directory: String, arguments: [String], input: Data = Data()) -> Command {
        var environment: [String: String?] = [:]
        // App 可能由带 GIT_DIR 等环境的终端启动，不能让它把用户选择的目录换成另一个仓库。
        for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("GIT_") { environment.updateValue(nil, forKey: key) }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        return Command(executable: git, arguments: [
            "--no-optional-locks", "--no-replace-objects", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-C", directory,
        ] + arguments, environment: environment, input: input)
    }

    static func trimLineEnding(_ value: String) -> String {
        value.hasSuffix("\n") ? String(value.dropLast()) : value
    }

    static func locateGit() throws -> String {
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"] where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw GitError("没有找到 Git，请先安装 Xcode Command Line Tools 或配置 Git 程序路径")
    }
}
