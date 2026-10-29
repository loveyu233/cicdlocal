import Foundation
import GRDB
import Models

/// 写入推送事件的结果。
public enum PushEventRecording: Sendable, Equatable {
    /// 新事件。`refUpdates` 只包含本次新写入的引用更新。
    case recorded(PushEvent, refUpdates: [RefUpdate])
    /// spool 事件已经写入过（重复投递），没有任何改动。
    case duplicate(PushEvent)
}

extension AppDatabase {
    public func refUpdate(_ id: RefUpdateID) async throws -> RefUpdate? {
        try await writer.read { db in try RefUpdate.fetchOne(db, key: id) }
    }

    public func pushEvent(_ id: PushEventID) async throws -> PushEvent? {
        try await writer.read { db in try PushEvent.fetchOne(db, key: id) }
    }

    /// 在一个事务中写入推送事件和它的引用更新。
    ///
    /// 去重分两级：
    /// - 同一个 spool 事件 ID 只写一次；
    /// - 引用更新的键由事件 ID 和序号生成，不阻止以后再次合法推送相同提交。
    public func recordPushEvent(_ event: PushEvent, refUpdates: [RefUpdate]) async throws -> PushEventRecording {
        try await writer.write { db in
            if let existing = try PushEvent.filter(Column("spool_event_id") == event.spoolEventID).fetchOne(db) {
                return .duplicate(existing)
            }
            guard !event.spoolEventID.isEmpty,
                Set(refUpdates.map(\.remoteRef)).count == refUpdates.count
            else { throw StorageError.invalidPushEvent }
            var event = event
            try event.insert(db)
            var inserted: [RefUpdate] = []
            for (ordinal, update) in refUpdates.enumerated() {
                var update = update
                update.dedupKey = "\(event.spoolEventID)#\(ordinal)"
                update.pushEventID = event.id
                try update.insert(db)
                inserted.append(update)
            }
            return .recorded(event, refUpdates: inserted)
        }
    }

    /// 更新引用更新的确认结果。
    public func confirmRefUpdate(
        _ id: RefUpdateID, confirmation: RefUpdateConfirmation, by layer: ConfirmationLayer?, reason: String? = nil
    ) async throws -> RefUpdate {
        try await writer.write { db in
            guard var update = try RefUpdate.fetchOne(db, key: id) else {
                throw StorageError.notFound(entity: "引用更新", id: id.rawValue)
            }
            // 已确认或明确拒绝的结果不能被后到的扫描覆盖；证据不足的记录仍可补充权威证据。
            if [.confirmed, .rejected].contains(update.confirmation) { return update }
            guard (confirmation == .confirmed) == (layer != nil) else { throw StorageError.invalidPushEvent }
            update.confirmation = confirmation
            update.confirmedBy = layer
            update.confirmationReason = reason
            try update.update(db)
            return update
        }
    }

    public func refUpdates(pushEventID: PushEventID) async throws -> [RefUpdate] {
        try await writer.read { db in
            try RefUpdate.filter(Column("push_event_id") == pushEventID).order(Column("id")).fetchAll(db)
        }
    }

    /// 尚未确认的引用更新，按写入顺序。用于 App 启动后补确认。
    public func pendingRefUpdates(projectID: ProjectID) async throws -> [RefUpdate] {
        try await writer.read { db in
            try RefUpdate
                .filter(Column("confirmation") == RefUpdateConfirmation.pending)
                .filter(
                    sql: "push_event_id IN (SELECT id FROM push_event WHERE project_id = ?)",
                    arguments: [projectID])
                .order(Column("id"))
                .fetchAll(db)
        }
    }
}
