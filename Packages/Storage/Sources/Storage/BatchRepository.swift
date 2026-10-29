import Foundation
import GRDB
import Models

extension AppDatabase {
    /// 计划的读改写处于同一事务，防止多个构建同时完成时覆盖彼此的 digest。
    public func transformPlan(_ id: RunID, transform: @escaping @Sendable (String) throws -> String) async throws {
        try await writer.write { db in
            guard var run = try Run.fetchOne(db, key: id), let json = run.plan else {
                throw StorageError.notFound(entity: "运行计划", id: id.rawValue)
            }
            run.plan = try transform(json)
            try run.update(db)
        }
    }

    public func waitForBatch(_ id: RunID, ids: [RunStageID], message: String) async throws {
        try await writer.write { db in
            let stages = try Self.stagesRequest(runID: id).fetchAll(db)
            let members = stages.filter { ids.contains($0.id) }
            guard !members.isEmpty, members.count == ids.count, members.allSatisfy({ $0.status == .pending }) else {
                throw StorageError.invalidValue("批次状态已经改变，不能等待确认")
            }
            for var stage in members {
                Self.apply(.waiting, message: message, at: Date(), to: &stage)
                try stage.update(db)
            }
            // 调度器仍可能有构建或部署任务，只在其收尾时汇总运行状态。
        }
    }

    /// 整批确认/跳过原子完成，所有成员必须属于指定运行且仍未确认。
    public func changeWaitingBatch(_ id: RunID, ids: [RunStageID], dependencies: [String], skip: Bool, confirmedMessage: String) async throws {
        try await writer.write { db in
            guard var run = try Run.fetchOne(db, key: id), [.running, .waiting, .queued, .interrupted].contains(run.status) else {
                throw StorageError.invalidValue("运行不能继续确认部署")
            }
            let stages = try Self.stagesRequest(runID: id).fetchAll(db)
            let members = stages.filter { ids.contains($0.id) }
            guard !members.isEmpty, members.count == ids.count,
                  members.allSatisfy({ $0.status == .waiting && $0.message != confirmedMessage }),
                  dependencies.allSatisfy({ key in stages.contains { $0.kind == .build && $0.targetKey == key && ($0.status == .succeeded || $0.status == .skipped) } }) else {
                throw StorageError.invalidValue("批次已确认、已跳过或自身镜像尚未就绪")
            }
            for var stage in members {
                Self.apply(skip ? .skipped : .waiting, message: skip ? "已跳过整个批次" : confirmedMessage, at: Date(), to: &stage)
                try stage.update(db)
            }
            // 跳过后持久排队，退出再启动也会继续；确认则保持等待，重启需重新确认。
            if skip && run.status != .running { run.status = .queued; try run.update(db) }
        }
    }
}
