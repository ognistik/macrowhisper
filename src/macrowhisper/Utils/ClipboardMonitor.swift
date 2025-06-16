import Foundation
import Cocoa

/// Handles clipboard monitoring and synchronization for insert actions triggered by valid results
/// This solves the timing issue where Superwhisper puts content on clipboard at the same time as insert execution
class ClipboardMonitor {
    private let logger: Logger
    private var originalClipboard: String?
    private let maxWaitTime: TimeInterval = 0.1 // Maximum time to wait for Superwhisper's clipboard change
    private let pollInterval: TimeInterval = 0.01 // 10ms polling interval
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    /// Executes an insert action with clipboard monitoring to handle Superwhisper interference
    /// - Parameters:
    ///   - insertAction: The closure that executes the actual insert action
    ///   - actionDelay: The user-configured action delay
    ///   - shouldEsc: Whether ESC should be simulated for responsiveness
    ///   - isAutoPaste: Whether this is an autoPaste action (affects ESC simulation logic)
    func executeInsertWithClipboardSync(
        insertAction: @escaping () -> Void,
        actionDelay: TimeInterval,
        shouldEsc: Bool,
        isAutoPaste: Bool = false
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Step 1: Save current clipboard content
            let pasteboard = NSPasteboard.general
            self.originalClipboard = pasteboard.string(forType: .string)
            
            // Step 2: Simulate ESC immediately for responsiveness if enabled
            // For autoPaste, only simulate ESC if user is in an input field
            if shouldEsc {
                if isAutoPaste {
                    // For autoPaste, check input field status before simulating ESC
                    if !requestAccessibilityPermission() {
                        logWarning("[ClipboardMonitor] Accessibility permission denied for autoPaste input field check")
                    } else if isInInputField() {
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
            
            // Step 3: Start monitoring for Superwhisper's clipboard change
            self.monitorClipboardChanges { [weak self] in
                guard let self = self else { return }
                
                // Step 4: Apply actionDelay before executing insert action (matches original timing)
                if actionDelay > 0 {
                    Thread.sleep(forTimeInterval: actionDelay)
                    logDebug("[ClipboardMonitor] Applied actionDelay: \(actionDelay)s")
                }
                
                // Step 5: Execute the insert action after Superwhisper has updated clipboard and delay
                insertAction()
                
                // Step 6: Restore original clipboard after a minimum wait time for paste to complete
                let restoreDelay = 0.1 // Minimum delay for paste operation to complete
                DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                    self.restoreOriginalClipboard()
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
    
    /// Restores the original clipboard content
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
} 
