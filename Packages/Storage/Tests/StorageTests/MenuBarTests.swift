import Models
import Testing
@testable import Storage

@Suite("菜单栏状态")
struct MenuBarTests {
    @Test("构建期间的等待独立计数，阶段变化和删除实时刷新")
    func concurrentWaiting() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed()
        var run = seeded.run
        run.status = .running
        try await database.updateRun(run)
        var iterator = database.observeMenuBar().makeAsyncIterator()
        let first = try #require(try await iterator.next())
        #expect(first.runningCount == 1 && first.waitingCount == 0)
        _ = try await database.transitionStage(seeded.stages[2].id, from: [.pending], to: .waiting)
        let waiting = try #require(try await iterator.next())
        #expect(waiting.runningCount == 1 && waiting.waitingCount == 1)
        #expect(waiting.waitingStages[run.id] == seeded.stages[2].id)
        _ = try await database.transitionStage(seeded.stages[1].id, from: [.pending], to: .failed)
        let failed = try #require(try await iterator.next())
        #expect(failed.failureCount == 1 && failed.waitingCount == 1)
        try await database.deleteProject(seeded.project.id)
        #expect(try await iterator.next() == MenuBarSnapshot())
    }

    @Test("列表每项目限八条并保留旧等待，失败数只看每项目最新运行")
    func boundedHistory() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed()
        _ = try await database.transitionStage(seeded.stages[2].id, from: [.pending], to: .waiting)
        var old = seeded.run
        old.status = .waiting
        try await database.updateRun(old)
        for index in 0..<12 {
            var run = Sample.run(projectID: seeded.project.id)
            run.status = index == 0 ? .failed : .succeeded
            _ = try await database.createRun(run, stages: [])
        }
        let other = try await database.seed(projectName: "另一个人工项目")
        var iterator = database.observeMenuBar().makeAsyncIterator()
        let snapshot = try #require(try await iterator.next())
        #expect(snapshot.runs.filter { $0.projectID == seeded.project.id }.count == 8)
        #expect(snapshot.runs.first { $0.projectID == seeded.project.id }?.id == old.id)
        #expect(snapshot.waitingCount == 1 && snapshot.failureCount == 0)
        #expect(snapshot.queuedCount == 1 && snapshot.runs.contains { $0.id == other.run.id })
    }
}
