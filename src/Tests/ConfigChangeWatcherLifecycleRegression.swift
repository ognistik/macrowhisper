import Foundation

func logDebug(_ message: String) {}
func logError(_ message: String) {}

private final class Changes {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@main
struct ConfigChangeWatcherLifecycleRegression {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
    }

    private static func waitForChange(_ changes: Changes, after baseline: Int) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if changes.count > baseline { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrowhisper-watcher-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: file)
        let changes = Changes()
        let watcher = ConfigChangeWatcher(filePath: file.path) { changes.record() }
        watcher.start()
        watcher.start()
        defer { watcher.stop() }

        var baseline = changes.count
        try Data("{\"value\":1}".utf8).write(to: file)
        expect(waitForChange(changes, after: baseline), "observes an ordinary write")

        baseline = changes.count
        try Data("{\"value\":2}".utf8).write(to: file, options: .atomic)
        expect(waitForChange(changes, after: baseline), "observes atomic replacement")
        Thread.sleep(forTimeInterval: 0.15)
        baseline = changes.count
        try Data("{\"value\":3}".utf8).write(to: file)
        expect(waitForChange(changes, after: baseline), "continues observing the replacement inode")

        // Allow the rename event to schedule its delayed restart, then stop
        // before that restart is due. It must not resurrect the watcher.
        try Data("{\"value\":4}".utf8).write(to: file, options: .atomic)
        Thread.sleep(forTimeInterval: 0.04)
        watcher.stop()
        baseline = changes.count
        Thread.sleep(forTimeInterval: 0.2)
        try Data("{\"value\":5}".utf8).write(to: file)
        Thread.sleep(forTimeInterval: 0.2)
        expect(changes.count == baseline, "stop cancels delayed restarts and later notifications")

        watcher.start()
        try Data("{\"value\":6}".utf8).write(to: file)
        expect(waitForChange(changes, after: baseline), "an explicit start after stop works")
        watcher.stop()
        try FileManager.default.removeItem(at: file)
        baseline = changes.count
        watcher.start()
        try Data("{}".utf8).write(to: file)
        expect(waitForChange(changes, after: baseline), "observes creation when the target was missing")
    }
}
