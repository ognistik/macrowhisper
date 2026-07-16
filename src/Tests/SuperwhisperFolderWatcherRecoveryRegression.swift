import Foundation

func logInfo(_ message: String) {}
func logWarning(_ message: String) {}
func logError(_ message: String) {}
func logDebug(_ message: String) {}

private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

private func runSuperwhisperFolderWatcherRecoveryRegression() {
    let fileManager = FileManager.default
    let testRoot = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("macrowhisper-folder-recovery-\(UUID().uuidString)")
    let documentsPath = (testRoot as NSString).appendingPathComponent("Documents")
    let configuredPath = (documentsPath as NSString).appendingPathComponent("superwhisper")
    let stagingPath = (testRoot as NSString).appendingPathComponent("staging")
    let stagedSuperwhisperPath = (stagingPath as NSString).appendingPathComponent("superwhisper")
    let stagedRecordingsPath = (stagedSuperwhisperPath as NSString).appendingPathComponent("recordings")

    defer { try? fileManager.removeItem(atPath: testRoot) }

    do {
        try fileManager.createDirectory(atPath: documentsPath, withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: stagedRecordingsPath, withIntermediateDirectories: true)
    } catch {
        fail("could not create test directories: \(error)")
    }

    let appeared = DispatchSemaphore(value: 0)
    let watcher = SuperwhisperFolderWatcher(parentPath: configuredPath) {
        appeared.signal()
    }
    watcher.start()

    // Simulate returning the complete Superwhisper folder to its original path
    // after it was absent long enough for normal recovery retries to finish.
    do {
        try fileManager.moveItem(atPath: stagedSuperwhisperPath, toPath: configuredPath)
    } catch {
        watcher.stop()
        fail("could not restore the Superwhisper folder: \(error)")
    }

    guard appeared.wait(timeout: .now() + 3) == .success else {
        watcher.stop()
        fail("watcher did not detect the restored recordings folder")
    }

    watcher.stop()
    print("PASS: missing configured folder is detected when it returns")
}

@main
struct SuperwhisperFolderWatcherRecoveryRegressionRunner {
    static func main() {
        runSuperwhisperFolderWatcherRecoveryRegression()
    }
}
