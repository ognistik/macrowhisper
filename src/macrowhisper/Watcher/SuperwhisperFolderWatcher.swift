import Foundation
import Dispatch

/// SuperwhisperFolderWatcher - Monitors parent directory for recordings folder creation
/// This watcher monitors the configured Superwhisper parent directory (e.g., ~/superwhisper)
/// and detects when the recordings subdirectory appears, allowing the app to continue
/// running gracefully while waiting for the Superwhisper folder structure to be created.
class SuperwhisperFolderWatcher {
    private let parentPath: String
    private let recordingsPath: String
    private var monitoredPath: String?
    private var source: DispatchSourceFileSystemObject?
    private var watcherStartedAt: Date?
    private var lastFolderEventAt: Date?
    private let queue = DispatchQueue(label: "com.macrowhisper.superwhisperwatcher")
    private let onRecordingsFolderAppeared: () -> Void
    private let onParentFolderInvalidated: ((String) -> Void)?

    init(parentPath: String, onParentFolderInvalidated: ((String) -> Void)? = nil, onRecordingsFolderAppeared: @escaping () -> Void) {
        self.parentPath = (parentPath as NSString).expandingTildeInPath
        self.recordingsPath = "\(self.parentPath)/recordings"
        self.onParentFolderInvalidated = onParentFolderInvalidated
        self.onRecordingsFolderAppeared = onRecordingsFolderAppeared
    }
    
    /// Ensures proper cleanup of resources to prevent memory leaks
    deinit {
        logDebug("SuperwhisperFolderWatcher deinitializing - cleaning up resources")
        stop()
    }

    func start() {
        // Ensure we don't start multiple watchers
        guard source == nil else { return }

        // Check if recordings folder already exists
        if FileManager.default.fileExists(atPath: recordingsPath) {
            logDebug("SuperwhisperFolderWatcher: Recordings folder already exists at \(recordingsPath)")
            onRecordingsFolderAppeared()
            return
        }

        // If the configured Superwhisper folder is missing, watch its nearest
        // existing ancestor. This lets the watcher notice when the original
        // folder returns without creating directories or polling continuously.
        guard let pathToMonitor = nearestExistingDirectory(to: parentPath) else {
            logError("SuperwhisperFolderWatcher: No existing ancestor found for \(parentPath)")
            return
        }
        monitoredPath = pathToMonitor

        logDebug("SuperwhisperFolderWatcher: Starting watcher at \(pathToMonitor) for recordings folder \(recordingsPath)")

        let fileDescriptor = open(pathToMonitor, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            logError("SuperwhisperFolderWatcher: Failed to open file descriptor for path: \(pathToMonitor)")
            return
        }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )

        source?.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = self.source?.data ?? []
            if event.contains(.delete) || event.contains(.rename) || event.contains(.revoke) ||
                !FileManager.default.fileExists(atPath: pathToMonitor) {
                let invalidatedPath = self.parentPath
                self.stop()
                self.onParentFolderInvalidated?(invalidatedPath)
                return
            }

            // As missing path components reappear, move the event source closer
            // to the target so creation of recordings is still observed.
            if let nearestPath = self.nearestExistingDirectory(to: self.parentPath),
               nearestPath != pathToMonitor {
                self.stop()
                self.start()
                return
            }
            self.handleDirectoryChange()
        }

        source?.setCancelHandler {
            close(fileDescriptor)
        }

        source?.resume()
        watcherStartedAt = Date()
        logDebug("SuperwhisperFolderWatcher: Started watching \(pathToMonitor) for recordings folder creation")
    }

    func stop() {
        source?.cancel()
        source = nil
        monitoredPath = nil
        watcherStartedAt = nil
        logDebug("SuperwhisperFolderWatcher: Stopped watching for recordings folder")
    }

    func statusSummary() -> String {
        if FileManager.default.fileExists(atPath: recordingsPath) {
            return "no (recordings folder exists)"
        }

        guard source != nil else {
            return "no (not armed)"
        }

        return "yes (waiting via \(monitoredPath ?? "unknown"), started \(describeStatusAge(watcherStartedAt)), last event \(describeStatusAge(lastFolderEventAt)))"
    }

    private func handleDirectoryChange() {
        lastFolderEventAt = Date()

        // Check if the recordings folder now exists
        if FileManager.default.fileExists(atPath: recordingsPath) {
            logInfo("SuperwhisperFolderWatcher: Recordings folder detected at \(recordingsPath)!")
            
            // Stop watching since we found what we were looking for
            stop()
            
            // Notify that the recordings folder appeared
            onRecordingsFolderAppeared()
        }
    }

    private func nearestExistingDirectory(to targetPath: String) -> String? {
        var candidate = (targetPath as NSString).standardizingPath

        while true {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }

            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate || parent.isEmpty {
                return nil
            }
            candidate = parent
        }
    }

    private func describeStatusAge(_ date: Date?) -> String {
        guard let date = date else {
            return "never"
        }

        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 5 {
            return "just now"
        }
        if seconds < 60 {
            return "\(seconds)s ago"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }

        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }

        return "\(hours / 24)d ago"
    }
} 
