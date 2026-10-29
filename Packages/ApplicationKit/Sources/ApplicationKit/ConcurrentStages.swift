import Models

/// 有界并发：失败后不再启动新任务，已开始的任务自然收尾；用户取消沿结构化任务树传播。
enum ConcurrentStages {
    static func run(_ stages: [RunStage], limit: Int,
                    operation: @escaping @Sendable (RunStage) async throws -> Bool) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            var next = 0
            var success = true
            for _ in 0..<min(max(1, limit), stages.count) {
                try Task.checkCancellation()
                let stage = stages[next]; next += 1
                group.addTask { try await operation(stage) }
            }
            while let result = try await group.next() {
                try Task.checkCancellation()
                success = success && result
                if success && next < stages.count {
                    let stage = stages[next]; next += 1
                    group.addTask { try await operation(stage) }
                }
            }
            return success
        }
    }
}
