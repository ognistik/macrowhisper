import Foundation
import Dispatch
import Cocoa

/// RecordingsFolderWatcher - Monitors Superwhisper recordings folder
/// 
/// CORE PRINCIPLE: Macrowhisper processes only single-arrival recordings with a valid result.
/// - On startup: Mark all existing recordings as processed
/// - When multiple new recordings appear simultaneously: Mark all as processed and skip execution
/// - This prevents processing storms and handles cloud sync scenarios elegantly
class RecordingsFolderWatcher {
    private let path: String
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.macrowhisper.recordingswatcher")
    private let queueSpecificKey = DispatchSpecificKey<Void>()
    private var lastKnownSubdirectories: Set<String> = []
    private var pendingMetaJsonFiles: [String: DispatchSourceFileSystemObject] = [:]
    private var pendingAudioFileWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var recordingHadWavFiles: [String: Bool] = [:] // Track if recording ever had .wav files
    private var recordingTimeoutTimers: [String: DispatchSourceTimer] = [:] // Timeout timers for recordings
    private var processedRecordings: Set<String> = []
    private let configManager: ConfigurationManager
    private let historyManager: HistoryManager
    private let socketCommunication: SocketCommunication
    private let triggerEvaluator: TriggerEvaluator
    private let actionExecutor: ActionExecutor
    private let clipboardMonitor: ClipboardMonitor
    private let processedRecordingsFile: String
    private let versionChecker: VersionChecker?
    
    // Constants
    private let RECORDING_TIMEOUT_SECONDS: Double = 17.0 // Timeout for recordings without WAV files

