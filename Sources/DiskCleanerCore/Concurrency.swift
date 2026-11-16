import Foundation

/// Runs `body` for every element, with at most `width` calls in flight. Stops starting new
/// calls when the task is cancelled.
func forEachConcurrently<Element: Sendable>(
    _ elements: [Element],
    width: Int,
    _ body: @escaping @Sendable (Element) async -> Void
) async {
    await withTaskGroup(of: Void.self) { group in
        var iterator = elements.makeIterator()
        for _ in 0..<max(width, 1) {
            guard let element = iterator.next() else { break }
            group.addTask { await body(element) }
        }
        while await group.next() != nil {
            guard !Task.isCancelled, let element = iterator.next() else { continue }
            group.addTask { await body(element) }
        }
    }
}

/// An async counting semaphore: at most `width` holders at once, waiters served in order.
actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(width: Int) {
        available = max(width, 1)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Runs blocking file-system work on a GCD thread, so it never ties up one of Swift's
/// few cooperative threads.
func runBlocking<Result: Sendable>(_ work: @escaping @Sendable () -> Result) async -> Result {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
    }
}
