import Foundation
import GRDB
import Models

extension AppDatabase {
    /// 在一个事务中创建运行和它的全部阶段。
    ///
    /// 由推送触发（`refUpdateID` 不为空）时同时写入处理结果；
    /// 这个引用更新已经处理过则什么都不写，返回 nil，避免重复投递产生两次运行。
    public func createRun(_ run: Run, stages: [RunStage], dispatchMessage: String = "已创建运行") async throws -> Run? {
        try await writer.write { db in
            if let refUpdateID = run.refUpdateID, try Self.fetchDispatch(db, refUpdateID) != nil {
                return nil
            }
            var run = run
            try run.insert(db)
            for stage in stages {
                var stage = stage
                stage.runID = run.id
                try stage.insert(db)
            }
            if let refUpdateID = run.refUpdateID {
                try Self.insertDispatch(db, refUpdateID, runID: run.id, message: dispatchMessage)
            }
            return run
        }
    }

    public func run(_ id: RunID) async throws -> Run? {
        try await writer.read { db in try Run.fetchOne(db, key: id) }
    }

    public func stages(runID: RunID) async throws -> [RunStage] {
        try await writer.read { db in try Self.stagesRequest(runID: runID).fetchAll(db) }
    }

    /// 最新的在前。
    public func runs(projectID: ProjectID, limit: Int = 100) async throws -> [Run] {
        try await writer.read { db in try Self.runsRequest(projectID: projectID, limit: limit).fetchAll(db) }
    }

    public func updateRun(_ run: Run) async throws {
        try await writer.write { db in try run.update(db) }
    }

    public func updateStage(_ stage: RunStage) async throws {
        try await writer.write { db in try stage.update(db) }
    }

    /// 阶段仍处于 `from` 中的某个状态时才改为 `to`，返回改后的阶段；否则返回 nil。
    ///
    /// 确认、跳过与取消可能同时发生，用这个条件更新保证只有一方生效。
    /// 进入运行中时记下开始时间，进入结束状态时记下结束时间。
    public func transitionStage(
        _ id: RunStageID, from: Set<StageStatus>, to status: StageStatus, message: String? = nil, at date: Date = Date()
    ) async throws -> RunStage? {
        try await writer.write { db in
            guard var stage = try RunStage.fetchOne(db, key: id), from.contains(stage.status) else { return nil }
            Self.apply(status, message: message, at: date, to: &stage)
            try stage.update(db)
            return stage
        }
    }

    /// 按阶段状态重新计算运行状态并保存。只应在运行开始以后调用：还有阶段没结束时运行视为运行中。
    @discardableResult
    public func settle(_ runID: RunID, message: String? = nil, at date: Date = Date()) async throws -> Run {
        try await writer.write { db in
            var run = try Self.settle(db, runID, at: date)
            if let message { run.message = message; try run.update(db) }
            return run
        }
    }

    /// 结束一个运行：运行中的阶段记为已取消，未开始和等待确认的阶段记为已跳过。
    /// 用于取消和执行器之外的错误。
    @discardableResult
    public func closeRun(_ id: RunID, status: RunStatus, message: String? = nil, at date: Date = Date()) async throws -> Run {
        try await writer.write { db in
            guard var run = try Run.fetchOne(db, key: id) else {
                throw StorageError.notFound(entity: "运行", id: id.rawValue)
            }
            for var stage in try Self.stagesRequest(runID: id).fetchAll(db) {
                switch stage.status {
                case .running: Self.apply(.canceled, message: message, at: date, to: &stage)
                case .pending, .waiting: Self.apply(.skipped, message: nil, at: date, to: &stage)
                default: continue
                }
                try stage.update(db)
            }
            run.status = status
            run.message = message ?? run.message
            run.finishedAt = date
            try run.update(db)
            return run
        }
    }

    /// 同一项目最早的排队运行。
    public func nextQueuedRun(projectID: ProjectID) async throws -> Run? {
        try await writer.read { db in
            try Run.filter(Column("project_id") == projectID && Column("status") == RunStatus.queued)
                .order(Column("id")).fetchOne(db)
        }
    }

    public func projectsWithQueuedRuns() async throws -> [ProjectID] {
        try await writer.read { db in
            try ProjectID.fetchAll(db, sql: "SELECT DISTINCT project_id FROM run WHERE status = ? ORDER BY project_id",
                arguments: [RunStatus.queued])
        }
    }

    /// App 启动时调用：上次退出时还在运行的运行记为已中断。
    ///
    /// 运行中的阶段记为已取消，未开始的记为已跳过；等待确认的阶段保留，重启后仍可确认；
    /// 排队的运行不受影响，会照常执行。返回被标记的运行。
    public func recoverInterruptedRuns(at date: Date = Date()) async throws -> [RunID] {
        try await writer.write { db in
            let runs = try Run.filter(Column("status") == RunStatus.running).fetchAll(db)
            for var run in runs {
                for var stage in try Self.stagesRequest(runID: run.id).fetchAll(db) {
                    switch stage.status {
                    case .running: Self.apply(.canceled, message: "App 退出时中断", at: date, to: &stage)
                    case .pending: Self.apply(.skipped, message: nil, at: date, to: &stage)
                    default: continue
                    }
                    try stage.update(db)
                }
                run.status = .interrupted
                run.message = run.message ?? "App 退出时中断，可以重新运行"
                run.finishedAt = date
                try run.update(db)
            }
            return runs.map(\.id)
        }
    }

    /// 删除运行和它的阶段；推送记录和以它为来源的重新运行只断开引用。磁盘上的日志由调用方清理。
    public func deleteRun(_ id: RunID) async throws {
        try await writer.write { db in
            guard try Run.deleteOne(db, key: id) else {
                throw StorageError.notFound(entity: "运行", id: id.rawValue)
            }
        }
    }

    // MARK: 内部

    static func runsRequest(projectID: ProjectID, limit: Int) -> QueryInterfaceRequest<Run> {
        Run.filter(Column("project_id") == projectID).order(Column("id").desc).limit(max(1, min(limit, 1_000)))
    }

    static func stagesRequest(runID: RunID) -> QueryInterfaceRequest<RunStage> {
        RunStage.filter(Column("run_id") == runID).order(Column("ordinal"))
    }

    static func apply(_ status: StageStatus, message: String?, at date: Date, to stage: inout RunStage) {
        stage.status = status
        if let message { stage.message = message }
        if status == .running { stage.startedAt = date }
        if status.isFinished { stage.finishedAt = date }
    }

    @discardableResult
    static func settle(_ db: Database, _ runID: RunID, at date: Date) throws -> Run {
        guard var run = try Run.fetchOne(db, key: runID) else {
            throw StorageError.notFound(entity: "运行", id: runID.rawValue)
        }
        let stages = try stagesRequest(runID: runID).fetchAll(db)
        var status = RunStatus.settled(stages.map(\.status)) ?? .running
        // 中断的运行里留下的等待确认被处理后，仍显示为已中断，而不是已取消。
        if status == .canceled && (run.status == .interrupted || stages.contains(where: {
            $0.status == .canceled && $0.message == "App 退出时中断"
        })) { status = .interrupted }
        guard status != run.status else { return run }
        run.status = status
        if status == .running, run.startedAt == nil { run.startedAt = date }
        run.finishedAt = status.isFinished ? date : nil
        try run.update(db)
        return run
    }
}