    init?(basePath: String, configManager: ConfigurationManager, historyManager: HistoryManager, socketCommunication: SocketCommunication, versionChecker: VersionChecker?) {
        self.path = "\(basePath)/recordings"
        self.configManager = configManager
        self.historyManager = historyManager
        self.socketCommunication = socketCommunication
        self.triggerEvaluator = TriggerEvaluator(logger: logger)
        self.clipboardMonitor = ClipboardMonitor(logger: logger, preRecordingBufferSeconds: configManager.config.defaults.clipboardBuffer, clipboardIgnore: configManager.config.defaults.clipboardIgnore ?? "")
        self.actionExecutor = ActionExecutor(logger: logger, socketCommunication: socketCommunication, configManager: configManager, clipboardMonitor: clipboardMonitor)
        
        // Set clipboard monitor reference in socket communication for CLI action cleanup
        socketCommunication.setClipboardMonitor(clipboardMonitor)
        
        self.versionChecker = versionChecker
        
        // Create a file to track processed recordings
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let macrowhisperDir = appSupportDir?.appendingPathComponent("Macrowhisper")
        
        // Create directory if it doesn't exist
        if let dirPath = macrowhisperDir?.path, !FileManager.default.fileExists(atPath: dirPath) {
            try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        }
        
        self.processedRecordingsFile = macrowhisperDir?.appendingPathComponent("processed_recordings.txt").path ?? "/tmp/macrowhisper_processed_recordings.txt"
        self.queue.setSpecific(key: queueSpecificKey, value: ())
        
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
    
    /// Ensures proper cleanup of resources to prevent memory leaks
    deinit {
        logDebug("RecordingsFolderWatcher deinitializing - cleaning up resources")
        stop()
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
        
        // Cancel all pending audio file watchers
        for (_, watcher) in pendingAudioFileWatchers {
            watcher.cancel()
        }
        pendingAudioFileWatchers.removeAll()
        recordingHadWavFiles.removeAll()
        
        // Cancel all timeout timers
        for (_, timer) in recordingTimeoutTimers {
            timer.cancel()
        }
        recordingTimeoutTimers.removeAll()
        
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
            
            // CORE PRINCIPLE: Burst protection - when multiple recordings appear simultaneously,
            // mark all as processed and execute none.
            if newSubdirectories.count > 1 {
                logInfo("Multiple new recordings detected (\(newSubdirectories.count)). Burst protection active: marking all as processed and skipping execution.")

                // Mark all burst recordings as processed
                for dirName in newSubdirectories {
                    let fullPath = "\(path)/\(dirName)"
                    markAsProcessed(recordingPath: fullPath)
                    logDebug("Marked as processed (burst protection): \(dirName)")
                }

                // Cancel one-shot state since bursts do not represent a single valid session
                cancelAutoReturn(reason: "multiple recordings appeared simultaneously - burst protection skips execution")
                cancelScheduledAction(reason: "multiple recordings appeared simultaneously - burst protection skips execution")

                // UNIFIED RECOVERY: Clean up all pending watchers since multiple recordings appeared
                // This can indicate a Superwhisper crash or restart scenario
                if !pendingMetaJsonFiles.isEmpty || !pendingAudioFileWatchers.isEmpty {
                    performRecordingRecovery(reason: "Superwhisper crash detected - multiple recordings appeared simultaneously while previous recording was being processed")
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
                    
                    // Cancel auto-return and scheduled action if this is a newer recording superseding a previous one being processed
                    // Only cancel if there are actually pending recordings being processed
                    if (!pendingMetaJsonFiles.isEmpty || !pendingAudioFileWatchers.isEmpty), let mostRecentExisting = mostRecentExistingDir, dirName > mostRecentExisting {
                        // UNIFIED RECOVERY: Clean up only OLD pending watchers since Superwhisper likely crashed
                        // and started a new recording session. This prevents orphaned watchers from
                        // interfering with the new recording session, but preserves the new recording's watcher.
                        performRecordingRecovery(reason: "Superwhisper crash detected - new recording \(dirName) appeared while previous recording was being processed", preserveRecording: fullPath)
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
                
                var hadWatchers = false
                
                // Remove meta.json watcher if it exists
                if let watcher = pendingMetaJsonFiles[metaJsonPath] {
                    watcher.cancel()
                    pendingMetaJsonFiles.removeValue(forKey: metaJsonPath)
                    logDebug("Removed watcher for deleted directory (meta.json watcher): \(fullPath)")
                    hadWatchers = true
                }
                // Also remove a potential creation watcher keyed by the recording directory path
                if let creationWatcher = pendingMetaJsonFiles[fullPath] {
                    creationWatcher.cancel()
                    pendingMetaJsonFiles.removeValue(forKey: fullPath)
                    logDebug("Removed watcher for deleted directory (creation watcher): \(fullPath)")
                    hadWatchers = true
                }
                
                // Remove audio file watcher if it exists
                if let audioWatcher = pendingAudioFileWatchers[fullPath] {
                    audioWatcher.cancel()
                    pendingAudioFileWatchers.removeValue(forKey: fullPath)
                    recordingHadWavFiles.removeValue(forKey: fullPath)
                    logDebug("Removed watcher for deleted directory (audio watcher): \(fullPath)")
                    hadWatchers = true
                }
                
                // Cancel timeout timer if it exists
                if let timer = recordingTimeoutTimers[fullPath] {
                    timer.cancel()
                    recordingTimeoutTimers.removeValue(forKey: fullPath)
                    logDebug("Cancelled timeout timer for deleted directory: \(fullPath)")
                    hadWatchers = true
                }
                
                // Cancel auto-return and scheduled action only if we had watchers (recording was being processed)
                if hadWatchers {
                    cancelAutoReturn(reason: "recording folder \(dirName) was deleted during processing")
                    cancelScheduledAction(reason: "recording folder \(dirName) was deleted during processing")
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
        
        // Start early monitoring immediately when the recording folder appears
        // This captures selected text and clipboard context at session start
        clipboardMonitor.startEarlyMonitoring(for: path)
        
        // Start monitoring for .wav file changes to detect cancellation
        setupAudioFileMonitoring(for: path)
        
        // Start timeout timer for recording to detect stalled recordings
        startRecordingTimeout(for: path)

        // Cancel timeouts since a recording session has started (folder appeared)
        cancelAutoReturnTimeout()
        cancelScheduledActionTimeout()
        
        let metaJsonPath = "\(path)/meta.json"
        
        // Check if meta.json exists immediately
        if FileManager.default.fileExists(atPath: metaJsonPath) {
            // Check if meta.json is already complete (has valid llmResult/result based on languageModelName)
            if isMetaJsonComplete(metaJsonPath: metaJsonPath) {
                // Meta.json is complete, process immediately without starting clipboard monitoring
                logDebug("Meta.json exists and is complete, processing immediately without clipboard monitoring")
                processMetaJson(metaJsonPath: metaJsonPath, recordingPath: path)
            } else {
                // Meta.json exists but is incomplete, start monitoring
                logDebug("Meta.json exists but is incomplete, watching for completion (early monitoring already started)")
                processMetaJson(metaJsonPath: metaJsonPath, recordingPath: path)
            }
        } else {
            // Meta.json doesn't exist yet, start monitoring and wait for creation
            logDebug("Meta.json doesn't exist, watching for creation (early monitoring already started)")
            watchForMetaJsonCreation(recordingPath: path)
        }
    }
    
    /// Checks if meta.json file is complete and ready for processing
    /// NEW VALIDATION: Now checks based on languageModelName and llmResult/result instead of duration
    private func isMetaJsonComplete(metaJsonPath: String) -> Bool {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: metaJsonPath))
            guard let metaJson = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }

            // NEW VALIDATION LOGIC: Check based on languageModelName and llmResult/result
            // If languageModelName is not empty, wait for llmResult
            // If languageModelName is empty, wait for result

            // First, check if languageModelName exists and is not empty
            if let languageModelName = metaJson["languageModelName"] as? String, !languageModelName.isEmpty {
                // languageModelName is not empty, check for llmResult
                guard let llmResult = metaJson["llmResult"], !(llmResult is NSNull) else {
                    return false
                }

                // llmResult must be a non-empty string
                if let llmResultString = llmResult as? String, !llmResultString.isEmpty {
                    return true
                } else {
                    return false
                }
            } else {
                // languageModelName is empty or missing, check for result
                guard let result = metaJson["result"], !(result is NSNull) else {
                    return false
                }

                // result must be a non-empty string
                if let resultString = result as? String, !resultString.isEmpty {
                    return true
                } else {
                    return false
                }
            }
        } catch {
            return false
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
    
    /// Sets up monitoring for .wav file changes to detect recording cancellation
    private func setupAudioFileMonitoring(for recordingPath: String) {
        // Skip if already processed
        if isAlreadyProcessed(recordingPath: recordingPath) {
            return
        }
        
        // Initialize tracking - check if .wav files exist initially (they might not yet)
        recordingHadWavFiles[recordingPath] = checkForWavFiles(in: recordingPath)
        
        // Watch the recording directory for file changes to detect .wav file removal
        let fileDescriptor = open(recordingPath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            logError("Failed to open file descriptor for audio monitoring: \(recordingPath)")
            return
        }
        
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .all, queue: queue)
        
        watcher.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            // Skip if already processed
            if self.isAlreadyProcessed(recordingPath: recordingPath) {
                watcher.cancel()
                self.pendingAudioFileWatchers.removeValue(forKey: recordingPath)
                self.recordingHadWavFiles.removeValue(forKey: recordingPath)
                return
            }
            
            // Add a delay to avoid false positives during file rewrites
            // This gives Superwhisper time to finish writing/rewriting the file
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                
                // Re-check if already processed after delay
                if self.isAlreadyProcessed(recordingPath: recordingPath) {
                    return
                }
                
                // Check current state
                let directoryExists = FileManager.default.fileExists(atPath: recordingPath)
                let hasWavFiles = directoryExists ? self.checkForWavFiles(in: recordingPath) : false
                let hadWavFilesBefore = self.recordingHadWavFiles[recordingPath] ?? false
                
                // Update tracking if we now have .wav files (recording started)
                if hasWavFiles && !hadWavFilesBefore {
                    self.recordingHadWavFiles[recordingPath] = true
                    logDebug("Audio recording started: .wav file detected in \(recordingPath)")
                    
                    // Cancel timeout timer since WAV file appeared
                    self.cancelRecordingTimeout(for: recordingPath)
                }
                
                // Only trigger cancellation if:
                // 1. Directory still exists (folder deletion is handled separately)
                // 2. We previously had .wav files (recording was active)
                // 3. No .wav files are present now (they were removed)
                if directoryExists && hadWavFilesBefore && !hasWavFiles {
                    // Double-check after another brief delay to be absolutely sure
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self = self else { return }
                        
                        // Final verification
                        let finalCheck = self.checkForWavFiles(in: recordingPath)
                        if !finalCheck && FileManager.default.fileExists(atPath: recordingPath) {
                            logInfo("CANCELLATION DETECTED: .wav file removed from \(recordingPath) - triggering recovery")
                            
                            // Mark as processed to prevent further processing
                            self.markAsProcessed(recordingPath: recordingPath)
                            
                            // Trigger unified recovery for cancellation
                            self.performRecordingRecovery(reason: "recording cancelled - .wav file removed from \((recordingPath as NSString).lastPathComponent)")
                            
                            // Clean up this watcher and tracking
                            watcher.cancel()
                            self.pendingAudioFileWatchers.removeValue(forKey: recordingPath)
                            self.recordingHadWavFiles.removeValue(forKey: recordingPath)
                        } else if finalCheck {
                            logDebug("False alarm: .wav file reappeared in \(recordingPath) - continuing monitoring")
                        }
                    }
                }
            }
        }
        
