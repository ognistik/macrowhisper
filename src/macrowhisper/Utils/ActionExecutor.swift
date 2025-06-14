import Foundation
import Cocoa

/// Handles execution of different action types
class ActionExecutor {
    private let logger: Logger
    private let socketCommunication: SocketCommunication
    private let configManager: ConfigurationManager
    
    init(logger: Logger, socketCommunication: SocketCommunication, configManager: ConfigurationManager) {
        self.logger = logger
        self.socketCommunication = socketCommunication
        self.configManager = configManager
    }
    
    /// Executes an action based on its type
    func executeAction(
        action: Any,
        name: String,
        type: ActionType,
        metaJson: [String: Any],
        recordingPath: String
    ) {
        logger.log("[TriggerEval] Action '\(name)' selected for execution due to trigger match.", level: .info)
        
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
                logger.log("[TriggerEval] Executing shell script action: \(name)", level: .info)
                executeShellScriptAction(shell, metaJson: metaJson, recordingPath: recordingPath)
            }
        case .appleScript:
            if let ascript = action as? AppConfiguration.ScriptAppleScript {
                logger.log("[TriggerEval] Executing AppleScript action: \(name)", level: .info)
                executeAppleScriptAction(ascript, metaJson: metaJson, recordingPath: recordingPath)
            }
        }
    }
    
    private func executeInsertAction(_ insert: AppConfiguration.Insert, metaJson: [String: Any], recordingPath: String) {
        let (processedAction, isAutoPasteResult) = socketCommunication.processInsertAction(insert.action, metaJson: metaJson)
        socketCommunication.applyInsert(
            processedAction,
            activeInsert: insert,
            isAutoPaste: insert.action == ".autoPaste" || isAutoPasteResult
        )
        handleMoveToSetting(folderPath: (recordingPath as NSString).deletingLastPathComponent, activeInsert: insert)
    }
    
    private func executeUrlAction(_ url: AppConfiguration.Url, metaJson: [String: Any], recordingPath: String) {
        processUrlAction(url, metaJson: metaJson)
        handleMoveToSetting(folderPath: (recordingPath as NSString).deletingLastPathComponent, activeInsert: nil)
    }
    
    private func executeShortcutAction(_ shortcut: AppConfiguration.Shortcut, metaJson: [String: Any], recordingPath: String, shortcutName: String) {
        processShortcutAction(shortcut, shortcutName: shortcutName, metaJson: metaJson)
        handleMoveToSetting(folderPath: (recordingPath as NSString).deletingLastPathComponent, activeInsert: nil)
    }
    
    private func executeShellScriptAction(_ shell: AppConfiguration.ScriptShell, metaJson: [String: Any], recordingPath: String) {
        processShellScriptAction(shell, metaJson: metaJson)
        handleMoveToSetting(folderPath: (recordingPath as NSString).deletingLastPathComponent, activeInsert: nil)
    }
    
    private func executeAppleScriptAction(_ ascript: AppConfiguration.ScriptAppleScript, metaJson: [String: Any], recordingPath: String) {
        processAppleScriptAction(ascript, metaJson: metaJson)
        handleMoveToSetting(folderPath: (recordingPath as NSString).deletingLastPathComponent, activeInsert: nil)
    }
    
    // MARK: - Action Processing Methods
    
    private func processUrlAction(_ urlAction: AppConfiguration.Url, metaJson: [String: Any]) {
        // Process the URL action with placeholders
        let processedAction = processDynamicPlaceholders(action: urlAction.action, metaJson: metaJson)
        
        // URL encode the processed action
        guard let encodedUrl = processedAction.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
              let url = URL(string: encodedUrl) else {
            logger.log("Invalid URL after processing: \(processedAction)", level: .error)
            return
        }
        
        // If openWith is specified, use that app to open the URL
        if let openWith = urlAction.openWith, !openWith.isEmpty {
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-a", openWith, url.absoluteString]
            do {
                try task.run()
            } catch {
                logger.log("Failed to open URL with specified app: \(error)", level: .error)
                // Fallback to default URL handling
                NSWorkspace.shared.open(url)
            }
        } else {
            // Open with default handler
            NSWorkspace.shared.open(url)
        }
        
        // Handle ESC key press if not disabled
        if !(urlAction.noEsc ?? false) {
            simulateEscKeyPress(activeInsert: nil)
        }
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
            logger.log("Shortcut '\(shortcutName)' launched asynchronously with direct stdin input", level: .info)
        } catch {
            logger.log("Failed to execute shortcut action: \(error)", level: .error)
        }
        if !(shortcut.noEsc ?? false) {
            simulateEscKeyPress(activeInsert: nil)
        }
        if let delay = shortcut.actionDelay, delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        autoReturnEnabled = false
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
            logger.log("Shell script '\(shell.action)' launched asynchronously", level: .info)
        } catch {
            logger.log("Failed to execute shell script: \(error)", level: .error)
        }
        if !(shell.noEsc ?? false) {
            simulateEscKeyPress(activeInsert: nil)
        }
        if let delay = shell.actionDelay, delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        autoReturnEnabled = false
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
            logger.log("AppleScript '\(ascript.action)' launched asynchronously", level: .info)
        } catch {
            logger.log("Failed to execute AppleScript action: \(error)", level: .error)
        }
        if !(ascript.noEsc ?? false) {
            simulateEscKeyPress(activeInsert: nil)
        }
        if let delay = ascript.actionDelay, delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        autoReturnEnabled = false
    }
    
    // MARK: - Helper Methods
    
    private func handleMoveToSetting(folderPath: String, activeInsert: AppConfiguration.Insert?) {
        let moveTo = activeInsert?.moveTo ?? configManager.config.defaults.moveTo
        if let path = moveTo, !path.isEmpty, path != ".none" {
            if path == ".delete" {
                logger.log("Deleting processed recording folder: \(folderPath)", level: .info)
                try? FileManager.default.removeItem(atPath: folderPath)
            } else {
                let expandedPath = (path as NSString).expandingTildeInPath
                let destinationUrl = URL(fileURLWithPath: expandedPath).appendingPathComponent((folderPath as NSString).lastPathComponent)
                logger.log("Moving processed recording folder to: \(destinationUrl.path)", level: .info)
                try? FileManager.default.moveItem(atPath: folderPath, toPath: destinationUrl.path)
            }
        }
    }
    
    private func simulateEscKeyPress(activeInsert: AppConfiguration.Insert?) {
        let shouldSkipEsc = activeInsert?.noEsc ?? configManager.config.defaults.noEsc ?? false
        if !shouldSkipEsc {
            DispatchQueue.main.async {
                simulateKeyDown(key: 53) // ESC key
            }
        }
    }
} 