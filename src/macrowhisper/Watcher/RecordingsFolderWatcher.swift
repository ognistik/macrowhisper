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
    private let basePath: String
    private let path: String
    private var source: DispatchSourceFileSystemObject?
    private var basePathSource: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.macrowhisper.recordingswatcher")
    private let queueSpecificKey = DispatchSpecificKey<Void>()
    private var lastKnownSubdirectories: Set<String> = []
    private var pendingMetaJsonFiles: [String: DispatchSourceFileSystemObject] = [:]
    private var pendingAudioFileWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var recordingHadAudioFiles: [String: Bool] = [:] // Track if recording ever had supported audio
    private var recordingTimeoutTimers: [String: DispatchSourceTimer] = [:] // Timeout timers for recordings
    private var integratedS1ResultGraceWorkItems: [String: DispatchWorkItem] = [:]
    private var processedRecordings: Set<String> = []
    private var watcherStartedAt: Date?
    private var lastFolderEventAt: Date?
    private let configManager: ConfigurationManager
    private let historyManager: HistoryManager
    private let socketCommunication: SocketCommunication
    private let triggerEvaluator: TriggerEvaluator
    private let actionExecutor: ActionExecutor
    private let clipboardMonitor: ClipboardMonitor
    private let processedRecordingsFile: String
    private let versionChecker: VersionChecker?
    private let onWatchedFolderInvalidated: ((String) -> Void)?
    private var invalidationReported = false
    
    // Constants
    private let RECORDING_TIMEOUT_SECONDS: Double = 17.0 // Timeout for recordings without supported audio

    init?(basePath: String, configManager: ConfigurationManager, historyManager: HistoryManager, socketCommunication: SocketCommunication, versionChecker: VersionChecker?, onWatchedFolderInvalidated: ((String) -> Void)? = nil) {
        self.basePath = basePath
        self.path = "\(basePath)/recordings"
        self.configManager = configManager
        self.historyManager = historyManager
        self.socketCommunication = socketCommunication
        self.triggerEvaluator = TriggerEvaluator(logger: logger)
        self.clipboardMonitor = ClipboardMonitor(
            logger: logger,
            preRecordingBufferSeconds: configManager.config.defaults.clipboardBuffer,
            clipboardIgnore: configManager.config.defaults.clipboardIgnore ?? "",
            clipboardAttachments: configManager.config.canCaptureClipboardAttachments
        )
        self.actionExecutor = ActionExecutor(logger: logger, socketCommunication: socketCommunication, configManager: configManager, clipboardMonitor: clipboardMonitor)
        
        // Set clipboard monitor reference in socket communication for CLI action cleanup
        socketCommunication.setClipboardMonitor(clipboardMonitor)
        
        self.versionChecker = versionChecker
        self.onWatchedFolderInvalidated = onWatchedFolderInvalidated
        
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

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )

        source?.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = self.source?.data ?? []
            if event.contains(.delete) || event.contains(.rename) || event.contains(.revoke) ||
                !FileManager.default.fileExists(atPath: self.path) {
                self.reportWatchedFolderInvalidation()
                return
            }
            self.handleFolderChangeEvent()
        }

        source?.setCancelHandler {
            close(fileDescriptor)
        }

        source?.resume()

        // Watching the Superwhisper folder itself catches a move of the parent
        // even when the recordings directory's vnode remains open and usable.
        let basePathFileDescriptor = open(basePath, O_EVTONLY)
        if basePathFileDescriptor >= 0 {
            basePathSource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: basePathFileDescriptor,
                eventMask: [.delete, .rename, .revoke],
                queue: queue
            )
            basePathSource?.setEventHandler { [weak self] in
                self?.reportWatchedFolderInvalidation()
            }
            basePathSource?.setCancelHandler {
                close(basePathFileDescriptor)
            }
            basePathSource?.resume()
        } else {
            logWarning("Failed to monitor Superwhisper folder for moves: \(basePath)")
        }

        watcherStartedAt = Date()
        logDebug("Started watching for new recordings in: \(path)")
    }

    func stop() {
        performQueueSynchronized {
            source?.cancel()
            source = nil
            basePathSource?.cancel()
            basePathSource = nil
            watcherStartedAt = nil
            
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
            recordingHadAudioFiles.removeAll()
            
            // Cancel all timeout timers
            for (_, timer) in recordingTimeoutTimers {
                timer.cancel()
            }
            recordingTimeoutTimers.removeAll()

            // Cancel bounded metadata-settle retries.
            for (_, workItem) in integratedS1ResultGraceWorkItems {
                workItem.cancel()
            }
            integratedS1ResultGraceWorkItems.removeAll()

            // Stop all early clipboard monitoring sessions
            let currentSubdirectories = getCurrentSubdirectories()
            for dirName in currentSubdirectories {
                let fullPath = "\(path)/\(dirName)"
                clipboardMonitor.stopEarlyMonitoring(for: fullPath)
            }
            
            // Save processed recordings list
            saveProcessedRecordings()
        }
    }

    private func reportWatchedFolderInvalidation() {
        guard !invalidationReported else { return }
        invalidationReported = true
        logWarning("RecordingsFolderWatcher: Watched folder moved or disappeared from \(basePath)")
        onWatchedFolderInvalidated?(basePath)
    }

    func statusSummary() -> String {
        let snapshot = performQueueSynchronized {
            (
                isArmed: source != nil,
                folderExists: FileManager.default.fileExists(atPath: path),
                startedAt: watcherStartedAt,
                lastEventAt: lastFolderEventAt,
                pendingCount: pendingMetaJsonFiles.count
                    + pendingAudioFileWatchers.count
                    + recordingTimeoutTimers.count
                    + integratedS1ResultGraceWorkItems.count
            )
        }

        guard snapshot.folderExists else {
            return "no (folder missing)"
        }

        guard snapshot.isArmed else {
            return "no (not armed)"
        }

        return "yes (armed, started \(describeStatusAge(snapshot.startedAt)), last event \(describeStatusAge(snapshot.lastEventAt)), pending \(snapshot.pendingCount))"
    }

    /// Ensures watcher-owned mutable state is only touched on the watcher queue.
    private func performQueueSynchronized<T>(_ block: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            return block()
        } else {
            return queue.sync(execute: block)
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

    private var hasPendingRecordingWork: Bool {
        !pendingMetaJsonFiles.isEmpty
            || !pendingAudioFileWatchers.isEmpty
            || !recordingTimeoutTimers.isEmpty
            || !integratedS1ResultGraceWorkItems.isEmpty
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
        let folderEventTime = Date()
        lastFolderEventAt = folderEventTime
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
                if hasPendingRecordingWork {
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
                    if hasPendingRecordingWork, let mostRecentExisting = mostRecentExistingDir, dirName > mostRecentExisting {
                        // A newer recording supersedes any incomplete recording. Recovery is a
                        // synchronous boundary so the replacement starts with fresh context.
                        performRecordingRecovery(
                            reason: "new recording \(dirName) superseded an incomplete recording"
                        )
                    }
                    
                    processNewRecording(atPath: fullPath, detectedAt: folderEventTime)
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
                    recordingHadAudioFiles.removeValue(forKey: fullPath)
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
                
                // A deleted recording is an abnormal termination. Do not preserve
                // root context or restore a clipboard snapshot from that session.
                _ = clipboardMonitor.abortExecutionGroups(
                    containing: [fullPath],
                    reason: "recording folder \(dirName) was deleted during processing"
                )
                
                // Remove from processed recordings list if it exists
                if processedRecordings.contains(fullPath) {
                    processedRecordings.remove(fullPath)
                    saveProcessedRecordings()
                }
            }
        }

        lastKnownSubdirectories = currentSubdirectories
    }
    
    private func processNewRecording(atPath path: String, detectedAt: Date = Date()) {
        // Skip if already processed
        if isAlreadyProcessed(recordingPath: path) {
            logDebug("Skipping already processed recording: \(path)")
            return
        }
        
        // Start early monitoring immediately when the recording folder appears
        // This captures selected text and clipboard context at session start
        clipboardMonitor.startEarlyMonitoring(for: path, sessionStartTime: detectedAt)
        
        // Start monitoring for supported audio file changes to detect cancellation
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
                    if RecordingMetadataSettlePolicy.shouldAwaitIntegratedS1Result(in: metaJson) {
                        return false
                    }
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
    
    /// Sets up monitoring for supported audio file changes to detect recording cancellation
    private func setupAudioFileMonitoring(for recordingPath: String) {
        // Skip if already processed
        if isAlreadyProcessed(recordingPath: recordingPath) {
            return
        }
        
        // Initialize tracking - audio files might not exist yet.
        let initiallyHasAudioFiles = checkForAudioFiles(in: recordingPath)
        recordingHadAudioFiles[recordingPath] = initiallyHasAudioFiles
        if initiallyHasAudioFiles {
            clipboardMonitor.markAudioRecordingStarted(for: recordingPath)
            cancelRecordingTimeout(for: recordingPath)
        }
        
        // Watch the recording directory for supported audio file removal.
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
                self.recordingHadAudioFiles.removeValue(forKey: recordingPath)
                return
            }
            
            // Add a delay to avoid false positives during file rewrites
            // This gives Superwhisper time to finish writing/rewriting the file
            self.queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                
                // Re-check if already processed after delay
                if self.isAlreadyProcessed(recordingPath: recordingPath) {
                    return
                }
                
                // Check current state
                let directoryExists = FileManager.default.fileExists(atPath: recordingPath)
                let hasAudioFiles = directoryExists ? self.checkForAudioFiles(in: recordingPath) : false
                let hadAudioFilesBefore = self.recordingHadAudioFiles[recordingPath] ?? false
                
                // Update tracking if supported audio appeared (recording started).
                if hasAudioFiles && !hadAudioFilesBefore {
                    self.recordingHadAudioFiles[recordingPath] = true
                    logDebug("Audio recording started: .wav or .ogg file detected in \(recordingPath)")
                    self.clipboardMonitor.markAudioRecordingStarted(for: recordingPath)
                    
                    // Cancel timeout timer since supported audio appeared.
                    self.cancelRecordingTimeout(for: recordingPath)
                }
                
                // Only trigger cancellation if:
                // 1. Directory still exists (folder deletion is handled separately)
                // 2. We previously had supported audio (recording was active)
                // 3. No supported audio is present now (it was removed)
                if directoryExists && hadAudioFilesBefore && !hasAudioFiles {
                    // Double-check after another brief delay to be absolutely sure
                    self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self = self else { return }
                        
                        // Final verification
                        let finalCheck = self.checkForAudioFiles(in: recordingPath)
                        if !finalCheck && FileManager.default.fileExists(atPath: recordingPath) {
                            logInfo("CANCELLATION DETECTED: audio file removed from \(recordingPath) - triggering recovery")
                            
                            // Mark as processed to prevent further processing
                            self.markAsProcessed(recordingPath: recordingPath)
                            
                            // Trigger unified recovery for cancellation
                            self.performRecordingRecovery(reason: "recording cancelled - audio file removed from \((recordingPath as NSString).lastPathComponent)")
                            
                            // Clean up this watcher and tracking
                            watcher.cancel()
                            self.pendingAudioFileWatchers.removeValue(forKey: recordingPath)
                            self.recordingHadAudioFiles.removeValue(forKey: recordingPath)
                        } else if finalCheck {
                            logDebug("False alarm: audio file reappeared in \(recordingPath) - continuing monitoring")
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
        logDebug("Started monitoring for .wav or .ogg file changes in: \(recordingPath)")
    }
    
    /// Checks if any nonempty supported audio file exists in the directory.
    private func checkForAudioFiles(in directoryPath: String) -> Bool {
        do {
            return try RecordingAudioFiles.hasUsableAudioFile(in: directoryPath)
        } catch {
            logError("Failed to check directory contents for audio files: \(error)")
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
                self.queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self else { return }
                    
                    // Re-check if file exists after delay
                    if !FileManager.default.fileExists(atPath: metaJsonPath) {
                        // File was truly deleted, not just overwritten
                        watcher.cancel()
                        self.pendingMetaJsonFiles.removeValue(forKey: metaJsonPath)
                        
                        // Treat permanent metadata deletion as cancellation so all watcher,
                        // timer, and session-local clipboard state crosses the same hard
                        // recovery boundary.
                        self.performRecordingRecovery(
                            reason: "meta.json was deleted during processing - \((recordingPath as NSString).lastPathComponent)"
                        )
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
    
    private func processMetaJson(
        metaJsonPath: String,
        recordingPath: String,
        allowEmptyIntegratedS1Result: Bool = false
    ) {
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

            // Meetings are not dictations. Skip as soon as the kind is known,
            // even when Superwhisper has not written a result yet.
            if isMeetingRecordingMetaJson(metaJson) {
                logInfo("Ignoring Superwhisper meeting in \(recordingPath)")
                markAsProcessed(recordingPath: recordingPath)
                cancelRecordingTimeout(for: recordingPath)
                cleanupPendingWatcher(for: recordingPath)
                cleanupPendingWatcher(for: metaJsonPath)
                clipboardMonitor.stopEarlyMonitoring(for: recordingPath)

                // Folder arrival paused one-time timeouts before kind was known.
                // Re-arm them after the meeting's watchers have been removed.
                queue.async { [weak self] in
                    guard let self = self, !self.hasActiveRecordingSessions() else { return }
                    if globalState.autoReturnEnabled {
                        startAutoReturnTimeout()
                    }
                    if globalState.scheduledActionName != nil {
                        startScheduledActionTimeout()
                    }
                }
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
                    if RecordingMetadataSettlePolicy.shouldAwaitIntegratedS1Result(in: metaJson) {
                        if !allowEmptyIntegratedS1Result {
                            scheduleIntegratedS1ResultRecheck(
                                metaJsonPath: metaJsonPath,
                                recordingPath: recordingPath
                            )
                            watchMetaJsonForChanges(metaJsonPath: metaJsonPath, recordingPath: recordingPath)
                            return
                        }

                        logDebug(
                            "[Validation] S1-Language + S1-Voice result remained empty after " +
                            "\(RecordingMetadataSettlePolicy.integratedS1ResultGraceSeconds)s grace; " +
                            "continuing with llmResult."
                        )
                    } else {
                        cancelIntegratedS1ResultRecheck(for: recordingPath)
                    }

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
            let frontApp = resolveFrontAppIdentity()
            globalState.lastDetectedFrontApp = frontApp
            
            // Get front app info for app triggers
            let frontAppName = frontApp?.localizedName
            let frontAppBundleId = frontApp?.bundleIdentifier
            let frontAppPid = frontApp?.processIdentifier
            let shouldResolveFrontAppUrl = shouldResolveFrontAppURLDuringValidation()
            let frontAppUrl = shouldResolveFrontAppUrl
                ? getActiveURL(targetPid: frontAppPid, fallbackBundleId: frontAppBundleId)
                : nil
            if !shouldResolveFrontAppUrl {
                logDebug("[ActiveURL] Skipping eager frontAppUrl lookup for this recording")
            }
            
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
                var autoReturnMetaJson = resolvedCandidate?.metaJson ?? enhancedMetaJson
                autoReturnMetaJson = freezeClipboardContext(
                    in: autoReturnMetaJson,
                    recordingPath: contextRecordingPath,
                    rootAction: resolvedCandidate?.action
                )
                let fallbackSwResult = (autoReturnMetaJson["llmResult"] as? String) ?? (autoReturnMetaJson["result"] as? String) ?? ""

                var textToInsert = fallbackSwResult
                var autoReturnInsert: AppConfiguration.Insert? = nil
                var shouldUseDefaultsOnlyPostProcessing = true
                var resolvedAutoReturnActionName: String? = nil

                if let candidate = resolvedCandidate {
                    autoReturnMetaJson = ensureFrozenFrontAppUrlIfNeeded(
                        metaJson: autoReturnMetaJson,
                        action: candidate.action,
                        name: candidate.name,
                        type: candidate.type,
                        frontAppPid: frontAppPid,
                        frontAppBundleId: frontAppBundleId
                    )
                }

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

                if shouldEnableAttachmentHandoffForExecution(
                    attachmentsEnabled: (autoReturnMetaJson["clipboardAttachments"] as? Bool) ?? false
                ) {
                    // Attachment handoff is an independent clipboard output.
                    // It does not require the insert template to consume the
                    // string-only clipboardContext placeholder.
                    clipboardMonitor.markAttachmentHandoffEligible(
                        for: recordingPath,
                        consumer: .watcher,
                        wholeChainSucceeded: true
                    )
                }

                clipboardMonitor.executeInsertWithEnhancedClipboardSync(
                    insertAction: { [weak self] in
                        let success = self?.socketCommunication.applyInsertWithoutEsc(
                            textToInsert,
                            activeInsert: autoReturnInsert,
                            isAutoPaste: false
                        ) ?? false
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
                    let scheduledMetaJson = ensureFrozenFrontAppUrlIfNeeded(
                        metaJson: enhancedMetaJson,
                        action: action,
                        name: actionName,
                        type: actionType,
                        frontAppPid: frontAppPid,
                        frontAppBundleId: frontAppBundleId
                    )
                    
                    // Execute the action on the main thread with cleanup callback
                    DispatchQueue.main.async { [weak self] in
                        self?.actionExecutor.executeActionChain(
                            initialAction: action,
                            name: actionName,
                            type: actionType,
                            metaJson: scheduledMetaJson,
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
                // Execute the highest-ranked trigger action. TriggerEvaluator applies
                // the same built-in priority used by auto-return and --run-auto.
                let (action, name, type, strippedResult, matchedVoiceTrigger) = matchedTriggerActions.first!
                
                // Prepare metaJson with updated result if voice trigger matched and stripped result
                let updatedJson = applyTriggerStrippingIfNeeded(
                    metaJson: enhancedMetaJson,
                    strippedResult: strippedResult,
                    matchedVoiceTrigger: matchedVoiceTrigger
                )
                // Execute the action on the main thread with cleanup callback
                let triggerMetaJson = ensureFrozenFrontAppUrlIfNeeded(
                    metaJson: updatedJson,
                    action: action,
                    name: name,
                    type: type,
                    frontAppPid: frontAppPid,
                    frontAppBundleId: frontAppBundleId
                )

                DispatchQueue.main.async { [weak self] in
                    self?.actionExecutor.executeActionChain(
                        initialAction: action,
                        name: name,
                        type: type,
                        metaJson: triggerMetaJson,
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
                    let activeActionMetaJson = ensureFrozenFrontAppUrlIfNeeded(
                        metaJson: enhancedMetaJson,
                        action: action,
                        name: activeActionName,
                        type: actionType,
                        frontAppPid: frontAppPid,
                        frontAppBundleId: frontAppBundleId
                    )
                    DispatchQueue.main.async { [weak self] in
                        self?.actionExecutor.executeActionChain(
                            initialAction: action,
                            name: activeActionName,
                            type: actionType,
                            metaJson: activeActionMetaJson,
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

    private func scheduleIntegratedS1ResultRecheck(metaJsonPath: String, recordingPath: String) {
        guard integratedS1ResultGraceWorkItems[recordingPath] == nil else {
            return
        }

        let delay = RecordingMetadataSettlePolicy.integratedS1ResultGraceSeconds
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.integratedS1ResultGraceWorkItems.removeValue(forKey: recordingPath)
            self.processMetaJson(
                metaJsonPath: metaJsonPath,
                recordingPath: recordingPath,
                allowEmptyIntegratedS1Result: true
            )
        }

        integratedS1ResultGraceWorkItems[recordingPath] = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        logDebug(
            "[Validation] S1-Language + S1-Voice llmResult arrived before result; " +
            "waiting up to \(delay)s for trigger source text."
        )
    }

    private func cancelIntegratedS1ResultRecheck(for recordingPath: String) {
        guard let workItem = integratedS1ResultGraceWorkItems.removeValue(forKey: recordingPath) else {
            return
        }
        workItem.cancel()
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

    private func handlePostProcessing(recordingPath: String, executedAction: Any? = nil) {
        // The final executed action takes precedence, followed by the configured active action and defaults.
        var actionForMoveTo: Any?
        if let executedAction {
            actionForMoveTo = executedAction
        } else if let activeActionName = configManager.config.defaults.activeAction,
                  !activeActionName.isEmpty {
            let (_, activeAction) = findActionByName(activeActionName, configManager: configManager)
            if let activeAction = activeAction {
                actionForMoveTo = activeAction
            }
        }

        let moveTo = effectiveMoveTo(
            for: actionForMoveTo,
            defaultValue: configManager.config.defaults.moveTo
        )
        
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

        // Run retention cleanup off the interactive dictation path.
        // It still runs at most once per 24 hours, but no longer competes with first-action responsiveness.
        historyManager.scheduleHistoryCleanup()
        
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

    private func freezeClipboardContext(
        in metaJson: [String: Any],
        recordingPath: String,
        rootAction: Any?
    ) -> [String: Any] {
        let enableStacking = effectiveClipboardStacking(
            for: rootAction,
            defaultValue: configManager.config.defaults.clipboardStacking
        )
        let enableAttachments = effectiveClipboardAttachments(
            for: rootAction,
            defaultValue: configManager.config.defaults.clipboardAttachments
        )
        clipboardMonitor.configureRootClipboardPolicy(
            for: recordingPath,
            attachmentsEnabled: enableAttachments,
            stackingEnabled: enableStacking
        )
        let swResult = (metaJson["llmResult"] as? String) ?? (metaJson["result"] as? String) ?? ""
        let snapshot = clipboardMonitor.freezeClipboardContext(for: recordingPath, swResult: swResult)
        var enhancedMetaJson = metaJson
        enhancedMetaJson["clipboardStacking"] = enableStacking
        enhancedMetaJson["clipboardAttachments"] = enableAttachments
        enhancedMetaJson["clipboardContext"] = snapshot.representations.value(enableStacking: enableStacking)
        enhancedMetaJson[runtimeClipboardContextLockedKey] = true
        return enhancedMetaJson
    }

    private func ensureFrozenFrontAppUrlIfNeeded(
        metaJson: [String: Any],
        action: Any,
        name: String,
        type: ActionType,
        frontAppPid: Int32?,
        frontAppBundleId: String?
    ) -> [String: Any] {
        let existingFrontAppUrl = (metaJson["frontAppUrl"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !existingFrontAppUrl.isEmpty {
            return metaJson
        }

        guard actionChainUsesPlaceholder(initialAction: action, name: name, type: type, key: "frontAppUrl") else {
            return metaJson
        }

        guard let frontAppUrl = getActiveURL(targetPid: frontAppPid, fallbackBundleId: frontAppBundleId),
              !frontAppUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return metaJson
        }

        var enhancedMetaJson = metaJson
        enhancedMetaJson["frontAppUrl"] = frontAppUrl
        return enhancedMetaJson
    }

    private func shouldResolveFrontAppURLDuringValidation() -> Bool {
        if configurationHasAnyURLTriggers() {
            return true
        }

        if let scheduledActionName = globalState.scheduledActionName,
           actionChainUsesPlaceholder(actionName: scheduledActionName, key: "frontAppUrl") {
            return true
        }

        if let activeActionName = configManager.config.defaults.activeAction?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !activeActionName.isEmpty,
           actionChainUsesPlaceholder(actionName: activeActionName, key: "frontAppUrl") {
            return true
        }

        return configuredTriggerRootsUsePlaceholder("frontAppUrl")
    }

    private func configurationHasAnyURLTriggers() -> Bool {
        configuredActions().contains { _, type, action in
            actionHasURLTrigger(action: action, type: type)
        }
    }

    private func configuredTriggerRootsUsePlaceholder(_ key: String) -> Bool {
        for (name, type, action) in configuredActions() {
            guard actionHasAnyTrigger(action: action, type: type) else {
                continue
            }

            if actionChainUsesPlaceholder(
                initialAction: action,
                name: name,
                type: type,
                key: key
            ) {
                return true
            }
        }

        return false
    }

    private func actionChainUsesPlaceholder(actionName: String, key: String) -> Bool {
        let normalizedName = actionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            return false
        }

        let (type, action) = findActionByName(normalizedName, configManager: configManager)
        guard let action else {
            return false
        }

        return actionChainUsesPlaceholder(
            initialAction: action,
            name: normalizedName,
            type: type,
            key: key
        )
    }

    private func configuredActions() -> [(name: String, type: ActionType, action: Any)] {
        var actions: [(name: String, type: ActionType, action: Any)] = []
        actions.append(contentsOf: configManager.config.inserts.map { ($0.key, .insert, $0.value as Any) })
        actions.append(contentsOf: configManager.config.urls.map { ($0.key, .url, $0.value as Any) })
        actions.append(contentsOf: configManager.config.shortcuts.map { ($0.key, .shortcut, $0.value as Any) })
        actions.append(contentsOf: configManager.config.scriptsShell.map { ($0.key, .shell, $0.value as Any) })
        actions.append(contentsOf: configManager.config.scriptsAS.map { ($0.key, .appleScript, $0.value as Any) })
        return actions
    }

    private func actionHasURLTrigger(action: Any, type: ActionType) -> Bool {
        let triggerUrls: String?
        switch type {
        case .insert:
            triggerUrls = (action as? AppConfiguration.Insert)?.triggerUrls
        case .url:
            triggerUrls = (action as? AppConfiguration.Url)?.triggerUrls
        case .shortcut:
            triggerUrls = (action as? AppConfiguration.Shortcut)?.triggerUrls
        case .shell:
            triggerUrls = (action as? AppConfiguration.ScriptShell)?.triggerUrls
        case .appleScript:
            triggerUrls = (action as? AppConfiguration.ScriptAppleScript)?.triggerUrls
        }

        return !(triggerUrls?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func actionHasAnyTrigger(action: Any, type: ActionType) -> Bool {
        let triggerValues: [String?]
        switch type {
        case .insert:
            let typedAction = action as? AppConfiguration.Insert
            triggerValues = [typedAction?.triggerVoice, typedAction?.triggerApps, typedAction?.triggerModes, typedAction?.triggerUrls]
        case .url:
            let typedAction = action as? AppConfiguration.Url
            triggerValues = [typedAction?.triggerVoice, typedAction?.triggerApps, typedAction?.triggerModes, typedAction?.triggerUrls]
        case .shortcut:
            let typedAction = action as? AppConfiguration.Shortcut
            triggerValues = [typedAction?.triggerVoice, typedAction?.triggerApps, typedAction?.triggerModes, typedAction?.triggerUrls]
        case .shell:
            let typedAction = action as? AppConfiguration.ScriptShell
            triggerValues = [typedAction?.triggerVoice, typedAction?.triggerApps, typedAction?.triggerModes, typedAction?.triggerUrls]
        case .appleScript:
            let typedAction = action as? AppConfiguration.ScriptAppleScript
            triggerValues = [typedAction?.triggerVoice, typedAction?.triggerApps, typedAction?.triggerModes, typedAction?.triggerUrls]
        }

        return triggerValues.contains { !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    }

    private func actionChainUsesPlaceholder(
        initialAction: Any,
        name: String,
        type: ActionType,
        key: String
    ) -> Bool {
        var currentName = name
        var currentType = type
        var currentAction: Any = initialAction
        var visited = Set<String>()

        while true {
            if visited.contains(currentName) {
                return false
            }
            visited.insert(currentName)

            if let template = actionTemplate(for: currentAction, type: currentType),
               template.contains("{{"),
               template.contains(key) {
                return true
            }

            guard let nextActionName = rawNextActionName(for: currentAction, type: currentType)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !nextActionName.isEmpty else {
                return false
            }

            let (nextType, nextAction) = findActionByName(nextActionName, configManager: configManager)
            guard let nextAction else {
                return false
            }

            currentName = nextActionName
            currentType = nextType
            currentAction = nextAction
        }
    }

    private func actionTemplate(for action: Any, type: ActionType) -> String? {
        switch type {
        case .insert:
            return (action as? AppConfiguration.Insert)?.action
        case .url:
            return (action as? AppConfiguration.Url)?.action
        case .shortcut:
            return (action as? AppConfiguration.Shortcut)?.action
        case .shell:
            return (action as? AppConfiguration.ScriptShell)?.action
        case .appleScript:
            return (action as? AppConfiguration.ScriptAppleScript)?.action
        }
    }

    private func rawNextActionName(for action: Any, type: ActionType) -> String? {
        switch type {
        case .insert:
            return (action as? AppConfiguration.Insert)?.nextAction
        case .url:
            return (action as? AppConfiguration.Url)?.nextAction
        case .shortcut:
            return (action as? AppConfiguration.Shortcut)?.nextAction
        case .shell:
            return (action as? AppConfiguration.ScriptShell)?.nextAction
        case .appleScript:
            return (action as? AppConfiguration.ScriptAppleScript)?.nextAction
        }
    }

    private typealias MatchedTriggerAction = (
        action: Any,
        name: String,
        type: ActionType,
        strippedResult: String?,
        matchedVoiceTrigger: VoiceTriggerRule?
    )

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
        if let (action, name, type, strippedResult, matchedVoiceTrigger) = matchedTriggerActions.first {
            let updatedMetaJson = applyTriggerStrippingIfNeeded(
                metaJson: metaJson,
                strippedResult: strippedResult,
                matchedVoiceTrigger: matchedVoiceTrigger
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
        strippedResult: String?,
        matchedVoiceTrigger: VoiceTriggerRule?
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

        if let matchedVoiceTrigger,
           let strippedLlm = VoiceTriggerMatcher.strip(llmResult, using: matchedVoiceTrigger) {
            updatedJson["llmResult"] = strippedLlm
            logDebug("[TriggerAction] Stripped matched trigger from llmResult: \(summarizeForLogs(llmResult, maxPreview: 120)) -> \(summarizeForLogs(strippedLlm, maxPreview: 120))")
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

    /// Gets the newest recording path currently tracked by watcher-level pending state.
    /// This is stricter than clipboard-monitor active-session lookup and is used for
    /// features that must bind to the recording that is actively being captured now.
    func getMostRecentPendingRecordingPath() -> String? {
        let resolvePath: () -> String? = {
            let metaPaths = self.pendingMetaJsonFiles.keys.map { path -> String in
                if path.hasSuffix("/meta.json") {
                    return URL(fileURLWithPath: path).deletingLastPathComponent().path
                }
                return path
            }
            let audioPaths = Array(self.pendingAudioFileWatchers.keys)
            let candidates = Array(Set(metaPaths + audioPaths))

            return candidates.max { lhs, rhs in
                let lhsName = (lhs as NSString).lastPathComponent
                let rhsName = (rhs as NSString).lastPathComponent
                if lhsName != rhsName {
                    return lhsName < rhsName
                }
                return lhs < rhs
            }
        }

        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            return resolvePath()
        }

        var resolvedPath: String?
        queue.sync {
            resolvedPath = resolvePath()
        }
        return resolvedPath
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
            self.cancelIntegratedS1ResultRecheck(for: self.extractRecordingPath(from: path))
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
                self.recordingHadAudioFiles.removeValue(forKey: path)
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
    
    /// Handles crash recovery, cancellation, and superseded incomplete recordings.
    ///
    /// Recovery is deliberately synchronous on the watcher queue. A replacement
    /// recording must not begin until old watchers, timers, and clipboard execution
    /// groups have been fully removed.
    private func performRecordingRecovery(reason: String, preserveRecording: String? = nil) {
        performQueueSynchronized {
            let metaWatcherCount = self.pendingMetaJsonFiles.count
            let audioWatcherCount = self.pendingAudioFileWatchers.count
            let recordingTimerCount = self.recordingTimeoutTimers.count
            let integratedS1GraceCount = self.integratedS1ResultGraceWorkItems.count

            var recordingPathsToRecover = Set(
                self.pendingMetaJsonFiles.keys.map(self.extractRecordingPath(from:))
                    + self.pendingAudioFileWatchers.keys.map(self.extractRecordingPath(from:))
                    + Array(self.recordingTimeoutTimers.keys)
                    + Array(self.integratedS1ResultGraceWorkItems.keys)
            )
            if let preserveRecording {
                recordingPathsToRecover.remove(preserveRecording)
            }

            guard !recordingPathsToRecover.isEmpty else {
                logDebug("UNIFIED RECOVERY: No pending recording work to clean up")
                return
            }

            logInfo(
                "UNIFIED RECOVERY: Closing \(recordingPathsToRecover.count) incomplete recording session(s) " +
                "before continuing (meta watchers: \(metaWatcherCount), audio watchers: \(audioWatcherCount), " +
                "recording timers: \(recordingTimerCount), S1 settle retries: \(integratedS1GraceCount)) - \(reason)"
            )

            var cleanedUpWatcherCount = 0

            let metaWatchersToCancel = self.pendingMetaJsonFiles.filter { path, _ in
                recordingPathsToRecover.contains(self.extractRecordingPath(from: path))
            }
            for (path, watcher) in metaWatchersToCancel {
                watcher.cancel()
                self.pendingMetaJsonFiles.removeValue(forKey: path)
                cleanedUpWatcherCount += 1
                logDebug("Cancelled pending meta watcher for: \(path)")
            }

            let audioWatchersToCancel = self.pendingAudioFileWatchers.filter { path, _ in
                recordingPathsToRecover.contains(self.extractRecordingPath(from: path))
            }
            for (path, watcher) in audioWatchersToCancel {
                let recordingPath = self.extractRecordingPath(from: path)
                watcher.cancel()
                self.pendingAudioFileWatchers.removeValue(forKey: path)
                self.recordingHadAudioFiles.removeValue(forKey: recordingPath)
                cleanedUpWatcherCount += 1
                logDebug("Cancelled pending audio watcher for: \(path)")
            }

            for recordingPath in recordingPathsToRecover {
                self.cancelIntegratedS1ResultRecheck(for: recordingPath)
                if let timer = self.recordingTimeoutTimers.removeValue(forKey: recordingPath) {
                    timer.cancel()
                }
                self.recordingHadAudioFiles.removeValue(forKey: recordingPath)
                self.markAsProcessed(recordingPath: recordingPath)
            }

            let abortSummary = self.clipboardMonitor.abortExecutionGroups(
                containing: recordingPathsToRecover,
                reason: reason
            )

            cancelAutoReturn(reason: reason)
            cancelScheduledAction(reason: reason)

            logInfo(
                "UNIFIED RECOVERY: Recovery boundary complete; cleaned \(cleanedUpWatcherCount) watcher(s), " +
                "aborted \(abortSummary.groupCount) clipboard execution group(s), and preserved the current clipboard"
            )
        }
    }
    
    /// Helper function to extract recording directory path from various watcher path formats
    private func extractRecordingPath(from path: String) -> String {
        // Watcher paths can be:
        // - Recording directory path (e.g., "/path/to/recordings/1234567890")
        // - Meta.json path (e.g., "/path/to/recordings/1234567890/meta.json")
        // - Audio file path (e.g., "/path/to/recordings/1234567890/output.ogg")
        if path.hasSuffix("/meta.json") {
            return String(path.dropLast(10)) // Remove "/meta.json"
        } else if path.contains("/") && RecordingAudioFiles.isSupportedAudioPath(path) {
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
    
    /// Starts a timeout timer for a recording to detect stalled recordings without supported audio.
    private func startRecordingTimeout(for recordingPath: String) {
        performQueueSynchronized {
            // Cancel any existing timer for this recording
            if let existingTimer = self.recordingTimeoutTimers[recordingPath] {
                existingTimer.cancel()
            }
            
            // Create a new timeout timer
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.RECORDING_TIMEOUT_SECONDS)
            
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                
                // Check if recording still lacks supported audio and has not been processed.
                if !self.isAlreadyProcessed(recordingPath: recordingPath) {
                    let hasAudioFiles = self.checkForAudioFiles(in: recordingPath)
                    if !hasAudioFiles {
                        logInfo("TIMEOUT CANCELLATION: Recording \((recordingPath as NSString).lastPathComponent) timed out after \(self.RECORDING_TIMEOUT_SECONDS) seconds without audio file")
                        
                        // Mark as processed to prevent further processing
                        self.markAsProcessed(recordingPath: recordingPath)
                        
                        // Trigger unified recovery for timeout cancellation
                        self.performRecordingRecovery(reason: "recording timed out after \(self.RECORDING_TIMEOUT_SECONDS) seconds without audio file - \((recordingPath as NSString).lastPathComponent)")
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
    
    /// Cancels the timeout timer for a recording (called when supported audio appears or recording completes).
    private func cancelRecordingTimeout(for recordingPath: String) {
        performQueueSynchronized {
            if let timer = self.recordingTimeoutTimers[recordingPath] {
                timer.cancel()
                self.recordingTimeoutTimers.removeValue(forKey: recordingPath)
                logDebug("Cancelled timeout timer for recording: \((recordingPath as NSString).lastPathComponent)")
            }
        }
    }


} 
