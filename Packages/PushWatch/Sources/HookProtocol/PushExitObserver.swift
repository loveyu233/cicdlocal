import Darwin
import Foundation

public struct PushExitReceipt: Codable, Sendable, Equatable {
    public let process: HookProcess
    public let waitStatus: Int32
    public let recordedAt: Date
    public var succeeded: Bool { waitStatus == 0 }
}

/// 一次性进程观察器只保存 Git 的内核退出结果，不承担后台 CI 执行。
public enum PushExitObserver {
    public static func permitsConfirmation(arguments: [String]) -> Bool {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "push" { break }
            if ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env"].contains(argument) {
                index += 2
            } else if ["--no-pager", "--paginate", "--no-optional-locks", "--no-replace-objects", "--literal-pathspecs"].contains(argument) ||
                        ["--git-dir=", "--work-tree=", "--namespace=", "--config-env="].contains(where: argument.hasPrefix) {
                index += 1
            } else { return false }
        }
        guard index < arguments.count, arguments[index] == "push" else { return false }
        for argument in arguments.dropFirst(index + 1) {
            if argument == "--" { break }
            if argument.hasPrefix("--"), argument.count >= 3, "--dry-run".hasPrefix(argument) { return false }
            if argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.contains("n") { return false }
        }
        return true
    }

    /// 命令行只在内存检查，绝不持久化其中可能存在的远端凭据和 push option。
    public static func processArguments(_ process: HookProcess) throws -> [String] {
        guard process.isRunning else { throw HookFailure("推送进程已结束") }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, process.pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size <= 2_097_152 else { throw HookFailure("无法核实推送进程参数") }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0, size >= 4, process.isRunning else {
            throw HookFailure("无法核实推送进程参数")
        }
        let count = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard count > 0, count <= 65_536 else { throw HookFailure("推送进程参数数量不合法") }
        var index = 4
        while index < size && bytes[index] != 0 { index += 1 }
        while index < size && bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            let start = index
            while index < size && bytes[index] != 0 { index += 1 }
            guard index < size, let argument = String(bytes: bytes[start..<index], encoding: .utf8) else {
                throw HookFailure("推送进程参数不是有效 UTF-8")
            }
            arguments.append(argument)
            index += 1
        }
        return arguments
    }

    public static func start(configuration: URL, installation: HookInstallation, process: HookProcess, spool: HookSpool) throws {
        let ready = "\(process.key).watch-ready.json"
        if let existing = try? spool.read(HookProcess.self, name: ready), existing == process { return }
        let observer = Process()
        observer.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        observer.arguments = ["observe-exit", configuration.path, process.key]
        observer.standardInput = FileHandle.nullDevice
        observer.standardOutput = FileHandle.nullDevice
        observer.standardError = FileHandle.nullDevice
        try observer.run()
        // 只有监视已在内核登记后才让 pre-push 返回，避免极短的推送丢失退出事件。
        let deadline = ContinuousClock.now + .milliseconds(300)
        while ContinuousClock.now < deadline {
            if let existing = try? spool.read(HookProcess.self, name: ready), existing == process { return }
            if !observer.isRunning { break }
            usleep(2_000)
        }
        if observer.isRunning { observer.terminate() }
        throw HookFailure("无法登记推送退出观察器")
    }

    public static func observe(configuration: URL, key: String) throws {
        // 观察器需要在 Git 退出后短暂保存结果；它不占用 Git 的输出管道或任务进程组。
        guard setsid() >= 0 || getpgrp() == getpid() else { throw HookFailure("无法隔离推送退出观察器") }
        let installation = try HookSpool.read(HookInstallation.self, url: configuration)
        let spool = try HookSpool(root: URL(fileURLWithPath: installation.spoolPath))
        let intent = try spool.read(HookIntent.self, name: "\(key).active.json")
        let process = intent.process
        guard process.key == key, process.isRunning, intent.installationID == installation.id else {
            throw HookFailure("推送进程身份已经变化")
        }
        let queue = kqueue()
        guard queue >= 0 else { throw HookFailure("无法创建推送退出观察器") }
        defer { close(queue) }
        var change = kevent(ident: UInt(process.pid), filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ONESHOT), fflags: NOTE_EXIT | UInt32(NOTE_EXITSTATUS), data: 0, udata: nil)
        guard kevent(queue, &change, 1, nil, 0, nil) == 0, process.isRunning else {
            throw HookFailure("无法登记推送进程退出事件")
        }
        try spool.write(process, name: "\(key).watch-ready.json")
        var event = kevent()
        var timeout = timespec(tv_sec: 3_600, tv_nsec: 0)
        let count = kevent(queue, nil, 0, &event, 1, &timeout)
        guard count == 1, event.flags & UInt16(EV_ERROR) == 0,
            event.fflags & UInt32(NOTE_EXITSTATUS) != 0 else { throw HookFailure("未取得 Git 的退出结果") }
        try spool.write(PushExitReceipt(process: process, waitStatus: Int32(truncatingIfNeeded: event.data), recordedAt: Date()),
            name: "\(key).exit.json")
    }
}
