import Darwin
import Foundation
import Platform

public struct GitConfigHook: Sendable, Equatable, Codable {
    public let name: String
    public let event: String
    public let command: String

    public init(name: String, event: String, command: String) {
        self.name = name; self.event = event; self.command = command
    }
}

extension GitRepository {
    public func supportsConfigHooks() async throws -> Bool {
        let result = try await run(["--version"])
        guard result.result.succeeded else { throw GitError("无法读取 Git 版本") }
        let version = result.outputString.split(separator: " ").dropFirst(2).first ?? ""
        let numbers = version.split(separator: ".").prefix(2).compactMap { Int($0) }
        return numbers.count == 2 && (numbers[0] > 2 || (numbers[0] == 2 && numbers[1] >= 54))
    }

    public func configHookMatches(_ hook: GitConfigHook) async throws -> Bool {
        let values = try await configHookValues(hook.name)
        let keys = try await run(["config", "--local", "--name-only", "--get-regexp", "^hook\\.\(hook.name)\\."])
        return values == [hook.event, hook.command, "true"] &&
            Set(keys.outputString.split(separator: "\n").map(String.init)) == Set(["event", "command", "enabled"].map { "hook.\(hook.name).\($0)" })
    }

    /// 只增删本应用保留命名空间，不修改已有 hook 文件或 core.hooksPath。
    /// 用 Git 自己的 config.lock 协议提交整组配置，避免安装一半或覆盖其他客户端的新配置。
    public func updateConfigHooks(_ hooks: [GitConfigHook], removing: Bool = false) async throws {
        guard !hooks.isEmpty, hooks.allSatisfy({
            $0.name.hasPrefix("localcicd-") &&
            $0.name.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 } &&
            ["pre-push", "reference-transaction"].contains($0.event) && !$0.command.utf8.contains(0)
        }) else { throw GitError("本地监听钩子的名称或事件不合法") }
        let config = commonDirectory.appendingPathComponent("config")
        let lock = commonDirectory.appendingPathComponent("config.lock")
        let fd = Darwin.open(lock.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GitError("Git 配置正在被其他程序修改，请稍后重试") }
        let temporary = commonDirectory.appendingPathComponent("localcicd-config-\(UUID().uuidString)")
        defer { close(fd); unlink(lock.path); unlink(temporary.path); unlink(temporary.path + ".lock") }
        let source = Darwin.open(config.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard source >= 0 else { throw GitError("无法安全读取仓库本地配置") }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == getuid(), info.st_size >= 0, info.st_size <= 4_194_304
        else { throw GitError("仓库配置文件的类型、所有者或大小不符合要求") }
        let handle = FileHandle(fileDescriptor: source, closeOnDealloc: false)
        let original = try handle.read(upToCount: 4_194_305) ?? Data()
        guard original.count <= 4_194_304 else { throw GitError("仓库配置超过大小限制") }
        try original.write(to: temporary, options: .withoutOverwriting)
        guard chmod(temporary.path, 0o600) == 0 else { throw GitError("无法保护仓库配置临时文件") }
        for hook in hooks {
            let expected = [hook.event, hook.command, "true"]
            var actual: [String] = []
            for field in ["event", "command", "enabled"] {
                let result = try await run(["config", "--file", temporary.path, "--get-all", "hook.\(hook.name).\(field)"])
                guard [0, 1].contains(result.result.exitCode) else { throw GitError("无法检查已安装的监听配置") }
                actual.append(Self.trimLineEnding(result.outputString))
            }
            let exists = actual.contains { !$0.isEmpty }
            let keyResult = try await run(["config", "--file", temporary.path, "--name-only", "--get-regexp", "^hook\\.\(hook.name)\\."])
            let keys = Set(keyResult.outputString.split(separator: "\n").map(String.init))
            let expectedKeys = Set(["event", "command", "enabled"].map { "hook.\(hook.name).\($0)" })
            guard [0, 1].contains(keyResult.result.exitCode), keys.isEmpty || keys == expectedKeys else {
                throw GitError("监听配置含新增字段，不会删除或覆盖外部修改")
            }
            guard !exists || actual == expected else {
                throw GitError("监听配置已被外部修改，请先检查；不会覆盖现有内容")
            }
            if removing {
                if exists {
                    let result = try await run(["config", "--file", temporary.path, "--remove-section", "hook.\(hook.name)"])
                    guard result.result.succeeded else { throw GitError("无法卸载本地监听配置") }
                }
            } else if !exists {
                for (field, value) in zip(["event", "command", "enabled"], expected) {
                    let result = try await run(["config", "--file", temporary.path, "--add", "hook.\(hook.name).\(field)", value])
                    guard result.result.succeeded else { throw GitError("无法写入本地监听配置") }
                }
            }
        }
        try Task.checkCancellation()
        guard chmod(temporary.path, info.st_mode & 0o777) == 0 else { throw GitError("无法恢复 Git 配置权限") }
        let prepared = Darwin.open(temporary.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard prepared >= 0 else { throw GitError("无法打开新 Git 配置") }
        defer { close(prepared) }
        guard fsync(prepared) == 0, rename(temporary.path, config.path) == 0 else {
            throw GitError("无法原子保存本地监听配置")
        }
    }

    private func configHookValues(_ name: String) async throws -> [String] {
        var values: [String] = []
        for field in ["event", "command", "enabled"] {
            let result = try await run(["config", "--local", "--get-all", "hook.\(name).\(field)"])
            guard [0, 1].contains(result.result.exitCode) else { throw GitError("无法读取监听配置") }
            values.append(Self.trimLineEnding(result.outputString))
        }
        return values
    }
}
