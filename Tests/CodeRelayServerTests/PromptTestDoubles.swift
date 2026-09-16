import Foundation
@testable import CodeRelayKit
@testable import CodeRelayServer

// Shared `PromptOptimizing` doubles. `FakeOptimizer` is used by
// `PromptRequestHandlerTests`, `AdminRoutesEndpointTests` and
// `WirePromptOptimizerTests`; the gated / hanging doubles exist so a test can
// hold the model call open across an event-loop deadline without real sleeps.

/// A `PromptOptimizing` double: fixed outcome, optional delay, records what it saw.
actor FakeOptimizer: PromptOptimizing {
    nonisolated let sharesScreen: Bool
    private let result: Result<OptimizerOutcome, Error>
    private let delay: Duration
    private(set) var received: [PromptContext] = []

    init(sharesScreen: Bool = true,
         result: Result<OptimizerOutcome, Error> = .success(.optimized("Run `git status`.")),
         delay: Duration = .zero) {
        self.sharesScreen = sharesScreen
        self.result = result
        self.delay = delay
    }

    func optimize(_ context: PromptContext) async throws -> OptimizerOutcome {
        received.append(context)
        if delay > .zero { try await Task.sleep(for: delay) }
        return try result.get()
    }
}

/// Hangs until `complete()` is called and **ignores cancellation**, so a test can
/// let the deadline fire and then deliver the model's answer late.
actor SlowThenFastOptimizer: PromptOptimizing {
    nonisolated let sharesScreen = true
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        var cont: AsyncStream<Void>.Continuation!
        self.stream = AsyncStream<Void> { cont = $0 }
        self.continuation = cont!
    }

    func optimize(_ context: PromptContext) async throws -> OptimizerOutcome {
        await withTaskCancellationHandler {
            // Deliberately nothing on cancellation — the late completion is the
            // case under test.
        } operation: {
            for await _ in stream { break }
        }
        return .optimized("late result")
    }

    func complete() {
        continuation.yield()
        continuation.finish()
    }
}

/// Never returns and ignores cancellation: the deadline is the only thing that
/// can resolve a request made against it.
actor HangingOptimizer: PromptOptimizing {
    nonisolated let sharesScreen = true

    func optimize(_ context: PromptContext) async throws -> OptimizerOutcome {
        while true {
            try? await Task.sleep(for: .seconds(100))
        }
    }
}

/// Parks the calls whose (zero-based) index is in `gatedCalls` until `release(_:)`
/// resumes them; every other call returns `outcome` immediately. Cancellation is
/// ignored on purpose — a late completion has to be dropped by the handler's
/// generation guard, not by cancellation.
actor GatedOptimizer: PromptOptimizing {
    nonisolated let sharesScreen: Bool
    private let gatedCalls: Set<Int>
    private let outcome: OptimizerOutcome
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []
    private(set) var received: [PromptContext] = []

    init(gatedCalls: Set<Int> = [0],
         outcome: OptimizerOutcome = .optimized("Run `git status`."),
         sharesScreen: Bool = true) {
        self.gatedCalls = gatedCalls
        self.outcome = outcome
        self.sharesScreen = sharesScreen
    }

    func optimize(_ context: PromptContext) async throws -> OptimizerOutcome {
        let index = received.count
        received.append(context)
        if gatedCalls.contains(index), !released.contains(index) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gates[index] = continuation
            }
        }
        return outcome
    }

    /// Resumes a parked call. Safe to call before that call has even arrived.
    func release(_ index: Int) {
        released.insert(index)
        gates.removeValue(forKey: index)?.resume()
    }

    func callCount() -> Int { received.count }
}
