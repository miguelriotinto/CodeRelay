import Foundation
import CodeRelayKit

/// Races `operation` against `deadline`; the loser is cancelled. A timeout
/// surfaces as `OptimizerError.unavailable` ("Optimizer unavailable, try again").
///
/// Used by both the WebSocket `optimize_prompt` handler (via event-loop scheduling)
/// and the admin `POST /optimizer/try` route (Foundation async) to enforce the
/// 12 s optimizer deadline (spec §5.2, §5.6).
func withOptimizerDeadline<T: Sendable>(
    _ deadline: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: deadline)
            throw OptimizerError.unavailable
        }
        guard let first = try await group.next() else { throw OptimizerError.unavailable }
        group.cancelAll()
        return first
    }
}
