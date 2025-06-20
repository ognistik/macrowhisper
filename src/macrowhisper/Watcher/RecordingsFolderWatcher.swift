import Foundation
import Dispatch
import Cocoa

class RecordingsFolderWatcher {
    private let path: String
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.macrowhisper.recordingswatcher")
    private var lastKnownSubdirectories: Set<String> = []
    private var pendingMetaJsonFiles: [String: DispatchSourceFileSystemObject] = [:]
    private var processedRecordings: Set<String> = []
    private let configManager: ConfigurationManager
    private let historyManager: HistoryManager
    private let socketCommunication: SocketCommunication
    private let triggerEvaluator: TriggerEvaluator
    private let actionExecutor: ActionExecutor
    private let clipboardMonitor: ClipboardMonitor
    private let processedRecordingsFile: String
    private let versionChecker: VersionChecker?

    init?(basePath: String, configManager: ConfigurationManager, historyManager: HistoryManager, socketCommunication: SocketCommunication, versionChecker: VersionChecker?) {
        self.path = "\(basePath)/recordings"
        self.configManager = configManager
        self.historyManager = historyManager
        self.socketCommunication = socketCommunication
        self.triggerEvaluator = TriggerEvaluator(logger: logger)
        self.actionExecutor = ActionExecutor(logger: logger, socketCommunication: socketCommunication, configManager: configManager)
        self.clipboardMonitor = ClipboardMonitor(logger: logger)
        self.versionChecker = versionChecker
        
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
        logDebug("Started watching for new recordings in: \(path)")
    }

    func stop() {
        source?.cancel()
        source = nil
        
        // Cancel all pending meta.json watchers
        for (_, watcher) in pendingMetaJsonFiles {
            watcher.cancel()
        }
        pendingMetaJsonFiles.removeAll()
        
        // Stop all early clipboard monitoring sessions
        let currentSubdirectories = getCurrentSubdirectories()
        for dirName in currentSubdirectories {
            let fullPath = "\(path)/\(dirName)"
            clipboardMonitor.stopEarlyMonitoring(for: fullPath)
        }
        
        // Save processed recordings list
        saveProcessedRecordings()
    }
    
    private func loadProcessedRecordings() {
        if let content = try? String(contentsOfFile: processedRecordingsFile, encoding: .utf8) {
            let recordings = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            processedRecordings = Set(recordings)
            logDebug("Loaded \(processedRecordings.count) previously processed recordings")
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
            logDebug("Marked most recent recording as processed on startup: \(fullPath)")
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
            logDebug("Detected new recording directories: \(newSubdirectories.joined(separator: ", "))")
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
                    logDebug("Removed watcher for deleted directory: \(fullPath)")
                }
                
                // Stop early clipboard monitoring for deleted folder
                clipboardMonitor.stopEarlyMonitoring(for: fullPath)
                
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
            logDebug("Skipping already processed recording: \(path)")
            return
        }
        
