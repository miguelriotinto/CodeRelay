import Foundation
import CodeRelayKit

/// Races `operation` against `deadline` and returns whichever finishes first.
/// A timeout surfaces as `OptimizerError.unavailable` ("Optimizer unavailable,
/// try again").
///
/// **The loser is cancelled but never awaited.** A structured task group would
/// await the cancelled child, so an optimizer that ignores cancellation (a
/// non-cooperative HTTP client, a hung `MessagesSending` double) would hold
/// `POST /optimizer/try` open long past the deadline — the deadline would
/// describe nothing observable. Instead the operation and the sleep each run in
/// their own unstructured `Task`, the first to finish resumes a continuation
/// (exactly once, guarded by `resolved` under a lock), and the loser is only
/// `cancel()`ed. Cancelling the caller cancels both children and resumes the
/// caller with `CancellationError` rather than waiting on work that may never
/// come back.
///
/// Only caller: the admin `POST /optimizer/try` route (spec §5.6). The
/// WebSocket `optimize_prompt` handler enforces the same
/// `PromptOptimizer.deadline` with `eventLoop.scheduleTask` instead, because it
/// must mutate handler state (`optimizeInFlight`, `optimizeGeneration`, …) on
/// the event loop — do not unify the two mechanisms.
func withOptimizerDeadline<T: Sendable>(
    _ deadline: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = OptimizerDeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            race.install(continuation)
            let work = Task {
                do { race.finish(.success(try await operation())) }
                catch { race.finish(.failure(error)) }
            }
            let timer = Task {
                do {
                    try await Task.sleep(for: deadline)
                    race.finish(.failure(OptimizerError.unavailable))
                } catch {
                    // Cancelled because the operation won the race.
                }
            }
            race.setChildren(work: work, timer: timer)
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// Single-resume arbiter for `withOptimizerDeadline`. Every field is touched
/// under `lock`; the continuation is resumed outside it.
private final class OptimizerDeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    /// A result that arrived before `install` ran. `withTaskCancellationHandler`
    /// may invoke `onCancel` before (or concurrently with) the continuation
    /// body when the caller is already cancelled, so the first result can beat
    /// the continuation it has to resume.
    private var pending: Result<T, Error>?
    private var resolved = false
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pending {
            self.pending = nil
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setChildren(work: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        let alreadyResolved = resolved
        if !alreadyResolved {
            self.work = work
            self.timer = timer
        }
        lock.unlock()
        // Resolved before the children were recorded (immediate cancellation):
        // cancel them here instead of leaking them.
        if alreadyResolved {
            work.cancel()
            timer.cancel()
        }
    }

    /// First finisher wins. Resumes the caller exactly once and cancels the
    /// loser **without awaiting it**.
    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pending = result }
        let losers = [work, timer].compactMap { $0 }
        work = nil
        timer = nil
        lock.unlock()
        continuation?.resume(with: result)
        for task in losers { task.cancel() }
    }
}
