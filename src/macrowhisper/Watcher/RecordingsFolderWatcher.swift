import Foundation
import Dispatch

class RecordingsFolderWatcher {
    private let path: String
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.macrowhisper.recordingswatcher")
    private var lastKnownSubdirectories: Set<String> = []
    private var pendingMetaJsonFiles: [String: DispatchSourceFileSystemObject] = [:]
    private var processedRecordings: Set<String> = []
    private let configManager: ConfigurationManager
    private let historyManager: HistoryManager
    private let processedRecordingsFile: String

    init?(basePath: String, configManager: ConfigurationManager, historyManager: HistoryManager) {
        self.path = "\(basePath)/recordings"
        self.configManager = configManager
        self.historyManager = historyManager
        
        // Create a file to track processed recordings
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let macrowhisperDir = appSupportDir?.appendingPathComponent("Macrowhisper")
        
        // Create directory if it doesn't exist
        if let dirPath = macrowhisperDir?.path, !FileManager.default.fileExists(atPath: dirPath) {
            try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        }
        
        self.processedRecordingsFile = macrowhisperDir?.appendingPathComponent("processed_recordings.txt").path ?? "/tmp/macrowhisper_processed_recordings.txt"
        
        // Ensure the directory exists
        guard FileManager.default.fileExists(atPath: self.path) else {
            logError("RecordingsFolderWatcher: Path does not exist or is not a directory: \(self.path)")
            return nil
        }
        
        // Load previously processed recordings
        loadProcessedRecordings()
        
        // Get the initial state
        self.lastKnownSubdirectories = self.getCurrentSubdirectories()
        
        // Mark the most recent recording as processed on startup
        markMostRecentRecordingAsProcessed()
    }

