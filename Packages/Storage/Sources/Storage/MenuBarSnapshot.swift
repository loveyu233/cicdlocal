import GRDB
import Models

/// 菜单栏的有界运行列表与全量状态计数；等待阶段可能属于仍在构建的运行。
public struct MenuBarSnapshot: Equatable, Sendable {
    public var runs: [Run] = []
    public var waitingStages: [RunID: RunStageID] = [:]
    public var runningCount = 0
    public var queuedCount = 0
    public var waitingCount = 0
    /// 每项目最新运行已失败或包含失败阶段的项目数，不累计历史失败。
    public var failureCount = 0

    public init() {}
}

extension AppDatabase {
    public func observeMenuBar() -> AsyncValueObservation<MenuBarSnapshot> {
        ValueObservation.tracking { db in try Self.menuBarSnapshot(db) }
            .removeDuplicates().values(in: writer)
    }

    static func menuBarSnapshot(_ db: Database) throws -> MenuBarSnapshot {
        var snapshot = MenuBarSnapshot()
        snapshot.runningCount = try Run.filter(Column("status") == RunStatus.running).fetchCount(db)
        snapshot.queuedCount = try Run.filter(Column("status") == RunStatus.queued).fetchCount(db)
        snapshot.waitingCount = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT run_id) FROM run_stage WHERE status = 'waiting'") ?? 0
        snapshot.failureCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM run r WHERE r.id = (SELECT MAX(id) FROM run WHERE project_id = r.project_id)
            AND (r.status = 'failed' OR EXISTS (SELECT 1 FROM run_stage s WHERE s.run_id = r.id AND s.status = 'failed'))
            """) ?? 0
        for project in try Self.projectsRequest.fetchAll(db) {
            let runs = try Run.fetchAll(db, sql: """
                SELECT r.* FROM run r WHERE r.project_id = ?
                ORDER BY CASE WHEN r.status = 'running' THEN 0 WHEN r.status = 'queued' THEN 1
                    WHEN EXISTS (SELECT 1 FROM run_stage s WHERE s.run_id = r.id AND s.status = 'waiting') THEN 2
                    ELSE 3 END, r.id DESC LIMIT 8
                """, arguments: [project.id])
            snapshot.runs += runs
            for run in runs {
                if let stage = try RunStage.filter(Column("run_id") == run.id && Column("status") == StageStatus.waiting)
                    .order(Column("ordinal")).fetchOne(db) {
                    snapshot.waitingStages[run.id] = stage.id
                }
            }
        }
        return snapshot
    }
}
