import Darwin
import Foundation

/// 每个文件通过同目录临时文件和 rename 原子发布。读取不跟随符号链接且严格限长。
public struct HookSpool: Sendable {
    public let root: URL
    public init(root: URL) throws {
        guard root.path.hasPrefix("/"), root.standardizedFileURL == root,
            root.resolvingSymlinksInPath().path == root.path
        else { throw HookFailure("推送记录目录必须是无符号链接的绝对路径") }
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw HookFailure("推送记录目录的所有者或访问权限不正确")
        }
    }

    public func write<T: Encodable>(_ value: T, name: String) throws {
        try Self.validateName(name)
        let data = try JSONEncoder().encode(value)
        guard data.count <= 2_097_152 else { throw HookFailure("推送记录超过大小限制") }
        let temp = root.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HookFailure("无法创建推送记录临时文件") }
        defer { close(fd); unlink(temp.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw HookFailure("无法完整写入推送记录") }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temp.path, root.appendingPathComponent(name).path) == 0 else {
            throw HookFailure("无法保存推送记录")
        }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory >= 0 { _ = fsync(directory); close(directory) }
    }

    public func read<T: Decodable>(_ type: T.Type, name: String) throws -> T {
        try Self.validateName(name)
        return try Self.read(type, url: root.appendingPathComponent(name))
    }

    public static func read<T: Decodable>(_ type: T.Type, url: URL) throws -> T {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw HookFailure("无法读取推送记录") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == getuid(), info.st_mode & 0o077 == 0,
            info.st_size >= 0, info.st_size <= 2_097_152
        else { throw HookFailure("推送记录的类型、权限或大小不符合要求") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw HookFailure("读取推送记录失败") }
            if count == 0 { break }
            guard data.count + count <= 2_097_152 else { throw HookFailure("推送记录超过大小限制") }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try JSONDecoder().decode(type, from: data)
    }

    public func names(suffix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(suffix) && !$0.hasPrefix(".") }.sorted()
    }

    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 200, !name.hasPrefix("."),
            name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46].contains($0) })
        else { throw HookFailure("推送记录文件名不合法") }
    }
}
