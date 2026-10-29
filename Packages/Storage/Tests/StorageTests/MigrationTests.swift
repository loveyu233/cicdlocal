import Foundation
import GRDB
import Testing
@testable import Storage

@Suite("迁移")
struct MigrationTests {
    static let tables = ["project", "push_event", "ref_update", "push_dispatch", "run", "run_stage", "k8s_connection"]

    @Test("从空库迁移到最新版本")
    func emptyToLatest() throws {
        let database = try AppDatabase.inMemory()
        let (applied, completed, missing) = try database.writer.read { db in
            try db.checkForeignKeys()
            return (
                try Schema.migrator.appliedMigrations(db),
                try Schema.migrator.hasCompletedMigrations(db),
                try Self.tables.filter { try !db.tableExists($0) }
            )
        }
        #expect(applied == Schema.migrationIdentifiers)
        #expect(completed)
        #expect(missing.isEmpty, "缺少表 \(missing)")
    }

    @Test("逐个版本迁移：每一步都能停下，并能继续迁移到最新", arguments: Schema.migrationIdentifiers)
    func eachVersion(_ identifier: String) throws {
        let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration())
        try Schema.migrator.migrate(queue, upTo: identifier)
        let expected = Array(Schema.migrationIdentifiers.prefix { $0 != identifier }) + [identifier]
        #expect(try queue.read(Schema.migrator.appliedMigrations) == expected)
        try Schema.migrator.migrate(queue)
        #expect(try queue.read(Schema.migrator.appliedMigrations) == Schema.migrationIdentifiers)
        try queue.read { db in try db.checkForeignKeys() }
    }

    @Test("重复打开同一个库不会重复迁移")
    func reopen() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "nested/app.sqlite")
        do {
            let database = try AppDatabase.open(at: url)
            try database.writer.write { db in
                try db.execute(sql: "INSERT INTO project (name, repository_path, hook_mode, created_at) VALUES ('a', '/a', 'none', '2026-10-20 00:00:00.000')")
            }
        }
        let database = try AppDatabase.open(at: url)
        let count = try database.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project") }
        #expect(count == 1)
    }

    @Test("磁盘数据库使用 WAL，外键开启")
    func walAndForeignKeys() throws {
        let directory = try TemporaryDirectory()
        let database = try AppDatabase.open(at: directory.url.appending(path: "app.sqlite"))
        #expect(database.writer is DatabasePool)
        let (journalMode, foreignKeys) = try database.writer.read { db in
            (try String.fetchOne(db, sql: "PRAGMA journal_mode"), try Bool.fetchOne(db, sql: "PRAGMA foreign_keys"))
        }
        #expect(journalMode == "wal")
        #expect(foreignKeys == true)
    }

    @Test("k8s 连接表没有存放 kubeconfig 的列")
    func connectionTableHasNoSecretColumn() throws {
        let database = try AppDatabase.inMemory()
        let columns = try database.writer.read { db in try db.columns(in: "k8s_connection").map(\.name) }
        #expect(Set(columns) == ["id", "name", "account", "metadata_json", "created_at"])
    }
}
