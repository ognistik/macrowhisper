import Foundation
import Dispatch

class ConfigChangeWatcher {
    private let filePath: String
    private var source: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.macrowhisper.configwatcher")
    private let onChanged: () -> Void

    init(filePath: String, onChanged: @escaping () -> Void) {
        self.filePath = filePath
        self.onChanged = onChanged
    }

    func start() {
        // Ensure we don't start multiple watchers
        guard source == nil && directorySource == nil else { return }

        if FileManager.default.fileExists(atPath: filePath) {
            // File exists, watch it directly
            startWatchingFile()
        } else {
            // File doesn't exist, watch the parent directory for file creation
            startWatchingDirectory()
        }
    }
    
    private func startWatchingFile() {
        logDebug("ConfigChangeWatcher: Starting file watcher for \(filePath)")
        
        let fileDescriptor = open(filePath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            logError("ConfigChangeWatcher: Failed to open file descriptor for path: \(filePath)")
            return
        }

        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .write, queue: queue)

        source?.setEventHandler { [weak self] in
            self?.onChanged()
        }

        source?.setCancelHandler {
            close(fileDescriptor)
        }

        source?.resume()
        logDebug("Started watching for configuration changes at: \(filePath)")
    }
    
    private func startWatchingDirectory() {
        let directoryPath = (filePath as NSString).deletingLastPathComponent
        let fileName = (filePath as NSString).lastPathComponent
        
        logDebug("ConfigChangeWatcher: File doesn't exist, watching directory \(directoryPath) for creation of \(fileName)")
        
        let directoryDescriptor = open(directoryPath, O_EVTONLY)
        guard directoryDescriptor >= 0 else {
            logError("ConfigChangeWatcher: Failed to open directory descriptor for path: \(directoryPath)")
            return
        }

        directorySource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: directoryDescriptor, eventMask: .write, queue: queue)

        directorySource?.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Check if our target file now exists
            if FileManager.default.fileExists(atPath: self.filePath) {
                logDebug("ConfigChangeWatcher: Target file \(self.filePath) was created, switching to file watcher")
                // Stop watching the directory
                self.directorySource?.cancel()
                self.directorySource = nil
                // Start watching the file
                self.startWatchingFile()
                // Also trigger the change handler since the file was just created
                self.onChanged()
            }
        }

        directorySource?.setCancelHandler {
            close(directoryDescriptor)
        }

        directorySource?.resume()
        logDebug("Started watching directory \(directoryPath) for file creation")
    }

    func stop() {
        source?.cancel()
        source = nil
        directorySource?.cancel()
        directorySource = nil
    }
} 