import Foundation
import Models
import Testing
@testable import Storage

@Suite("观察")
struct ObservationTests {
    @Test("项目列表：立即发出当前值，提交后发出新值")
    func projects() async throws {
        let database = try AppDatabase.inMemory()
        var iterator = database.observeProjects().makeAsyncIterator()
        #expect(try await iterator.next() == [])
        let project = try await database.createProject(Sample.project())
        #expect(try await iterator.next() == [project])
    }

    @Test("阶段列表：状态变化后发出新值")
    func stages() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed()
        var iterator = database.observeStages(runID: seeded.run.id).makeAsyncIterator()
        #expect(try await iterator.next() == seeded.stages)
        _ = try await database.transitionStage(seeded.stages[0].id, from: [.pending], to: .running, at: Sample.date)
        #expect(try await iterator.next()?.first?.status == .running)
    }

    @Test("运行列表只包含所属项目，最新的在前")
    func runs() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed()
        _ = try await database.seed(projectName: "other")
        var iterator = database.observeRuns(projectID: seeded.project.id).makeAsyncIterator()
        #expect(try await iterator.next() == [seeded.run])
        let rerun = try #require(try await database.createRun(
            Sample.run(projectID: seeded.project.id), stages: Sample.stages()))
        #expect(try await iterator.next()?.map(\.id) == [rerun.id, seeded.run.id])
    }

    @Test("单个运行与连接列表")
    func runAndConnections() async throws {
        let database = try AppDatabase.inMemory()
        let seeded = try await database.seed()
        var runs = database.observeRun(seeded.run.id).makeAsyncIterator()
        #expect(try await runs.next() == seeded.run)
        try await database.deleteProject(seeded.project.id)
        #expect(try await runs.next() == .some(nil))

        var connections = database.observeConnections().makeAsyncIterator()
        #expect(try await connections.next() == [])
        let connection = try await database.createConnection(Sample.connection())
        #expect(try await connections.next() == [connection])
    }
}
