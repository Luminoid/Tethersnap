import Synchronization

/// Thread-safe cancellation flag for the synchronous download path, which
/// cannot see Swift structured-concurrency cancellation from inside an actor.
public final class CancelToken: Sendable {
    private let flag = Mutex(false)

    public init() {}

    public func cancel() {
        flag.withLock { $0 = true }
    }

    public var isCancelled: Bool {
        flag.withLock { $0 }
    }
}
