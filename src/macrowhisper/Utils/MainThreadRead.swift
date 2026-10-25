import Foundation

/// A bounded main-thread read whose result cannot race with a late callback.
/// A timed-out request drops its result and skips work that has not started.
enum MainThreadRead {
    static func perform<Value>(timeout: TimeInterval, _ read: @escaping () -> Value) -> Value? {
        if Thread.isMainThread { return read() }
        let request = Request<Value>()
        DispatchQueue.main.async {
            guard request.begin() else { return }
            request.complete(read())
        }
        return request.wait(timeout: timeout)
    }

    private final class Request<Value> {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var isCancelled = false
        private var value: Value?

        func begin() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !isCancelled
        }

        func complete(_ value: Value) {
            lock.lock()
            if !isCancelled { self.value = value }
            lock.unlock()
            semaphore.signal()
        }

        func wait(timeout: TimeInterval) -> Value? {
            let outcome = semaphore.wait(timeout: .now() + max(0, timeout))
            lock.lock()
            let publishedValue = value
            value = nil
            if outcome != .success { isCancelled = true }
            lock.unlock()
            guard outcome == .success else {
                // Native result destruction must not execute while holding
                // the handoff lock, even at the timeout/publication boundary.
                withExtendedLifetime(publishedValue) {}
                return nil
            }
            return publishedValue
        }
    }
}
