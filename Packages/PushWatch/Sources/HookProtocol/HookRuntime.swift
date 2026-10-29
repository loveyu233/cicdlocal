import Darwin
import Foundation

/// 钩子入口只记录本地证据，不解析 CI、不连接远端，也不启动任务。
public enum HookRuntime {
    public static func run(arguments: [String] = CommandLine.arguments) -> Int32 {
        do {
            guard arguments.count >= 4 else { throw HookFailure("钩子参数不完整") }
            if arguments[1] == "observe-exit" {
                try PushExitObserver.observe(configuration: URL(fileURLWithPath: arguments[2]), key: arguments[3])
                return 0
            }
            let installation = try HookSpool.read(HookInstallation.self, url: URL(fileURLWithPath: arguments[2]))
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
            // 本地 Git 配置可能由 worktree 共享；只有用户启用的准确目录可以产生事件。
            guard cwd == installation.repositoryPath else { return 0 }
            let process = try gitParent()
            let spool = try HookSpool(root: URL(fileURLWithPath: installation.spoolPath))
            switch arguments[1] {
            case "pre-push":
                guard arguments.count == 5 else { throw HookFailure("推送钩子参数不完整") }
                let input = try readInput()
                var refs = try HookRef.parse(input)
                guard !refs.isEmpty else { return 0 }
                let refspecs = try fetchRefspecs(remote: arguments[3], installation: installation)
                for index in refs.indices {
                    refs[index].trackingRef = trackingRef(remoteRef: refs[index].remoteRef, refspecs: refspecs)
                }
                var intent = HookIntent(
                    installation: installation, process: process, remoteName: arguments[3], remoteURL: arguments[4], refs: refs)
                intent.permitsExitConfirmation = (try? PushExitObserver.processArguments(process)).map(PushExitObserver.permitsConfirmation) ?? false
                try spool.write(intent, name: "\(intent.id.uuidString).intent.json")
                // 同一 Git 进程按远端串行推送，当前事件只用于关联随后发生的引用事务。
                try spool.write(intent, name: "\(process.key).active.json")
                if intent.permitsExitConfirmation == true {
                    try PushExitObserver.start(configuration: URL(fileURLWithPath: arguments[2]), installation: installation, process: process, spool: spool)
                }
            case "reference-transaction":
                guard arguments.count == 4, arguments[3] == "committed" else { return 0 }
                let input = try readInput()
                let activeName = "\(process.key).active.json"
                guard FileManager.default.fileExists(atPath: spool.root.appendingPathComponent(activeName).path) else { return 0 }
                let intent = try spool.read(HookIntent.self, name: activeName)
                guard intent.installationID == installation.id, intent.process == process else { return 0 }
                let updates = try matchingUpdates(input, intent: intent)
                guard !updates.isEmpty else { return 0 }
                let receipt = HookReceipt(intentID: intent.id, process: process, updates: updates)
                try spool.write(receipt, name: "\(intent.id.uuidString).\(UUID().uuidString).receipt.json")
            default:
                throw HookFailure("无法识别钩子操作")
            }
        } catch {
            // 监听失败不能阻断 Git 推送；不打印可能含凭据的外部错误。
            FileHandle.standardError.write(Data("本地 CI：推送监听记录失败，请在 App 中检查监听状态；Git 推送继续。\n".utf8))
        }
        return 0
    }

    public static func trackingRef(remoteRef: String, refspecs: [String]) -> String? {
        var destinations = Set<String>()
        for raw in refspecs {
            let spec = raw.hasPrefix("+") ? String(raw.dropFirst()) : raw
            if spec.hasPrefix("^") {
                if match(remoteRef, pattern: String(spec.dropFirst())) != nil { return nil }
                continue
            }
            let pair = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard pair.count == 2, let capture = match(remoteRef, pattern: pair[0]) else { continue }
            let target = pair[1].replacingOccurrences(of: "*", with: capture)
            if HookRef.validRef(target), target.hasPrefix("refs/remotes/") { destinations.insert(target) }
        }
        return destinations.count == 1 ? destinations.first : nil
    }

    public static func matchingUpdates(_ input: Data, intent: HookIntent) throws -> [HookReceipt.Update] {
        guard let text = String(data: input, encoding: .utf8) else { throw HookFailure("引用事务不是有效 UTF-8") }
        var results: [HookReceipt.Update] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count == 3 else { continue }
            for ref in intent.refs where ref.trackingRef == parts[2] && ref.newSHA == parts[1] {
                results.append(.init(remoteRef: ref.remoteRef, newSHA: ref.newSHA))
            }
        }
        return results
    }

    private static func match(_ ref: String, pattern: String) -> String? {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 { return ref == pattern ? "" : nil }
        guard parts.count == 2, ref.hasPrefix(parts[0]), ref.hasSuffix(parts[1]),
            ref.count >= parts[0].count + parts[1].count else { return nil }
        return String(ref.dropFirst(parts[0].count).dropLast(parts[1].count))
    }

    private static func readInput() throws -> Data {
        var data = Data()
        var tooLarge = false
        while let chunk = try FileHandle.standardInput.read(upToCount: 16_384), !chunk.isEmpty {
            if data.count + chunk.count <= 1_048_576 && !tooLarge { data.append(chunk) }
            else { tooLarge = true }
        }
        // 即使输入过大也先读完，避免因断开管道而影响正常推送。
        guard !tooLarge else { throw HookFailure("钩子输入超过大小限制") }
        return data
    }

    private static func gitParent() throws -> HookProcess {
        let pid = getppid()
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { throw HookFailure("无法识别 Git 父进程") }
        let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard URL(fileURLWithPath: executable).lastPathComponent == "git" else {
            throw HookFailure("钩子没有直接由 Git 调用")
        }
        return try HookProcess.inspect(pid)
    }

    private static func fetchRefspecs(remote: String, installation: HookInstallation) throws -> [String] {
        guard !remote.isEmpty, !remote.contains("://"), !remote.contains("/"), !remote.contains(":"),
            !remote.unicodeScalars.contains(where: { $0.value <= 32 })
        else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: installation.gitExecutable)
        process.arguments = ["--no-optional-locks", "-C", installation.repositoryPath, "config", "--get-all", "remote.\(remote).fetch"]
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
            guard data.count + chunk.count <= 1_048_576 else {
                process.terminate()
                process.waitUntilExit()
                throw HookFailure("远端引用映射超过大小限制")
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard [0, 1].contains(process.terminationStatus) else { throw HookFailure("无法读取远端引用映射") }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
