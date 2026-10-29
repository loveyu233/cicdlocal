import Foundation
import Testing
@testable import Platform

@Suite("应用目录布局")
struct AppPathsTests {
    let paths = AppPaths(applicationSupport: URL(filePath: "/tmp/support/io.github.loveyu233.cicdlocal", directoryHint: .isDirectory))

    @Test("标准位置在用户 Library 下，以 bundle id 命名")
    func standard() throws {
        let standard = try AppPaths.standard()
        #expect(standard.applicationSupport.path(percentEncoded: false).hasSuffix("Library/Application Support/io.github.loveyu233.cicdlocal/"))
    }

    @Test("数据库、日志、临时文件、spool、钩子都在 Application Support；新库不复用旧库文件名")
    func layout() {
        for url in [paths.database, paths.instanceLock, paths.logsRoot, paths.temporary, paths.spoolNew, paths.spoolTmp, paths.hooks] {
            #expect(AppPaths.isInside(url, root: paths.applicationSupport), "\(url)")
        }
        #expect(paths.database.lastPathComponent == "localcicd.sqlite")
        #expect(paths.stageLog(run: 18, ordinal: 2).path(percentEncoded: false).hasSuffix("/logs/18/2/"))
        #expect(AppPaths.isInside(paths.stageLog(run: 18, ordinal: 2), root: paths.runLogs(run: 18)))
    }

    @Test("isInside 不把同前缀的兄弟目录当成子目录")
    func isInside() {
        let root = URL(filePath: "/tmp/a", directoryHint: .isDirectory)
        #expect(AppPaths.isInside(URL(filePath: "/tmp/a/b"), root: root))
        #expect(!AppPaths.isInside(URL(filePath: "/tmp/ab"), root: root))
        #expect(!AppPaths.isInside(URL(filePath: "/tmp/a"), root: root))
        #expect(!AppPaths.isInside(URL(filePath: "/tmp/a/../b"), root: root))
    }

    @Test("创建目录，权限 0700")
    func createDirectories() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "localcicd-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let temp = AppPaths(applicationSupport: base.appending(path: "support"))
        try temp.createDirectories()
        try temp.createDirectories() // 重复调用不报错
        for url in [temp.spoolNew, temp.hooks, temp.temporary, temp.logsRoot] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
    }
}
