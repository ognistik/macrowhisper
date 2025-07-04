import Foundation
import Dispatch
import Cocoa

/// RecordingsFolderWatcher - Monitors Superwhisper recordings folder
/// 
/// CORE PRINCIPLE: Macrowhisper only processes the most recent recording with a valid result.
/// - On startup: Mark all existing recordings as processed
/// - When multiple new recordings appear simultaneously: Process only the most recent, mark others as processed
/// - This prevents processing storms and handles cloud sync scenarios elegantly
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
        
        // CORE PRINCIPLE: On startup, mark ALL existing recordings as processed
        // This prevents processing storms and aligns with the principle that we only process
        // the most recent recording that appears AFTER the app starts
        markAllExistingRecordingsAsProcessed()
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
    
    private func markAllExistingRecordingsAsProcessed() {
        // CORE PRINCIPLE: Mark all existing recordings as processed on startup
        // We only want to process recordings that appear AFTER the app starts
        let existingDirectories = lastKnownSubdirectories
        var markedCount = 0
        
        for dirName in existingDirectories {
            let fullPath = "\(path)/\(dirName)"
            if !isAlreadyProcessed(recordingPath: fullPath) {
                markAsProcessed(recordingPath: fullPath)
                markedCount += 1
            }
        }
        
        if markedCount > 0 {
            logInfo("Startup: Marked \(markedCount) existing recordings as processed. Will only process new recordings that appear after startup.")
        } else {
            logDebug("Startup: All existing recordings were already marked as processed.")
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
            
            // ENHANCED LOGIC: Check if any new recording is older than existing processed recordings
            // This handles cloud sync scenarios where older recordings appear after newer ones
            let allExistingDirs = lastKnownSubdirectories
            let mostRecentExistingDir = allExistingDirs.max() // Most recent existing directory
            
            // CORE PRINCIPLE: Only process the most recent recording, mark all others as processed
            // Enhanced to also mark recordings older than existing ones as processed
            if newSubdirectories.count > 1 {
                // Multiple new recordings detected - sort by name (timestamp) and only process the most recent
                let sortedNewDirs = newSubdirectories.sorted(by: >)  // Most recent first
                let mostRecentNewDir = sortedNewDirs.first!
                
                // Check if even the most recent new recording is older than existing recordings
                if let mostRecentExisting = mostRecentExistingDir, mostRecentNewDir < mostRecentExisting {
                    // All new recordings are older than existing ones - mark all as processed
                    logInfo("All new recordings (\(newSubdirectories.count)) are older than existing recordings. Marking all as processed to prevent cloud sync interference.")
                    for dirName in newSubdirectories {
                        let fullPath = "\(path)/\(dirName)"
                        markAsProcessed(recordingPath: fullPath)
                        logDebug("Marked as processed (older than existing): \(dirName)")
                    }
                } else {
                    // At least one new recording is recent enough to consider
                    logInfo("Multiple new recordings detected (\(newSubdirectories.count)). Processing only the most recent: \(mostRecentNewDir)")
                    
                    // Mark all others as processed immediately (except the most recent)
                    for dirName in sortedNewDirs.dropFirst() {
                        let fullPath = "\(path)/\(dirName)"
                        markAsProcessed(recordingPath: fullPath)
                        logDebug("Marked as processed (not most recent): \(dirName)")
                    }
                    
                    // Cancel auto-return since multiple recordings appeared - autoReturn should only apply to the first recording
                    if sortedNewDirs.count > 1 {
                        cancelAutoReturn(reason: "multiple recordings appeared simultaneously - autoReturn was intended for a single recording session")
                    }
                    
                    // Process only the most recent
                    let mostRecentPath = "\(path)/\(mostRecentNewDir)"
                    processNewRecording(atPath: mostRecentPath)
                }
            } else {
                // Single new recording - check if it's older than existing recordings
                let dirName = newSubdirectories.first!
                
                if let mostRecentExisting = mostRecentExistingDir, dirName < mostRecentExisting {
                    // This new recording is older than existing ones - mark as processed
                    let fullPath = "\(path)/\(dirName)"
                    markAsProcessed(recordingPath: fullPath)
                    logInfo("New recording \(dirName) is older than existing recordings. Marked as processed to prevent cloud sync interference.")
                } else {
                    // This recording is recent enough to process
                    let fullPath = "\(path)/\(dirName)"
                    
                    // Cancel auto-return if this is a newer recording superseding a previous one being processed
                    if let mostRecentExisting = mostRecentExistingDir, dirName > mostRecentExisting {
                        cancelAutoReturn(reason: "newer recording \(dirName) appeared while processing older recording - autoReturn was intended for the original recording")
                    }
                    
                    processNewRecording(atPath: fullPath)
                }
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
                    
                    // Cancel auto-return if it was enabled - recording was interrupted
                    cancelAutoReturn(reason: "recording folder \(dirName) was deleted during processing")
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
                
                // Cancel auto-return if it was enabled - meta.json was deleted during processing
                cancelAutoReturn(reason: "meta.json was deleted during processing")
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
            
            // FIRST: Check for auto-return (highest priority - overrides everything)
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
            
            // SECOND: Evaluate triggers for all actions - this has precedence over active inserts
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
                        recordingPath: recordingPath,
                        isTriggeredAction: true  // This is a trigger action
                    )
                }
                
                handlePostProcessing(recordingPath: recordingPath)
                
                // Early monitoring will be stopped by ClipboardMonitor when done
                return
            }
            
            // THIRD: Process active action if there is one (supports all action types)
            if let activeActionName = configManager.config.defaults.activeAction,
               !activeActionName.isEmpty {
                
                // Find the active action across all action types
                let (actionType, action) = findActionByName(activeActionName, configManager: configManager)
                
                if let action = action {
                    logDebug("Processing with active action: \(activeActionName) (type: \(actionType))")
                    
                    // Handle based on action type
                    switch actionType {
                    case .insert:
                        if let activeInsert = action as? AppConfiguration.Insert {
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
                                
                                // Use action-level restoreClipboard if set, otherwise fall back to global default
                                let restoreClipboard = activeInsert.restoreClipboard ?? configManager.config.defaults.restoreClipboard
                                
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
                                    restoreClipboard: restoreClipboard
                                )
                            }
                        }
                    case .url, .shortcut, .shell, .appleScript:
                        // For non-insert active actions, execute directly
                        DispatchQueue.main.async { [weak self] in
                            self?.actionExecutor.executeAction(
                                action: action,
                                name: activeActionName,
                                type: actionType,
                                metaJson: enhancedMetaJson,
                                recordingPath: recordingPath,
                                isTriggeredAction: false  // This is an active action, not triggered
                            )
                        }
                    }
                } else {
                    logDebug("Active action '\(activeActionName)' not found, skipping action.")
                }
            } else {
                logDebug("No active action, skipping action.")
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
        // Determine the moveTo value with proper precedence (active action takes precedence over default)
        var moveTo: String?
        
        if let activeActionName = configManager.config.defaults.activeAction,
           !activeActionName.isEmpty {
            // Find the active action and get its moveTo value
            let (actionType, action) = findActionByName(activeActionName, configManager: configManager)
            
            if let action = action {
                var actionMoveTo: String?
                
                switch actionType {
                case .insert:
                    if let insert = action as? AppConfiguration.Insert {
                        actionMoveTo = insert.moveTo
                    }
                case .url:
                    if let url = action as? AppConfiguration.Url {
                        actionMoveTo = url.moveTo
                    }
                case .shortcut:
                    if let shortcut = action as? AppConfiguration.Shortcut {
                        actionMoveTo = shortcut.moveTo
                    }
                case .shell:
                    if let shell = action as? AppConfiguration.ScriptShell {
                        actionMoveTo = shell.moveTo
                    }
                case .appleScript:
                    if let script = action as? AppConfiguration.ScriptAppleScript {
                        actionMoveTo = script.moveTo
                    }
                }
                
                if let actionMoveTo = actionMoveTo, !actionMoveTo.isEmpty {
                    // Active action has an explicit moveTo value (including ".none" and ".delete")
                    moveTo = actionMoveTo
                } else {
                    // Active action moveTo is nil/empty, fall back to default
                    moveTo = configManager.config.defaults.moveTo
                }
            } else {
                // Active action not found, fall back to default
                moveTo = configManager.config.defaults.moveTo
            }
        } else {
            // No active action, use default
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
    
    // Helper function to find any action by name across all types
    private func findActionByName(_ name: String, configManager: ConfigurationManager) -> (ActionType, Any?) {
        let config = configManager.config
        
        if let insert = config.inserts[name] {
            return (.insert, insert)
        }
        if let url = config.urls[name] {
            return (.url, url)
        }
        if let shortcut = config.shortcuts[name] {
            return (.shortcut, shortcut)
        }
        if let shell = config.scriptsShell[name] {
            return (.shell, shell)
        }
        if let script = config.scriptsAS[name] {
            return (.appleScript, script)
        }
        
        return (.insert, nil) // Default type for not found
    }
} 
