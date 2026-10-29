import Foundation
import Testing
@testable import LogKit

@Suite("跨块日志与落盘脱敏")
struct LogPipelineTests {
    @Test("UTF-8、ANSI、OSC 和敏感值在任意切块下结果一致")
    func chunking() throws {
        let secrets = ["敏感口令🙂", "abcdef", "abc", "第一行\r\n第二行"]
        let input = Data("中文🙂\u{1B}[31m红色\u{1B}[0m 敏感\u{1B}[32m口令🙂 abcdef abc\n第一行\r\n第二行\n\u{1B}]8;;https://example.invalid\u{1B}\\链接\u{1B}]8;;\u{1B}\\\r\n结束".utf8)
        var whole = try LogSanitizer(secrets: secrets)
        let expected = whole.append(input) + whole.finish()
        #expect(expected.contains("[已隐藏]"))
        #expect(!expected.contains("https://example.invalid"))
        #expect(!expected.contains("\u{1B}"))
        #expect(!expected.contains("敏感口令🙂"))
        #expect(!expected.contains("第一行\n第二行"))
        for split in 0...input.count {
            var parser = try LogSanitizer(secrets: secrets)
            let output = parser.append(Data(input.prefix(split))) + parser.append(Data(input.dropFirst(split))) + parser.finish()
            #expect(output == expected)
        }
        var random: UInt64 = 19
        for _ in 0..<100 {
            var parser = try LogSanitizer(secrets: secrets)
            var output = ""
            var offset = 0
            while offset < input.count {
                random = random &* 6_364_136_223_846_793_005 &+ 1
                let end = min(input.count, offset + Int(random % 17) + 1)
                output += parser.append(Data(input[offset..<end]))
                offset = end
            }
            output += parser.finish()
            #expect(output == expected)
        }
    }

    @Test("普通输出立即可见，敏感前缀等下一块，损坏 UTF-8 在结束时替换")
    func partialAndInvalidUTF8() throws {
        var parser = try LogSanitizer(secrets: ["secret-value"])
        #expect(parser.append(Data("普通日志 ".utf8)) == "普通日志 ")
        #expect(parser.append(Data("sec".utf8)).isEmpty)
        #expect(parser.append(Data("ret-value".utf8)) == "[已隐藏]")
        #expect(parser.finish().isEmpty)
        for bytes: [UInt8] in [[0xE4, 0xB8], [0xF4, 0x90, 0x80, 0x80], [0xE0, 0x80, 0x41]] {
            var incremental = try LogSanitizer()
            var output = ""
            for byte in bytes { output += incremental.append(Data([byte])) }
            output += incremental.finish()
            #expect(output == String(decoding: bytes, as: UTF8.self))
        }
    }

    @Test("脱敏后分段落盘，历史读取不会泄漏跨块凭据")
    func diskSegments() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "localcicd-log-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "attempt")
        let store = try JobLogStore(directory: directory, allowedRoot: root, secrets: ["不可记录的口令"], segmentBytes: 64)
        for byte in "构建中：不可记录的口令\n".utf8 { try await store.append(Data([byte])) }
        try await store.append(Data(String(repeating: "日志🙂\n", count: 30).utf8))
        try await store.finish()
        let snapshot = await store.snapshot()
        let restored = try JobLogStore.read(directory: directory)
        #expect(snapshot.finished)
        #expect(!restored.contains("不可记录的口令"))
        #expect(restored.contains("[已隐藏]"))
        #expect(restored == snapshot.text)
        #expect(try JobLogStore.readManifest(directory: directory).bytesWritten == snapshot.bytesWritten)
        #expect(snapshot.textStartOffset == 0)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count > 2)
        for file in files {
            #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("不可记录的口令"))
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
        }
        #expect(throws: LogError.self) { try JobLogStore(directory: directory, allowedRoot: root) }
    }

    @Test("磁盘日志达到上限后截断并继续接收；超长单行和 UI 快照有上限")
    func boundedStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "localcicd-log-limit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobLogStore(directory: root.appending(path: "attempt"), allowedRoot: root, maximumBytes: 512, segmentBytes: 128)
        let stream = await store.updates()
        for _ in 0..<100 { try await store.append(Data("仍在继续的输出\n".utf8)) }
        try await store.append(Data(repeating: 65, count: 1_000_000))
        try await store.finish()
        let snapshot = await store.snapshot()
        #expect(snapshot.truncated)
        #expect(snapshot.bytesWritten <= 512)
        #expect(snapshot.text.contains("任务继续执行"))
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.finished == true)
        #expect(await iterator.next() == nil)
        #expect(try JobLogStore.read(directory: root.appending(path: "attempt"), maximumBytes: 512) == snapshot.text)
    }
}
