import Foundation
import Cocoa

/// Configuration constants for clipboard monitoring bounds to prevent memory issues
private let MAX_SESSION_CLIPBOARD_CHANGES = 50  // Maximum clipboard changes per session
private let MAX_GLOBAL_CLIPBOARD_HISTORY = 100  // Maximum global history entries

/// Handles clipboard monitoring and synchronization for insert actions triggered by valid results
/// This solves the timing issue where Superwhisper puts content on clipboard at the same time as insert execution
class ClipboardMonitor {
    private let logger: Logger
    private var originalClipboard: String?
    private let maxWaitTime: TimeInterval = 0.1 // Maximum time to wait for Superwhisper's clipboard change
    private let pollInterval: TimeInterval = 0.01 // 10ms polling interval
    
    // Global clipboard history for pre-recording capture (lightweight, app-lifetime monitoring)
    private var preRecordingBuffer: TimeInterval // Keep N seconds of history (0 disables)
    
    // Clipboard ignore pattern for filtering clipboard content from specific apps
    private var clipboardIgnorePattern: String
    
    /// Dynamic cleanup interval that scales with user's clipboard buffer setting
    private var cleanupInterval: TimeInterval {
        return max(30.0, preRecordingBuffer + 10.0)
    }
    
    private var globalClipboardHistory: [ClipboardChange] = []
    private let globalHistoryQueue = DispatchQueue(label: "ClipboardMonitor.globalHistory", attributes: .concurrent)
    private var globalMonitoringTimer: Timer?
    private var isFirstGlobalCheck = true // Track if this is the first clipboard check
    private var lastSeenClipboardContent: String? // Track last seen content independently of history
    private var lastSeenChangeCount: Int = 0 // Track NSPasteboard changeCount for more reliable detection
    
    // Early monitoring state for recording sessions - made thread-safe with bounds management
    private var earlyMonitoringSessions: [String: EarlyMonitoringSession] = [:]
    private let sessionsQueue = DispatchQueue(label: "ClipboardMonitor.sessions", attributes: .concurrent)
    private var cleanupTimer: Timer? // Periodic cleanup timer to prevent memory growth
    
    private struct EarlyMonitoringSession {
        let userOriginalClipboard: String?
        let startTime: Date
        var clipboardChanges: [ClipboardChange] = []
        var isActive: Bool = true
        let selectedText: String?  // Capture selected text at session start
        var isExecutingAction: Bool = false  // Only log clipboard changes during action execution
        var preRecordingClipboard: String?  // Clipboard content captured from global history before recording (mutable for cleanup)
        var preRecordingClipboardStack: [String]  // All clipboard content captured from global history before recording (mutable for cleanup)
        let startingChangeCount: Int  // NSPasteboard changeCount at session start for better tracking
        var lastSeenChangeCount: Int  // Track last seen changeCount for this session
    }
    
    private struct ClipboardChange {
        let content: String?
        let timestamp: Date
        let changeCount: Int  // NSPasteboard changeCount when this change was detected
    }
    
    init(logger: Logger, preRecordingBufferSeconds: TimeInterval = 5.0, clipboardIgnore: String = "") {
        self.logger = logger
        self.preRecordingBuffer = max(0.0, preRecordingBufferSeconds)
        self.clipboardIgnorePattern = clipboardIgnore
        // Initialize with current pasteboard state
        let pasteboard = NSPasteboard.general
        lastSeenChangeCount = pasteboard.changeCount
        if self.preRecordingBuffer > 0 {
            startGlobalClipboardMonitoring()
        } else {
            logDebug("[ClipboardMonitor] Global clipboard buffer disabled (clipboardBuffer = 0)")
        }
        
        // Start periodic cleanup to prevent memory growth
        startPeriodicCleanup()
    }
    
    deinit {
        stopGlobalClipboardMonitoring()
        stopPeriodicCleanup()
    }
    
    /// Starts early clipboard monitoring when a recording folder appears
    /// This captures the user's original clipboard before anyone (Superwhisper or CLI) modifies it
    /// Also captures selected text at the moment the recording folder appears
    /// Enhanced to also capture clipboard content from approximately 5 seconds before recording
    func startEarlyMonitoring(for recordingPath: String) {
        let pasteboard = NSPasteboard.general
        let userOriginal = pasteboard.string(forType: .string)
        
        // Capture selected text immediately when recording folder appears
        let selectedText = getSelectedText()
        
        // Capture pre-recording clipboard from global history (5 seconds before this recording started)
        let sessionStartTime = Date()
        let preRecordingClipboard = capturePreRecordingClipboard(beforeTime: sessionStartTime)
        let preRecordingClipboardStack = capturePreRecordingClipboardStack(beforeTime: sessionStartTime)
        
        let currentChangeCount = pasteboard.changeCount
        let session = EarlyMonitoringSession(
            userOriginalClipboard: userOriginal,
            startTime: sessionStartTime,
            selectedText: selectedText,
            preRecordingClipboard: preRecordingClipboard,
            preRecordingClipboardStack: preRecordingClipboardStack,
            startingChangeCount: currentChangeCount,
            lastSeenChangeCount: currentChangeCount
        )
        
        sessionsQueue.async(flags: .barrier) { [weak self] in
            self?.earlyMonitoringSessions[recordingPath] = session
        }
        
        logDebug("[ClipboardMonitor] Started early monitoring for \(recordingPath)")
        logDebug("[ClipboardMonitor] Captured user original clipboard content")
        if !selectedText.isEmpty {
            logDebug("[ClipboardMonitor] Captured selected text at recording start")
        }
        
        // Start monitoring clipboard changes (continues until session cleanup)
        monitorClipboardChangesForSession(recordingPath: recordingPath)
    }
    
    /// Marks that action execution is starting (enables clipboard change logging)
    func startActionExecution(for recordingPath: String) {
        sessionsQueue.async(flags: .barrier) { [weak self] in
            self?.earlyMonitoringSessions[recordingPath]?.isExecutingAction = true
        }
    }
    
    /// Marks that action execution is finished (disables clipboard change logging)
    func finishActionExecution(for recordingPath: String) {
        sessionsQueue.async(flags: .barrier) { [weak self] in
            self?.earlyMonitoringSessions[recordingPath]?.isExecutingAction = false
        }
        
        // Trigger cleanup of clipboard changes after 0.5s to prevent contamination
        cleanupClipboardChangesAfterAction(for: recordingPath)
    }
    
