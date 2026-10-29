import Darwin
import Foundation

public enum LogStream: String, Sendable, Codable { case stdout, stderr, system }

public struct LogSnapshot: Sendable, Equatable {
    public var text: String
    public var textStartOffset: Int
    public var bytesWritten: Int
    public var truncated: Bool
    public var finished: Bool
}

public struct LogManifest: Sendable, Codable {
    public var version = 1
    public var segments: [String]
    public var bytesWritten: Int
    public var truncated: Bool
    public var finished: Bool
}

/// 只写脱敏后的 UTF-8。超出上限后继续接收并丢弃输出，不中断正在执行的任务。
public actor JobLogStore {
    public let directory: URL
    private let maximumBytes: Int
    private let segmentBytes: Int
    private var sanitizers: [LogStream: LogSanitizer]
    private var pending: [LogStream: String] = [:]
    private var droppingLine: Set<LogStream> = []
    private var segments: [String] = []
    private var handle: FileHandle?
    private var segmentWritten = 0
    private var bytesWritten = 0
    private var tail = ""
    private var truncated = false
    private var finished = false
    private var subscribers: [UUID: AsyncStream<LogSnapshot>.Continuation] = [:]
    private var notificationTask: Task<Void, Never>?
    private static let truncationNotice = "\n[日志已达到大小上限，后续输出不再保存，任务继续执行]\n"

    public init(directory: URL, allowedRoot: URL, secrets: [String] = [], maximumBytes: Int = 4 * 1_024 * 1_024, segmentBytes: Int = 1_024 * 1_024) throws {
        let path = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let root = allowedRoot.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard path.count > root.count, Array(path.prefix(root.count)) == root else { throw LogError("日志目录越出应用管理范围") }
        let sanitizer = try LogSanitizer(secrets: secrets)
        self.directory = directory
        self.maximumBytes = max(256, maximumBytes)
        self.segmentBytes = max(64, segmentBytes)
        self.sanitizers = [.stdout: sanitizer, .stderr: sanitizer, .system: sanitizer]
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard mkdir(directory.path, 0o700) == 0 else { throw LogError("本次尝试的日志目录已存在或无法创建，拒绝覆盖旧日志") }
    }

    public func append(_ data: Data, stream: LogStream = .stdout) throws {
        guard !finished, !truncated else { return }
        let text = sanitizers[stream]!.append(data)
        try consume(text, stream: stream)
        scheduleNotification()
    }

    public func message(_ text: String) throws {
        try append(Data("[本地] \(text)\n".utf8), stream: .system)
    }

    public func finish() throws {
        guard !finished else { return }
        for stream in [LogStream.stdout, .stderr, .system] {
            let text = sanitizers[stream]!.finish()
            try consume(text, stream: stream)
            if let remainder = pending[stream], !remainder.isEmpty { try write(remainder) }
        }
        pending.removeAll()
        finished = true
        try handle?.synchronize()
        try handle?.close()
        handle = nil
        try persistManifest()
        notificationTask?.cancel()
        notificationTask = nil
        broadcast()
        for subscriber in subscribers.values { subscriber.finish() }
        subscribers.removeAll()
    }

    public func snapshot() -> LogSnapshot {
        let partial = [LogStream.stdout, .stderr, .system].compactMap { pending[$0] }.joined()
        let text = Self.boundedSuffix(tail + partial)
        return LogSnapshot(text: text, textStartOffset: max(0, bytesWritten + partial.utf8.count - text.utf8.count),
            bytesWritten: bytesWritten, truncated: truncated, finished: finished)
    }

    public func updates() -> AsyncStream<LogSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: LogSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(snapshot())
        if finished { continuation.finish(); return stream }
        subscribers[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }

    /// 历史读取只接受本地生成的分段名称，并限制累计读取；索引损坏时也不允许越界读文件。
    public static func read(directory: URL, maximumBytes: Int = 4 * 1_024 * 1_024) throws -> String {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
            $0.count == 10 && $0.hasSuffix(".log") && $0.prefix(6).allSatisfy(\.isNumber)
        }.sorted()
        var data = Data()
        for name in names {
            let url = directory.appending(path: name)
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw LogError("日志文件无法读取，或已被替换成符号链接") }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw LogError("日志分段不是普通文件")
            }
            let remaining = max(0, maximumBytes - data.count)
            let part = try file.read(upToCount: remaining + 1) ?? Data()
            guard part.count <= remaining else { throw LogError("历史日志超过读取上限") }
            data.append(part)
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func readManifest(directory: URL) throws -> LogManifest {
        let descriptor = Darwin.open(directory.appending(path: "index.json").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw LogError("日志分段索引不存在或已被替换") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 512 << 10,
              let data = try handle.read(upToCount: (512 << 10) + 1), data.count <= 512 << 10,
              let manifest = try? JSONDecoder().decode(LogManifest.self, from: data),
              manifest.version == 1, manifest.bytesWritten >= 0
        else { throw LogError("日志分段索引损坏或超过大小上限") }
        return manifest
    }

    private func consume(_ text: String, stream: LogStream) throws {
        guard !truncated else { return }
        var value = (pending[stream] ?? "") + text
        if droppingLine.contains(stream) {
            guard let newline = value.firstIndex(of: "\n") else { return }
            value = String(value[value.index(after: newline)...])
            droppingLine.remove(stream)
        }
        while let newline = value.firstIndex(of: "\n") {
            let line = String(value[..<newline])
            if line.utf8.count > 65_536 {
                try write(Self.boundedPrefix(line, bytes: 65_536) + "\n[单行日志过长，已截断]\n")
            } else { try write(line + "\n") }
            value = String(value[value.index(after: newline)...])
            if truncated { value = ""; break }
        }
        if value.utf8.count > 65_536 {
            try write(Self.boundedPrefix(value, bytes: 65_536) + "\n[单行日志过长，已截断]\n")
            value = ""
            droppingLine.insert(stream)
        }
        pending[stream] = value
    }

    private func write(_ text: String) throws {
        guard !truncated else { return }
        let data = Data(text.utf8)
        let available = max(0, maximumBytes - Self.truncationNotice.utf8.count - bytesWritten)
        if data.count <= available { try writeBytes(data); return }
        var prefix = Data(data.prefix(available))
        while !prefix.isEmpty, String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        try writeBytes(prefix)
        try writeBytes(Data(Self.truncationNotice.utf8))
        truncated = true
        pending.removeAll()
        try persistManifest()
    }

    private func writeBytes(_ data: Data) throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            if handle == nil || segmentWritten == segmentBytes {
                try handle?.close()
                let name = String(format: "%06d.log", segments.count)
                let descriptor = Darwin.open(directory.appending(path: name).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard descriptor >= 0 else { throw LogError("无法创建本次尝试的日志分段") }
                handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                segments.append(name)
                segmentWritten = 0
            }
            let count = min(segmentBytes - segmentWritten, data.endIndex - offset)
            try handle?.write(contentsOf: data[offset..<offset + count])
            offset += count
            bytesWritten += count
            segmentWritten += count
        }
        tail += String(decoding: data, as: UTF8.self)
        if tail.utf8.count > 262_144 { tail = Self.boundedSuffix(tail) }
    }

    private static func boundedPrefix(_ text: String, bytes: Int) -> String {
        var data = Data(text.utf8.prefix(bytes))
        while !data.isEmpty, String(data: data, encoding: .utf8) == nil { data.removeLast() }
        return String(decoding: data, as: UTF8.self)
    }

    private static func boundedSuffix(_ text: String) -> String {
        let data = Array(text.utf8.suffix(262_144))
        var start = 0
        while start < data.count, data[start] & 0xC0 == 0x80 { start += 1 }
        return String(decoding: data[start...], as: UTF8.self)
    }

    private func persistManifest() throws {
        let manifest = LogManifest(segments: segments, bytesWritten: bytesWritten, truncated: truncated, finished: finished)
        let url = directory.appending(path: "index.json")
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func scheduleNotification() {
        guard notificationTask == nil else { return }
        notificationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(75)) } catch { return }
            await self?.notifyNow()
        }
    }
    private func notifyNow() { notificationTask = nil; broadcast() }
    private func broadcast() { let value = snapshot(); for continuation in subscribers.values { continuation.yield(value) } }
    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }
}
