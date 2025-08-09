import Foundation
import Cocoa

/// Handles execution of different action types
class ActionExecutor {
    private let logger: Logger
    private let socketCommunication: SocketCommunication
    private let configManager: ConfigurationManager
    private let clipboardMonitor: ClipboardMonitor
    
    init(logger: Logger, socketCommunication: SocketCommunication, configManager: ConfigurationManager, clipboardMonitor: ClipboardMonitor) {
        self.logger = logger
        self.socketCommunication = socketCommunication
        self.configManager = configManager
        self.clipboardMonitor = clipboardMonitor
    }
    
    /// Executes an action based on its type
    func executeAction(
        action: Any,
        name: String,
        type: ActionType,
        metaJson: [String: Any],
        recordingPath: String,
        isTriggeredAction: Bool = true  // Default to true since this is typically called for trigger actions
    ) {
        logInfo("[TriggerEval] Executing action '\(name)' (type: \(type)) due to trigger match.")
        
        switch type {
        case .insert:
            if let insert = action as? AppConfiguration.Insert {
                executeInsertAction(insert, metaJson: metaJson, recordingPath: recordingPath, isTriggeredAction: isTriggeredAction)
            }
        case .url:
            if let url = action as? AppConfiguration.Url {
                executeUrlAction(url, metaJson: metaJson, recordingPath: recordingPath)
            }
        case .shortcut:
            if let shortcut = action as? AppConfiguration.Shortcut {
                executeShortcutAction(shortcut, metaJson: metaJson, recordingPath: recordingPath, shortcutName: name)
            }
        case .shell:
            if let shell = action as? AppConfiguration.ScriptShell {
                executeShellScriptAction(shell, metaJson: metaJson, recordingPath: recordingPath)
            }
        case .appleScript:
            if let ascript = action as? AppConfiguration.ScriptAppleScript {
                executeAppleScriptAction(ascript, metaJson: metaJson, recordingPath: recordingPath)
            }
        }
    }
    
    private func executeInsertAction(_ insert: AppConfiguration.Insert, metaJson: [String: Any], recordingPath: String, isTriggeredAction: Bool) {
        // Enhance metaJson with session data from clipboard monitor
        let enhancedMetaJson = enhanceMetaJsonWithSessionData(metaJson: metaJson, recordingPath: recordingPath)
        
        let (processedAction, isAutoPasteResult) = socketCommunication.processInsertAction(insert.action, metaJson: enhancedMetaJson)
        let shouldEsc = !(insert.noEsc ?? configManager.config.defaults.noEsc)
        let actionDelay = insert.actionDelay ?? configManager.config.defaults.actionDelay
        
        // Use action-level restoreClipboard if set, otherwise fall back to global default
        let restoreClipboard = insert.restoreClipboard ?? configManager.config.defaults.restoreClipboard
        
        clipboardMonitor.executeInsertWithEnhancedClipboardSync(
            insertAction: { [weak self] in
                // Execute the insert action without ESC (already handled by clipboard monitor)
                self?.socketCommunication.applyInsertWithoutEsc(
                    processedAction,
                    activeInsert: insert,
                    isAutoPaste: insert.action == ".autoPaste" || isAutoPasteResult
                )
            },
            actionDelay: actionDelay,
            shouldEsc: shouldEsc,
            isAutoPaste: insert.action == ".autoPaste" || isAutoPasteResult,
            recordingPath: recordingPath,
            metaJson: enhancedMetaJson,
            restoreClipboard: restoreClipboard
        )
        
        // Only handle moveTo for triggered actions; active inserts are handled by RecordingsFolderWatcher
        if isTriggeredAction {
            logDebug("Handling moveTo for triggered insert action")
            handleMoveToSetting(folderPath: recordingPath, activeInsert: insert)
        } else {
            logDebug("Skipping moveTo for active insert action (handled by RecordingsFolderWatcher)")
        }
    }
    
