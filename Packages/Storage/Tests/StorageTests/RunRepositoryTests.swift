import Foundation
import GRDB
import Models
import Testing
@testable import Storage

@Suite("运行与阶段")
struct RunRepositoryTests {
    @Test("推送创建运行时写入处理结果；同一引用更新只能创建一次")
    func createOncePerRefUpdate() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed()
        #expect(seeded.run.status == .queued)
        #expect(seeded.stages.map(\.ordinal) == [0, 1, 2])
        #expect(seeded.stages.allSatisfy { $0.runID == seeded.run.id && $0.status == .pending })
        #expect(seeded.stages[2].ordinal == 2)

        let dispatch = try await database.pushDispatch(seeded.refUpdate.id)
        #expect(dispatch?.runID == seeded.run.id)
        let again = try await database.createRun(
            Sample.run(projectID: seeded.project.id, refUpdateID: seeded.refUpdate.id), stages: Sample.stages())
        #expect(again == nil)
        #expect(try await database.runs(projectID: seeded.project.id).count == 1)

        // 已经记录为「不运行」的引用更新也不能再创建运行。
        guard case .recorded(_, let updates) = try await database.recordPushEvent(
            Sample.pushEvent(projectID: seeded.project.id, spoolID: "spool-skip"), refUpdates: [Sample.refUpdate(ref: "refs/heads/feature")])
        else { Issue.record("应当写入新事件"); return }
        try await database.recordPushDispatch(updates[0].id, runID: nil, message: "分支 feature 不在配置里")
        try await database.recordPushDispatch(updates[0].id, runID: nil, message: "覆盖")
        #expect(try await database.pushDispatch(updates[0].id)?.message == "分支 feature 不在配置里")
        #expect(try await database.createRun(
            Sample.run(projectID: seeded.project.id, refUpdateID: updates[0].id), stages: Sample.stages()) == nil)
    }

    @Test("条件更新：只有处于 from 状态时才生效，并记下时间")
    func transition() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed()
        let test = seeded.stages[0]
        let running = try #require(try await database.transitionStage(test.id, from: [.pending], to: .running, at: Sample.date))
        #expect(running.startedAt == Sample.date && running.finishedAt == nil)
        #expect(try await database.transitionStage(test.id, from: [.pending], to: .running) == nil)
        let done = try #require(try await database.transitionStage(
            test.id, from: [.running], to: .succeeded, message: "2 条命令", at: Sample.later))
        #expect(done.finishedAt == Sample.later && done.message == "2 条命令")
    }

    @Test("汇总：等待确认 → 确认后成功；失败优先；还有未结束阶段时为运行中")
    func settle() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed(targets: ["a", "b"])
        let ids = seeded.stages.map(\.id)
        _ = try await database.transitionStage(ids[0], from: [.pending], to: .succeeded)
        var run = try await database.settle(seeded.run.id, at: Sample.date)
        #expect(run.status == .running && run.startedAt == Sample.date && run.finishedAt == nil)

        _ = try await database.transitionStage(ids[1], from: [.pending], to: .succeeded)
        _ = try await database.transitionStage(ids[2], from: [.pending], to: .succeeded)
        _ = try await database.transitionStage(ids[3], from: [.pending], to: .waiting)
        run = try await database.settle(seeded.run.id, at: Sample.later)
        #expect(run.status == .waiting && run.finishedAt == nil)

        _ = try await database.transitionStage(ids[3], from: [.waiting], to: .running)
        #expect(try await database.settle(seeded.run.id).status == .running)
        _ = try await database.transitionStage(ids[3], from: [.running], to: .failed)
        run = try await database.settle(seeded.run.id, at: Sample.later)
        #expect(run.status == .failed && run.finishedAt == Sample.later)
    }

    @Test("关闭运行：运行中的阶段取消，其余跳过")
    func close() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed()
        _ = try await database.transitionStage(seeded.stages[0].id, from: [.pending], to: .running)
        let run = try await database.closeRun(seeded.run.id, status: .canceled, message: "已取消", at: Sample.later)
        #expect(run.status == .canceled && run.finishedAt == Sample.later)
        let stages = try await database.stages(runID: seeded.run.id)
        #expect(stages.map(\.status) == [.canceled, .skipped, .skipped])
    }

    @Test("排队：同一项目按创建顺序取下一个")
    func queue() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed()
        let second = try #require(try await database.createRun(Sample.run(projectID: seeded.project.id), stages: []))
        #expect(try await database.nextQueuedRun(projectID: seeded.project.id)?.id == seeded.run.id)
        #expect(try await database.projectsWithQueuedRuns() == [seeded.project.id])
        var first = seeded.run
        first.status = .running
        try await database.updateRun(first)
        #expect(try await database.nextQueuedRun(projectID: seeded.project.id)?.id == second.id)
    }

    @Test("重启恢复：运行中 → 已中断，等待确认保留，排队不受影响")
    func recover() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed(targets: ["a", "b"])
        let ids = seeded.stages.map(\.id)
        _ = try await database.transitionStage(ids[0], from: [.pending], to: .succeeded)
        _ = try await database.transitionStage(ids[1], from: [.pending], to: .succeeded)
        _ = try await database.transitionStage(ids[2], from: [.pending], to: .waiting)
        _ = try await database.transitionStage(ids[3], from: [.pending], to: .running)
        try await database.settle(seeded.run.id)
        let queued = try #require(try await database.createRun(Sample.run(projectID: seeded.project.id), stages: Sample.stages()))

        #expect(try await database.recoverInterruptedRuns(at: Sample.later) == [seeded.run.id])
        let run = try #require(try await database.run(seeded.run.id))
        #expect(run.status == .interrupted && run.finishedAt == Sample.later)
        #expect(try await database.stages(runID: run.id).map(\.status) == [.succeeded, .succeeded, .waiting, .canceled])
        #expect(try await database.run(queued.id)?.status == .queued)

        // 中断运行里的等待确认仍可处理，处理后保持「已中断」。
        _ = try await database.transitionStage(ids[2], from: [.waiting], to: .skipped)
        #expect(try await database.settle(run.id).status == .interrupted)
    }

    @Test("删除运行：阶段一并删除，推送记录和重新运行只断开引用，其他运行不受影响")
    func deleteRun() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed()
        let kept = try await database.seed(projectName: "other")
        var rerun = Sample.run(projectID: seeded.project.id)
        rerun.rerunOf = seeded.run.id
        let created = try #require(try await database.createRun(rerun, stages: Sample.stages()))

        try await database.deleteRun(seeded.run.id)
        #expect(try await database.run(seeded.run.id) == nil)
        #expect(try await database.stages(runID: seeded.run.id).isEmpty)
        #expect(try await database.run(created.id)?.rerunOf == nil)
        let dispatch = try #require(try await database.pushDispatch(seeded.refUpdate.id))
        #expect(dispatch.runID == nil)
        #expect(try await database.stages(runID: kept.run.id).count == 3)
        await #expect(throws: StorageError.notFound(entity: "运行", id: seeded.run.id.rawValue)) {
            try await database.deleteRun(seeded.run.id)
        }
    }

    @Test("提交说明随运行保存和读取，可以为空")
    func commitMessage() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed()
        #expect(seeded.run.commitMessage == nil)
        var run = Sample.run(projectID: seeded.project.id)
        run.commitMessage = "修复登录\n\n详细说明：「引号」与 emoji 🚀"
        let created = try #require(try await database.createRun(run, stages: []))
        #expect(try await database.run(created.id)?.commitMessage == run.commitMessage)
    }

    @Test("删除项目时级联删除推送、运行和阶段")
    func cascade() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed()
        let kept = try await database.seed(projectName: "other")
        try await database.deleteProject(seeded.project.id)
        let counts = try await database.writer.read { db in
            try ["push_event", "ref_update", "push_dispatch", "run", "run_stage"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
        #expect(counts == [1, 1, 1, 1, 3])
        #expect(try await database.run(kept.run.id) != nil)
        await #expect(throws: StorageError.notFound(entity: "项目", id: seeded.project.id.rawValue)) {
            try await database.deleteProject(seeded.project.id)
        }
    }

    @Test("SHA 列被改坏时读取报错，而不是带着坏数据继续")
    func corruptSHA() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed()
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE run SET sha = 'not-a-sha' WHERE id = ?", arguments: [seeded.run.id])
        }
        await #expect(throws: (any Error).self) { try await database.run(seeded.run.id) }
    }
}
