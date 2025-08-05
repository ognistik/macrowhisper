import Foundation
import Cocoa

/// Handles clipboard monitoring and synchronization for insert actions triggered by valid results
/// This solves the timing issue where Superwhisper puts content on clipboard at the same time as insert execution
class ClipboardMonitor {
    private let logger: Logger
    private var originalClipboard: String?
    private let maxWaitTime: TimeInterval = 0.1 // Maximum time to wait for Superwhisper's clipboard change
    private let pollInterval: TimeInterval = 0.01 // 10ms polling interval
    
    // Early monitoring state for recording sessions - made thread-safe
    private var earlyMonitoringSessions: [String: EarlyMonitoringSession] = [:]
    private let sessionsQueue = DispatchQueue(label: "ClipboardMonitor.sessions", attributes: .concurrent)
    
    private struct EarlyMonitoringSession {
        let userOriginalClipboard: String?
        let startTime: Date
        var clipboardChanges: [ClipboardChange] = []
        var isActive: Bool = true
        let selectedText: String?  // Capture selected text at session start
    }
    
    private struct ClipboardChange {
        let content: String?
        let timestamp: Date
    }
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    /// Starts early clipboard monitoring when a recording folder appears
    /// This captures the user's original clipboard before anyone (Superwhisper or CLI) modifies it
    /// Also captures selected text at the moment the recording folder appears
    func startEarlyMonitoring(for recordingPath: String) {
        let pasteboard = NSPasteboard.general
        let userOriginal = pasteboard.string(forType: .string)
        
        // Capture selected text immediately when recording folder appears
        let selectedText = getSelectedText()
        
        let session = EarlyMonitoringSession(
            userOriginalClipboard: userOriginal,
            startTime: Date(),
            selectedText: selectedText
        )
        
        sessionsQueue.async(flags: .barrier) { [weak self] in
            self?.earlyMonitoringSessions[recordingPath] = session
        }
        
        logDebug("[ClipboardMonitor] Started early monitoring for \(recordingPath)")
        logDebug("[ClipboardMonitor] Captured user original clipboard content")
        if !selectedText.isEmpty {
            logDebug("[ClipboardMonitor] Captured selected text at recording start")
        }
        
        // Start monitoring clipboard changes
        monitorClipboardChangesForSession(recordingPath: recordingPath)
    }
    
