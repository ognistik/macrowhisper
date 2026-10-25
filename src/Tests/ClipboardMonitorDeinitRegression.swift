import Cocoa
import Dispatch
import Foundation

private final class ClipboardMonitorRetention {
    private var monitor: ClipboardMonitor?

    init(_ monitor: ClipboardMonitor) {
        self.monitor = monitor
    }

    func releaseLastReference() {
        monitor = nil
    }
}

private final class WeakClipboardMonitorReference {
    weak var value: ClipboardMonitor?

    init(_ monitor: ClipboardMonitor) {
        value = monitor
    }
}

private final class CompletionFlag {
    private let lock = NSLock()
    private var completed = false

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }
}

private func failClipboardMonitorDeinitRegression(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

@main
private struct ClipboardMonitorDeinitRegression {
    static func main() {
        guard Thread.isMainThread else {
            failClipboardMonitorDeinitRegression("runner must create the monitor on the main thread")
        }

        let sessionsQueue = DispatchQueue(
            label: "macrowhisper.clipboard-monitor-deinit-regression.sessions.\(UUID().uuidString)"
        )
        let attachmentStoreRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrowhisper-monitor-deinit-attachments-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: attachmentStoreRoot) }

        // The retention box owns the monitor's only strong reference. Releasing
        // it from the injected serial sessions queue reproduces deinit running
        // on that queue without starting the global clipboard watcher.
        let (retention, weakMonitor) = {
            let monitor = ClipboardMonitor(
                logger: Logger(),
                preRecordingBufferSeconds: 0,
                clipboardIgnore: "",
                attachmentFileStore: ClipboardAttachmentFileStore(rootDirectory: attachmentStoreRoot),
                sessionsQueue: sessionsQueue
            )
            return (
                ClipboardMonitorRetention(monitor),
                WeakClipboardMonitorReference(monitor)
            )
        }()

        // Let the initializer's periodic-cleanup timer be installed on the
        // main run loop before deinitialization is forced on another queue.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let releaseFinished = CompletionFlag()

        sessionsQueue.async {
            retention.releaseLastReference()
            releaseFinished.markCompleted()
        }

        // Keep the main run loop active while waiting. Deinit dispatches timer
        // invalidation back to main, so blocking on a semaphore here could hide
        // a teardown deadlock or starve that cleanup work.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && (!releaseFinished.value || weakMonitor.value != nil) {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        guard releaseFinished.value else {
            failClipboardMonitorDeinitRegression(
                "final release on the sessions queue did not finish within 5 seconds"
            )
        }
        guard weakMonitor.value == nil else {
            failClipboardMonitorDeinitRegression("the monitor remained alive after its last strong reference was released")
        }

        // A main-queue marker enqueued after deinit's timer invalidation gives
        // the run loop a bounded opportunity to execute that teardown block.
        let mainQueueDrained = CompletionFlag()
        DispatchQueue.main.async {
            mainQueueDrained.markCompleted()
        }
        while Date() < deadline && !mainQueueDrained.value {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard mainQueueDrained.value else {
            failClipboardMonitorDeinitRegression("main-queue timer cleanup did not run within 5 seconds")
        }

        print("PASS: cleanup timer is installed and final monitor release completes on its serial sessions queue")
        print("PASS: the monitor deallocates and main-queue timer cleanup runs")
    }
}
