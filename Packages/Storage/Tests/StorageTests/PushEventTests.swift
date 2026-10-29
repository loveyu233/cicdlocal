import Foundation
import GRDB
import Models
import Testing
@testable import Storage

@Suite("推送记录")
struct PushEventTests {
    @Test("同一 spool 事件重复投递：只写一次")
    func duplicateSpoolEvent() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed()
        let again = try await database.recordPushEvent(
            Sample.pushEvent(projectID: seeded.project.id, spoolID: seeded.event.spoolEventID),
            refUpdates: [Sample.refUpdate(ref: "refs/heads/other")])
        #expect(again == .duplicate(seeded.event))
        let counts = try await database.writer.read { db in
            (try PushEvent.fetchCount(db), try RefUpdate.fetchCount(db))
        }
        #expect(counts == (1, 1))
    }

    @Test("新事件再次推送同一引用和提交：保留独立更新")
    func duplicateRefUpdate() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed()
        let other = try await database.recordPushEvent(
            Sample.pushEvent(projectID: seeded.project.id, spoolID: "another-spool"),
            refUpdates: [Sample.refUpdate(), Sample.refUpdate(ref: "refs/heads/new")])
        guard case .recorded(_, let updates) = other else {
            Issue.record("新事件应当写入")
            return
        }
        #expect(updates.map(\.remoteRef) == ["refs/heads/main", "refs/heads/new"])
        #expect(updates[0].dedupKey != seeded.refUpdate.dedupKey)
    }

    @Test("事件内重复目标引用被拒绝，整次写入回滚")
    func repeatedDestination() async throws {
        let database = try AppDatabase.inMemory()
        let project = try await database.createProject(Sample.project())
        await #expect(throws: StorageError.invalidPushEvent) {
            _ = try await database.recordPushEvent(
                Sample.pushEvent(projectID: project.id), refUpdates: [Sample.refUpdate(), Sample.refUpdate()])
        }
        #expect(try await database.writer.read { db in try PushEvent.fetchCount(db) } == 0)
    }

    @Test("确认结果：已确认的不被后到的扫描覆盖；只有确认的分支更新能记录解析到的提交")
    func confirmation() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed()
        let id = seeded.refUpdate.id
        await #expect(throws: StorageError.invalidPushEvent) { try await database.setResolvedCommit(Sample.sha2, for: id) }

        let confirmed = try await database.confirmRefUpdate(id, confirmation: .confirmed, by: .referenceTransaction)
        #expect(confirmed.createsRun && confirmed.branch == "main")
        let later = try await database.confirmRefUpdate(id, confirmation: .unconfirmable, by: nil, reason: "网络中断")
        #expect(later.confirmation == .confirmed)
        #expect(try await database.pendingRefUpdates(projectID: seeded.project.id).isEmpty)

        await #expect(throws: StorageError.invalidPushEvent) { try await database.setResolvedCommit(Sample.sha1, for: id) }
        try await database.setResolvedCommit(Sample.sha2, for: id)
        #expect(try await database.refUpdate(id)?.resolvedCommitSHA == Sample.sha2)
    }

    @Test("唯一约束直接作用在数据库上：绕过仓储也无法写入重复数据")
    func uniqueIndexes() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed()
        await #expect(throws: DatabaseError.self) {
            try await database.writer.write { db in
                var duplicate = Sample.run(projectID: seeded.project.id, refUpdateID: seeded.refUpdate.id)
                try duplicate.insert(db)
            }
        }
        await #expect(throws: DatabaseError.self) { _ = try await database.createProject(Sample.project()) }
        await #expect(throws: DatabaseError.self) {
            try await database.writer.write { db in
                var stage = seeded.stages[0]
                stage.id = .unsaved
                try stage.insert(db)
            }
        }
    }
}
