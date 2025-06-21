import Foundation
import Cocoa

/// Handles execution of different action types
class ActionExecutor {
    private let logger: Logger
    private let socketCommunication: SocketCommunication
    private let configManager: ConfigurationManager
    private let clipboardMonitor: ClipboardMonitor
    
    init(logger: Logger, socketCommunication: SocketCommunication, configManager: ConfigurationManager) {
        self.logger = logger
        self.socketCommunication = socketCommunication
        self.configManager = configManager
        self.clipboardMonitor = ClipboardMonitor(logger: logger)
    }
    
    /// Executes an action based on its type
    func executeAction(
        action: Any,
        name: String,
        type: ActionType,
        metaJson: [String: Any],
        recordingPath: String
    ) {
        logInfo("[TriggerEval] Executing action '\(name)' (type: \(type)) due to trigger match.")
        
        switch type {
        case .insert:
            if let insert = action as? AppConfiguration.Insert {
                executeInsertAction(insert, metaJson: metaJson, recordingPath: recordingPath)
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
    
    private func executeInsertAction(_ insert: AppConfiguration.Insert, metaJson: [String: Any], recordingPath: String) {
        // Check if the insert action is ".none" or empty - if so, skip action but apply delay
        if insert.action == ".none" || insert.action.isEmpty {
            logDebug("Insert action is '.none' or empty - skipping action, no ESC, no clipboard restoration")
            // Apply actionDelay if specified, but don't do anything else
            let actionDelay = insert.actionDelay ?? configManager.config.defaults.actionDelay
            if actionDelay > 0 {
                Thread.sleep(forTimeInterval: actionDelay)
                logDebug("Applied actionDelay: \(actionDelay)s for .none/.empty action")
            }
            
            handleMoveToSetting(folderPath: (recordingPath as NSString).deletingLastPathComponent, activeInsert: insert)
            return
        }
        
        let (processedAction, isAutoPasteResult) = socketCommunication.processInsertAction(insert.action, metaJson: metaJson)
        
        // Use enhanced clipboard monitoring for insert actions triggered by valid results (from watcher)
        // This handles the timing issue where Superwhisper puts content on clipboard simultaneously
        let actionDelay = insert.actionDelay ?? configManager.config.defaults.actionDelay
        let shouldEsc = !(insert.noEsc ?? configManager.config.defaults.noEsc)
        
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
            metaJson: metaJson,
            restoreClipboard: configManager.config.defaults.restoreClipboard
        )
        
        handleMoveToSetting(folderPath: (recordingPath as NSString).deletingLastPathComponent, activeInsert: insert)
    }
    
    private func executeUrlAction(_ url: AppConfiguration.Url, metaJson: [String: Any], recordingPath: String) {
        let shouldEsc = !(url.noEsc ?? configManager.config.defaults.noEsc)
        let actionDelay = url.actionDelay ?? configManager.config.defaults.actionDelay
        
        clipboardMonitor.executeNonInsertActionWithClipboardRestore(
            action: { [weak self] in
                self?.processUrlAction(url, metaJson: metaJson)
            },
            shouldEsc: shouldEsc,
            actionDelay: actionDelay,
            recordingPath: recordingPath,
            metaJson: metaJson,
            restoreClipboard: configManager.config.defaults.restoreClipboard
        )
        
        handleMoveToSettingForAction(folderPath: (recordingPath as NSString).deletingLastPathComponent, action: url)
    }
    
    private func executeShortcutAction(_ shortcut: AppConfiguration.Shortcut, metaJson: [String: Any], recordingPath: String, shortcutName: String) {
        let shouldEsc = !(shortcut.noEsc ?? configManager.config.defaults.noEsc)
        let actionDelay = shortcut.actionDelay ?? configManager.config.defaults.actionDelay
        
        clipboardMonitor.executeNonInsertActionWithClipboardRestore(
            action: { [weak self] in
                self?.processShortcutAction(shortcut, shortcutName: shortcutName, metaJson: metaJson)
            },
            shouldEsc: shouldEsc,
            actionDelay: actionDelay,
            recordingPath: recordingPath,
            metaJson: metaJson,
            restoreClipboard: configManager.config.defaults.restoreClipboard
        )
        
        handleMoveToSettingForAction(folderPath: (recordingPath as NSString).deletingLastPathComponent, action: shortcut)
    }
    
    private func executeShellScriptAction(_ shell: AppConfiguration.ScriptShell, metaJson: [String: Any], recordingPath: String) {
        let shouldEsc = !(shell.noEsc ?? configManager.config.defaults.noEsc)
        let actionDelay = shell.actionDelay ?? configManager.config.defaults.actionDelay
        
        clipboardMonitor.executeNonInsertActionWithClipboardRestore(
            action: { [weak self] in
                self?.processShellScriptAction(shell, metaJson: metaJson)
            },
            shouldEsc: shouldEsc,
            actionDelay: actionDelay,
            recordingPath: recordingPath,
            metaJson: metaJson,
            restoreClipboard: configManager.config.defaults.restoreClipboard
        )
        
        handleMoveToSettingForAction(folderPath: (recordingPath as NSString).deletingLastPathComponent, action: shell)
    }
    
    private func executeAppleScriptAction(_ ascript: AppConfiguration.ScriptAppleScript, metaJson: [String: Any], recordingPath: String) {
        let shouldEsc = !(ascript.noEsc ?? configManager.config.defaults.noEsc)
        let actionDelay = ascript.actionDelay ?? configManager.config.defaults.actionDelay
        
        clipboardMonitor.executeNonInsertActionWithClipboardRestore(
            action: { [weak self] in
                self?.processAppleScriptAction(ascript, metaJson: metaJson)
            },
            shouldEsc: shouldEsc,
            actionDelay: actionDelay,
            recordingPath: recordingPath,
            metaJson: metaJson,
            restoreClipboard: configManager.config.defaults.restoreClipboard
        )
        
        handleMoveToSettingForAction(folderPath: (recordingPath as NSString).deletingLastPathComponent, action: ascript)
    }
    
    // MARK: - Action Processing Methods
    
    private func processUrlAction(_ urlAction: AppConfiguration.Url, metaJson: [String: Any]) {
        // Process the URL action with placeholders
        let processedAction = processDynamicPlaceholders(action: urlAction.action, metaJson: metaJson, actionType: .url)
        
        // URL encode the processed action
        guard let encodedUrl = processedAction.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
              let url = URL(string: encodedUrl) else {
            logError("Invalid URL after processing: \(processedAction)")
            return
        }
        
        // If openWith is specified, use that app to open the URL
        if let openWith = urlAction.openWith, !openWith.isEmpty {
            let expandedOpenWith = (openWith as NSString).expandingTildeInPath
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-a", expandedOpenWith, url.absoluteString]
            do {
                try task.run()
            } catch {
                logError("Failed to open URL with specified app: \(error)")
                // Fallback to default URL handling
                NSWorkspace.shared.open(url)
            }
        } else {
            // Open with default handler
            NSWorkspace.shared.open(url)
        }
        
        // ESC simulation and action delay are now handled by ClipboardMonitor
    }
    
    private func processShortcutAction(_ shortcut: AppConfiguration.Shortcut, shortcutName: String, metaJson: [String: Any]) {
        let processedAction = processDynamicPlaceholders(action: shortcut.action, metaJson: metaJson, actionType: .shortcut)
        let task = Process()
        task.launchPath = "/usr/bin/shortcuts"
        task.arguments = ["run", shortcutName, "-i", "-"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        let inputPipe = Pipe()
        task.standardInput = inputPipe
        do {
            try task.run()
            // Write the action to stdin (do NOT escape again)
            if let data = processedAction.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            inputPipe.fileHandleForWriting.closeFile()
            logDebug("Shortcut launched asynchronously with direct stdin input")
        } catch {
            logError("Failed to execute shortcut action: \(error)")
        }
        // ESC simulation and action delay are now handled by ClipboardMonitor
    }
    
    private func processShellScriptAction(_ shell: AppConfiguration.ScriptShell, metaJson: [String: Any]) {
        let processedAction = processDynamicPlaceholders(action: shell.action, metaJson: metaJson, actionType: .shell)
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
        let processedAction = processDynamicPlaceholders(action: ascript.action, metaJson: metaJson, actionType: .appleScript)
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