        // Start early clipboard monitoring immediately when folder appears
        clipboardMonitor.startEarlyMonitoring(for: path)
        
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
        logDebug("Started watching for meta.json creation in: \(recordingPath)")
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
        logDebug("Started watching for changes to meta.json at: \(metaJsonPath)")
    }
    
    private func processMetaJson(metaJsonPath: String, recordingPath: String) {
        // Skip if already processed
        if isAlreadyProcessed(recordingPath: recordingPath) {
            logDebug("Skipping already processed recording: \(recordingPath)")
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
                logDebug("No result found in meta.json for \(recordingPath), watching for updates.")
                // Watch for changes to the meta.json file
                watchMetaJsonForChanges(metaJsonPath: metaJsonPath, recordingPath: recordingPath)
                // Don't stop early monitoring here as we're still watching for changes
                return
            }
            
            // We have a valid result, process it immediately
            logDebug("Valid result found in meta.json for \(recordingPath), processing.")
            
            // Always update lastDetectedFrontApp to the current frontmost app for app triggers and input field detection
            var frontApp: NSRunningApplication?
            if Thread.isMainThread {
                frontApp = NSWorkspace.shared.frontmostApplication
            } else {
                DispatchQueue.main.sync {
                    frontApp = NSWorkspace.shared.frontmostApplication
                }
            }
            lastDetectedFrontApp = frontApp
            
            // Get front app info for app triggers and add to metaJson to optimize placeholder processing
            let frontAppName = frontApp?.localizedName
            let frontAppBundleId = frontApp?.bundleIdentifier
            
            // Create enhanced metaJson with front app info to optimize {{frontApp}} placeholder processing
            var enhancedMetaJson = metaJson
            enhancedMetaJson["frontAppName"] = frontAppName
            enhancedMetaJson["frontApp"] = frontAppName  // Add frontApp directly to avoid semaphore delay
            enhancedMetaJson["frontAppBundleId"] = frontAppBundleId
            
            // Mark as processed before executing actions to prevent reprocessing
            markAsProcessed(recordingPath: recordingPath)
            
            // Remove any pending watcher for this meta.json
            if let watcher = pendingMetaJsonFiles[metaJsonPath] {
                watcher.cancel()
                pendingMetaJsonFiles.removeValue(forKey: metaJsonPath)
            }
            
            // FIRST: Evaluate triggers for all actions - this has precedence over active inserts and auto-return
            let matchedTriggerActions = triggerEvaluator.evaluateTriggersForAllActions(
                configManager: configManager,
                result: String(describing: result),
                metaJson: enhancedMetaJson,
                frontAppName: frontAppName,
                frontAppBundleId: frontAppBundleId
            )
            
            if !matchedTriggerActions.isEmpty {
                // Execute the first matched trigger action (they're already sorted by name)
                let (action, name, type, strippedResult) = matchedTriggerActions.first!
                
                // Prepare metaJson with updated result if voice trigger matched and stripped result
                var updatedJson = enhancedMetaJson
                if let stripped = strippedResult {
                    updatedJson["result"] = stripped
                    updatedJson["swResult"] = stripped
                }
                
                // Execute the action on the main thread
                DispatchQueue.main.async { [weak self] in
                    self?.actionExecutor.executeAction(
                        action: action,
                        name: name,
                        type: type,
                        metaJson: updatedJson,
                        recordingPath: recordingPath
                    )
                }
                
                // Continue processing to allow auto-return to work if enabled
                handlePostProcessing(recordingPath: recordingPath)
                
                // Early monitoring will be stopped by ClipboardMonitor when done
                return
            }
            
            // SECOND: Check for auto-return (has precedence over active inserts)
            if autoReturnEnabled {
                // Apply the result directly using {{swResult}}
                let resultValue = enhancedMetaJson["result"] as? String ?? enhancedMetaJson["llmResult"] as? String ?? ""
                
                // Use enhanced clipboard monitoring for auto-return to handle Superwhisper interference
                let actionDelay = configManager.config.defaults.actionDelay
                let shouldEsc = !configManager.config.defaults.noEsc
                
                clipboardMonitor.executeInsertWithEnhancedClipboardSync(
                    insertAction: { [weak self] in
                        // Apply the result without ESC (handled by clipboard monitor)
                        self?.socketCommunication.applyInsertWithoutEsc(resultValue, activeInsert: nil)
                        // Reset the flag after using it once
                        autoReturnEnabled = false
                    },
                    actionDelay: actionDelay,
                    shouldEsc: shouldEsc,
                    isAutoPaste: false,  // Auto-return is not autoPaste
                    recordingPath: recordingPath,
                    metaJson: enhancedMetaJson,
                    restoreClipboard: configManager.config.defaults.restoreClipboard
                )
                
                logDebug("Applied auto-return with enhanced clipboard monitoring")
                handlePostProcessing(recordingPath: recordingPath)
                
                // Early monitoring will be stopped by ClipboardMonitor when done
                return
            }
            
            // THIRD: Process active insert if there is one
            if let activeInsertName = configManager.config.defaults.activeInsert,
               !activeInsertName.isEmpty,
               let activeInsert = configManager.config.inserts[activeInsertName] {
                
                logDebug("Processing with active insert: \(activeInsertName)")
                
                // Check if the insert action is ".none" or empty - if so, skip action but apply delay
                if activeInsert.action == ".none" || activeInsert.action.isEmpty {
                    logDebug("Active insert action is '.none' or empty - skipping action, no ESC, no clipboard restoration")
                    // Apply actionDelay if specified, but don't do anything else
                    let actionDelay = activeInsert.actionDelay ?? configManager.config.defaults.actionDelay
                    if actionDelay > 0 {
                        Thread.sleep(forTimeInterval: actionDelay)
                        logDebug("Applied actionDelay: \(actionDelay)s for .none/.empty action")
                    }
                } else {
                    // Use enhanced clipboard monitoring for active insert to handle Superwhisper interference
                    let (processedAction, isAutoPaste) = socketCommunication.processInsertAction(activeInsert.action, metaJson: enhancedMetaJson)
                    let actionDelay = activeInsert.actionDelay ?? configManager.config.defaults.actionDelay
                    let shouldEsc = !(activeInsert.noEsc ?? configManager.config.defaults.noEsc)
                    
                                    clipboardMonitor.executeInsertWithEnhancedClipboardSync(
                    insertAction: { [weak self] in
                        // Apply the insert without ESC (handled by clipboard monitor)
                        self?.socketCommunication.applyInsertWithoutEsc(processedAction, activeInsert: activeInsert, isAutoPaste: isAutoPaste)
                    },
                    actionDelay: actionDelay,
                    shouldEsc: shouldEsc,
                    isAutoPaste: isAutoPaste,
                    recordingPath: recordingPath,
                    metaJson: enhancedMetaJson,
                    restoreClipboard: configManager.config.defaults.restoreClipboard
                )
                }
            } else {
                logDebug("No active insert, skipping action.")
            }
            
            handlePostProcessing(recordingPath: recordingPath)
            
            // Early monitoring will be stopped by ClipboardMonitor when done
        } catch {
            logError("Error reading meta.json at \(metaJsonPath): \(error)")
            watchMetaJsonForChanges(metaJsonPath: metaJsonPath, recordingPath: recordingPath)
            // Don't stop early monitoring here as we're still watching for changes
        }
    }

    private func handlePostProcessing(recordingPath: String) {
        // Determine the moveTo value with proper precedence (active insert takes precedence over default)
        var moveTo: String?
        if let activeInsertName = configManager.config.defaults.activeInsert,
           !activeInsertName.isEmpty,
           let activeInsert = configManager.config.inserts[activeInsertName],
           let insertMoveTo = activeInsert.moveTo, !insertMoveTo.isEmpty {
            // Active insert has an explicit moveTo value (including ".none" and ".delete")
            moveTo = insertMoveTo
        } else {
            // No active insert or insert moveTo is nil/empty, fall back to default
            moveTo = configManager.config.defaults.moveTo
        }
        
        // Handle the moveTo action
        if let path = moveTo, !path.isEmpty {
            if path == ".delete" {
                logDebug("Deleting processed recording folder: \(recordingPath)")
                try? FileManager.default.removeItem(atPath: recordingPath)
            } else if path == ".none" {
                logDebug("Keeping folder in place as requested by .none setting")
                // Explicitly do nothing
            } else {
                let expandedPath = (path as NSString).expandingTildeInPath
                let destinationUrl = URL(fileURLWithPath: expandedPath).appendingPathComponent((recordingPath as NSString).lastPathComponent)
                logDebug("Moving processed recording folder to: \(destinationUrl.path)")
                try? FileManager.default.moveItem(atPath: recordingPath, toPath: destinationUrl.path)
            }
        }

        historyManager.performHistoryCleanup()
        
        // Check for version updates during active usage with a 30-second delay
        // This ensures users get update notifications during normal app usage, but not immediately
        // after dictation to avoid interrupting their workflow
        if let versionChecker = self.versionChecker {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30.0) {
                versionChecker.checkForUpdates()
            }
        }
    }
} 
