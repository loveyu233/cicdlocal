import GRDB
import Models

// 供界面订阅的数据流。每次相关表提交变化后发出最新结果；首个值立即发出。
// 界面层在 MainActor 上 `for try await` 读取即可。

extension AppDatabase {
    public func observeProjects() -> AsyncValueObservation<[Project]> {
        ValueObservation
            .tracking { db in try Self.projectsRequest.fetchAll(db) }
            .removeDuplicates()
            .values(in: writer)
    }

    /// 最新的在前。
    public func observeRuns(projectID: ProjectID, limit: Int = 100) -> AsyncValueObservation<[Run]> {
        ValueObservation
            .tracking { db in try Self.runsRequest(projectID: projectID, limit: limit).fetchAll(db) }
            .removeDuplicates()
            .values(in: writer)
    }

    /// 运行被删除（随项目删除）后发出 nil。
    public func observeRun(_ id: RunID) -> AsyncValueObservation<Run?> {
        ValueObservation
            .tracking { db in try Run.fetchOne(db, key: id) }
            .removeDuplicates()
            .values(in: writer)
    }

    public func observeStages(runID: RunID) -> AsyncValueObservation<[RunStage]> {
        ValueObservation
            .tracking { db in try Self.stagesRequest(runID: runID).fetchAll(db) }
            .removeDuplicates()
            .values(in: writer)
    }

    public func observeConnections() -> AsyncValueObservation<[K8sConnection]> {
        ValueObservation
            .tracking { db in try Self.connectionsRequest.fetchAll(db) }
            .removeDuplicates()
            .values(in: writer)
    }
}