    /// Stops early monitoring for a recording session
    func stopEarlyMonitoring(for recordingPath: String) {
        sessionsQueue.async(flags: .barrier) { [weak self] in
            self?.earlyMonitoringSessions[recordingPath]?.isActive = false
            self?.earlyMonitoringSessions.removeValue(forKey: recordingPath)
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
    /// Returns empty string if no clipboard changes occurred during monitoring
    /// This represents the clipboard content the user had before Superwhisper changed it
    func getSessionClipboardContent(for recordingPath: String, swResult: String) -> String {
        var clipboardContent = ""
        sessionsQueue.sync {
            guard let session = earlyMonitoringSessions[recordingPath] else { return }
            
            // Return the last clipboard change during the session (not the initial clipboard)
            // This represents what the user actually copied during the recording session
            if let lastChange = session.clipboardChanges.last {
                clipboardContent = lastChange.content ?? ""
            }
            // If no clipboard changes occurred during monitoring, return empty
            // (Don't return userOriginalClipboard as that's what was there before recording started)
        }
        return clipboardContent
    }
    
    /// Monitors clipboard changes during early monitoring session
    private func monitorClipboardChangesForSession(recordingPath: String) {
        // Get session data in a single atomic operation to prevent race conditions
        var sessionData: (isActive: Bool, userOriginalClipboard: String?, lastChange: ClipboardChange?) = (false, nil, nil)
        
        sessionsQueue.sync { [weak self] in
            guard let session = self?.earlyMonitoringSessions[recordingPath] else { return }
            sessionData.isActive = session.isActive
            sessionData.userOriginalClipboard = session.userOriginalClipboard
            sessionData.lastChange = session.clipboardChanges.last
        }
        
        // Exit early if session is not active - prevents race condition with stopEarlyMonitoring
        guard sessionData.isActive else { 
            logDebug("[ClipboardMonitor] Stopping clipboard monitoring for \(recordingPath) - session inactive")
            return 
        }
        
        let pasteboard = NSPasteboard.general
        let currentContent = pasteboard.string(forType: .string)
        
        // Check if clipboard has changed since last check
        if currentContent != sessionData.lastChange?.content && currentContent != sessionData.userOriginalClipboard {
            let change = ClipboardChange(content: currentContent, timestamp: Date())
            
            // Update the session with new change (requires barrier write)
            // Only update if session still exists to prevent updating removed sessions
            sessionsQueue.async(flags: .barrier) { [weak self] in
                // Double-check session still exists before updating
                if self?.earlyMonitoringSessions[recordingPath]?.isActive == true {
                    self?.earlyMonitoringSessions[recordingPath]?.clipboardChanges.append(change)
                    logDebug("[ClipboardMonitor] Detected clipboard change during early monitoring")
                }
            }
        }
        
        // Schedule next monitoring iteration only if session is still active
        // Final check to prevent scheduling after session is stopped
        var shouldContinue = false
        sessionsQueue.sync { [weak self] in
            shouldContinue = self?.earlyMonitoringSessions[recordingPath]?.isActive ?? false
        }
        
        if shouldContinue {
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
                self?.monitorClipboardChangesForSession(recordingPath: recordingPath)
            }
        } else {
            logDebug("[ClipboardMonitor] Stopping clipboard monitoring for \(recordingPath) - session inactive")
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
        restoreClipboard: Bool = true
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
                
                // Stop early monitoring since we're not using it for restoration
                self.stopEarlyMonitoring(for: recordingPath)
                
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
                    recordingPath: recordingPath
                )
                return
            }
            
            // Extract swResult from metaJson (llmResult takes precedence over result)
            let swResult = (metaJson["llmResult"] as? String) ?? (metaJson["result"] as? String) ?? ""
            
            // Step 1: First, handle clipboard synchronization with Superwhisper BEFORE applying actionDelay
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
                    recordingPath: recordingPath
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
                    recordingPath: recordingPath
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
        recordingPath: String
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
            recordingPath: recordingPath
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
        recordingPath: String
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
                superwhisperWasFaster: true,
                actionDelay: actionDelay,
                shouldEsc: shouldEsc,
                isAutoPaste: isAutoPaste,
                userIsInInputField: userIsInInputField,
                recordingPath: recordingPath
            )
            return
        }
        
        // Check if we've exceeded maximum wait time
        if Date().timeIntervalSince(startTime) >= maxWaitTime {
            logDebug("[ClipboardMonitor] Max wait time (\(maxWaitTime)s) reached - proceeding without Superwhisper sync")
            
            // Determine clipboard to restore - use what's currently there (before we modify it)
            let clipboardToRestore = currentClipboard
            
            proceedWithActionAndDelay(
                insertAction: insertAction,
                clipboardToRestore: clipboardToRestore,
                superwhisperWasFaster: false,
                actionDelay: actionDelay,
                shouldEsc: shouldEsc,
                isAutoPaste: isAutoPaste,
                userIsInInputField: userIsInInputField,
                recordingPath: recordingPath
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
                recordingPath: recordingPath
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
        recordingPath: String
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
        
        // Step 4: Restore the correct clipboard after a minimum wait time for paste to complete
        let restoreDelay = 0.3 // Minimum delay for paste operation to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [weak self] in
            self?.restoreCorrectClipboard(clipboardToRestore)
            // Stop early monitoring after clipboard restoration is complete
            self?.stopEarlyMonitoring(for: recordingPath)
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
        recordingPath: String
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
                
                // Stop early monitoring since we're not using it for restoration
                self.stopEarlyMonitoring(for: recordingPath)
                
                logDebug("[ClipboardMonitor] Action completed without clipboard restoration (fallback)")
                return
            }
            
            // Step 1: Save current clipboard content
            let pasteboard = NSPasteboard.general
            self.originalClipboard = pasteboard.string(forType: .string)
            
            // Step 2: Monitor for Superwhisper's clipboard change BEFORE applying actionDelay
            logDebug("[ClipboardMonitor] Fallback: monitoring clipboard changes (maxWaitTime: \(maxWaitTime)s)")
            self.monitorClipboardChanges { [weak self] in
                guard let self = self else { return }
                
                // Step 3: Apply actionDelay after clipboard synchronization is complete
                if actionDelay > 0 {
                    Thread.sleep(forTimeInterval: actionDelay)
                    logDebug("[ClipboardMonitor] Applied actionDelay: \(actionDelay)s after clipboard sync (fallback)")
                }
                
                // Step 4: Simulate ESC after actionDelay if enabled
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
                
                // Step 5: Execute the insert action
                insertAction()
                
                // Step 6: Restore original clipboard after a minimum wait time for paste to complete
                let restoreDelay = 0.3 // Minimum delay for paste operation to complete
                DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [weak self] in
                    self?.restoreOriginalClipboard()
                    // Stop early monitoring after clipboard restoration is complete
                    self?.stopEarlyMonitoring(for: recordingPath)
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
        restoreClipboard: Bool = true
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Only restore clipboard if ESC will be simulated AND restoreClipboard is enabled
            let shouldRestoreClipboard = shouldEsc && restoreClipboard
            
            if !shouldRestoreClipboard {
                logDebug("[ClipboardMonitor] Non-insert action: No clipboard restoration (ESC=\(shouldEsc), restore=\(restoreClipboard))")
                
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
                
                // Stop early monitoring since we're not using it
                self.stopEarlyMonitoring(for: recordingPath)
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
                    recordingPath: recordingPath
                )
                return
            }
            
            // Extract swResult from metaJson (llmResult takes precedence over result)
            let swResult = (metaJson["llmResult"] as? String) ?? (metaJson["result"] as? String) ?? ""
            
            // Determine what clipboard content should be restored
            let clipboardToRestore = self.determineClipboardToRestore(session: validSession, swResult: swResult)
            
            logDebug("[ClipboardMonitor] Non-insert action with clipboard restoration")
            
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
            
            // Restore clipboard after a brief delay to let any action complete
            let restoreDelay = 0.3
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [weak self] in
                self?.restoreCorrectClipboard(clipboardToRestore)
            }
        }
    }
    
    /// Simple clipboard save/restore for non-insert actions when early monitoring is not available
    private func executeNonInsertActionWithSimpleRestore(
        action: @escaping () -> Void,
        shouldEsc: Bool,
        actionDelay: TimeInterval,
        recordingPath: String
    ) {
        // Save current clipboard
        let pasteboard = NSPasteboard.general
        let originalClipboard = pasteboard.string(forType: .string)
        
        logDebug("[ClipboardMonitor] Non-insert action with simple clipboard restore")
        
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
        
        // Restore clipboard after a brief delay
        let restoreDelay = 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [weak self] in
            if let original = originalClipboard {
                pasteboard.clearContents()
                pasteboard.setString(original, forType: .string)
                logDebug("[ClipboardMonitor] Restored original clipboard for non-insert action")
            } else {
                pasteboard.clearContents()
                logDebug("[ClipboardMonitor] Cleared clipboard for non-insert action (no original content)")
            }
            // Stop early monitoring after clipboard restoration is complete
            self?.stopEarlyMonitoring(for: recordingPath)
        }
    }
} 
