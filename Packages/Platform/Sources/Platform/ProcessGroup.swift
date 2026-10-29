import Darwin
import Foundation

/// 只跟踪本次 spawn 创建的独立进程组，不按名称查杀进程。
actor ProcessGroup {
    struct Identity: Sendable, Equatable {
        var pid: pid_t
        var seconds: UInt64
        var microseconds: UInt64
    }

    private var pid: pid_t?
    private var identity: Identity?
    private var cleanup: Task<Bool, Never>?
    private var monitor: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private(set) var reason: ProcessStopReason?
    private let grace: Duration

    init(grace: Duration) { self.grace = grace }

    func register(_ pid: pid_t, timeout: Duration?) async throws {
        guard pid > 1, pid != getpgrp() else { throw CommandError("子进程未建立独立进程组") }
        self.pid = pid
        let info = Self.info(pid)
        if let info, info.pbi_pgid != UInt32(pid) { throw CommandError("子进程组不属于本次执行，已拒绝向它发送信号") }
        identity = info.map { Identity(pid: pid, seconds: $0.pbi_start_tvsec, microseconds: $0.pbi_start_tvusec) }
        if reason != nil { _ = await stop(reason); return }
        monitor = Task {
            // 组长退出后，后台后代可能仍占着输出管道，必须主动结束它们才能读到 EOF。
            while !Task.isCancelled {
                if let info = Self.info(pid), info.pbi_status != UInt32(SZOMB) {
                    do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                } else {
                    _ = await self.stop(nil)
                    return
                }
            }
        }
        if let timeout {
            timer = Task {
                do {
                    try await Task.sleep(for: timeout)
                    _ = await self.stop(.timeout)
                } catch {}
            }
        }
    }

    @discardableResult
    func stop(_ requested: ProcessStopReason?) async -> Bool {
        if reason == nil { reason = requested }
        guard let pid else { return true }
        if let cleanup { return await cleanup.value }
        let identity = identity
        let grace = grace
        // 清理不能继承调用者的取消状态，否则 TERM 宽限期会被立即跳过。
        let task = Task.detached {
            guard Self.owned(pid, identity: identity) else { return false }
            if Self.liveMembers(pid).isEmpty { return true }
            guard killpg(pid, SIGTERM) == 0 || errno == ESRCH else { return false }
            let deadline = ContinuousClock.now.advanced(by: grace)
            while ContinuousClock.now < deadline {
                if Self.liveMembers(pid).isEmpty { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard Self.owned(pid, identity: identity) else { return false }
            guard killpg(pid, SIGKILL) == 0 || errno == ESRCH else { return false }
            let killedDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < killedDeadline {
                if Self.liveMembers(pid).isEmpty { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return Self.liveMembers(pid).isEmpty
        }
        cleanup = task
        return await task.value
    }

    func finish() async -> Bool {
        timer?.cancel()
        monitor?.cancel()
        return await stop(nil)
    }

    private static func owned(_ pid: pid_t, identity: Identity?) -> Bool {
        guard pid > 1, pid != getpgrp() else { return false }
        guard let current = info(pid) else { return true } // 组长已退出，存活组员仍保有组 ID。
        guard current.pbi_pgid == UInt32(pid), let identity else { return false }
        return current.pbi_start_tvsec == identity.seconds && current.pbi_start_tvusec == identity.microseconds
    }

    static func info(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    static func liveMembers(_ group: pid_t) -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.stride + 64)
        let used = pids.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), raw.baseAddress, Int32(raw.count))
        }
        guard used > 0 else { return [] }
        return pids.prefix(Int(used) / MemoryLayout<pid_t>.stride).filter {
            guard $0 > 0, let info = info($0) else { return false }
            return info.pbi_pgid == UInt32(group) && info.pbi_status != UInt32(SZOMB)
        }
    }
}
