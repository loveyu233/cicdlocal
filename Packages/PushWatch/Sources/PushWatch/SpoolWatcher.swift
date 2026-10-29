import Darwin
import Dispatch
import Foundation
import HookProtocol

/// 只观察应用自有目录；目录事件仅唤醒扫描，完整性仍由文件协议与数据库检查。
public final class SpoolWatcher: @unchecked Sendable {
    private let source: any DispatchSourceFileSystemObject

    public init(directory: URL, changed: @escaping @Sendable () -> Void) throws {
        let fd = open(directory.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HookFailure("无法观察推送记录目录") }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
            queue: DispatchQueue(label: "io.github.loveyu233.cicdlocal.spool"))
        source.setEventHandler(handler: changed)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
