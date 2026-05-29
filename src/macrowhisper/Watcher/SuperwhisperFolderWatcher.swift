import Foundation
import Dispatch

/// SuperwhisperFolderWatcher - Monitors parent directory for recordings folder creation
/// This watcher monitors the Superwhisper parent directory (e.g., ~/Documents/superwhisper)
/// and detects when the recordings subdirectory appears, allowing the app to continue
/// running gracefully while waiting for the Superwhisper folder structure to be created.
class SuperwhisperFolderWatcher {
    private let parentPath: String
    private let recordingsPath: String
    private var source: DispatchSourceFileSystemObject?
    private var watcherStartedAt: Date?
    private var lastFolderEventAt: Date?
    private let queue = DispatchQueue(label: "com.macrowhisper.superwhisperwatcher")
    private let onRecordingsFolderAppeared: () -> Void

    init(parentPath: String, onRecordingsFolderAppeared: @escaping () -> Void) {
        self.parentPath = (parentPath as NSString).expandingTildeInPath
        self.recordingsPath = "\(self.parentPath)/recordings"
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

        // Check if parent directory exists, if not create it
        if !FileManager.default.fileExists(atPath: parentPath) {
            logDebug("SuperwhisperFolderWatcher: Parent directory doesn't exist, creating: \(parentPath)")
            do {
                try FileManager.default.createDirectory(atPath: parentPath, withIntermediateDirectories: true, attributes: nil)
                logDebug("SuperwhisperFolderWatcher: Created parent directory: \(parentPath)")
            } catch {
                logError("SuperwhisperFolderWatcher: Failed to create parent directory \(parentPath): \(error)")
                return
            }
        }

        logDebug("SuperwhisperFolderWatcher: Starting watcher for recordings folder at \(recordingsPath)")

        let fileDescriptor = open(parentPath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            logError("SuperwhisperFolderWatcher: Failed to open file descriptor for path: \(parentPath)")
            return
        }

        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .write, queue: queue)

        source?.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.handleDirectoryChange()
        }

        source?.setCancelHandler {
            close(fileDescriptor)
        }

        source?.resume()
        watcherStartedAt = Date()
        logDebug("SuperwhisperFolderWatcher: Started watching parent directory \(parentPath) for recordings folder creation")
    }

    func stop() {
        source?.cancel()
        source = nil
        watcherStartedAt = nil
        logDebug("SuperwhisperFolderWatcher: Stopped watching for recordings folder")
    }

    func statusSummary() -> String {
        if FileManager.default.fileExists(atPath: recordingsPath) {
            return "no (recordings folder exists)"
        }

        if !FileManager.default.fileExists(atPath: parentPath) {
            return "no (parent folder missing)"
        }

        guard source != nil else {
            return "no (not armed)"
        }

        return "yes (waiting, started \(describeStatusAge(watcherStartedAt)), last event \(describeStatusAge(lastFolderEventAt)))"
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