    /// Clears clipboard changes after action execution to prevent contamination of clipboardContext
    /// This addresses the issue where fast usage causes previous action results to contaminate the next clipboardContext
    /// Called 0.5s after action execution completes to account for 0.3s clipboard restoration + buffer
    private func cleanupClipboardChangesAfterAction(for recordingPath: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sessionsQueue.async(flags: .barrier) { [weak self] in
                guard let self = self,
                      var session = self.earlyMonitoringSessions[recordingPath],
                      session.isActive else { return }
                
                // FULL RESET: Clear ALL clipboard changes that might contain contaminated content from action execution
                let clearedSessionChanges = session.clipboardChanges.count
                session.clipboardChanges.removeAll()
                
                // FULL RESET: Clear ALL pre-recording clipboard content that might be contaminated from previous actions
                // This prevents previous action results from being used as "pre-recording" content in fast usage scenarios
                let hadPreRecordingClipboard = session.preRecordingClipboard != nil
                let preRecordingStackCount = session.preRecordingClipboardStack.count
                
                session.preRecordingClipboard = nil
                session.preRecordingClipboardStack = []
                
                // Update the session
                self.earlyMonitoringSessions[recordingPath] = session
                
                // FULL RESET: Clear ALL global clipboard history to prevent contamination
                // This ensures that any content that was restored or captured during action execution
                // won't appear in future clipboardContext placeholders
                var cleanedGlobalEntries = 0
                self.globalHistoryQueue.async(flags: .barrier) { [weak self] in
                    guard let self = self else { return }
                    
                    // FULL RESET: Remove ALL global history entries, not just the last 2 seconds
                    let beforeCount = self.globalClipboardHistory.count
                    self.globalClipboardHistory.removeAll()
                    cleanedGlobalEntries = beforeCount
                    
                    // Reset the last seen content to prevent immediate re-capture of restored content
                    self.lastSeenClipboardContent = nil
                    self.lastSeenChangeCount = 0
                    self.isFirstGlobalCheck = true
                    
                    // Log cleanup details on main queue
                    DispatchQueue.main.async {
                        var cleanupMessages: [String] = []
                        if clearedSessionChanges > 0 {
                            cleanupMessages.append("\(clearedSessionChanges) session clipboard changes")
                        }
                        if hadPreRecordingClipboard {
                            cleanupMessages.append("pre-recording clipboard content")
                        }
                        if preRecordingStackCount > 0 {
                            cleanupMessages.append("\(preRecordingStackCount) pre-recording stack items")
                        }
                        if cleanedGlobalEntries > 0 {
                            cleanupMessages.append("\(cleanedGlobalEntries) global history entries (FULL RESET)")
                        }
                        
                        if !cleanupMessages.isEmpty {
                            logDebug("[ClipboardMonitor] FULL RESET: Cleaned up \(cleanupMessages.joined(separator: ", ")) after action execution to prevent clipboardContext contamination")
                        }
                    }
                }
                
                // RESET PERIODIC CLEANUP TIMER: Restart the periodic cleanup timer to start fresh
                // This ensures that the periodic cleanup doesn't interfere with the action execution cleanup
                DispatchQueue.main.async {
                    self.stopPeriodicCleanup()
                    self.startPeriodicCleanup()
                    logDebug("[ClipboardMonitor] Reset periodic cleanup timer after action execution")
                }
            }
        }
    }
    
    /// Stops early monitoring for a recording session (natural cleanup)
    func stopEarlyMonitoring(for recordingPath: String, onCompletion: (() -> Void)? = nil) {
        sessionsQueue.async(flags: .barrier) { [weak self] in
            // Mark session as inactive for eventual cleanup
            // Monitoring will stop naturally when session becomes inactive
            self?.earlyMonitoringSessions[recordingPath]?.isActive = false
            // Remove session after a brief delay to let any in-flight monitoring complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.sessionsQueue.async(flags: .barrier) {
                    self?.earlyMonitoringSessions.removeValue(forKey: recordingPath)
                    // Call completion callback after cleanup is done
                    DispatchQueue.main.async {
                        onCompletion?()
                    }
                }
            }
        }
        logDebug("[ClipboardMonitor] Stopped early monitoring for \(recordingPath)")
    }
    
    /// Gets the selected text that was captured when the recording session started
    /// Returns empty string if no session exists or no text was selected
    func getSessionSelectedText(for recordingPath: String) -> String {
        var selectedText = ""
        sessionsQueue.sync {
            selectedText = earlyMonitoringSessions[recordingPath]?.selectedText ?? ""
        }
        return selectedText
    }
    
    /// Gets the last clipboard content that was captured during the monitoring session
    /// Enhanced to also consider clipboard content from before recording started
    /// Returns empty string if no relevant clipboard changes occurred
    func getSessionClipboardContent(for recordingPath: String, swResult: String) -> String {
        var clipboardContent = ""
        sessionsQueue.sync {
            guard let session = earlyMonitoringSessions[recordingPath] else { return }
            
            // Priority 1: Return the last clipboard change during the session (maintains current behavior)
            if let lastChange = session.clipboardChanges.last {
                clipboardContent = lastChange.content ?? ""
                return
            }
            
            // Priority 2: If no changes during session, use pre-recording clipboard if available
            if let preRecording = session.preRecordingClipboard, !preRecording.isEmpty {
                clipboardContent = preRecording
                logDebug("[ClipboardMonitor] Using pre-recording clipboard content (within buffer window before recording)")
                return
            }
            
            // If we reach here, no clipboard content found (will return empty string)
            logDebug("[ClipboardMonitor] No clipboard content found (no session changes, no pre-recording content within buffer window)")
        }
        return clipboardContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Gets clipboard content with stacking support - returns all clipboard changes when stacking is enabled
    /// - Parameters:
    ///   - recordingPath: The recording path to get session data from
    ///   - swResult: The Superwhisper result to filter out
    ///   - enableStacking: Whether to enable clipboard stacking (from configuration)
    /// - Returns: Formatted clipboard content (single content or XML-tagged stack)
    func getSessionClipboardContentWithStacking(for recordingPath: String, swResult: String, enableStacking: Bool) -> String {
        // If stacking is disabled, use the original behavior
        if !enableStacking {
            return getSessionClipboardContent(for: recordingPath, swResult: swResult)
        }
        
        var allClipboardChanges: [String] = []
        sessionsQueue.sync {
            guard let session = earlyMonitoringSessions[recordingPath] else { return }
            
            // First, add all pre-recording clipboard content if available (these should be the first entries)
            for preRecording in session.preRecordingClipboardStack {
                if !preRecording.isEmpty && preRecording != swResult {
                    allClipboardChanges.append(preRecording)
                }
            }
            if !session.preRecordingClipboardStack.isEmpty {
                logDebug("[ClipboardMonitor] Added \(session.preRecordingClipboardStack.count) pre-recording clipboard items for stacking (within buffer window before recording)")
            }
            
            // Then collect all clipboard changes during the session (excluding swResult)
            for change in session.clipboardChanges {
                if let content = change.content, content != swResult, !content.isEmpty {
                    allClipboardChanges.append(content)
                }
            }
        }
        
        // Format the result based on number of clipboard changes
        if allClipboardChanges.isEmpty {
            logDebug("[ClipboardMonitor] No clipboard content found for stacking")
            return ""
        } else if allClipboardChanges.count == 1 {
            // Single clipboard change - return without XML tags (maintains current behavior)
            logDebug("[ClipboardMonitor] Single clipboard change for stacking - returning without XML tags")
            return allClipboardChanges[0].trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // Multiple clipboard changes - format with XML tags
            var result = ""
            for (index, content) in allClipboardChanges.enumerated() {
                let tagNumber = index + 1
                let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                result += "<clipboard-context-\(tagNumber)>\n\(trimmedContent)\n</clipboard-context-\(tagNumber)>\n\n"
            }
            logDebug("[ClipboardMonitor] Multiple clipboard changes for stacking - formatted with \(allClipboardChanges.count) XML tags")
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    /// Gets the most recent clipboard content from global history for CLI execution context
    /// This is used when --exec-action is called and there's no recording session
    /// Returns empty string if no recent clipboard changes found
    func getRecentClipboardContent() -> String {
        var recentContent = ""
        
        // If buffer disabled, return empty to avoid using global history
        guard preRecordingBuffer > 0 else {
            logDebug("[ClipboardMonitor] Global clipboard buffer disabled - no recent clipboard content available for CLI context")
            return ""
        }

        globalHistoryQueue.sync {
            // Find the most recent clipboard change within the 5-second buffer
            if let mostRecent = globalClipboardHistory.last {
                let timeSinceLastChange = Date().timeIntervalSince(mostRecent.timestamp)
                if timeSinceLastChange <= preRecordingBuffer {
                    recentContent = mostRecent.content ?? ""
                    logDebug("[ClipboardMonitor] Using recent clipboard content from \(String(format: "%.1f", timeSinceLastChange))s ago for CLI context")
                } else {
                    logDebug("[ClipboardMonitor] Last clipboard change was \(String(format: "%.1f", timeSinceLastChange))s ago (older than buffer)")
                }
            } else {
                logDebug("[ClipboardMonitor] No clipboard changes found in global history for CLI context")
            }
        }
        
        return recentContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Gets clipboard content from global history for CLI execution context with stacking support
    /// This is used when --exec-action is called and there's no recording session
    /// - Parameter enableStacking: Whether to enable clipboard stacking (from configuration)
    /// - Returns: Formatted clipboard content (single content or XML-tagged stack)
    func getRecentClipboardContentWithStacking(enableStacking: Bool) -> String {
        // If stacking is disabled, use the original behavior
        if !enableStacking {
            return getRecentClipboardContent()
        }
        
        // If buffer disabled, return empty to avoid using global history
        guard preRecordingBuffer > 0 else {
            logDebug("[ClipboardMonitor] Global clipboard buffer disabled - no recent clipboard content available for CLI stacking")
            return ""
        }

        var allClipboardChanges: [String] = []
        
        globalHistoryQueue.sync {
            // Find all clipboard changes within the 5-second buffer
            let now = Date()
            let cutoffTime = now.addingTimeInterval(-preRecordingBuffer)
            
            let recentChanges = globalClipboardHistory.filter { change in
                change.timestamp >= cutoffTime
            }
            
            // Add all recent changes (excluding empty content)
            for change in recentChanges {
                if let content = change.content, !content.isEmpty {
                    allClipboardChanges.append(content)
                }
            }
        }
        
        // Format the result based on number of clipboard changes
        if allClipboardChanges.isEmpty {
            logDebug("[ClipboardMonitor] No clipboard content found in global history for CLI stacking")
            return ""
        } else if allClipboardChanges.count == 1 {
            // Single clipboard change - return without XML tags (maintains current behavior)
            logDebug("[ClipboardMonitor] Single clipboard change for CLI stacking - returning without XML tags")
            return allClipboardChanges[0].trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // Multiple clipboard changes - format with XML tags
            var result = ""
            for (index, content) in allClipboardChanges.enumerated() {
                let tagNumber = index + 1
                let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                result += "<clipboard-context-\(tagNumber)>\n\(trimmedContent)\n</clipboard-context-\(tagNumber)>\n\n"
            }
            logDebug("[ClipboardMonitor] Multiple clipboard changes for CLI stacking - formatted with \(allClipboardChanges.count) XML tags")
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    /// Captures clipboard content from the global clipboard history (5 seconds before recording started)
    /// This uses the lightweight app-lifetime monitoring to get pre-recording clipboard content
    /// - Parameter beforeTime: The recording session start time to use as reference point
    private func capturePreRecordingClipboard(beforeTime sessionStartTime: Date) -> String? {
        // If buffer disabled, skip pre-recording capture
        guard preRecordingBuffer > 0 else {
            logDebug("[ClipboardMonitor] Pre-recording clipboard buffer disabled - skipping pre-recording capture")
            return nil
        }
        let fiveSecondsBeforeSession = sessionStartTime.addingTimeInterval(-preRecordingBuffer)
        var recentClipboard: String?
        
        globalHistoryQueue.sync {
            // Find clipboard changes that occurred within 5 seconds BEFORE the recording session started
            let preRecordingChanges = globalClipboardHistory.filter { change in
                change.timestamp >= fiveSecondsBeforeSession && change.timestamp < sessionStartTime
            }
            
            // Use the most recent change from within the 5-second window before recording
            if let mostRecent = preRecordingChanges.last {
                recentClipboard = mostRecent.content
                let timeBeforeRecording = sessionStartTime.timeIntervalSince(mostRecent.timestamp)
                logDebug("[ClipboardMonitor] Using pre-recording clipboard change from \(String(format: "%.1f", timeBeforeRecording))s before recording")
            } else {
                logDebug("[ClipboardMonitor] No clipboard changes found within buffer window before recording started")
            }
        }
        
        return recentClipboard
    }
    
    /// Captures all clipboard content from the global clipboard history (N seconds before recording started) for stacking
    /// This uses the lightweight app-lifetime monitoring to get all pre-recording clipboard content within the buffer window
    /// - Parameter beforeTime: The recording session start time to use as reference point
    private func capturePreRecordingClipboardStack(beforeTime sessionStartTime: Date) -> [String] {
        // If buffer disabled, skip pre-recording capture
        guard preRecordingBuffer > 0 else {
            logDebug("[ClipboardMonitor] Pre-recording clipboard buffer disabled - skipping pre-recording stack capture")
            return []
        }
        let bufferStartTime = sessionStartTime.addingTimeInterval(-preRecordingBuffer)
        var clipboardStack: [String] = []
        
        globalHistoryQueue.sync {
            // Find all clipboard changes that occurred within buffer window BEFORE the recording session started
            let preRecordingChanges = globalClipboardHistory.filter { change in
                change.timestamp >= bufferStartTime && change.timestamp < sessionStartTime
            }
            
            // Add all changes from the buffer window (excluding empty content)
            for change in preRecordingChanges {
                if let content = change.content, !content.isEmpty {
                    clipboardStack.append(content)
                }
            }
            
            if !clipboardStack.isEmpty {
                let timeBeforeRecording = sessionStartTime.timeIntervalSince(preRecordingChanges.first?.timestamp ?? sessionStartTime)
                logDebug("[ClipboardMonitor] Using \(clipboardStack.count) pre-recording clipboard changes from up to \(String(format: "%.1f", timeBeforeRecording))s before recording")
            } else {
                logDebug("[ClipboardMonitor] No clipboard changes found within buffer window before recording started for stacking")
            }
        }
        
        return clipboardStack
    }
    
    /// Monitors clipboard changes during early monitoring session
    private func monitorClipboardChangesForSession(recordingPath: String) {
        // Get session data in a single atomic operation to prevent race conditions
        var sessionData: (isActive: Bool, userOriginalClipboard: String?, lastChange: ClipboardChange?, isExecutingAction: Bool, lastSeenChangeCount: Int) = (false, nil, nil, false, 0)
        
        sessionsQueue.sync { [weak self] in
            guard let session = self?.earlyMonitoringSessions[recordingPath] else { return }
            sessionData.isActive = session.isActive
            sessionData.userOriginalClipboard = session.userOriginalClipboard
            sessionData.lastChange = session.clipboardChanges.last
            sessionData.isExecutingAction = session.isExecutingAction
            sessionData.lastSeenChangeCount = session.lastSeenChangeCount
        }
        
        // Exit silently if session is not active - session will be cleaned up naturally
        guard sessionData.isActive else { 
            return 
        }
        
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        
        // Use changeCount for more reliable change detection
        if currentChangeCount != sessionData.lastSeenChangeCount {
            let currentContent = pasteboard.string(forType: .string)
            
            // Check if the frontmost app should be ignored
            let shouldIgnore = self.shouldIgnoreFrontmostApp()
            
            if !shouldIgnore {
                // Track ANY clipboard operation (even if content is identical) as changeCount indicates a copy action occurred
                // This fixes the bug where copying the same content multiple times wasn't being detected
                let change = ClipboardChange(content: currentContent, timestamp: Date(), changeCount: currentChangeCount)
                
                // Always track the change, but only log if we're actively executing an action
                sessionsQueue.async(flags: .barrier) { [weak self] in
                    guard let self = self,
                          let session = self.earlyMonitoringSessions[recordingPath],
                          session.isActive else {
                        return
                    }
                    
                    // Always append the change for restoration logic, with bounds checking
                    if var session = self.earlyMonitoringSessions[recordingPath] {
                        session.clipboardChanges.append(change)
                        
                        // Prevent unbounded growth by removing oldest entries if we exceed the limit
                        if session.clipboardChanges.count > MAX_SESSION_CLIPBOARD_CHANGES {
                            let excessCount = session.clipboardChanges.count - MAX_SESSION_CLIPBOARD_CHANGES
                            session.clipboardChanges.removeFirst(excessCount)
                            logDebug("[ClipboardMonitor] Trimmed \(excessCount) old clipboard changes to stay within bounds")
                        }
                        
                        session.lastSeenChangeCount = currentChangeCount
                        self.earlyMonitoringSessions[recordingPath] = session
                    }
                    
                    // Only log if we're currently executing an action
                    if session.isExecutingAction {
                        logDebug("[ClipboardMonitor] Detected clipboard change during action execution (changeCount: \(currentChangeCount))")
                    }
                }
            } else {
                // Update the session's last seen change count even if we're ignoring this change
                sessionsQueue.async(flags: .barrier) { [weak self] in
                    guard let self = self,
                          var session = self.earlyMonitoringSessions[recordingPath],
                          session.isActive else {
                        return
                    }
                    
                    session.lastSeenChangeCount = currentChangeCount
                    self.earlyMonitoringSessions[recordingPath] = session
                }
            }
        }
        
        // Continue monitoring as long as session exists
        // Session cleanup happens naturally when recording is processed
        var shouldContinue = false
        sessionsQueue.sync { [weak self] in
            shouldContinue = self?.earlyMonitoringSessions[recordingPath]?.isActive ?? false
        }
        
        if shouldContinue {
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
                self?.monitorClipboardChangesForSession(recordingPath: recordingPath)
            }
        }
    }
    
    /// Executes an insert action with enhanced clipboard monitoring that uses early monitoring data
    /// - Parameters:
    ///   - insertAction: The closure that executes the actual insert action
    ///   - actionDelay: The user-configured action delay
    ///   - shouldEsc: Whether ESC should be simulated
    ///   - isAutoPaste: Whether this is an autoPaste action (affects ESC simulation logic)
    ///   - recordingPath: The recording path to use early monitoring data from
    ///   - metaJson: The meta.json data to extract swResult from
    ///   - restoreClipboard: Whether clipboard restoration should be performed
    func executeInsertWithEnhancedClipboardSync(
        insertAction: @escaping () -> Void,
        actionDelay: TimeInterval,
        shouldEsc: Bool,
        isAutoPaste: Bool = false,
        recordingPath: String,
        metaJson: [String: Any],
        restoreClipboard: Bool = true,
        onCompletion: (() -> Void)? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Determine if ESC will actually be simulated
            var escWillBeSimulated = false
            var userIsInInputField = false
            
            if shouldEsc {
                if isAutoPaste {
                    // For autoPaste, check once if user is in input field and cache the result
                    if requestAccessibilityPermission() {
                        userIsInInputField = isInInputField()
                        escWillBeSimulated = userIsInInputField
                    }
                } else {
                    // For regular inserts, always simulate ESC if enabled
                    escWillBeSimulated = true
                }
            }
            
            // Only restore clipboard if ESC will be simulated AND restoreClipboard is enabled
            let shouldRestoreClipboard = escWillBeSimulated && restoreClipboard
            
            // If clipboard restoration is disabled, execute action directly
            if !shouldRestoreClipboard {
                logDebug("[ClipboardMonitor] Clipboard restoration disabled - executing action directly (ESC=\(escWillBeSimulated), restore=\(restoreClipboard))")
                
                // Mark action execution as starting
                self.startActionExecution(for: recordingPath)
                
                // Step 1: Apply actionDelay before ESC simulation and action execution
                if actionDelay > 0 {
                    Thread.sleep(forTimeInterval: actionDelay)
                    logDebug("[ClipboardMonitor] Applied actionDelay: \(actionDelay)s before ESC and action")
                }
                
                // Step 2: Simulate ESC after actionDelay if enabled
                if shouldEsc {
                    if isAutoPaste {
                        // For autoPaste, use the cached input field status
                        if !requestAccessibilityPermission() {
                            logWarning("[ClipboardMonitor] Accessibility permission denied for autoPaste input field check")
                        } else if userIsInInputField {
                            simulateKeyDown(key: 53) // ESC key
                            logDebug("[ClipboardMonitor] ESC key pressed for autoPaste (user is in input field)")
                        } else {
                            logDebug("[ClipboardMonitor] ESC key skipped for autoPaste (user not in input field)")
                        }
                    } else {
                        // For regular inserts, always simulate ESC if enabled
                        simulateKeyDown(key: 53) // ESC key
                        logDebug("[ClipboardMonitor] ESC key pressed for responsiveness")
                    }
                }
                
                // Step 3: Execute the insert action
                insertAction()
                
                // Mark action execution as finished
                self.finishActionExecution(for: recordingPath)
                
                // Stop early monitoring after cleanup has had time to complete (0.5s + small buffer)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.stopEarlyMonitoring(for: recordingPath, onCompletion: onCompletion)
                }
                
                logDebug("[ClipboardMonitor] Action completed without clipboard restoration")
                return
            }
            
            // Get the early monitoring session data with thread safety
            var session: EarlyMonitoringSession?
            self.sessionsQueue.sync {
                session = self.earlyMonitoringSessions[recordingPath]
            }
            
            guard let validSession = session else {
                logDebug("[ClipboardMonitor] No early monitoring session found for \(recordingPath), falling back to basic monitoring")
                // Fallback to original implementation
                self.executeInsertWithClipboardSync(
                    insertAction: insertAction,
                    actionDelay: actionDelay,
                    shouldEsc: shouldEsc,
                    isAutoPaste: isAutoPaste,
                    restoreClipboard: shouldRestoreClipboard,
                    recordingPath: recordingPath,
                    onCompletion: onCompletion
                )
                return
            }
            
            // Extract swResult from metaJson (llmResult takes precedence over result)
            let swResult = (metaJson["llmResult"] as? String) ?? (metaJson["result"] as? String) ?? ""
            
            // Step 1: Mark that action execution is starting (enables relevant clipboard logging)
            self.startActionExecution(for: recordingPath)
            
            // Step 2: Handle clipboard synchronization with Superwhisper BEFORE applying actionDelay
            // This ensures proper timing coordination regardless of user's actionDelay setting
            let pasteboard = NSPasteboard.general
            let currentClipboard = pasteboard.string(forType: .string)
            
            if currentClipboard == swResult {
                // Superwhisper was faster - we already have swResult on clipboard
                logDebug("[ClipboardMonitor] Superwhisper was faster: swResult already on clipboard")
                let clipboardToRestore = self.determineClipboardToRestore(session: validSession, swResult: swResult)
                self.proceedWithActionAndDelay(
                    insertAction: insertAction,
                    clipboardToRestore: clipboardToRestore,
                    superwhisperWasFaster: true,
                    actionDelay: actionDelay,
                    shouldEsc: shouldEsc,
                    isAutoPaste: isAutoPaste,
                    userIsInInputField: userIsInInputField,
                    recordingPath: recordingPath,
                    onCompletion: onCompletion
                )
            } else {
                // Need to wait for Superwhisper up to maxWaitTime, then proceed regardless
                logDebug("[ClipboardMonitor] Waiting for Superwhisper clipboard change (maxWaitTime: \(maxWaitTime)s)")
                self.waitForSuperwhisperThenProceed(
                    insertAction: insertAction,
                    swResult: swResult,
                    session: validSession,
                    actionDelay: actionDelay,
                    shouldEsc: shouldEsc,
                    isAutoPaste: isAutoPaste,
                    userIsInInputField: userIsInInputField,
                    recordingPath: recordingPath,
                    onCompletion: onCompletion
                )
            }
        }
    }
    
    /// Determines what clipboard content should be restored based on session history and current state
    private func determineClipboardToRestore(session: EarlyMonitoringSession, swResult: String) -> String? {
        let pasteboard = NSPasteboard.general
        let currentClipboard = pasteboard.string(forType: .string)
        
        // Case 1: Current clipboard is swResult - Superwhisper was faster
        if currentClipboard == swResult {
            // Find the clipboard content that was there just before swResult
            // Look for the most recent change that is NOT swResult
            for change in session.clipboardChanges.reversed() {
                if change.content != swResult {
                    logDebug("[ClipboardMonitor] Found clipboard to restore from session history")
                    return change.content
                }
            }
            // If no changes found, use the original clipboard from when folder appeared
            logDebug("[ClipboardMonitor] Using original clipboard from folder appearance")
            return session.userOriginalClipboard
        }
        
        // Case 2: Current clipboard is not swResult - we need to preserve current content
        // This could be:
        // - User's original content (no changes yet)
        // - Content user manually copied during the process
        // - Content from another app
        
        // If current content is different from original and there are changes, use current
        if currentClipboard != session.userOriginalClipboard && !session.clipboardChanges.isEmpty {
            // Check if current clipboard is one we've seen in our change history
            let isKnownChange = session.clipboardChanges.contains { $0.content == currentClipboard }
            if isKnownChange {
                logDebug("[ClipboardMonitor] Current clipboard is from tracked changes, will restore")
            } else {
                logDebug("[ClipboardMonitor] Current clipboard is unknown change, will restore")
            }
            return currentClipboard
        }
        
        // Case 3: Current clipboard is same as original, use it
        logDebug("[ClipboardMonitor] Current clipboard same as original, will restore")
        return currentClipboard
    }
    
    /// Wait for Superwhisper to update clipboard or proceed after maxWaitTime, then apply actionDelay
    private func waitForSuperwhisperThenProceed(
        insertAction: @escaping () -> Void,
        swResult: String,
        session: EarlyMonitoringSession,
        actionDelay: TimeInterval,
        shouldEsc: Bool,
        isAutoPaste: Bool,
        userIsInInputField: Bool,
        recordingPath: String,
        onCompletion: (() -> Void)? = nil
    ) {
        let startTime = Date()
        let pasteboard = NSPasteboard.general
        let initialClipboard = pasteboard.string(forType: .string)
        
        // Start polling for Superwhisper's clipboard change
        pollForSuperwhisperChange(
            startTime: startTime,
            initialClipboard: initialClipboard,
            swResult: swResult,
            session: session,
            insertAction: insertAction,
            actionDelay: actionDelay,
            shouldEsc: shouldEsc,
            isAutoPaste: isAutoPaste,
            userIsInInputField: userIsInInputField,
            recordingPath: recordingPath,
            onCompletion: onCompletion
        )
    }
    
    /// Polls for Superwhisper's clipboard change
    private func pollForSuperwhisperChange(
        startTime: Date,
        initialClipboard: String?,
        swResult: String,
        session: EarlyMonitoringSession,
        insertAction: @escaping () -> Void,
        actionDelay: TimeInterval,
        shouldEsc: Bool,
        isAutoPaste: Bool,
        userIsInInputField: Bool,
        recordingPath: String,
        onCompletion: (() -> Void)? = nil
    ) {
        let pasteboard = NSPasteboard.general
        let currentClipboard = pasteboard.string(forType: .string)
        
        // Check if Superwhisper has placed swResult on clipboard
        if currentClipboard == swResult {
            logDebug("[ClipboardMonitor] Detected Superwhisper placed swResult on clipboard during polling")
            
            // Determine clipboard to restore using updated session state
            let clipboardToRestore = self.determineClipboardToRestore(session: session, swResult: swResult)
            
            proceedWithActionAndDelay(
                insertAction: insertAction,
                clipboardToRestore: clipboardToRestore,
                superwhisperWasFaster: false, // Superwhisper was NOT faster initially - we had to wait for it
                actionDelay: actionDelay,
                shouldEsc: shouldEsc,
                isAutoPaste: isAutoPaste,
                userIsInInputField: userIsInInputField,
                recordingPath: recordingPath,
                onCompletion: onCompletion
            )
            return
        }
        
            // Check if we've exceeded maximum wait time
    if Date().timeIntervalSince(startTime) >= maxWaitTime {
        logDebug("[ClipboardMonitor] Max wait time (\(maxWaitTime)s) reached - proceeding without Superwhisper sync")
        
        // FIXED: Use session history to determine what was on clipboard before Superwhisper modified it
        // Don't just use current clipboard, as it might be Superwhisper's result
        let clipboardToRestore = self.determineClipboardToRestore(session: session, swResult: swResult)
        
        proceedWithActionAndDelay(
            insertAction: insertAction,
            clipboardToRestore: clipboardToRestore,
            superwhisperWasFaster: false,
            actionDelay: actionDelay,
            shouldEsc: shouldEsc,
            isAutoPaste: isAutoPaste,
            userIsInInputField: userIsInInputField,
            recordingPath: recordingPath,
            onCompletion: onCompletion
        )
        return
    }
        
        // Continue polling
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            self?.pollForSuperwhisperChange(
                startTime: startTime,
                initialClipboard: initialClipboard,
                swResult: swResult,
                session: session,
                insertAction: insertAction,
                actionDelay: actionDelay,
                shouldEsc: shouldEsc,
                isAutoPaste: isAutoPaste,
                userIsInInputField: userIsInInputField,
                recordingPath: recordingPath,
                onCompletion: onCompletion
            )
        }
    }
    
    /// Proceeds with action execution: applies actionDelay, simulates ESC, executes action, restores clipboard
    private func proceedWithActionAndDelay(
        insertAction: @escaping () -> Void,
        clipboardToRestore: String?,
        superwhisperWasFaster: Bool,
        actionDelay: TimeInterval,
        shouldEsc: Bool,
        isAutoPaste: Bool,
        userIsInInputField: Bool,
        recordingPath: String,
        onCompletion: (() -> Void)? = nil
    ) {
        // Step 1: Apply actionDelay now that clipboard synchronization is complete
        if actionDelay > 0 {
            Thread.sleep(forTimeInterval: actionDelay)
            logDebug("[ClipboardMonitor] Applied actionDelay: \(actionDelay)s after clipboard sync")
        }
        
        // Step 2: Simulate ESC after actionDelay if enabled
        if shouldEsc {
            if isAutoPaste {
                // For autoPaste, use the cached input field status
                if !requestAccessibilityPermission() {
                    logWarning("[ClipboardMonitor] Accessibility permission denied for autoPaste input field check")
                } else if userIsInInputField {
                    simulateKeyDown(key: 53) // ESC key
                    logDebug("[ClipboardMonitor] ESC key pressed for autoPaste (user is in input field)")
                } else {
                    logDebug("[ClipboardMonitor] ESC key skipped for autoPaste (user not in input field)")
                }
            } else {
                // For regular inserts, always simulate ESC if enabled
                simulateKeyDown(key: 53) // ESC key
                logDebug("[ClipboardMonitor] ESC key pressed for responsiveness")
            }
        }
        
        // Step 3: Execute the insert action
        insertAction()
        
        // Step 4: Mark action execution as finished (disables clipboard change logging)
        self.finishActionExecution(for: recordingPath)
        
        // Step 5: Restore the correct clipboard after a minimum wait time for paste to complete
        let restoreDelay = 0.3 // Minimum delay for paste operation to complete
        let completion = onCompletion
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [weak self] in
            self?.restoreCorrectClipboard(clipboardToRestore)
            // Stop early monitoring after cleanup has had time to complete (0.5s + small buffer)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.stopEarlyMonitoring(for: recordingPath, onCompletion: completion)
            }
        }
        
        logDebug("[ClipboardMonitor] Action completed. Superwhisper was faster: \(superwhisperWasFaster)")
    }
    
    /// Restores the clipboard content that was there just before anyone modified it
    private func restoreCorrectClipboard(_ clipboardToRestore: String?) {
        let pasteboard = NSPasteboard.general
        if let contentToRestore = clipboardToRestore {
            pasteboard.clearContents()
            pasteboard.setString(contentToRestore, forType: .string)
            logDebug("[ClipboardMonitor] Restored clipboard content that was there just before modification")
        } else {
            pasteboard.clearContents()
            logDebug("[ClipboardMonitor] Cleared clipboard (no content to restore)")
        }
    }
    
    /// Executes an insert action with clipboard monitoring to handle Superwhisper interference
    /// This is the fallback method when early monitoring is not available
    /// - Parameters:
    ///   - insertAction: The closure that executes the actual insert action
    ///   - actionDelay: The user-configured action delay
    ///   - shouldEsc: Whether ESC should be simulated for responsiveness
    ///   - isAutoPaste: Whether this is an autoPaste action (affects ESC simulation logic)
    ///   - restoreClipboard: Whether clipboard restoration should be performed
    func executeInsertWithClipboardSync(
        insertAction: @escaping () -> Void,
        actionDelay: TimeInterval,
        shouldEsc: Bool,
        isAutoPaste: Bool = false,
        restoreClipboard: Bool = true,
        recordingPath: String,
        onCompletion: (() -> Void)? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Determine if ESC will actually be simulated
            var escWillBeSimulated = false
            var userIsInInputField = false
            
            if shouldEsc {
                if isAutoPaste {
                    // For autoPaste, check once if user is in input field and cache the result
                    if requestAccessibilityPermission() {
                        userIsInInputField = isInInputField()
                        escWillBeSimulated = userIsInInputField
                    }
                } else {
                    // For regular inserts, always simulate ESC if enabled
                    escWillBeSimulated = true
                }
            }
            
            // Only restore clipboard if ESC will be simulated AND restoreClipboard is enabled
            let shouldRestoreClipboard = escWillBeSimulated && restoreClipboard
            
            // If clipboard restoration is disabled, execute action directly
            if !shouldRestoreClipboard {
                logDebug("[ClipboardMonitor] Clipboard restoration disabled - executing action directly (fallback, ESC=\(escWillBeSimulated), restore=\(restoreClipboard))")
                
                // Mark action execution as starting
                self.startActionExecution(for: recordingPath)
                
                // Step 1: Apply actionDelay before ESC simulation and action execution
                if actionDelay > 0 {
                    Thread.sleep(forTimeInterval: actionDelay)
                    logDebug("[ClipboardMonitor] Applied actionDelay: \(actionDelay)s before ESC and action (fallback)")
                }
                
                // Step 2: Simulate ESC after actionDelay if enabled
                if shouldEsc {
                    if isAutoPaste {
                        // For autoPaste, use the cached input field status
                        if !requestAccessibilityPermission() {
                            logWarning("[ClipboardMonitor] Accessibility permission denied for autoPaste input field check")
                        } else if userIsInInputField {
                            simulateKeyDown(key: 53) // ESC key
                            logDebug("[ClipboardMonitor] ESC key pressed for autoPaste (user is in input field)")
                        } else {
                            logDebug("[ClipboardMonitor] ESC key skipped for autoPaste (user not in input field)")
                        }
                    } else {
                        // For regular inserts, always simulate ESC if enabled
                        simulateKeyDown(key: 53) // ESC key
                        logDebug("[ClipboardMonitor] ESC key pressed for responsiveness")
                    }
                }
                
                // Step 3: Execute the insert action
                insertAction()
                
                // Mark action execution as finished
                self.finishActionExecution(for: recordingPath)
                
                // Stop early monitoring after cleanup has had time to complete (0.5s + small buffer)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.stopEarlyMonitoring(for: recordingPath, onCompletion: onCompletion)
                }
                
                logDebug("[ClipboardMonitor] Action completed without clipboard restoration (fallback)")
                return
            }
            
            // Step 1: Save current clipboard content
            let pasteboard = NSPasteboard.general
            self.originalClipboard = pasteboard.string(forType: .string)
            
            // Step 2: Mark action execution as starting (enables relevant clipboard logging)
            self.startActionExecution(for: recordingPath)
            
            // Step 3: Monitor for Superwhisper's clipboard change BEFORE applying actionDelay
            logDebug("[ClipboardMonitor] Fallback: monitoring clipboard changes (maxWaitTime: \(maxWaitTime)s)")
            self.monitorClipboardChanges { [weak self] in
                guard let self = self else { return }
                
                // Step 4: Apply actionDelay after clipboard synchronization is complete
                if actionDelay > 0 {
                    Thread.sleep(forTimeInterval: actionDelay)
                    logDebug("[ClipboardMonitor] Applied actionDelay: \(actionDelay)s after clipboard sync (fallback)")
                }
                
                // Step 5: Simulate ESC after actionDelay if enabled
                if shouldEsc {
                    if isAutoPaste {
                        // For autoPaste, use the cached input field status
                        if !requestAccessibilityPermission() {
                            logWarning("[ClipboardMonitor] Accessibility permission denied for autoPaste input field check")
                        } else if userIsInInputField {
                            simulateKeyDown(key: 53) // ESC key
                            logDebug("[ClipboardMonitor] ESC key pressed for autoPaste (user is in input field)")
                        } else {
                            logDebug("[ClipboardMonitor] ESC key skipped for autoPaste (user not in input field)")
                        }
                    } else {
                        // For regular inserts, always simulate ESC if enabled
                        simulateKeyDown(key: 53) // ESC key
                        logDebug("[ClipboardMonitor] ESC key pressed for responsiveness")
                    }
                }
                
                // Step 6: Execute the insert action
                insertAction()
                
                // Step 7: Mark action execution as finished
                self.finishActionExecution(for: recordingPath)
                
                // Step 8: Restore original clipboard after a minimum wait time for paste to complete
                let restoreDelay = 0.3 // Minimum delay for paste operation to complete
                let completion = onCompletion
                DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [weak self] in
                    self?.restoreOriginalClipboard()
                    // Stop early monitoring after cleanup has had time to complete (0.5s + small buffer)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.stopEarlyMonitoring(for: recordingPath, onCompletion: completion)
                    }
                }
            }
        }
    }
    
    /// Monitors clipboard for changes from Superwhisper
    private func monitorClipboardChanges(completion: @escaping () -> Void) {
        let startTime = Date()
        let pasteboard = NSPasteboard.general
        let initialClipboard = pasteboard.string(forType: .string)
        
        // Start polling for clipboard changes
        pollClipboard(
            startTime: startTime,
            initialClipboard: initialClipboard,
            completion: completion
        )
    }
    
    /// Polls clipboard at regular intervals to detect changes
    private func pollClipboard(
        startTime: Date,
        initialClipboard: String?,
        completion: @escaping () -> Void
    ) {
        let pasteboard = NSPasteboard.general
        let currentClipboard = pasteboard.string(forType: .string)
        
        // Check if clipboard has changed (Superwhisper has updated it)
        if currentClipboard != initialClipboard {
            logDebug("[ClipboardMonitor] Detected clipboard change from Superwhisper")
            completion()
            return
        }
        
        // Check if we've exceeded maximum wait time
        if Date().timeIntervalSince(startTime) >= maxWaitTime {
            logDebug("[ClipboardMonitor] Max wait time reached, proceeding with insert action")
            completion()
            return
        }
        
        // Continue polling
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            self?.pollClipboard(
                startTime: startTime,
                initialClipboard: initialClipboard,
                completion: completion
            )
        }
    }
    
    /// Restores the original clipboard content (fallback method)
    private func restoreOriginalClipboard() {
        let pasteboard = NSPasteboard.general
        if let original = originalClipboard {
            pasteboard.clearContents()
            pasteboard.setString(original, forType: .string)
            logDebug("[ClipboardMonitor] Restored original clipboard content")
        } else {
            pasteboard.clearContents()
            logDebug("[ClipboardMonitor] Cleared clipboard (no original content)")
        }
        originalClipboard = nil
    }
    
    /// Executes a non-insert action with clipboard restoration if ESC is simulated
    /// This handles URL, Shortcut, Shell Script, and AppleScript actions
    /// - Parameters:
    ///   - action: The closure that executes the actual action
    ///   - shouldEsc: Whether ESC should be simulated
    ///   - actionDelay: The action delay to apply
    ///   - recordingPath: The recording path for early monitoring data
    ///   - metaJson: The meta.json data
    ///   - restoreClipboard: Whether clipboard restoration is enabled in settings
    func executeNonInsertActionWithClipboardRestore(
        action: @escaping () -> Void,
        shouldEsc: Bool,
        actionDelay: TimeInterval,
        recordingPath: String,
        metaJson: [String: Any],
        restoreClipboard: Bool = true,
        onCompletion: (() -> Void)? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Only restore clipboard if ESC will be simulated AND restoreClipboard is enabled
            let shouldRestoreClipboard = shouldEsc && restoreClipboard
            
            if !shouldRestoreClipboard {
                logDebug("[ClipboardMonitor] Non-insert action: No clipboard restoration (ESC=\(shouldEsc), restore=\(restoreClipboard))")
                
                // Mark action execution as starting
                self.startActionExecution(for: recordingPath)
                
                // Apply action delay before ESC and action execution
                if actionDelay > 0 {
                    Thread.sleep(forTimeInterval: actionDelay)
                    logDebug("[ClipboardMonitor] Applied actionDelay: \(actionDelay)s before ESC and action (non-insert)")
                }
                
                // Simulate ESC after actionDelay if requested
                if shouldEsc {
                    simulateKeyDown(key: 53) // ESC key
                    logDebug("[ClipboardMonitor] ESC key pressed for non-insert action")
                }
                
                // Execute action directly without clipboard monitoring
                action()
                
                // Mark action execution as finished
                self.finishActionExecution(for: recordingPath)
                
                // Stop early monitoring after cleanup has had time to complete (0.5s + small buffer)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.stopEarlyMonitoring(for: recordingPath, onCompletion: onCompletion)
                }
                return
            }
            
            // Get the early monitoring session data with thread safety
            var session: EarlyMonitoringSession?
            self.sessionsQueue.sync {
                session = self.earlyMonitoringSessions[recordingPath]
            }
            
            guard let validSession = session else {
                logDebug("[ClipboardMonitor] No early monitoring session found for non-insert action, using simple restore")
                // Fallback to simple clipboard save/restore
                self.executeNonInsertActionWithSimpleRestore(
                    action: action,
                    shouldEsc: shouldEsc,
                    actionDelay: actionDelay,
                    recordingPath: recordingPath,
                    onCompletion: onCompletion
                )
                return
            }
            
            // Extract swResult from metaJson (llmResult takes precedence over result)
            let swResult = (metaJson["llmResult"] as? String) ?? (metaJson["result"] as? String) ?? ""
            
            // Determine what clipboard content should be restored
            let clipboardToRestore = self.determineClipboardToRestore(session: validSession, swResult: swResult)
            
            logDebug("[ClipboardMonitor] Non-insert action with clipboard restoration")
            
            // Mark action execution as starting
            self.startActionExecution(for: recordingPath)
            
            // Apply action delay before ESC and action execution
            if actionDelay > 0 {
                Thread.sleep(forTimeInterval: actionDelay)
                logDebug("[ClipboardMonitor] Applied actionDelay: \(actionDelay)s before ESC and action (non-insert with restore)")
            }
            
            // Simulate ESC after actionDelay if requested
            if shouldEsc {
                simulateKeyDown(key: 53) // ESC key
                logDebug("[ClipboardMonitor] ESC key pressed for non-insert action with restore")
            }
            
            // Execute the action
            action()
            
            // Mark action execution as finished
            self.finishActionExecution(for: recordingPath)
            
            // Restore clipboard after a brief delay to let any action complete
            let restoreDelay = 0.3
            let completion = onCompletion
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [weak self] in
                self?.restoreCorrectClipboard(clipboardToRestore)
                // Stop early monitoring after cleanup has had time to complete (0.5s + small buffer)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.stopEarlyMonitoring(for: recordingPath, onCompletion: completion)
                }
            }
        }
    }
    
    /// Simple clipboard save/restore for non-insert actions when early monitoring is not available
    private func executeNonInsertActionWithSimpleRestore(
        action: @escaping () -> Void,
        shouldEsc: Bool,
        actionDelay: TimeInterval,
        recordingPath: String,
        onCompletion: (() -> Void)? = nil
    ) {
        // Save current clipboard
        let pasteboard = NSPasteboard.general
        let originalClipboard = pasteboard.string(forType: .string)
        
        logDebug("[ClipboardMonitor] Non-insert action with simple clipboard restore")
        
        // Mark action execution as starting
        self.startActionExecution(for: recordingPath)
        
        // Apply action delay before ESC and action execution
        if actionDelay > 0 {
            Thread.sleep(forTimeInterval: actionDelay)
            logDebug("[ClipboardMonitor] Applied actionDelay: \(actionDelay)s before ESC and action (simple restore)")
        }
        
        // Simulate ESC after actionDelay if requested
        if shouldEsc {
            simulateKeyDown(key: 53) // ESC key
            logDebug("[ClipboardMonitor] ESC key pressed for non-insert action (simple restore)")
        }
        
        // Execute the action
        action()
        
        // Mark action execution as finished
        self.finishActionExecution(for: recordingPath)
        
        // Restore clipboard after a brief delay
        let restoreDelay = 0.3
        let completion = onCompletion
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [weak self] in
            if let original = originalClipboard {
                pasteboard.clearContents()
                pasteboard.setString(original, forType: .string)
                logDebug("[ClipboardMonitor] Restored original clipboard for non-insert action")
            } else {
                pasteboard.clearContents()
                logDebug("[ClipboardMonitor] Cleared clipboard for non-insert action (no original content)")
            }
            // Stop early monitoring after cleanup has had time to complete (0.5s + small buffer)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.stopEarlyMonitoring(for: recordingPath, onCompletion: completion)
            }
        }
    }
    
    // MARK: - Global Clipboard Monitoring (Lightweight App-Lifetime)
    
    /// Starts lightweight global clipboard monitoring to maintain 5-second rolling buffer
    /// This ensures pre-recording clipboard content is available even for the first recording session
    private func startGlobalClipboardMonitoring() {
        // Prevent multiple timers from being created
        guard globalMonitoringTimer == nil else {
            logDebug("[ClipboardMonitor] Global monitoring already running, skipping start")
            return
        }
        
        logDebug("[ClipboardMonitor] Starting lightweight global clipboard monitoring")
        
        // Initialize with empty history - we only want to track actual clipboard CHANGES
        // Don't timestamp existing clipboard content as "new" since we don't know when it was actually copied
        globalHistoryQueue.async(flags: .barrier) { [weak self] in
            self?.globalClipboardHistory = []
            self?.lastSeenClipboardContent = nil
            self?.lastSeenChangeCount = 0
            self?.isFirstGlobalCheck = true
        }
        
        // Start periodic monitoring with 0.5s interval (lightweight)
        DispatchQueue.main.async { [weak self] in
            self?.globalMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.checkGlobalClipboardChange()
            }
            if let timer = self?.globalMonitoringTimer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }
    
    /// Stops global clipboard monitoring
    private func stopGlobalClipboardMonitoring() {
        globalMonitoringTimer?.invalidate()
        globalMonitoringTimer = nil
        
        globalHistoryQueue.async(flags: .barrier) { [weak self] in
            self?.globalClipboardHistory.removeAll()
            self?.lastSeenClipboardContent = nil
            self?.lastSeenChangeCount = 0
            self?.isFirstGlobalCheck = true
        }
        
        logDebug("[ClipboardMonitor] Stopped global clipboard monitoring")
    }

    // MARK: - Public Configuration Update
    /// Updates the pre-recording clipboard buffer window (in seconds). 0 disables global buffer.
    func updateClipboardBuffer(seconds: TimeInterval) {
        let newValue = max(0.0, seconds)
        if newValue == preRecordingBuffer { return }

        preRecordingBuffer = newValue
        if newValue == 0 {
            stopGlobalClipboardMonitoring()
            logInfo("[ClipboardMonitor] Disabled global clipboard buffer (clipboardBuffer = 0)")
        } else {
            // Restart monitoring to apply new window; history is lightweight and will refill
            stopGlobalClipboardMonitoring()
            startGlobalClipboardMonitoring()
            logInfo(String(format: "[ClipboardMonitor] Updated global clipboard buffer to %.2fs", newValue))
        }
        
        // Restart cleanup timer with new interval based on updated buffer setting
        stopPeriodicCleanup()
        startPeriodicCleanup()
    }
    
    /// Updates the clipboard ignore pattern for filtering clipboard content from specific apps
    /// - Parameter pattern: Regex pattern matching app names or bundle IDs (pipe-separated)
    func updateClipboardIgnore(pattern: String) {
        clipboardIgnorePattern = pattern
        if pattern.isEmpty {
            logInfo("[ClipboardMonitor] Cleared clipboard ignore pattern - all apps will be monitored")
        } else {
            logInfo("[ClipboardMonitor] Updated clipboard ignore pattern: '\(pattern)'")
        }
    }
    
    /// Checks if the frontmost application should be ignored based on clipboardIgnore pattern
    /// Returns true if the app matches the ignore pattern, false otherwise
    private func shouldIgnoreFrontmostApp() -> Bool {
        // If no ignore pattern is set, don't ignore any apps
        guard !clipboardIgnorePattern.isEmpty else { return false }
        
        // Get the frontmost application
        let frontApp: NSRunningApplication?
        if Thread.isMainThread {
            frontApp = NSWorkspace.shared.frontmostApplication
        } else {
            var app: NSRunningApplication?
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                app = NSWorkspace.shared.frontmostApplication
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 0.1)
            frontApp = app
        }
        
        guard let app = frontApp else { return false }
        
        // Get app name and bundle ID for matching
        let appName = app.localizedName ?? ""
        let bundleId = app.bundleIdentifier ?? ""
        
        // Try to match against the ignore pattern (supports regex with pipe-separated values)
        do {
            let regex = try NSRegularExpression(pattern: clipboardIgnorePattern, options: [.caseInsensitive])
            
            // Check if app name matches
            let nameRange = NSRange(appName.startIndex..., in: appName)
            if regex.firstMatch(in: appName, options: [], range: nameRange) != nil {
                logDebug("[ClipboardMonitor] Ignoring clipboard change from app '\(appName)' (matched by name)")
                return true
            }
            
            // Check if bundle ID matches
            let bundleRange = NSRange(bundleId.startIndex..., in: bundleId)
            if regex.firstMatch(in: bundleId, options: [], range: bundleRange) != nil {
                logDebug("[ClipboardMonitor] Ignoring clipboard change from app '\(appName)' (\(bundleId)) (matched by bundle ID)")
                return true
            }
        } catch {
            logError("[ClipboardMonitor] Invalid clipboardIgnore regex pattern '\(clipboardIgnorePattern)': \(error.localizedDescription)")
        }
        
        return false
    }
    
    /// Triggers clipboard cleanup for CLI actions that bypass the normal action execution flow
    /// This ensures CLI actions also get the full reset treatment to prevent contamination
    func triggerClipboardCleanupForCLI() {
        logDebug("[ClipboardMonitor] Triggering clipboard cleanup for CLI action execution")
        
        // Perform the same cleanup as finishActionExecution but without session-specific data
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            
            // FULL RESET: Clear ALL global clipboard history to prevent contamination
            // This ensures that any content that was captured during CLI action execution
            // won't appear in future clipboardContext placeholders
            var cleanedGlobalEntries = 0
            self.globalHistoryQueue.async(flags: .barrier) { [weak self] in
                guard let self = self else { return }
                
                // FULL RESET: Remove ALL global history entries, not just the last 2 seconds
                let beforeCount = self.globalClipboardHistory.count
                self.globalClipboardHistory.removeAll()
                cleanedGlobalEntries = beforeCount
                
                // Reset the last seen content to prevent immediate re-capture of restored content
                self.lastSeenClipboardContent = nil
                self.lastSeenChangeCount = 0
                self.isFirstGlobalCheck = true
                
                // Log cleanup details on main queue
                DispatchQueue.main.async {
                    if cleanedGlobalEntries > 0 {
                        logDebug("[ClipboardMonitor] CLI FULL RESET: Cleaned up \(cleanedGlobalEntries) global history entries after CLI action execution to prevent clipboardContext contamination")
                    }
                }
            }
            
            // RESET PERIODIC CLEANUP TIMER: Restart the periodic cleanup timer to start fresh
            // This ensures the periodic cleanup doesn't interfere with the CLI action execution cleanup
            DispatchQueue.main.async {
                self.stopPeriodicCleanup()
                self.startPeriodicCleanup()
                logDebug("[ClipboardMonitor] Reset periodic cleanup timer after CLI action execution")
            }
        }
    }
    
    /// Checks for clipboard changes and maintains the lightweight rolling buffer
    private func checkGlobalClipboardChange() {
        let pasteboard = NSPasteboard.general
        let currentChangeCount = pasteboard.changeCount
        let currentClipboard = pasteboard.string(forType: .string)
        let now = Date()
        
        globalHistoryQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            // On first check, just record what's there without treating it as a "change"
            if self.isFirstGlobalCheck {
                self.isFirstGlobalCheck = false
                self.lastSeenClipboardContent = currentClipboard
                self.lastSeenChangeCount = currentChangeCount
                logDebug("[ClipboardMonitor] Global monitoring initialized - recording baseline clipboard content (changeCount: \(currentChangeCount))")
                return
            }
            
            // Use changeCount for more reliable change detection - track ANY clipboard operation
            if currentChangeCount != self.lastSeenChangeCount {
                // Check if the frontmost app should be ignored
                let shouldIgnore = self.shouldIgnoreFrontmostApp()
                
                if !shouldIgnore {
                    // Track ANY clipboard operation (even if content is identical) as changeCount indicates a copy action occurred
                    // This fixes the bug where copying the same content multiple times wasn't being detected
                    let change = ClipboardChange(content: currentClipboard, timestamp: now, changeCount: currentChangeCount)
                    self.globalClipboardHistory.append(change)
                    
                    // Prevent unbounded growth by removing oldest entries if we exceed the limit
                    if self.globalClipboardHistory.count > MAX_GLOBAL_CLIPBOARD_HISTORY {
                        let excessCount = self.globalClipboardHistory.count - MAX_GLOBAL_CLIPBOARD_HISTORY
                        self.globalClipboardHistory.removeFirst(excessCount)
                        logDebug("[ClipboardMonitor] Trimmed \(excessCount) old global history entries to stay within bounds")
                    }
                    
                    logDebug("[ClipboardMonitor] Global monitoring detected clipboard operation (changeCount: \(currentChangeCount))")
                    logDebug("[ClipboardMonitor] Global history size: \(self.globalClipboardHistory.count)/\(MAX_GLOBAL_CLIPBOARD_HISTORY)")
                }
                
                // Always update last seen values even if we're ignoring this change
                self.lastSeenClipboardContent = currentClipboard
                self.lastSeenChangeCount = currentChangeCount
            }
            
            // Clean up old entries beyond the buffer time (keep only last 5 seconds)
            let cutoffTime = now.addingTimeInterval(-self.preRecordingBuffer)
            let beforeCount = self.globalClipboardHistory.count
            self.globalClipboardHistory.removeAll { change in
                change.timestamp < cutoffTime
            }
            let afterCount = self.globalClipboardHistory.count
            
            // Only log cleanup if entries were actually removed (reduce log noise)
            if beforeCount != afterCount {
                logDebug("[ClipboardMonitor] Global cleanup: removed \(beforeCount - afterCount) old entries, \(afterCount) remaining")
            }
        }
    }
    
    // MARK: - Memory Management and Bounds Control
    
    /// Starts periodic cleanup to prevent memory growth from unbounded arrays
    private func startPeriodicCleanup() {
        let interval = cleanupInterval
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.performPeriodicCleanup()
        }
        RunLoop.main.add(cleanupTimer!, forMode: .common)
        logDebug("[ClipboardMonitor] Started periodic cleanup (every \(String(format: "%.1f", interval))s, based on clipboardBuffer: \(String(format: "%.1f", preRecordingBuffer))s)")
    }
    
    /// Stops periodic cleanup timer
    private func stopPeriodicCleanup() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        logDebug("[ClipboardMonitor] Stopped periodic cleanup")
    }
    
    /// Performs cleanup of old data to prevent memory growth
    private func performPeriodicCleanup() {
        let startTime = Date()
        var cleanupActions: [String] = []
        
        // Clean up global clipboard history (already has time-based cleanup, but add count bounds)
        globalHistoryQueue.async(flags: .barrier) {
            let beforeGlobalCount = self.globalClipboardHistory.count
            
            // Keep only the most recent entries within bounds
            if self.globalClipboardHistory.count > MAX_GLOBAL_CLIPBOARD_HISTORY {
                let excessCount = self.globalClipboardHistory.count - MAX_GLOBAL_CLIPBOARD_HISTORY
                self.globalClipboardHistory.removeFirst(excessCount)
                cleanupActions.append("trimmed \(excessCount) excess global history entries")
            }
            
            let afterGlobalCount = self.globalClipboardHistory.count
            if beforeGlobalCount != afterGlobalCount {
                cleanupActions.append("global history: \(beforeGlobalCount) → \(afterGlobalCount)")
            }
        }
        
        // Clean up session clipboard changes and remove old inactive sessions
        sessionsQueue.async(flags: .barrier) {
            let beforeSessionCount = self.earlyMonitoringSessions.count
            var totalClipboardChangesBefore = 0
            var totalClipboardChangesAfter = 0
            
            // Count total clipboard changes before cleanup
            for session in self.earlyMonitoringSessions.values {
                totalClipboardChangesBefore += session.clipboardChanges.count
            }
            
            // Remove inactive sessions older than 5 minutes
            let cutoffTime = Date().addingTimeInterval(-300) // 5 minutes
            let inactiveSessionKeys = self.earlyMonitoringSessions.compactMap { (key, session) in
                (!session.isActive && session.startTime < cutoffTime) ? key : nil
            }
            
            for key in inactiveSessionKeys {
                self.earlyMonitoringSessions.removeValue(forKey: key)
            }
            
            // Trim clipboard changes in remaining sessions
            for (key, var session) in self.earlyMonitoringSessions {
                if session.clipboardChanges.count > MAX_SESSION_CLIPBOARD_CHANGES {
                    let excessCount = session.clipboardChanges.count - MAX_SESSION_CLIPBOARD_CHANGES
                    session.clipboardChanges.removeFirst(excessCount)
                    self.earlyMonitoringSessions[key] = session
                }
                totalClipboardChangesAfter += session.clipboardChanges.count
            }
            
            let afterSessionCount = self.earlyMonitoringSessions.count
            
            if beforeSessionCount != afterSessionCount || totalClipboardChangesBefore != totalClipboardChangesAfter {
                cleanupActions.append("sessions: \(beforeSessionCount) → \(afterSessionCount), changes: \(totalClipboardChangesBefore) → \(totalClipboardChangesAfter)")
            }
            
            if inactiveSessionKeys.count > 0 {
                cleanupActions.append("removed \(inactiveSessionKeys.count) inactive sessions")
            }
        }
        
        // Log cleanup results if any actions were taken
        DispatchQueue.main.async {
            let duration = Date().timeIntervalSince(startTime)
            if !cleanupActions.isEmpty {
                logDebug("[ClipboardMonitor] Periodic cleanup (\(String(format: "%.2f", duration * 1000))ms): \(cleanupActions.joined(separator: ", "))")
            }
        }
    }
} 
