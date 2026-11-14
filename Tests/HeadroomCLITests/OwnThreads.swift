import Foundation

// Tests that block until a file changes must not hold the shared test threads, and the change
// they wait for must not queue behind them: on a small CI machine both stall for seconds.

/// Runs `work` after `delay` on a thread of its own.
func after(_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
    Thread { Thread.sleep(forTimeInterval: delay); work() }.start()
}

/// Runs a blocking call on a thread of its own and hands back what it returns.
func offPool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in Thread { c.resume(returning: body()) }.start() }
}
