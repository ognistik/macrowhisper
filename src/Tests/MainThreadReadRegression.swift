import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    print("PASS: \(message)")
}

private final class Results {
    private let lock = NSLock()
    private var values: [Int?] = []

    func append(_ value: Int?) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Int?] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@main
struct MainThreadReadRegression {
    static func main() {
        require(MainThreadRead.perform(timeout: 0) { 17 } == 17, "main-thread read executes inline")

        let results = Results()
        let workers = DispatchGroup()
        for value in 0..<100 {
            workers.enter()
            DispatchQueue.global().async {
                results.append(MainThreadRead.perform(timeout: 2) {
                    precondition(Thread.isMainThread)
                    return value
                })
                workers.leave()
            }
        }
        pumpMain(until: { workers.wait(timeout: .now()) == .success })
        require(results.snapshot().compactMap { $0 }.sorted() == Array(0..<100), "concurrent requests publish every result on main")

        var abandonedBodyRan = false
        let expired = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            results.append(MainThreadRead.perform(timeout: 0.01) {
                abandonedBodyRan = true
                return -1
            })
            expired.signal()
        }
        // Deliberately keep main unavailable until the request expires.
        require(expired.wait(timeout: .now() + 2) == .success, "blocked-main request times out without hanging")
        require(results.snapshot().last! == nil, "timeout returns no partially published value")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        require(!abandonedBodyRan, "expired queued request skips late native work")

        let started = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            results.append(MainThreadRead.perform(timeout: 0.01) {
                started.signal()
                Thread.sleep(forTimeInterval: 0.03)
                return -2
            })
            completed.signal()
        }
        pumpMain(until: { completed.wait(timeout: .now()) == .success })
        require(started.wait(timeout: .now()) == .success, "timeout fixture began the native read")
        require(results.snapshot().last! == nil, "in-flight result is discarded after timeout")
        print("Main-thread read regression passed")
    }

    private static func pumpMain(until done: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            if done() { return }
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        require(false, "main-thread work completes within its deadline")
    }
}
