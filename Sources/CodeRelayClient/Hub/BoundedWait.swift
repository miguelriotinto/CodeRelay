import Foundation

/// Awaits `operation` for at most `budget`, then returns anyway. Unlike a task
/// group it never waits for a straggling child: the operation keeps running in
/// its own task and simply nobody is listening (multi-server spec §7.5).
@MainActor
enum BoundedWait {
    private final class OneShot {
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ c: CheckedContinuation<Void, Never>) { continuation = c }
        func fire() { continuation?.resume(); continuation = nil }
    }

    static func run(budget: Duration, _ operation: @escaping @MainActor () async -> Void) async {
        var timer: Task<Void, Never>?
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let shot = OneShot(c)
            Task { @MainActor in await operation(); shot.fire() }
            timer = Task { @MainActor in
                try? await Task.sleep(for: budget)
                shot.fire()
            }
        }
        timer?.cancel()
    }
}
