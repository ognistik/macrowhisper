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
    func startEarlyMonitoring(for recordingPath: String) {
        let pasteboard = NSPasteboard.general
        let userOriginal = pasteboard.string(forType: .string)
        
        let session = EarlyMonitoringSession(
            userOriginalClipboard: userOriginal,
            startTime: Date()
        )
        
        sessionsQueue.async(flags: .barrier) { [weak self] in
            self?.earlyMonitoringSessions[recordingPath] = session
        }
        
        logDebug("[ClipboardMonitor] Started early monitoring for \(recordingPath)")
        logDebug("[ClipboardMonitor] Captured user original clipboard: '\(userOriginal?.prefix(50) ?? "nil")...'")
        
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
    
    /// Monitors clipboard changes during early monitoring session
    private func monitorClipboardChangesForSession(recordingPath: String) {
        // Check if session is still active before proceeding
        var sessionActive = false
        var userOriginalClipboard: String?
        
        sessionsQueue.sync { [weak self] in
            guard let session = self?.earlyMonitoringSessions[recordingPath] else { return }
            sessionActive = session.isActive
            userOriginalClipboard = session.userOriginalClipboard
        }
        
        guard sessionActive else { return }
        
        let pasteboard = NSPasteboard.general
        let currentContent = pasteboard.string(forType: .string)
        
        // Check if clipboard has changed since last check
        sessionsQueue.sync { [weak self] in
            guard let self = self,
                  let session = self.earlyMonitoringSessions[recordingPath] else { return }
            
            let lastChange = session.clipboardChanges.last
            if currentContent != lastChange?.content && currentContent != userOriginalClipboard {
                let change = ClipboardChange(content: currentContent, timestamp: Date())
                
                // Update the session with new change (requires barrier write)
                self.sessionsQueue.async(flags: .barrier) { [weak self] in
                    self?.earlyMonitoringSessions[recordingPath]?.clipboardChanges.append(change)
                }
                
                logDebug("[ClipboardMonitor] Detected clipboard change during early monitoring: '\(currentContent?.prefix(50) ?? "nil")...'")
            }
        }
        
        // Continue monitoring if session is still active
        if sessionActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
                self?.monitorClipboardChangesForSession(recordingPath: recordingPath)
            }
        }
    }
    
    /// Executes an insert action with enhanced clipboard monitoring that uses early monitoring data
    /// - Parameters:
    ///   - insertAction: The closure that executes the actual insert action
    ///   - actionDelay: The user-configured action delay
    ///   - shouldEsc: Whether ESC should be simulated for responsiveness
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
            
            // Determine what clipboard content should be restored
            // This should be the content that was on clipboard just before anyone (Superwhisper or CLI) modifies it
            let clipboardToRestore = self.determineClipboardToRestore(session: validSession, swResult: swResult)
            
            // Step 1: Apply actionDelay before ESC simulation and clipboard sync
            if actionDelay > 0 {
                Thread.sleep(forTimeInterval: actionDelay)
                logDebug("[ClipboardMonitor] Applied actionDelay: \(actionDelay)s before ESC and clipboard sync")
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
            
            // Step 3: Determine if we need to wait for Superwhisper or if we can proceed immediately
            // If actionDelay > maxWaitTime, skip waiting as Superwhisper must have already acted
            let pasteboard = NSPasteboard.general
            let currentClipboard = pasteboard.string(forType: .string)
            
            if currentClipboard == swResult || actionDelay >= maxWaitTime {
                // Superwhisper was faster OR actionDelay exceeded maxWaitTime - proceed immediately
                let reason = currentClipboard == swResult ? "swResult already on clipboard" : "actionDelay (\(actionDelay)s) >= maxWaitTime (\(maxWaitTime)s)"
                logDebug("[ClipboardMonitor] Proceeding immediately: \(reason)")
                self.proceedWithActionAfterDelay(
                    insertAction: insertAction,
                    clipboardToRestore: clipboardToRestore,
                    superwhisperWasFaster: currentClipboard == swResult,
                    recordingPath: recordingPath
                )
            } else {
                // Need to wait for Superwhisper or proceed if maxWaitTime reached
                self.waitForSuperwhisperOrProceed(
                    insertAction: insertAction,
                    swResult: swResult,
                    clipboardToRestore: clipboardToRestore,
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
                    logDebug("[ClipboardMonitor] Found clipboard to restore from session history: '\(change.content?.prefix(50) ?? "nil")...'")
                    return change.content
                }
            }
            // If no changes found, use the original clipboard from when folder appeared
            logDebug("[ClipboardMonitor] Using original clipboard from folder appearance: '\(session.userOriginalClipboard?.prefix(50) ?? "nil")...'")
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
                logDebug("[ClipboardMonitor] Current clipboard is from tracked changes, will restore: '\(currentClipboard?.prefix(50) ?? "nil")...'")
            } else {
                logDebug("[ClipboardMonitor] Current clipboard is unknown change, will restore: '\(currentClipboard?.prefix(50) ?? "nil")...'")
            }
            return currentClipboard
        }
        
        // Case 3: Current clipboard is same as original, use it
        logDebug("[ClipboardMonitor] Current clipboard same as original, will restore: '\(currentClipboard?.prefix(50) ?? "nil")...'")
        return currentClipboard
    }
    
    /// Wait for Superwhisper to update clipboard or proceed after maxWaitTime
    private func waitForSuperwhisperOrProceed(
        insertAction: @escaping () -> Void,
        swResult: String,
        clipboardToRestore: String?,
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
            insertAction: insertAction,
            clipboardToRestore: clipboardToRestore,
            recordingPath: recordingPath
        )
    }
    
    /// Polls for Superwhisper's clipboard change
    private func pollForSuperwhisperChange(
        startTime: Date,
        initialClipboard: String?,
        swResult: String,
        insertAction: @escaping () -> Void,
        clipboardToRestore: String?,
        recordingPath: String
    ) {
        let pasteboard = NSPasteboard.general
        let currentClipboard = pasteboard.string(forType: .string)
        
        // Check if Superwhisper has placed swResult on clipboard
        if currentClipboard == swResult {
            logDebug("[ClipboardMonitor] Detected Superwhisper placed swResult on clipboard")
            
            // Update the clipboard to restore - it should be what was there just before swResult
            let finalClipboardToRestore = initialClipboard ?? clipboardToRestore
            
            proceedWithActionAfterDelay(
                insertAction: insertAction,
                clipboardToRestore: finalClipboardToRestore,
                superwhisperWasFaster: true,
                recordingPath: recordingPath
            )
            return
        }
        
        // Check if we've exceeded maximum wait time
        if Date().timeIntervalSince(startTime) >= maxWaitTime {
            logDebug("[ClipboardMonitor] Max wait time reached - CLI will be first to modify clipboard")
            
            // Update the clipboard to restore - it should be what's currently there (just before CLI modifies it)
            let finalClipboardToRestore = currentClipboard
            
            proceedWithActionAfterDelay(
                insertAction: insertAction,
                clipboardToRestore: finalClipboardToRestore,
                superwhisperWasFaster: false,
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
                insertAction: insertAction,
                clipboardToRestore: clipboardToRestore,
                recordingPath: recordingPath
            )
        }
    }
    
    /// Proceeds with the action execution and handles restoration (actionDelay already applied)
    private func proceedWithActionAfterDelay(
        insertAction: @escaping () -> Void,
        clipboardToRestore: String?,
        superwhisperWasFaster: Bool,
        recordingPath: String
    ) {
        // Step 1: Execute the insert action (actionDelay already applied)
        insertAction()
        
        // Step 2: Restore the correct clipboard after a minimum wait time for paste to complete
        let restoreDelay = 0.1 // Minimum delay for paste operation to complete
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
            
            // Step 2: Apply actionDelay before ESC simulation and clipboard monitoring
            if actionDelay > 0 {
                Thread.sleep(forTimeInterval: actionDelay)
                logDebug("[ClipboardMonitor] Applied actionDelay: \(actionDelay)s before ESC and clipboard monitoring (fallback)")
            }
            
            // Step 3: Simulate ESC after actionDelay if enabled
            // For autoPaste, only simulate ESC if user is in an input field
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
            
            // Step 4: Start monitoring for Superwhisper's clipboard change
            // If actionDelay >= maxWaitTime, skip waiting as Superwhisper must have already acted
            if actionDelay >= maxWaitTime {
                logDebug("[ClipboardMonitor] ActionDelay (\(actionDelay)s) >= maxWaitTime (\(maxWaitTime)s), proceeding immediately (fallback)")
                insertAction()
                
                let restoreDelay = 0.1 // Minimum delay for paste operation to complete
                DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [weak self] in
                    self?.restoreOriginalClipboard()
                    self?.stopEarlyMonitoring(for: recordingPath)
                }
            } else {
                self.monitorClipboardChanges { [weak self] in
                    guard let self = self else { return }
                    
                    // Step 5: Execute the insert action after Superwhisper has updated clipboard (no additional delay)
                    insertAction()
                    
                    // Step 6: Restore original clipboard after a minimum wait time for paste to complete
                    let restoreDelay = 0.1 // Minimum delay for paste operation to complete
                    DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [weak self] in
                        self?.restoreOriginalClipboard()
                        // Stop early monitoring after clipboard restoration is complete
                        self?.stopEarlyMonitoring(for: recordingPath)
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
            let restoreDelay = 0.1
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
        let restoreDelay = 0.1
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