    private func executeUrlAction(_ url: AppConfiguration.Url, metaJson: [String: Any], recordingPath: String) {
        // Enhance metaJson with session data from clipboard monitor
        let enhancedMetaJson = enhanceMetaJsonWithSessionData(metaJson: metaJson, recordingPath: recordingPath)
        
        let shouldEsc = !(url.noEsc ?? configManager.config.defaults.noEsc)
        let actionDelay = url.actionDelay ?? configManager.config.defaults.actionDelay
        
        // Use action-level restoreClipboard if set, otherwise fall back to global default
        let restoreClipboard = url.restoreClipboard ?? configManager.config.defaults.restoreClipboard
        
        clipboardMonitor.executeNonInsertActionWithClipboardRestore(
            action: { [weak self] in
                self?.processUrlAction(url, metaJson: enhancedMetaJson)
            },
            shouldEsc: shouldEsc,
            actionDelay: actionDelay,
            recordingPath: recordingPath,
            metaJson: enhancedMetaJson,
            restoreClipboard: restoreClipboard
        )
        
        // FIX: Pass the individual recording folder path, not its parent
        logDebug("Handling moveTo for triggered URL action")
        handleMoveToSettingForAction(folderPath: recordingPath, action: url)
    }
    
    private func executeShortcutAction(_ shortcut: AppConfiguration.Shortcut, metaJson: [String: Any], recordingPath: String, shortcutName: String) {
        // Enhance metaJson with session data from clipboard monitor
        let enhancedMetaJson = enhanceMetaJsonWithSessionData(metaJson: metaJson, recordingPath: recordingPath)
        
        let shouldEsc = !(shortcut.noEsc ?? configManager.config.defaults.noEsc)
        let actionDelay = shortcut.actionDelay ?? configManager.config.defaults.actionDelay
        
        // Use action-level restoreClipboard if set, otherwise fall back to global default
        let restoreClipboard = shortcut.restoreClipboard ?? configManager.config.defaults.restoreClipboard
        
        clipboardMonitor.executeNonInsertActionWithClipboardRestore(
            action: { [weak self] in
                self?.processShortcutAction(shortcut, shortcutName: shortcutName, metaJson: enhancedMetaJson)
            },
            shouldEsc: shouldEsc,
            actionDelay: actionDelay,
            recordingPath: recordingPath,
            metaJson: enhancedMetaJson,
            restoreClipboard: restoreClipboard
        )
        
        // FIX: Pass the individual recording folder path, not its parent
        handleMoveToSettingForAction(folderPath: recordingPath, action: shortcut)
    }
    
    private func executeShellScriptAction(_ shell: AppConfiguration.ScriptShell, metaJson: [String: Any], recordingPath: String) {
        // Enhance metaJson with session data from clipboard monitor
        let enhancedMetaJson = enhanceMetaJsonWithSessionData(metaJson: metaJson, recordingPath: recordingPath)
        
        let shouldEsc = !(shell.noEsc ?? configManager.config.defaults.noEsc)
        let actionDelay = shell.actionDelay ?? configManager.config.defaults.actionDelay
        
        // Use action-level restoreClipboard if set, otherwise fall back to global default
        let restoreClipboard = shell.restoreClipboard ?? configManager.config.defaults.restoreClipboard
        
        clipboardMonitor.executeNonInsertActionWithClipboardRestore(
            action: { [weak self] in
                self?.processShellScriptAction(shell, metaJson: enhancedMetaJson)
            },
            shouldEsc: shouldEsc,
            actionDelay: actionDelay,
            recordingPath: recordingPath,
            metaJson: enhancedMetaJson,
            restoreClipboard: restoreClipboard
        )
        
        // FIX: Pass the individual recording folder path, not its parent
        handleMoveToSettingForAction(folderPath: recordingPath, action: shell)
    }
    
