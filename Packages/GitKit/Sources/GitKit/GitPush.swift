import Foundation
import Models
import Platform

extension GitRepository {
    /// 远端地址通过子进程环境配置传入，避免内嵌认证信息进入命令行参数。
    public func remoteObject(url: String, targetRef: String) async throws -> CommitSHA? {
        guard !url.isEmpty, !url.utf8.contains(0), !url.hasPrefix("ext::") else { throw GitError("不支持此远端确认地址") }
        let checked = try await run(["check-ref-format", targetRef])
        guard checked.result.succeeded else { throw GitError("远端确认引用不合法") }
        var command = Self.command(git: executable, directory: root.path, arguments: [
            "-c", "protocol.ext.allow=never", "ls-remote", "--refs", "--exit-code", "local-cicd-confirmation", targetRef,
        ])
        command.environment["GIT_CONFIG_COUNT"] = "1"
        command.environment["GIT_CONFIG_KEY_0"] = "remote.local-cicd-confirmation.url"
        command.environment["GIT_CONFIG_VALUE_0"] = url
        command.timeout = .seconds(15)
        let result = try await runner.capture(command, limit: 1_048_576)
        if result.result.exitCode == 2 { return nil }
        guard result.result.succeeded else { throw GitError("无法读取本次推送的远端引用") }
        let matches = result.outputString.split(separator: "\n").compactMap { line -> CommitSHA? in
            let parts = line.split(separator: "\t")
            guard parts.count == 2, parts[1] == targetRef else { return nil }
            return CommitSHA(rawValue: String(parts[0]))
        }
        guard matches.count <= 1 else { throw GitError("远端返回了重复的目标引用") }
        return matches.first
    }

    /// 远端唯一的推送地址，用于向远端确认本次推送的结果。
    public func pushURL(remote: String) async throws -> String {
        guard !remote.isEmpty, !remote.hasPrefix("-"), !remote.utf8.contains(0), !remote.contains("\n") else {
            throw GitError("远端名称不合法")
        }
        let remotes = try await run(["remote"])
        guard remotes.outputString.split(separator: "\n").contains(Substring(remote)) else {
            throw GitError("请选择仓库已配置的命名远端")
        }
        let result = try await run(["remote", "get-url", "--push", "--all", remote])
        let urls = result.outputString.split(separator: "\n").map(String.init)
        guard result.result.succeeded, urls.count == 1 else {
            throw GitError("该远端需要恰好配置一个推送地址才能确认推送结果")
        }
        return urls[0]
    }
}
