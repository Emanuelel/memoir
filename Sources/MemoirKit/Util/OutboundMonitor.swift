import Foundation

/// Counts the requests that have actually left this Mac, at the point they leave it.
///
/// **Why this lives in `MemoirKit` and not in the app.** The counter used to be an
/// `ObservableObject` in `MemoirApp`, incremented once: in the ask handler, after an answer
/// came back, from `reply.brain.isCloud`. `MemoirKit` cannot import `MemoirApp`, so the three
/// pieces of code that actually open a connection had no way to reach it even in principle.
/// The number was therefore inferred from which brain answered, and PRIVACY.md's promise that
/// it is "incremented by the code path that makes the request, not estimated" was false in a
/// way anyone reading the source could see. Four real paths incremented nothing: extraction's
/// `complete()`, the `memoir-ask` CLI, the network brain, and any request that failed.
///
/// So the rule this type exists to enforce: **every send site calls ``record(destination:)``
/// immediately before it sends, and nothing else ever increments.** A brain that forgets is a
/// bug with a test attached, not a silent undercount.
///
/// Deliberately not an actor. A send site is `async` but a counter that can only be read by
/// awaiting is a counter the UI cannot draw synchronously, and this number's whole job is to
/// be visible. A lock around two fields is cheaper and simpler than the alternative.
public final class OutboundMonitor: @unchecked Sendable {

    /// The process-wide counter. There is exactly one.
    public static let shared = OutboundMonitor()

    /// What the honesty panel draws.
    public struct Snapshot: Sendable, Equatable {
        /// Requests that have left this machine since launch.
        public let count: Int
        /// Where the most recent one went, for the sentence under the count.
        public let lastDestination: String?

        public init(count: Int, lastDestination: String?) {
            self.count = count
            self.lastDestination = lastDestination
        }
    }

    private let lock = NSLock()
    private var _count = 0
    private var _lastDestination: String?
    private var observers: [UUID: @Sendable (Snapshot) -> Void] = [:]

    public init() {}

    /// The current state, readable from anywhere without awaiting.
    public var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(count: _count, lastDestination: _lastDestination)
    }

    /// Records one request leaving the machine.
    ///
    /// Call this on the line before the send, not after it returns: a request that is made and
    /// then fails still left. `destination` is a host or a brain name, never a URL carrying a
    /// query, and never anything drawn from the user's own text.
    public func record(destination: String) {
        lock.lock()
        _count += 1
        _lastDestination = destination
        let snapshot = Snapshot(count: _count, lastDestination: _lastDestination)
        let callbacks = Array(observers.values)
        lock.unlock()
        // Outside the lock: an observer that hops to the main actor must not be able to
        // deadlock a send site that is holding it.
        for callback in callbacks { callback(snapshot) }
    }

    /// Watches the counter. Returns a token; drop it into ``removeObserver(_:)`` to stop.
    @discardableResult
    public func observe(_ callback: @escaping @Sendable (Snapshot) -> Void) -> UUID {
        lock.lock()
        let token = UUID()
        observers[token] = callback
        let current = Snapshot(count: _count, lastDestination: _lastDestination)
        lock.unlock()
        callback(current)
        return token
    }

    public func removeObserver(_ token: UUID) {
        lock.lock()
        observers[token] = nil
        lock.unlock()
    }

    /// Resets to zero. Tests only: the shipped counter is per-process and never cleared,
    /// because a counter a user can reset is a counter that cannot be trusted at a glance.
    public func resetForTesting() {
        lock.lock()
        _count = 0
        _lastDestination = nil
        lock.unlock()
    }
}