    private func executeAppleScriptAction(_ ascript: AppConfiguration.ScriptAppleScript, metaJson: [String: Any], recordingPath: String) {
        // Enhance metaJson with session data from clipboard monitor
        let enhancedMetaJson = enhanceMetaJsonWithSessionData(metaJson: metaJson, recordingPath: recordingPath)
        
        let shouldEsc = !(ascript.noEsc ?? configManager.config.defaults.noEsc)
        let actionDelay = ascript.actionDelay ?? configManager.config.defaults.actionDelay
        
        // Use action-level restoreClipboard if set, otherwise fall back to global default
        let restoreClipboard = ascript.restoreClipboard ?? configManager.config.defaults.restoreClipboard
        
        clipboardMonitor.executeNonInsertActionWithClipboardRestore(
            action: { [weak self] in
                self?.processAppleScriptAction(ascript, metaJson: enhancedMetaJson)
            },
            shouldEsc: shouldEsc,
            actionDelay: actionDelay,
            recordingPath: recordingPath,
            metaJson: enhancedMetaJson,
            restoreClipboard: restoreClipboard
        )
        
        // FIX: Pass the individual recording folder path, not its parent
        handleMoveToSettingForAction(folderPath: recordingPath, action: ascript)
    }
    
    // MARK: - Helper Methods
    
    /// Enhances metaJson with session data from clipboard monitor (selectedText, clipboardContext)
    private func enhanceMetaJsonWithSessionData(metaJson: [String: Any], recordingPath: String) -> [String: Any] {
        var enhanced = metaJson
        
        // Get selected text that was captured when recording session started
        let sessionSelectedText = clipboardMonitor.getSessionSelectedText(for: recordingPath)
        if !sessionSelectedText.isEmpty {
            enhanced["selectedText"] = sessionSelectedText
        }
        
        // Get clipboard content for the clipboardContext placeholder with stacking support
        let swResult = (metaJson["llmResult"] as? String) ?? (metaJson["result"] as? String) ?? ""
        let enableStacking = configManager.config.defaults.clipboardStacking
        let sessionClipboardContent = clipboardMonitor.getSessionClipboardContentWithStacking(for: recordingPath, swResult: swResult, enableStacking: enableStacking)
        if !sessionClipboardContent.isEmpty {
            enhanced["clipboardContext"] = sessionClipboardContent
        }
        
        return enhanced
    }
    
    // MARK: - Action Processing Methods
    
    private func processUrlAction(_ urlAction: AppConfiguration.Url, metaJson: [String: Any]) {
        // Process the URL action with both XML and dynamic placeholders
        let processedAction = processAllPlaceholders(action: urlAction.action, metaJson: metaJson, actionType: .url)
        
        // Prefer already valid URLs; otherwise percent-encode using urlQueryAllowed (matches previous behavior)
        if let directUrl = URL(string: processedAction) {
            // Already valid, use as-is to avoid unnecessary encoding
            openResolvedUrl(directUrl, with: urlAction)
            return
        }
        guard let encoded = processedAction.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
              let url = URL(string: encoded) else {
            logError("Invalid URL after processing: \(processedAction)")
            return
        }
        openResolvedUrl(url, with: urlAction)
        
        // This code path is now moved to helper openResolvedUrl(_:with:)
    }

    private func openResolvedUrl(_ url: URL, with urlAction: AppConfiguration.Url) {
        // Check if URL should open in background
        let shouldOpenInBackground = urlAction.openBackground ?? false

        // If openWith is specified, use that app to open the URL
        if let openWith = urlAction.openWith, !openWith.isEmpty {
            let expandedOpenWith = (openWith as NSString).expandingTildeInPath
            let task = Process()
            task.launchPath = "/usr/bin/open"
            // Add -g flag only if openBackground is true
            if shouldOpenInBackground {
                task.arguments = ["-g", "-a", expandedOpenWith, url.absoluteString]
            } else {
                task.arguments = ["-a", expandedOpenWith, url.absoluteString]
            }
            do {
                try task.run()
            } catch {
                logError("Failed to open URL with specified app: \(error)")
                // Fallback to opening with default handler
                openUrl(url, inBackground: shouldOpenInBackground)
            }
        } else {
            // Open with default handler
            openUrl(url, inBackground: shouldOpenInBackground)
        }
    }

