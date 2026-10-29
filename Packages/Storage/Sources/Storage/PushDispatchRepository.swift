import Foundation
import GRDB
import Models

/// 一次引用更新的处理结果：创建的运行，或者没有运行的原因。
public struct PushDispatch: Sendable, Equatable {
    public var refUpdateID: RefUpdateID
    public var runID: RunID?
    public var message: String
}

extension AppDatabase {
    /// 记下确认推送后实际解析到的提交。只接受与推送一致的分支提交。
    public func setResolvedCommit(_ sha: CommitSHA, for id: RefUpdateID) async throws {
        try await writer.write { db in
            guard var update = try RefUpdate.fetchOne(db, key: id), update.createsRun,
                !sha.isZero, update.newSHA == sha,
                update.resolvedCommitSHA == nil || update.resolvedCommitSHA == sha
            else { throw StorageError.invalidPushEvent }
            update.resolvedCommitSHA = sha
            try update.update(db)
        }
    }

    public func pushDispatch(_ id: RefUpdateID) async throws -> PushDispatch? {
        try await writer.read { db in try Self.fetchDispatch(db, id) }
    }

    /// 记录没有创建运行的处理结果（分支不在配置里、配置错误等）。已处理过的引用更新不会被覆盖。
    public func recordPushDispatch(_ id: RefUpdateID, runID: RunID?, message: String) async throws {
        _ = try await writer.write { db in try Self.insertDispatch(db, id, runID: runID, message: message) }
    }

    /// 插入成功返回 true；已经处理过返回 false。
    @discardableResult
    static func insertDispatch(_ db: Database, _ id: RefUpdateID, runID: RunID?, message: String) throws -> Bool {
        try db.execute(sql: """
            INSERT INTO push_dispatch (ref_update_id, run_id, message, created_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(ref_update_id) DO NOTHING
            """, arguments: [id, runID, message, Date()])
        return db.changesCount > 0
    }

    static func fetchDispatch(_ db: Database, _ id: RefUpdateID) throws -> PushDispatch? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM push_dispatch WHERE ref_update_id = ?", arguments: [id])
        else { return nil }
        return PushDispatch(refUpdateID: id, runID: row["run_id"], message: row["message"])
    }
}