    func start() {
        // Ensure we don't start multiple watchers
        guard source == nil else { return }

        let fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            logError("Failed to open file descriptor for path: \(path)")
            return
        }

        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .write, queue: queue)

        source?.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.handleFolderChangeEvent()
        }

        source?.setCancelHandler {
            close(fileDescriptor)
        }

        source?.resume()
        logInfo("Started watching for new recordings in: \(path)")
    }

    func stop() {
        source?.cancel()
        source = nil
        
        // Cancel all pending meta.json watchers
        for (_, watcher) in pendingMetaJsonFiles {
            watcher.cancel()
        }
        pendingMetaJsonFiles.removeAll()
        
        // Save processed recordings list
        saveProcessedRecordings()
    }
    
    private func loadProcessedRecordings() {
        if let content = try? String(contentsOfFile: processedRecordingsFile, encoding: .utf8) {
            let recordings = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            processedRecordings = Set(recordings)
            logInfo("Loaded \(processedRecordings.count) previously processed recordings")
        }
    }
    
    private func saveProcessedRecordings() {
        let content = processedRecordings.joined(separator: "\n")
        try? content.write(toFile: processedRecordingsFile, atomically: true, encoding: .utf8)
    }
    
    private func markMostRecentRecordingAsProcessed() {
        // Get all recording directories sorted by name (which should be timestamps)
        let sortedDirectories = lastKnownSubdirectories.sorted(by: >)
        
        if let mostRecent = sortedDirectories.first {
            let fullPath = "\(path)/\(mostRecent)"
            markAsProcessed(recordingPath: fullPath)
            logInfo("Marked most recent recording as processed on startup: \(fullPath)")
        }
    }
    
    private func markAsProcessed(recordingPath: String) {
        processedRecordings.insert(recordingPath)
        saveProcessedRecordings()
    }
    
    private func isAlreadyProcessed(recordingPath: String) -> Bool {
        return processedRecordings.contains(recordingPath)
    }

    private func getCurrentSubdirectories() -> Set<String> {
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: path)
            return Set(contents.filter { isDirectory(atPath: "\(path)/\($0)") })
        } catch {
            logError("Failed to get contents of directory \(path): \(error)")
            return []
        }
    }

    private func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func handleFolderChangeEvent() {
        let currentSubdirectories = getCurrentSubdirectories()
        
        // Check for new directories
        let newSubdirectories = currentSubdirectories.subtracting(lastKnownSubdirectories)
        if !newSubdirectories.isEmpty {
            logInfo("Detected new recording directories: \(newSubdirectories.joined(separator: ", "))")
            for dirName in newSubdirectories {
                let fullPath = "\(path)/\(dirName)"
                processNewRecording(atPath: fullPath)
            }
        }
        
        // Check for removed directories and clean up any pending watchers
        let removedSubdirectories = lastKnownSubdirectories.subtracting(currentSubdirectories)
        if !removedSubdirectories.isEmpty {
            for dirName in removedSubdirectories {
                let fullPath = "\(path)/\(dirName)"
                let metaJsonPath = "\(fullPath)/meta.json"
                
                // Remove watcher if it exists
                if let watcher = pendingMetaJsonFiles[metaJsonPath] {
                    watcher.cancel()
                    pendingMetaJsonFiles.removeValue(forKey: metaJsonPath)
                    logInfo("Removed watcher for deleted directory: \(fullPath)")
                }
                
                // Remove from processed recordings list if it exists
                if processedRecordings.contains(fullPath) {
                    processedRecordings.remove(fullPath)
                    saveProcessedRecordings()
                }
            }
        }

        lastKnownSubdirectories = currentSubdirectories
    }
    
    private func processNewRecording(atPath path: String) {
        // Skip if already processed
        if isAlreadyProcessed(recordingPath: path) {
            logInfo("Skipping already processed recording: \(path)")
            return
        }
        
        let metaJsonPath = "\(path)/meta.json"
        
        // Check if meta.json exists immediately
        if FileManager.default.fileExists(atPath: metaJsonPath) {
            // Process the meta.json file right away
            processMetaJson(metaJsonPath: metaJsonPath, recordingPath: path)
        } else {
            // Start watching for meta.json creation
            watchForMetaJsonCreation(recordingPath: path)
        }
    }
    
    private func watchForMetaJsonCreation(recordingPath: String) {
        // Skip if already processed
        if isAlreadyProcessed(recordingPath: recordingPath) {
            return
        }
        
        // Watch the recording directory for changes to detect meta.json creation
        let fileDescriptor = open(recordingPath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            logError("Failed to open file descriptor for path: \(recordingPath)")
            return
        }
        
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .all, queue: queue)
        
        watcher.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            // Skip if already processed
            if self.isAlreadyProcessed(recordingPath: recordingPath) {
                watcher.cancel()
                self.pendingMetaJsonFiles.removeValue(forKey: recordingPath)
                return
            }
            
            let metaJsonPath = "\(recordingPath)/meta.json"
            if FileManager.default.fileExists(atPath: metaJsonPath) {
                // meta.json was created, process it immediately
                self.processMetaJson(metaJsonPath: metaJsonPath, recordingPath: recordingPath)
                
                // Clean up this watcher
                watcher.cancel()
                self.pendingMetaJsonFiles.removeValue(forKey: recordingPath)
            }
        }
        
        watcher.setCancelHandler {
            close(fileDescriptor)
        }
        
        watcher.resume()
        pendingMetaJsonFiles[recordingPath] = watcher
        logInfo("Started watching for meta.json creation in: \(recordingPath)")
    }
    
    private func watchMetaJsonForChanges(metaJsonPath: String, recordingPath: String) {
        // Skip if already processed
        if isAlreadyProcessed(recordingPath: recordingPath) {
            return
        }
        
        // Don't create duplicate watchers
        if pendingMetaJsonFiles[metaJsonPath] != nil {
            return
        }
        
        let fileDescriptor = open(metaJsonPath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            logError("Failed to open file descriptor for path: \(metaJsonPath)")
            return
        }
        
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .all, queue: queue)
        
        watcher.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            // Skip if already processed
            if self.isAlreadyProcessed(recordingPath: recordingPath) {
                watcher.cancel()
                self.pendingMetaJsonFiles.removeValue(forKey: metaJsonPath)
                return
            }
            
            // Check if the file still exists (it might have been deleted)
            guard FileManager.default.fileExists(atPath: metaJsonPath) else {
                // File was deleted, clean up
                watcher.cancel()
                self.pendingMetaJsonFiles.removeValue(forKey: metaJsonPath)
                return
            }
            
            // Process the updated meta.json file immediately
            self.processMetaJson(metaJsonPath: metaJsonPath, recordingPath: recordingPath)
        }
        
        watcher.setCancelHandler {
            close(fileDescriptor)
        }
        
        watcher.resume()
        pendingMetaJsonFiles[metaJsonPath] = watcher
        logInfo("Started watching for changes to meta.json at: \(metaJsonPath)")
    }
    
    private func processMetaJson(metaJsonPath: String, recordingPath: String) {
        // Skip if already processed
        if isAlreadyProcessed(recordingPath: recordingPath) {
            logInfo("Skipping already processed recording: \(recordingPath)")
            return
        }
        
        guard FileManager.default.fileExists(atPath: metaJsonPath) else {
            logWarning("meta.json not found at \(metaJsonPath)")
            return
        }

        // Read and parse the meta.json file
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: metaJsonPath))
            guard let metaJson = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logError("Failed to parse meta.json at \(metaJsonPath)")
                watchMetaJsonForChanges(metaJsonPath: metaJsonPath, recordingPath: recordingPath)
                return
            }
            
            // Check for a valid result
            guard let result = metaJson["result"], !(result is NSNull), (result as? String)?.isEmpty == false else {
                logInfo("No result found in meta.json for \(recordingPath), watching for updates.")
                // Watch for changes to the meta.json file
                watchMetaJsonForChanges(metaJsonPath: metaJsonPath, recordingPath: recordingPath)
                return
            }
            
            // We have a valid result, process it immediately
            logInfo("Valid result found in meta.json for \(recordingPath), processing.")
            
            // Mark as processed before executing actions to prevent reprocessing
            markAsProcessed(recordingPath: recordingPath)
            
            // Remove any pending watcher for this meta.json
            if let watcher = pendingMetaJsonFiles[metaJsonPath] {
                watcher.cancel()
                pendingMetaJsonFiles.removeValue(forKey: metaJsonPath)
            }
            
            // Process active insert if there is one
            if let activeInsertName = configManager.config.defaults.activeInsert,
               !activeInsertName.isEmpty,
               let activeInsert = configManager.config.inserts[activeInsertName] {
                
                logInfo("Processing with active insert: \(activeInsertName)")
                
                // Process on the main thread to ensure UI operations happen immediately
                DispatchQueue.main.async {
                    let (processedAction, isAutoPaste) = socketCommunication.processInsertAction(activeInsert.action, metaJson: metaJson)
                    socketCommunication.applyInsert(processedAction, activeInsert: activeInsert, isAutoPaste: isAutoPaste)
                }
            } else {
                logInfo("No active insert, skipping action.")
            }
            
            handlePostProcessing(recordingPath: recordingPath)
        } catch {
            logError("Error reading meta.json at \(metaJsonPath): \(error)")
            watchMetaJsonForChanges(metaJsonPath: metaJsonPath, recordingPath: recordingPath)
        }
    }

    private func handlePostProcessing(recordingPath: String) {
        let moveTo = configManager.config.defaults.moveTo
        if let path = moveTo, !path.isEmpty, path != ".none" {
            if path == ".delete" {
                logInfo("Deleting processed recording folder: \(recordingPath)")
                try? FileManager.default.removeItem(atPath: recordingPath)
            } else {
                let expandedPath = (path as NSString).expandingTildeInPath
                let destinationUrl = URL(fileURLWithPath: expandedPath).appendingPathComponent((recordingPath as NSString).lastPathComponent)
                logInfo("Moving processed recording folder to: \(destinationUrl.path)")
                try? FileManager.default.moveItem(atPath: recordingPath, toPath: destinationUrl.path)
            }
        }

        historyManager.performHistoryCleanup()
    }
} 
