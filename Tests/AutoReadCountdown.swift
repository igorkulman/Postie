import Foundation

/// A test-controlled read delay: signal entry, then finish only when explicitly released.
@MainActor
final class AutoReadCountdown {
    private let starts: AsyncStream<Void>
    private let started: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<Void, Never>?
    private var released = false

    init() {
        (starts, started) = AsyncStream.makeStream(of: Void.self)
    }

    func wait() async throws {
        if !released {
            await withCheckedContinuation { continuation in
                pending = continuation
                started.yield()
            }
        }
        try Task.checkCancellation()
    }

    func waitForStart() async {
        var iterator = starts.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        released = true
        pending?.resume()
        pending = nil
        started.finish()
    }
}