    // Helper method to open URLs with background option
    private func openUrl(_ url: URL, inBackground: Bool) {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        // Use -g flag only if opening in background
        if inBackground {
            task.arguments = ["-g", url.absoluteString]
        } else {
            task.arguments = [url.absoluteString]
        }
        do {
            try task.run()
            logDebug("URL opened \(inBackground ? "in background" : "normally"): \(url.absoluteString)")
        } catch {
            logError("Failed to open URL \(inBackground ? "in background" : "normally"): \(error)")
            // Ultimate fallback to standard opening
            NSWorkspace.shared.open(url)
        }
    }
    
    private func processShortcutAction(_ shortcut: AppConfiguration.Shortcut, shortcutName: String, metaJson: [String: Any]) {
        let processedAction = processAllPlaceholders(action: shortcut.action, metaJson: metaJson, actionType: .shortcut)
        
        logDebug("[ShortcutAction] Processed action before sending to shortcuts: '\(processedAction)'")
        
        // Check if action is .none or empty - if so, run shortcut without input
        if processedAction == ".none" || processedAction.isEmpty {
            logDebug("[ShortcutAction] Action is '.none' or empty - running shortcut without input")
            
            let task = Process()
            task.launchPath = "/usr/bin/shortcuts"
            task.arguments = ["run", shortcutName]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            
            do {
                try task.run()
                logDebug("[ShortcutAction] Shortcut launched without input")
            } catch {
                logError("Failed to execute shortcut action without input: \(error)")
            }
        } else {
            // Use temporary file approach to ensure proper UTF-8 encoding
            let tempDir = NSTemporaryDirectory()
            let tempFile = tempDir + "macrowhisper_shortcut_input_\(UUID().uuidString).txt"
            
            do {
                // Write the processed action to a temporary file with explicit UTF-8 encoding
                try processedAction.write(toFile: tempFile, atomically: true, encoding: .utf8)
                logDebug("[ShortcutAction] Wrote UTF-8 content to temporary file: \(tempFile)")
                
                let task = Process()
                task.launchPath = "/usr/bin/shortcuts"
                task.arguments = ["run", shortcutName, "-i", tempFile]
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
                
                try task.run()
                logDebug("[ShortcutAction] Shortcut launched with temporary file input")
                
                // Clean up the temporary file after a short delay to ensure shortcuts has read it
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                    do {
                        try FileManager.default.removeItem(atPath: tempFile)
                        logDebug("[ShortcutAction] Cleaned up temporary file: \(tempFile)")
                    } catch {
                        logWarning("[ShortcutAction] Failed to clean up temporary file \(tempFile): \(error)")
                    }
                }
                
            } catch {
                logError("Failed to execute shortcut action: \(error)")
                // Clean up temp file on error
                try? FileManager.default.removeItem(atPath: tempFile)
            }
        }
        // ESC simulation and action delay are now handled by ClipboardMonitor
    }
    
    private func processShellScriptAction(_ shell: AppConfiguration.ScriptShell, metaJson: [String: Any]) {
        let processedAction = processAllPlaceholders(action: shell.action, metaJson: metaJson, actionType: .shell)
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", processedAction]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            logDebug("Shell script launched asynchronously")
        } catch {
            logError("Failed to execute shell script: \(error)")
        }
        // ESC simulation and action delay are now handled by ClipboardMonitor
    }
    
    private func processAppleScriptAction(_ ascript: AppConfiguration.ScriptAppleScript, metaJson: [String: Any]) {
        let processedAction = processAllPlaceholders(action: ascript.action, metaJson: metaJson, actionType: .appleScript)
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", processedAction]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            logDebug("AppleScript launched asynchronously")
        } catch {
            logError("Failed to execute AppleScript action: \(error)")
        }
        // ESC simulation and action delay are now handled by ClipboardMonitor
    }
    
    // MARK: - Helper Methods
    
    private func handleMoveToSetting(folderPath: String, activeInsert: AppConfiguration.Insert?) {
        // Determine the moveTo value with proper precedence
        var moveTo: String?
        if let activeInsert = activeInsert, let insertMoveTo = activeInsert.moveTo, !insertMoveTo.isEmpty {
            // Insert has an explicit moveTo value (including ".none" and ".delete")
            moveTo = insertMoveTo
        } else {
            // Insert moveTo is nil or empty, fall back to default
            moveTo = configManager.config.defaults.moveTo
        }
        
        // Handle the moveTo action
        if let path = moveTo, !path.isEmpty {
            if path == ".delete" {
                logInfo("Deleting processed recording folder: \(folderPath)")
                try? FileManager.default.removeItem(atPath: folderPath)
            } else if path == ".none" {
                logInfo("Keeping folder in place as requested by .none setting")
                // Explicitly do nothing
            } else {
                let expandedPath = (path as NSString).expandingTildeInPath
                let destinationUrl = URL(fileURLWithPath: expandedPath).appendingPathComponent((folderPath as NSString).lastPathComponent)
                logInfo("Moving processed recording folder to: \(destinationUrl.path)")
                try? FileManager.default.moveItem(atPath: folderPath, toPath: destinationUrl.path)
            }
        }
    }
    
    private func handleMoveToSettingForAction(folderPath: String, action: Any) {
        // Determine the moveTo value with proper precedence for different action types
        var moveTo: String?
        
        if let url = action as? AppConfiguration.Url {
            if let actionMoveTo = url.moveTo, !actionMoveTo.isEmpty {
                moveTo = actionMoveTo
            } else {
                moveTo = configManager.config.defaults.moveTo
            }
        } else if let shortcut = action as? AppConfiguration.Shortcut {
            if let actionMoveTo = shortcut.moveTo, !actionMoveTo.isEmpty {
                moveTo = actionMoveTo
            } else {
                moveTo = configManager.config.defaults.moveTo
            }
        } else if let shell = action as? AppConfiguration.ScriptShell {
            if let actionMoveTo = shell.moveTo, !actionMoveTo.isEmpty {
                moveTo = actionMoveTo
            } else {
                moveTo = configManager.config.defaults.moveTo
            }
        } else if let ascript = action as? AppConfiguration.ScriptAppleScript {
            if let actionMoveTo = ascript.moveTo, !actionMoveTo.isEmpty {
                moveTo = actionMoveTo
            } else {
                moveTo = configManager.config.defaults.moveTo
            }
        } else {
            // Fallback to default
            moveTo = configManager.config.defaults.moveTo
        }
        
        // Handle the moveTo action
        if let path = moveTo, !path.isEmpty {
            if path == ".delete" {
                logInfo("Deleting processed recording folder: \(folderPath)")
                try? FileManager.default.removeItem(atPath: folderPath)
            } else if path == ".none" {
                logInfo("Keeping folder in place as requested by .none setting")
                // Explicitly do nothing
            } else {
                let expandedPath = (path as NSString).expandingTildeInPath
                let destinationUrl = URL(fileURLWithPath: expandedPath).appendingPathComponent((folderPath as NSString).lastPathComponent)
                logInfo("Moving processed recording folder to: \(destinationUrl.path)")
                try? FileManager.default.moveItem(atPath: folderPath, toPath: destinationUrl.path)
            }
        }
    }
    
    private func simulateEscKeyPress(activeInsert: AppConfiguration.Insert?) {
        // Use insert-specific noEsc if set, otherwise fall back to global default
        let shouldSkipEsc = activeInsert?.noEsc ?? configManager.config.defaults.noEsc
        if !shouldSkipEsc {
            DispatchQueue.main.async {
                simulateKeyDown(key: 53) // ESC key
            }
        }
    }
} 