        watcher.setCancelHandler {
            close(fileDescriptor)
        }
        
        watcher.resume()
        pendingAudioFileWatchers[recordingPath] = watcher
        logDebug("Started monitoring for .wav file changes in: \(recordingPath)")
    }
    
    /// Checks if any .wav files exist in the given directory with additional validation
    private func checkForWavFiles(in directoryPath: String) -> Bool {
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: directoryPath)
            let wavFiles = contents.filter { $0.lowercased().hasSuffix(".wav") }
            
            // Not only check for existence, but also verify the files are accessible and not zero-size
            // This helps distinguish between file deletion and temporary file states during rewrites
            for wavFile in wavFiles {
                let wavPath = "\(directoryPath)/\(wavFile)"
                let attributes = try? FileManager.default.attributesOfItem(atPath: wavPath)
                if let fileSize = attributes?[.size] as? Int64, fileSize > 0 {
                    // Found at least one valid .wav file with content
                    return true
                }
            }
            
            // Either no .wav files found, or all are zero-size (which could indicate deletion in progress)
            return false
        } catch {
            logError("Failed to check directory contents for .wav files: \(error)")
            return false
        }
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
            
             // Check if the file still exists (it might have been deleted or overwritten)
            guard FileManager.default.fileExists(atPath: metaJsonPath) else {
                // File might be temporarily unavailable during overwrite, add delay to check if it reappears
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self else { return }
                    
                    // Re-check if file exists after delay
                    if !FileManager.default.fileExists(atPath: metaJsonPath) {
                        // File was truly deleted, not just overwritten
                        watcher.cancel()
                        self.pendingMetaJsonFiles.removeValue(forKey: metaJsonPath)
                        
                        // Cancel auto-return and scheduled action if they were enabled - meta.json was deleted during processing
                        cancelAutoReturn(reason: "meta.json was deleted during processing")
                        cancelScheduledAction(reason: "meta.json was deleted during processing")
                        
                        // Stop clipboard monitoring for this recording path as well
                        self.clipboardMonitor.stopEarlyMonitoring(for: recordingPath)
                        logDebug("Stopped clipboard monitoring for \(recordingPath) - meta.json was deleted")
                    } else {
                        // File reappeared, it was just being overwritten - continue processing
                        logDebug("meta.json reappeared after overwrite in \(recordingPath) - continuing monitoring")
                        self.processMetaJson(metaJsonPath: metaJsonPath, recordingPath: recordingPath)
                    }
                }
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
            
            // NEW VALIDATION LOGIC: Check based on languageModelName and llmResult/result
            // If languageModelName is not empty, wait for llmResult
            // If languageModelName is empty, wait for result

            // First, check if languageModelName exists and is not empty
            if let languageModelName = metaJson["languageModelName"] as? String, !languageModelName.isEmpty {
                // languageModelName is not empty, check for llmResult
                guard let llmResult = metaJson["llmResult"], !(llmResult is NSNull) else {
                    logDebug("No valid llmResult found in meta.json for \(recordingPath) (languageModelName present), watching for updates.")
                    // Watch for changes to the meta.json file
                    watchMetaJsonForChanges(metaJsonPath: metaJsonPath, recordingPath: recordingPath)
                    // Don't stop early monitoring here as we're still watching for changes
                    return
                }

                // llmResult must be a non-empty string
                if let llmResultString = llmResult as? String, !llmResultString.isEmpty {
                    // In LLM mode, llmResult is sufficient for processing.
                    // Trigger voice matching still runs against result and will simply not match when result is empty.
                    logDebug("[Validation] Passed validation with languageModelName present. llmResult=\(summarizeForLogs(llmResultString, maxPreview: 120))")
                } else {
                    logDebug("llmResult is empty in meta.json for \(recordingPath), watching for updates.")
                    // Watch for changes to the meta.json file
                    watchMetaJsonForChanges(metaJsonPath: metaJsonPath, recordingPath: recordingPath)
                    // Don't stop early monitoring here as we're still watching for changes
                    return
                }
            } else {
                // languageModelName is empty or missing, check for result
                guard let result = metaJson["result"], !(result is NSNull) else {
                    logDebug("No valid result found in meta.json for \(recordingPath) (no languageModelName), watching for updates.")
                    // Watch for changes to the meta.json file
                    watchMetaJsonForChanges(metaJsonPath: metaJsonPath, recordingPath: recordingPath)
                    // Don't stop early monitoring here as we're still watching for changes
                    return
                }

                // result must be a non-empty string
                if let resultString = result as? String, !resultString.isEmpty {
                    // result is valid, continue processing
                    logDebug("[Validation] Passed validation without languageModelName. result=\(summarizeForLogs(resultString, maxPreview: 120))")
                } else {
                    logDebug("result is empty in meta.json for \(recordingPath), watching for updates.")
                    // Watch for changes to the meta.json file
                    watchMetaJsonForChanges(metaJsonPath: metaJsonPath, recordingPath: recordingPath)
                    // Don't stop early monitoring here as we're still watching for changes
                    return
                }
            }
            
            // Always update lastDetectedFrontApp to the current frontmost app for app triggers and input field detection
            var frontApp: NSRunningApplication?
            if Thread.isMainThread {
                frontApp = NSWorkspace.shared.frontmostApplication
            } else {
                DispatchQueue.main.sync {
                    frontApp = NSWorkspace.shared.frontmostApplication
                }
            }
            globalState.lastDetectedFrontApp = frontApp
            
            // Get front app info for app triggers
            let frontAppName = frontApp?.localizedName
            let frontAppBundleId = frontApp?.bundleIdentifier
            let frontAppPid = frontApp?.processIdentifier
            let frontAppUrl = getActiveURL(targetPid: frontAppPid, fallbackBundleId: frontAppBundleId)
            
            // Create enhanced metaJson with app metadata captured at processing time
            var enhancedMetaJson = metaJson
            enhancedMetaJson["frontAppName"] = frontAppName
            enhancedMetaJson["frontAppBundleId"] = frontAppBundleId
            if let frontAppPid {
                enhancedMetaJson["frontAppPid"] = Int(frontAppPid)
            }
            if let frontAppUrl, !frontAppUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                enhancedMetaJson["frontAppUrl"] = frontAppUrl
            }
            
            // Resolve session context from the root recording path so overlap chains
            // always read/write a single clipboard/selection context source.
            let contextRecordingPath = clipboardMonitor.getContextRootRecordingPath(for: recordingPath)

            // Add session data from clipboard monitor for placeholder processing
            let sessionSelectedText = clipboardMonitor.getSessionSelectedText(for: contextRecordingPath)
            if !sessionSelectedText.isEmpty {
                enhancedMetaJson["selectedText"] = sessionSelectedText
            }
            
            // Filter out recent system clipboard sync (Superwhisper) from clipboardContext capture
            // before resolving placeholders, regardless of action type.
            clipboardMonitor.markRecentClipboardActivityAsSystemSync(for: contextRecordingPath)

            let swResult = (metaJson["llmResult"] as? String) ?? (metaJson["result"] as? String) ?? ""
            let enableStacking = configManager.config.defaults.clipboardStacking
            let sessionClipboardContent = clipboardMonitor.getSessionClipboardContentWithStacking(
                for: contextRecordingPath,
                swResult: swResult,
                enableStacking: enableStacking
            )
            // Freeze clipboardContext at meta validation time (including explicit empty snapshot).
            enhancedMetaJson["clipboardContext"] = sessionClipboardContent
            enhancedMetaJson[runtimeClipboardContextLockedKey] = true

            // Bypass processing entirely for configured Superwhisper modes.
            let modeName = metaJson["modeName"] as? String
            if shouldBypassProcessing(for: modeName) {
                let normalizedMode = modeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let readableMode = normalizedMode.isEmpty ? "(empty)" : normalizedMode
                logInfo("Bypassing Macrowhisper processing for mode '\(readableMode)' due to defaults.bypassModes.")
                markAsProcessed(recordingPath: recordingPath)
                cancelRecordingTimeout(for: recordingPath)
                cleanupPendingWatcher(for: recordingPath)
                cleanupPendingWatcher(for: metaJsonPath)
                clipboardMonitor.stopEarlyMonitoring(for: recordingPath)
                return
            }
            
            // Mark as processed before executing actions to prevent reprocessing
            markAsProcessed(recordingPath: recordingPath)
            
            // Cancel timeout timer since recording completed successfully
            cancelRecordingTimeout(for: recordingPath)
            
            // IMMEDIATE CLEANUP: Clean up pending watchers as soon as recording is processed
            // This ensures hasActiveRecordingSessions() returns false immediately, allowing scheduled actions to work properly
            cleanupPendingWatcher(for: recordingPath)
            cleanupPendingWatcher(for: metaJsonPath)
            
            // Store the metaJsonPath for cleanup after action completion
            let metaJsonPathForCleanup = metaJsonPath
            let finalizeAfterAction: (ActionExecutor.ChainExecutionResult?) -> Void = { [weak self] result in
                self?.cleanupPendingWatcher(for: metaJsonPathForCleanup)
                self?.cleanupPendingWatcher(for: recordingPath)
                self?.handlePostProcessing(
                    recordingPath: recordingPath,
                    executedActionType: result?.finalActionType,
                    executedAction: result?.finalAction
                )
            }
            
            // FIRST: Check for auto-return (highest priority - overrides everything)
            if globalState.autoReturnEnabled {
                let resolvedCandidate = resolveAutoReturnActionCandidate(
                    metaJson: enhancedMetaJson,
                    frontAppName: frontAppName,
                    frontAppBundleId: frontAppBundleId,
                    frontAppUrl: frontAppUrl
                )
                let autoReturnMetaJson = resolvedCandidate?.metaJson ?? enhancedMetaJson
                let fallbackSwResult = (autoReturnMetaJson["llmResult"] as? String) ?? (autoReturnMetaJson["result"] as? String) ?? ""

                var textToInsert = fallbackSwResult
                var autoReturnInsert: AppConfiguration.Insert? = nil
                var shouldUseDefaultsOnlyPostProcessing = true
                var resolvedAutoReturnActionName: String? = nil

                if let candidate = resolvedCandidate, candidate.type == .insert, let rawInsert = candidate.action as? AppConfiguration.Insert {
                    let resolvedInsert = actionExecutor.resolveInsertForAutoReturn(rawInsert)
                    let processedInsert = socketCommunication.processInsertAction(
                        resolvedInsert.action,
                        metaJson: autoReturnMetaJson,
                        activeInsert: resolvedInsert
                    )

                    let shouldFallbackToSwResult = processedInsert.isAutoPaste
                        || processedInsert.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || processedInsert.text == ".none"

                    if shouldFallbackToSwResult {
                        textToInsert = fallbackSwResult
                        logDebug("[AutoReturn] Resolved insert '\(candidate.name)' produced empty/.none/.autoPaste payload. Falling back to swResult.")
                    } else {
                        textToInsert = processedInsert.text
                    }

                    autoReturnInsert = resolvedInsert
                    shouldUseDefaultsOnlyPostProcessing = false
                    resolvedAutoReturnActionName = candidate.name
                    logDebug("[AutoReturn] Using resolved insert '\(candidate.name)' for one-shot auto-return.")
                } else if let candidate = resolvedCandidate {
                    logDebug("[AutoReturn] Resolved non-insert action '\(candidate.name)' (type: \(candidate.type)); using fallback swResult insert.")
                } else {
                    logDebug("[AutoReturn] No trigger/active insert candidate resolved; using fallback swResult insert.")
                }

                let actionDelay = autoReturnInsert?.actionDelay ?? configManager.config.defaults.actionDelay
                let shouldEsc = autoReturnInsert?.simEsc ?? configManager.config.defaults.simEsc
                let restoreClipboard = autoReturnInsert?.restoreClipboard ?? configManager.config.defaults.restoreClipboard
                let restoreClipboardDelay = autoReturnInsert?.restoreClipboardDelay ?? configManager.config.defaults.restoreClipboardDelay ?? 0.3

                clipboardMonitor.executeInsertWithEnhancedClipboardSync(
                    insertAction: { [weak self] in
                        let success = self?.socketCommunication.applyInsertWithoutEsc(
                            textToInsert,
                            activeInsert: autoReturnInsert,
                            isAutoPaste: false
                        ) ?? false
                        globalState.autoReturnEnabled = false
                        cancelAutoReturnTimeout()
                        return success
                    },
                    actionDelay: actionDelay,
                    shouldEsc: shouldEsc,
                    isAutoPaste: false,
                    recordingPath: recordingPath,
                    metaJson: autoReturnMetaJson,
                    restoreClipboard: restoreClipboard,
                    restoreClipboardDelay: restoreClipboardDelay,
                    onCompletion: { success in
                        if shouldUseDefaultsOnlyPostProcessing {
                            // Non-insert/no-candidate fallback must ignore resolved action settings.
                            let defaultsFallbackInsert = AppConfiguration.Insert(action: "{{swResult}}")
                            let result = ActionExecutor.ChainExecutionResult(
                                success: success,
                                finalActionName: nil,
                                finalActionType: .insert,
                                finalAction: defaultsFallbackInsert,
                                errorMessage: success ? nil : "Auto-return fallback insert execution failed."
                            )
                            finalizeAfterAction(result)
                        } else if let resolvedInsert = autoReturnInsert {
                            let result = ActionExecutor.ChainExecutionResult(
                                success: success,
                                finalActionName: resolvedAutoReturnActionName,
                                finalActionType: .insert,
                                finalAction: resolvedInsert,
                                errorMessage: success ? nil : "Auto-return resolved insert execution failed."
                            )
                            finalizeAfterAction(result)
                        } else {
                            finalizeAfterAction(nil)
                        }
                    }
                )

                logDebug("Applied auto-return with resolved insert behavior and forced one-time return.")

                // Early monitoring will be stopped by ClipboardMonitor when done
                return
            }
            
            // SECOND: Check for scheduled action (same priority as auto-return - overrides everything)
            if let actionName = globalState.scheduledActionName {
                // Find the scheduled action across all action types
                let (actionType, action) = findActionByName(actionName, configManager: configManager)
                
                if let action = action {
                    logDebug("Executing scheduled action: \(actionName) (type: \(actionType))")
                    
                    // Execute the action on the main thread with cleanup callback
                    DispatchQueue.main.async { [weak self] in
                        self?.actionExecutor.executeActionChain(
                            initialAction: action,
                            name: actionName,
                            type: actionType,
                            metaJson: enhancedMetaJson,
                            recordingPath: recordingPath,
                            isTriggeredAction: false
                        ) { chainResult in
                            finalizeAfterAction(chainResult)
                        }
                    }
                    
                    // Reset the scheduled action after using it once
                    globalState.scheduledActionName = nil
                    // Cancel timeout since scheduled action was used
                    cancelScheduledActionTimeout()
                    
                    // Early monitoring will be stopped by ClipboardMonitor when done
                    return
                } else {
                    logWarning("Scheduled action '\(actionName)' not found - cancelling scheduled action")

                    // CRITICAL: Stop early monitoring since no action will be executed
                    clipboardMonitor.stopEarlyMonitoring(for: recordingPath)

                    globalState.scheduledActionName = nil
                    // Cancel timeout since scheduled action was cancelled
                    cancelScheduledActionTimeout()
                    // Clean up pending watchers since no action was executed (both keys for consistency)
                    cleanupPendingWatcher(for: metaJsonPathForCleanup)
                    cleanupPendingWatcher(for: recordingPath)
                }
            }
            
            // THIRD: Evaluate triggers for all actions - this has precedence over active inserts
            let matchedTriggerActions = evaluateMatchedTriggerActions(
                metaJson: enhancedMetaJson,
                frontAppName: frontAppName,
                frontAppBundleId: frontAppBundleId,
                frontAppUrl: frontAppUrl
            )
            
            if !matchedTriggerActions.isEmpty {
                // Execute the first matched trigger action (they're already sorted by name)
                let (action, name, type, strippedResult) = matchedTriggerActions.first!
                
                // Prepare metaJson with updated result if voice trigger matched and stripped result
                let updatedJson = applyTriggerStrippingIfNeeded(
                    metaJson: enhancedMetaJson,
                    action: action,
                    type: type,
                    strippedResult: strippedResult
                )
                
                // Execute the action on the main thread with cleanup callback
                DispatchQueue.main.async { [weak self] in
                    self?.actionExecutor.executeActionChain(
                        initialAction: action,
                        name: name,
                        type: type,
                        metaJson: updatedJson,
                        recordingPath: recordingPath,
                        isTriggeredAction: true
                    ) { chainResult in
                        finalizeAfterAction(chainResult)
                    }
                }

                // Early monitoring will be stopped by ClipboardMonitor when done
                return
            }
            
            // FOURTH: Process active action if there is one (supports all action types)
            if let activeActionName = configManager.config.defaults.activeAction,
               !activeActionName.isEmpty {
                
                // Find the active action across all action types
                let (actionType, action) = findActionByName(activeActionName, configManager: configManager)
                
                if let action = action {
                    logDebug("Processing with active action: \(activeActionName) (type: \(actionType))")
                    DispatchQueue.main.async { [weak self] in
                        self?.actionExecutor.executeActionChain(
                            initialAction: action,
                            name: activeActionName,
                            type: actionType,
                            metaJson: enhancedMetaJson,
                            recordingPath: recordingPath,
                            isTriggeredAction: false
                        ) { chainResult in
                            finalizeAfterAction(chainResult)
                        }
                    }
                    return
                } else {
                    logDebug("Active action '\(activeActionName)' not found, skipping action.")

                    // CRITICAL: Stop early monitoring since no action will be executed
                    clipboardMonitor.stopEarlyMonitoring(for: recordingPath)

                    // Clean up pending watchers since no action was executed (both keys for consistency)
                    cleanupPendingWatcher(for: metaJsonPathForCleanup)
                    cleanupPendingWatcher(for: recordingPath)
                    handlePostProcessing(recordingPath: recordingPath)
                }
            } else {
                logDebug("No active action, skipping action.")

                // CRITICAL: Stop early monitoring since no action will be executed
                clipboardMonitor.stopEarlyMonitoring(for: recordingPath)

                // Clean up pending watchers since no action was executed (both keys for consistency)
                cleanupPendingWatcher(for: metaJsonPathForCleanup)
                cleanupPendingWatcher(for: recordingPath)
                handlePostProcessing(recordingPath: recordingPath)
            }
        } catch {
            logError("Error reading meta.json at \(metaJsonPath): \(error)")
            watchMetaJsonForChanges(metaJsonPath: metaJsonPath, recordingPath: recordingPath)
            // Don't stop early monitoring here as we're still watching for changes
        }
    }

    private func shouldBypassProcessing(for modeName: String?) -> Bool {
        let bypassModes = configManager.config.defaults.bypassModes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !bypassModes.isEmpty else { return false }

        let normalizedMode = modeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedMode.isEmpty else { return false }

        let configuredModes = bypassModes
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !configuredModes.isEmpty else { return false }
        return configuredModes.contains { $0.caseInsensitiveCompare(normalizedMode) == .orderedSame }
    }

    private func handlePostProcessing(recordingPath: String, executedActionType: ActionType? = nil, executedAction: Any? = nil) {
        // Determine the moveTo value with proper precedence (active action takes precedence over default)
        var moveTo: String?
        var actionForMoveTo: (type: ActionType, action: Any)?
        if let explicitType = executedActionType, let explicitAction = executedAction {
            actionForMoveTo = (type: explicitType, action: explicitAction)
        } else if let activeActionName = configManager.config.defaults.activeAction,
                  !activeActionName.isEmpty {
            let (activeType, activeAction) = findActionByName(activeActionName, configManager: configManager)
            if let activeAction = activeAction {
                actionForMoveTo = (type: activeType, action: activeAction)
            }
        }

        if let actionForMoveTo = actionForMoveTo {
            var actionMoveTo: String?
            switch actionForMoveTo.type {
            case .insert:
                actionMoveTo = (actionForMoveTo.action as? AppConfiguration.Insert)?.moveTo
            case .url:
                actionMoveTo = (actionForMoveTo.action as? AppConfiguration.Url)?.moveTo
            case .shortcut:
                actionMoveTo = (actionForMoveTo.action as? AppConfiguration.Shortcut)?.moveTo
            case .shell:
                actionMoveTo = (actionForMoveTo.action as? AppConfiguration.ScriptShell)?.moveTo
            case .appleScript:
                actionMoveTo = (actionForMoveTo.action as? AppConfiguration.ScriptAppleScript)?.moveTo
            }
            if let actionMoveTo = actionMoveTo, !actionMoveTo.isEmpty {
                moveTo = actionMoveTo
            } else {
                moveTo = configManager.config.defaults.moveTo
            }
        } else {
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

    private typealias MatchedTriggerAction = (action: Any, name: String, type: ActionType, strippedResult: String?)

    private struct AutoReturnActionCandidate {
        let action: Any
        let name: String
        let type: ActionType
        let metaJson: [String: Any]
    }

    private func evaluateMatchedTriggerActions(
        metaJson: [String: Any],
        frontAppName: String?,
        frontAppBundleId: String?,
        frontAppUrl: String?
    ) -> [MatchedTriggerAction] {
        let runtimeMuteActive = globalState.isRuntimeMuteTriggersActive()
        let persistentMuteEnabled = configManager.config.defaults.muteTriggers
        let effectiveMuteTriggers = persistentMuteEnabled || runtimeMuteActive
        if effectiveMuteTriggers {
            if persistentMuteEnabled {
                logInfo("[TriggerEval] Skipping trigger evaluation because defaults.muteTriggers is enabled.")
            } else {
                logInfo("[TriggerEval] Skipping trigger evaluation because runtime temporary mute is active.")
            }
            return []
        }

        // Extract result text for trigger evaluation (can be empty, that's fine for triggers)
        let resultText = metaJson["result"] as? String ?? ""

        if isVerboseLogDetailEnabled() {
            logDebug(
                "[TriggerEval] Inputs resultText=\(summarizeForLogs(resultText, maxPreview: 120)) " +
                "resultField=\(summarizeAnyForLogs(metaJson["result"], maxPreview: 120)) " +
                "llmResultField=\(summarizeAnyForLogs(metaJson["llmResult"], maxPreview: 120))"
            )
        } else {
            logDebug(
                "[TriggerEval] Input summary resultTextLen=\(resultText.count) " +
                "hasResult=\(metaJson["result"] != nil) hasLlmResult=\(metaJson["llmResult"] != nil)"
            )
        }

        return triggerEvaluator.evaluateTriggersForAllActions(
            configManager: configManager,
            result: resultText,
            metaJson: metaJson,
            frontAppName: frontAppName,
            frontAppBundleId: frontAppBundleId,
            frontAppUrl: frontAppUrl
        )
    }

    private func resolveAutoReturnActionCandidate(
        metaJson: [String: Any],
        frontAppName: String?,
        frontAppBundleId: String?,
        frontAppUrl: String?
    ) -> AutoReturnActionCandidate? {
        let matchedTriggerActions = evaluateMatchedTriggerActions(
            metaJson: metaJson,
            frontAppName: frontAppName,
            frontAppBundleId: frontAppBundleId,
            frontAppUrl: frontAppUrl
        )
        if let (action, name, type, strippedResult) = matchedTriggerActions.first {
            let updatedMetaJson = applyTriggerStrippingIfNeeded(
                metaJson: metaJson,
                action: action,
                type: type,
                strippedResult: strippedResult
            )
            return AutoReturnActionCandidate(action: action, name: name, type: type, metaJson: updatedMetaJson)
        }

        if let activeActionName = configManager.config.defaults.activeAction, !activeActionName.isEmpty {
            let (actionType, action) = findActionByName(activeActionName, configManager: configManager)
            if let action {
                return AutoReturnActionCandidate(action: action, name: activeActionName, type: actionType, metaJson: metaJson)
            }
            logDebug("[AutoReturn] Active action '\(activeActionName)' not found; using fallback swResult insert.")
        }

        return nil
    }

    private func applyTriggerStrippingIfNeeded(
        metaJson: [String: Any],
        action: Any,
        type: ActionType,
        strippedResult: String?
    ) -> [String: Any] {
        guard let stripped = strippedResult else {
            return metaJson
        }

        var updatedJson = metaJson
        updatedJson["result"] = stripped

        // Also strip the trigger from llmResult if it exists
        // This ensures {{swResult}} doesn't contain the trigger string when using llmResult
        guard let llmResult = metaJson["llmResult"] as? String, !llmResult.isEmpty else {
            return updatedJson
        }

        // Get the triggerVoice pattern from the matched action
        var triggerVoice: String? = nil
        switch type {
        case .insert:
            triggerVoice = (action as? AppConfiguration.Insert)?.triggerVoice
        case .url:
            triggerVoice = (action as? AppConfiguration.Url)?.triggerVoice
        case .shortcut:
            triggerVoice = (action as? AppConfiguration.Shortcut)?.triggerVoice
        case .shell:
            triggerVoice = (action as? AppConfiguration.ScriptShell)?.triggerVoice
        case .appleScript:
            triggerVoice = (action as? AppConfiguration.ScriptAppleScript)?.triggerVoice
        }

        if let triggerVoicePattern = triggerVoice, !triggerVoicePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let strippedLlmResult = stripTriggerFromText(
                text: llmResult,
                triggerVoice: triggerVoicePattern
            )
            if let strippedLlm = strippedLlmResult {
                updatedJson["llmResult"] = strippedLlm
                logDebug("[TriggerAction] Stripped trigger from llmResult: \(summarizeForLogs(llmResult, maxPreview: 120)) -> \(summarizeForLogs(strippedLlm, maxPreview: 120))")
            }
        }

        return updatedJson
    }
    
    /// Provides access to the ClipboardMonitor for CLI commands that need recent clipboard content
    func getClipboardMonitor() -> ClipboardMonitor {
        return clipboardMonitor
    }

    /// Gets the path for the most recent active recording session, if any.
    func getMostRecentActiveRecordingPath() -> String? {
        return clipboardMonitor.getMostRecentActiveRecordingPath()
    }
    
    /// Checks if there are any active recording sessions (pending meta.json files or audio watchers)
    func hasActiveRecordingSessions() -> Bool {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            return !pendingMetaJsonFiles.isEmpty || !pendingAudioFileWatchers.isEmpty
        }

        // Ensure thread-safe access to pending watchers, which are mutated on the watcher's queue
        var hasActive = false
        queue.sync {
            hasActive = !pendingMetaJsonFiles.isEmpty || !pendingAudioFileWatchers.isEmpty
        }
        return hasActive
    }
    
    /// Helper to clean up pendingMetaJsonFiles entry when action completes
    /// Handles both recordingPath and metaJsonPath keys for consistent cleanup
    private func cleanupPendingWatcher(for path: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let hadMetaWatcher = self.pendingMetaJsonFiles[path] != nil
            let hadAudioWatcher = self.pendingAudioFileWatchers[path] != nil
            let previousTotal = self.pendingMetaJsonFiles.count + self.pendingAudioFileWatchers.count

            // Clean up meta.json watcher if it exists for this path
            if let watcher = self.pendingMetaJsonFiles[path] {
                watcher.cancel()
                self.pendingMetaJsonFiles.removeValue(forKey: path)
                logDebug("Cleaned up pending meta watcher for path: \(path)")
            }
            
            // Clean up audio file watcher if it exists for this path
            if let audioWatcher = self.pendingAudioFileWatchers[path] {
                audioWatcher.cancel()
                self.pendingAudioFileWatchers.removeValue(forKey: path)
                self.recordingHadWavFiles.removeValue(forKey: path)
                logDebug("Cleaned up pending audio watcher for path: \(path)")
            }

            if !hadMetaWatcher && !hadAudioWatcher && isVerboseLogDetailEnabled() {
                logDebug("No pending watchers found for path: \(path)")
            }
            
            // Log current state for debugging
            let remainingMetaCount = self.pendingMetaJsonFiles.count
            let remainingAudioCount = self.pendingAudioFileWatchers.count
            let totalRemaining = remainingMetaCount + remainingAudioCount
            
            if totalRemaining > 0 {
                logDebug("Remaining pending watchers: \(totalRemaining) (\(remainingMetaCount) meta, \(remainingAudioCount) audio)")
            } else if previousTotal > 0 {
                logDebug("All pending watchers cleaned up - no active recording sessions")
            }
        }
    }
    
    /// UNIFIED RECOVERY: Handles both crash recovery and cancellation recovery
    /// This prevents orphaned watchers from interfering with new recording sessions
    private func performRecordingRecovery(reason: String, preserveRecording: String? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let metaWatcherCount = self.pendingMetaJsonFiles.count
            let audioWatcherCount = self.pendingAudioFileWatchers.count
            let totalWatchers = metaWatcherCount + audioWatcherCount
            
            if totalWatchers > 0 {
                if let preserveRecording = preserveRecording {
                    logInfo("UNIFIED RECOVERY: Cleaning up old pending watchers while preserving new recording \((preserveRecording as NSString).lastPathComponent) - \(reason)")
                } else {
                    logInfo("UNIFIED RECOVERY: Cleaning up \(totalWatchers) pending watchers (\(metaWatcherCount) meta, \(audioWatcherCount) audio) - \(reason)")
                }
                
                // Track which recording paths had early monitoring stopped to avoid duplicate logs
                var stoppedMonitoringPaths: Set<String> = []
                var cleanedUpCount = 0
                
                // Cancel meta.json watchers
                for (path, watcher) in self.pendingMetaJsonFiles {
                    let recordingPath = self.extractRecordingPath(from: path)
                    
                    // Skip if this watcher belongs to the recording we want to preserve
                    if let preserveRecording = preserveRecording, recordingPath == preserveRecording {
                        logDebug("Preserving meta watcher for new recording: \(path)")
                        continue
                    }
                    
                    watcher.cancel()
                    logDebug("Cancelled pending meta watcher for: \(path)")
                    cleanedUpCount += 1
                    
                    // Only stop early monitoring if we haven't already stopped it for this recording
                    if !stoppedMonitoringPaths.contains(recordingPath) {
                        self.clipboardMonitor.stopEarlyMonitoring(for: recordingPath)
                        stoppedMonitoringPaths.insert(recordingPath)
                    }
                }
                
                // Cancel audio file watchers
                for (path, watcher) in self.pendingAudioFileWatchers {
                    let recordingPath = self.extractRecordingPath(from: path)
                    
                    // Skip if this watcher belongs to the recording we want to preserve
                    if let preserveRecording = preserveRecording, recordingPath == preserveRecording {
                        logDebug("Preserving audio watcher for new recording: \(path)")
                        continue
                    }
                    
                    watcher.cancel()
                    logDebug("Cancelled pending audio watcher for: \(path)")
                    cleanedUpCount += 1
                }
                
                // Remove watchers from dictionaries
                if let preserveRecording = preserveRecording {
                    // Remove only old watchers, preserve new recording's watchers
                    let oldMetaWatchers = self.pendingMetaJsonFiles.filter { (path, _) in
                        self.extractRecordingPath(from: path) != preserveRecording
                    }
                    let oldAudioWatchers = self.pendingAudioFileWatchers.filter { (path, _) in
                        self.extractRecordingPath(from: path) != preserveRecording
                    }
                    
                    for (path, _) in oldMetaWatchers {
                        self.pendingMetaJsonFiles.removeValue(forKey: path)
                    }
                    for (path, _) in oldAudioWatchers {
                        self.pendingAudioFileWatchers.removeValue(forKey: path)
                        self.recordingHadWavFiles.removeValue(forKey: path)
                    }
                    
                    logInfo("UNIFIED RECOVERY: Cleaned up \(cleanedUpCount) old pending watchers, preserved new recording watcher")
                } else {
                    // Clear all pending watchers
                    self.pendingMetaJsonFiles.removeAll()
                    self.pendingAudioFileWatchers.removeAll()
                    self.recordingHadWavFiles.removeAll()
                    
                    logInfo("UNIFIED RECOVERY: All pending watchers cleaned up successfully")
                }
                
                // Cancel auto-return and scheduled actions for all recovery scenarios
                cancelAutoReturn(reason: reason)
                cancelScheduledAction(reason: reason)
                
                // Clean up timeout timers for all recordings (or preserve for new recording)
                if let preserveRecording = preserveRecording {
                    // Cancel timeout timers for old recordings only
                    let recordingPathsToCleanup = self.recordingTimeoutTimers.keys.filter { $0 != preserveRecording }
                    for recordingPath in recordingPathsToCleanup {
                        if let timer = self.recordingTimeoutTimers[recordingPath] {
                            timer.cancel()
                            self.recordingTimeoutTimers.removeValue(forKey: recordingPath)
                        }
                    }
                } else {
                    // Cancel all timeout timers
                    for (_, timer) in self.recordingTimeoutTimers {
                        timer.cancel()
                    }
                    self.recordingTimeoutTimers.removeAll()
                }
                
                // Trigger clipboard cleanup to reset state (same as action execution)
                self.clipboardMonitor.triggerClipboardCleanupForCLI()
                
            } else {
                logDebug("UNIFIED RECOVERY: No pending watchers to clean up")
            }
        }
    }
    
    /// Helper function to extract recording directory path from various watcher path formats
    private func extractRecordingPath(from path: String) -> String {
        // Watcher paths can be:
        // - Recording directory path (e.g., "/path/to/recordings/1234567890")
        // - Meta.json path (e.g., "/path/to/recordings/1234567890/meta.json")
        // - Audio file path (e.g., "/path/to/recordings/1234567890/audio.wav")
        if path.hasSuffix("/meta.json") {
            return String(path.dropLast(10)) // Remove "/meta.json"
        } else if path.contains("/") && path.hasSuffix(".wav") {
            return (path as NSString).deletingLastPathComponent
        } else {
            return path // Already a recording directory path
        }
    }
    
    /// DEPRECATED: Use performRecordingRecovery instead
    /// Legacy wrapper for crash recovery - use performRecordingRecovery(preserveRecording:) instead
    private func cleanupOldPendingWatchers(preservingNewRecording: String, reason: String) {
        performRecordingRecovery(reason: reason, preserveRecording: preservingNewRecording)
    }
    
    /// DEPRECATED: Use performRecordingRecovery instead  
    /// Legacy wrapper for crash recovery - use performRecordingRecovery() instead
    private func cleanupAllPendingWatchers(reason: String) {
        performRecordingRecovery(reason: reason)
    }
    
    // MARK: - Recording Timeout Management
    
    /// Starts a timeout timer for a recording to detect stalled recordings without WAV files
    private func startRecordingTimeout(for recordingPath: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Cancel any existing timer for this recording
            if let existingTimer = self.recordingTimeoutTimers[recordingPath] {
                existingTimer.cancel()
            }
            
            // Create a new timeout timer
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.RECORDING_TIMEOUT_SECONDS)
            
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                
                // Check if recording still doesn't have WAV files and hasn't been processed
                if !self.isAlreadyProcessed(recordingPath: recordingPath) {
                    let hasWavFiles = self.checkForWavFiles(in: recordingPath)
                    if !hasWavFiles {
                        logInfo("TIMEOUT CANCELLATION: Recording \((recordingPath as NSString).lastPathComponent) timed out after \(self.RECORDING_TIMEOUT_SECONDS) seconds without WAV file")
                        
                        // Mark as processed to prevent further processing
                        self.markAsProcessed(recordingPath: recordingPath)
                        
                        // Trigger unified recovery for timeout cancellation
                        self.performRecordingRecovery(reason: "recording timed out after \(self.RECORDING_TIMEOUT_SECONDS) seconds without WAV file - \((recordingPath as NSString).lastPathComponent)")
                    }
                }
                
                // Clean up timer
                self.recordingTimeoutTimers.removeValue(forKey: recordingPath)
            }
            
            timer.resume()
            self.recordingTimeoutTimers[recordingPath] = timer
            
            logDebug("Started \(self.RECORDING_TIMEOUT_SECONDS)-second timeout timer for recording: \((recordingPath as NSString).lastPathComponent)")
        }
    }
    
    /// Cancels the timeout timer for a recording (called when WAV file appears or recording completes)
    private func cancelRecordingTimeout(for recordingPath: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            if let timer = self.recordingTimeoutTimers[recordingPath] {
                timer.cancel()
                self.recordingTimeoutTimers.removeValue(forKey: recordingPath)
                logDebug("Cancelled timeout timer for recording: \((recordingPath as NSString).lastPathComponent)")
            }
        }
    }
    
    /// Strips trigger pattern from text using the same logic as TriggerEvaluator
    /// Returns stripped text if a trigger matches, nil otherwise
    private func stripTriggerFromText(text: String, triggerVoice: String) -> String? {
        // Split triggers by '|' but ignore '|' inside raw regex blocks delimited by '=='
        let triggers = splitVoiceTriggers(triggerVoice)
        
        for trigger in triggers {
            let isException = trigger.hasPrefix("!")
            if isException {
                continue // Don't strip exception patterns
            }
            
            let actualPattern = trigger
            
            // Check if this is a raw regex pattern (wrapped in ==)
            let isRawRegex = actualPattern.hasPrefix("==") && actualPattern.hasSuffix("==")
            let regexPattern: String
            
            if isRawRegex {
                // Don't strip raw regex patterns (same as TriggerEvaluator logic)
                continue
            } else {
                // For prefix matching (current behavior)
                regexPattern = "^(?i)" + NSRegularExpression.escapedPattern(for: actualPattern)
            }
            
            if let regex = try? NSRegularExpression(pattern: regexPattern, options: []) {
                let range = NSRange(location: 0, length: text.utf16.count)
                if let match = regex.firstMatch(in: text, options: [], range: range) {
                    // Strip the trigger from the start, plus any leading punctuation/whitespace after
                    let afterTriggerIdx = text.index(text.startIndex, offsetBy: match.range.length)
                    var stripped = String(text[afterTriggerIdx...])
                    let punctuationSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
                    while let first = stripped.unicodeScalars.first, punctuationSet.contains(first) {
                        stripped.removeFirst()
                    }
                    if let first = stripped.first {
                        stripped.replaceSubrange(stripped.startIndex...stripped.startIndex, with: String(first).uppercased())
                    }
                    return stripped
                }
            }
        }
        
        return nil
    }
    
    /// Splits a triggerVoice string into individual patterns, using '|' as separator,
    /// but ignoring '|' inside raw regex blocks delimited by '==' ... '=='.
    /// Trims whitespace around each part and removes empty parts.
    private func splitVoiceTriggers(_ input: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var i = input.startIndex
        var inRaw = false

        func pushCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
            current.removeAll(keepingCapacity: true)
        }

        while i < input.endIndex {
            if inRaw {
                // Look for closing '=='
                if input[i] == "=" {
                    let next = input.index(after: i)
                    if next < input.endIndex && input[next] == "=" {
                        // Append the closing '==' and exit raw mode
                        current.append("==")
                        i = input.index(after: next)
                        inRaw = false
                        continue
                    }
                }
                // Regular char inside raw
                current.append(input[i])
                i = input.index(after: i)
            } else {
                // Not in raw mode
                if input[i] == "|" {
                    pushCurrent()
                    i = input.index(after: i)
                    continue
                }
                // Enter raw mode on '=='
                if input[i] == "=" {
                    let next = input.index(after: i)
                    if next < input.endIndex && input[next] == "=" {
                        inRaw = true
                        current.append("==")
                        i = input.index(after: next)
                        continue
                    }
                }
                current.append(input[i])
                i = input.index(after: i)
            }
        }
        pushCurrent()
        return parts
    }

} 
