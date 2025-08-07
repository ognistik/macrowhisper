import Foundation
import Dispatch
import Darwin
import Cocoa
import Carbon.HIToolbox

private let UNIX_PATH_MAX = 104

class SocketCommunication {
    private let socketPath: String
    private var server: DispatchSourceRead?
    private var serverSocket: Int32 = -1
    private let queue = DispatchQueue(label: "com.macrowhisper.socket", qos: .utility)
    private var configManagerRef: ConfigurationManager?
    
    enum Command: String, Codable {
        case reloadConfig
        case updateConfig
        case status
        case debug
        case version
        case listInserts  // Deprecated, but maintained for backward compatibility
        case addInsert
        case getIcon
        case getInsert    // Deprecated, but maintained for backward compatibility
        case autoReturn
        case scheduleAction
        case execInsert   // Deprecated, but maintained for backward compatibility
        case addUrl
        case addShortcut
        case addShell
        case addAppleScript
        case quit
        case versionState
        case forceUpdateCheck
        case versionClear
        // Service management commands
        case serviceStatus
        case serviceInstall
        case serviceStart
        case serviceStop
        case serviceRestart
        case serviceUninstall
        
        // New unified action commands
        case listActions
        case listUrls
        case listShortcuts
        case listShell
        case listAppleScript
        case execAction
        case getAction
        case removeAction
    }
    
    struct CommandMessage: Codable {
        let command: Command
        let arguments: [String: String]?
    }
    
    init(socketPath: String) {
        self.socketPath = socketPath
    }
    
    func startServer(configManager: ConfigurationManager) {
        self.configManagerRef = configManager
        let socketDir = (socketPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: socketDir) {
            try? FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logError("Failed to create socket: \(errno)")
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLength = min(socketPath.utf8.count, Int(UNIX_PATH_MAX) - 1)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            socketPath.withCString { strncpy(ptr, $0, pathLength) }
        }
        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, addrSize)
            }
        }
        guard bindResult == 0 else {
            logError("Failed to bind socket: \(errno)"); close(serverSocket); return
        }
        chmod(socketPath, 0o777)
        guard listen(serverSocket, 5) == 0 else {
            logError("Failed to listen on socket: \(errno)"); close(serverSocket); return
        }
        server = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        server?.setEventHandler { [weak self] in
            guard let self = self else { return }
            let clientSocket = accept(self.serverSocket, nil, nil)
            guard clientSocket >= 0 else { logError("Failed to accept connection: \(errno)"); return }
            self.queue.async {
                self.handleConnection(clientSocket: clientSocket, configManager: globalConfigManager)
            }
        }
        server?.setCancelHandler { [weak self] in
            guard let self = self else { return }
            close(self.serverSocket)
            self.serverSocket = -1
            try? FileManager.default.removeItem(atPath: self.socketPath)
        }
        server?.resume()
        logInfo("Socket server started at \(socketPath)")
    }

    func stopServer() {
        server?.cancel()
        server = nil
    }

    private func findLastValidJsonFile(configManager: ConfigurationManager) -> [String: Any]? {
        let expandedWatchPath = (configManager.config.defaults.watch as NSString).expandingTildeInPath
        let recordingsPath = expandedWatchPath + "/recordings"
        guard let contents = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: recordingsPath), includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey], options: .skipsHiddenFiles) else { return nil }
        let directories = contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }.sorted {
            let date1 = try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate
            let date2 = try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate
            return (date1 ?? .distantPast) > (date2 ?? .distantPast)
        }
        for directory in directories {
            let metaJsonPath = directory.appendingPathComponent("meta.json").path
            if FileManager.default.fileExists(atPath: metaJsonPath),
               let data = try? Data(contentsOf: URL(fileURLWithPath: metaJsonPath)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let duration = json["duration"], !(duration is NSNull) {
                
                // Check if duration is valid (greater than 0)
                if let durationDouble = duration as? Double, durationDouble > 0 {
                    return json
                } else if let durationInt = duration as? Int, durationInt > 0 {
                    return json
                }
            }
        }
        return nil
    }
    
    /// Enhances metaJson with CLI-specific data for placeholder processing
    /// This adds clipboard stacking setting and other CLI context data
    private func enhanceMetaJsonForCLI(metaJson: [String: Any], configManager: ConfigurationManager) -> [String: Any] {
        var enhanced = metaJson
        
        // Add clipboard stacking setting for CLI context
        enhanced["clipboardStacking"] = configManager.config.defaults.clipboardStacking
        
        // Add CLI execution context flag
        enhanced["isCLIExecution"] = true
        
        return enhanced
    }

    private func validateInsertExists(_ insertName: String, configManager: ConfigurationManager) -> Bool {
        if insertName.isEmpty { return true }
        return configManager.config.inserts[insertName] != nil
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
    
    // Helper to validate any action exists
    private func validateActionExists(_ actionName: String, configManager: ConfigurationManager) -> Bool {
        if actionName.isEmpty { return true }
        let (_, action) = findActionByName(actionName, configManager: configManager)
        return action != nil
    }
    
    // Helper to check if an action name already exists (for duplicate prevention)
    private func actionNameExists(_ actionName: String, configManager: ConfigurationManager) -> Bool {
        let config = configManager.config
        return config.inserts[actionName] != nil ||
               config.urls[actionName] != nil ||
               config.shortcuts[actionName] != nil ||
               config.scriptsShell[actionName] != nil ||
               config.scriptsAS[actionName] != nil
    }
    
    // Function to get the current active action (generalizes validateInsertExists for activeInsert)
    private func getActiveAction(configManager: ConfigurationManager) -> (type: ActionType, action: Any?, name: String) {
        let activeActionName = configManager.config.defaults.activeAction ?? ""
        
        if activeActionName.isEmpty {
            return (.insert, nil, "")
        }
        
        let (type, action) = findActionByName(activeActionName, configManager: configManager)
        return (type, action, activeActionName)
    }

    func processInsertAction(_ action: String, metaJson: [String: Any]) -> (String, Bool) {
        if action == ".none" { return ("", false) }
        if action == ".autoPaste" {
            let swResult = (metaJson["llmResult"] as? String) ?? (metaJson["result"] as? String) ?? ""
            return (swResult, true)
        }
        // Use the unified placeholder processing function for consistency across all action types
        // (newline conversion is handled within processAllPlaceholders for Insert actions)
        let result = processAllPlaceholders(action: action, metaJson: metaJson, actionType: .insert)
        return (result, false)
    }

    // This version is for the main watcher flow and respects the 'noEsc' setting
    func applyInsert(_ text: String, activeInsert: AppConfiguration.Insert?, isAutoPaste: Bool = false) {
        if text.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == ".none" {
            // For empty or .none actions, apply actionDelay but don't press ESC, paste, or do any clipboard operations
            let delay = activeInsert?.actionDelay ?? globalConfigManager?.config.defaults.actionDelay ?? 0.0
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return
        }
        let delay = activeInsert?.actionDelay ?? globalConfigManager?.config.defaults.actionDelay ?? 0.0
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if isAutoPaste {
            if !requestAccessibilityPermission() { logWarning("Accessibility permission denied"); return }
            if !isInInputField() {
                logDebug("Auto paste - not in input field, direct paste only")
                let pasteboard = NSPasteboard.general; pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
                simulateKeyDown(key: 9, flags: .maskCommand) // Cmd+V
                checkAndSimulatePressReturn(activeInsert: activeInsert); return
            }
        }
        simulateEscKeyPress(activeInsert: activeInsert)
        pasteText(text, activeInsert: activeInsert)
        checkAndSimulatePressReturn(activeInsert: activeInsert)
    }
    
    // This version is for the --exec-insert CLI command and does NOT press ESC.
    func applyInsertForExec(_ text: String, activeInsert: AppConfiguration.Insert?, isAutoPaste: Bool = false) {
        if text.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == ".none" { 
            // For empty or .none actions, apply actionDelay but don't paste or do any clipboard operations
            let delay = activeInsert?.actionDelay ?? globalConfigManager?.config.defaults.actionDelay ?? 0.0
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return 
        }
        let delay = activeInsert?.actionDelay ?? globalConfigManager?.config.defaults.actionDelay ?? 0.0
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        
        // Use action-level restoreClipboard if set, otherwise fall back to global default
        let restoreClipboard = activeInsert?.restoreClipboard ?? globalConfigManager?.config.defaults.restoreClipboard ?? true
        
        if isAutoPaste {
            if !requestAccessibilityPermission() { logWarning("Accessibility permission denied"); return }
            if !isInInputField() {
                logInfo("Exec-insert auto paste - not in input field, direct paste only")
                let pasteboard = NSPasteboard.general; pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
                simulateKeyDown(key: 9, flags: .maskCommand) // Cmd+V
                checkAndSimulatePressReturn(activeInsert: activeInsert); return
            }
        }
        // No ESC key press for exec-insert
        if restoreClipboard {
            pasteText(text, activeInsert: activeInsert)
        } else {
            pasteTextNoRestore(text, activeInsert: activeInsert)
        }
        checkAndSimulatePressReturn(activeInsert: activeInsert)
    }
    
    // This version is for clipboard-monitored insert actions and does NOT press ESC or apply actionDelay
    // (ESC and delay are handled by ClipboardMonitor)
    func applyInsertWithoutEsc(_ text: String, activeInsert: AppConfiguration.Insert?, isAutoPaste: Bool = false) {
        if text.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == ".none" {
            // For empty or .none actions, do nothing since delay is handled by ClipboardMonitor
            return
        }
        
        if isAutoPaste {
            if !requestAccessibilityPermission() { logWarning("Accessibility permission denied"); return }
            if !isInInputField() {
                logDebug("Clipboard-monitored auto paste - not in input field, direct paste only")
                let pasteboard = NSPasteboard.general; pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
                simulateKeyDown(key: 9, flags: .maskCommand) // Cmd+V
                checkAndSimulatePressReturn(activeInsert: activeInsert); return
            }
        }
        
        // No ESC key press or actionDelay - these are handled by ClipboardMonitor
        pasteTextNoRestore(text, activeInsert: activeInsert)
        checkAndSimulatePressReturn(activeInsert: activeInsert)
    }
    
    // MARK: - CLI Execution Methods for Non-Insert Actions
    
    // Simple execution methods for CLI commands (no ESC, no clipboard monitoring, no moveTo handling)
    func executeUrlForCLI(_ urlAction: AppConfiguration.Url, metaJson: [String: Any]) {
        let actionDelay = urlAction.actionDelay ?? globalConfigManager?.config.defaults.actionDelay ?? 0.0
        if actionDelay > 0 { Thread.sleep(forTimeInterval: actionDelay) }
        
        let processedAction = processAllPlaceholders(action: urlAction.action, metaJson: metaJson, actionType: .url)
        
        guard let encodedUrl = processedAction.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
              let url = URL(string: encodedUrl) else {
            logError("Invalid URL after processing: \(processedAction)")
            return
        }
        
        // Check if URL should open in background
        let shouldOpenInBackground = urlAction.openBackground ?? false
        
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
                openUrlCLI(url, inBackground: shouldOpenInBackground)
            }
        } else {
            // Open with default handler
            openUrlCLI(url, inBackground: shouldOpenInBackground)
        }
    }

    // Helper method for CLI URL opening with background option
    private func openUrlCLI(_ url: URL, inBackground: Bool) {
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
            logDebug("URL opened \(inBackground ? "in background" : "normally") via CLI: \(url.absoluteString)")
        } catch {
            logError("Failed to open URL \(inBackground ? "in background" : "normally") via CLI: \(error)")
            // Ultimate fallback to standard opening
            NSWorkspace.shared.open(url)
        }
    }
    
    func executeShortcutForCLI(_ shortcut: AppConfiguration.Shortcut, shortcutName: String, metaJson: [String: Any]) {
        let actionDelay = shortcut.actionDelay ?? globalConfigManager?.config.defaults.actionDelay ?? 0.0
        if actionDelay > 0 { Thread.sleep(forTimeInterval: actionDelay) }
        
        let processedAction = processAllPlaceholders(action: shortcut.action, metaJson: metaJson, actionType: .shortcut)
        
        let tempDir = NSTemporaryDirectory()
        let tempFile = tempDir + "macrowhisper_shortcut_input_\(UUID().uuidString).txt"
        
        do {
            try processedAction.write(toFile: tempFile, atomically: true, encoding: .utf8)
            
            let task = Process()
            task.launchPath = "/usr/bin/shortcuts"
            task.arguments = ["run", shortcutName, "-i", tempFile]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            
            try task.run()
            
            // Clean up temp file after delay
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                try? FileManager.default.removeItem(atPath: tempFile)
            }
        } catch {
            logError("Failed to execute shortcut action: \(error)")
            try? FileManager.default.removeItem(atPath: tempFile)
        }
    }
    
    func executeShellForCLI(_ shell: AppConfiguration.ScriptShell, metaJson: [String: Any]) {
        let actionDelay = shell.actionDelay ?? globalConfigManager?.config.defaults.actionDelay ?? 0.0
        if actionDelay > 0 { Thread.sleep(forTimeInterval: actionDelay) }
        
        let processedAction = processAllPlaceholders(action: shell.action, metaJson: metaJson, actionType: .shell)
        
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", processedAction]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        
        do {
            try task.run()
        } catch {
            logError("Failed to execute shell script: \(error)")
        }
    }
    
    func executeAppleScriptForCLI(_ ascript: AppConfiguration.ScriptAppleScript, metaJson: [String: Any]) {
        let actionDelay = ascript.actionDelay ?? globalConfigManager?.config.defaults.actionDelay ?? 0.0
        if actionDelay > 0 { Thread.sleep(forTimeInterval: actionDelay) }
        
        let processedAction = processAllPlaceholders(action: ascript.action, metaJson: metaJson, actionType: .appleScript)
        
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", processedAction]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        
        do {
            try task.run()
        } catch {
            logError("Failed to execute AppleScript action: \(error)")
        }
    }

    private func pasteText(_ text: String, activeInsert: AppConfiguration.Insert?) {
        let shouldSimulate = activeInsert?.simKeypress ?? globalConfigManager?.config.defaults.simKeypress ?? false
        if shouldSimulate {
            // Use the new comprehensive CGEvent-based typing
            typeText(text)
        } else {
            pasteUsingClipboard(text)
        }
    }

    // Version of pasteText that doesn't save/restore clipboard (used with ClipboardMonitor)
    private func pasteTextNoRestore(_ text: String, activeInsert: AppConfiguration.Insert?) {
        let shouldSimulate = activeInsert?.simKeypress ?? globalConfigManager?.config.defaults.simKeypress ?? false
        if shouldSimulate {
            // Use the new comprehensive CGEvent-based typing
            typeText(text)
        } else {
            pasteUsingClipboardNoRestore(text)
        }
    }
    
    private func checkAndSimulatePressReturn(activeInsert: AppConfiguration.Insert?) {
        let shouldPressReturn = activeInsert?.pressReturn ?? globalConfigManager?.config.defaults.pressReturn ?? false
        if autoReturnEnabled {
            if shouldPressReturn {
                // If both autoReturn and pressReturn are set, treat as pressReturn (simulate once, clear autoReturnEnabled)
                logInfo("Simulating return key press due to pressReturn setting (auto-return was also set)")
                simulateReturnKeyPress()
            } else {
                logInfo("Simulating return key press due to auto-return")
                simulateReturnKeyPress()
            }
            autoReturnEnabled = false
        } else if shouldPressReturn {
            logInfo("Simulating return key press due to pressReturn setting")
            simulateReturnKeyPress()
        }
    }

    private func simulateReturnKeyPress() {
        let delay = globalConfigManager?.config.defaults.returnDelay ?? 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            simulateKeyDown(key: 36)
        }
    }

    private func pasteUsingClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let originalContent = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        simulateKeyDown(key: 9, flags: .maskCommand) // Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.clearContents()
            if let original = originalContent { pasteboard.setString(original, forType: .string) }
        }
    }
    
    // Version of pasteUsingClipboard that doesn't save/restore clipboard (used with ClipboardMonitor)
    private func pasteUsingClipboardNoRestore(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        simulateKeyDown(key: 9, flags: .maskCommand) // Cmd+V
    }

    private func handleConnection(clientSocket: Int32, configManager: ConfigurationManager?) {
        guard let configMgr = self.configManagerRef ?? configManager ?? globalConfigManager else {
            logError("No valid config manager"); close(clientSocket); return
        }
        defer { close(clientSocket) }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096); defer { buffer.deallocate() }
        let bytesRead = read(clientSocket, buffer, 4096)
        guard bytesRead > 0 else { logError("Failed to read from socket"); return }
        let data = Data(bytes: buffer, count: bytesRead)
        
        do {
            let commandMessage = try JSONDecoder().decode(CommandMessage.self, from: data)
            logInfo("Received command: \(commandMessage.command.rawValue)")
            var response = ""
            
            switch commandMessage.command {
            case .reloadConfig:
                if let loadedConfig = configMgr.loadConfig() {
                    configMgr.config = loadedConfig
                    configMgr.configurationSuccessfullyLoaded()
                    configMgr.onConfigChanged?(nil)
                    configMgr.resetFileWatcher()
                    response = "Configuration reloaded successfully"
                    logInfo(response)
                } else {
                    response = "Failed to reload configuration"
                    logError(response)
                }
                write(clientSocket, response, response.utf8.count)
                
            case .updateConfig:
                // Handle configuration updates
                if let arguments = commandMessage.arguments {
                    var updated = false
                    
                    // Update active action with validation (supports both new activeAction and legacy activeInsert)
                    if let activeAction = arguments["activeAction"] ?? arguments["activeInsert"] {
                        // Validate action exists if it's not empty
                        if !activeAction.isEmpty && !validateActionExists(activeAction, configManager: configMgr) {
                            response = "Error: Action '\(activeAction)' does not exist."
                            write(clientSocket, response, response.utf8.count)
                            logError("Attempted to set non-existent action: \(activeAction)")
                            notify(title: "Macrowhisper", message: "Non-existent action: \(activeAction)")
                            return
                        }
                        configMgr.config.defaults.activeAction = activeAction
                        updated = true
                    }
                    
                    if updated {
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                        response = "Configuration has been updated"
                    } else {
                        response = "No configuration changes were made"
                    }
                } else {
                    response = "Configuration has been updated"
                }
                write(clientSocket, response, response.utf8.count)
                
            case .status:
                // Gather status information
                var lines: [String] = []
                let configMgr = configManagerRef ?? globalConfigManager!
                let config = configMgr.config
                let defaults = config.defaults
                let activeActionName = defaults.activeAction ?? ""
                let icon = defaults.icon ?? ""
                let moveTo = defaults.moveTo ?? ""
                let configPathMirror = Mirror(reflecting: configMgr)
                var configPath: String? = nil
                for child in configPathMirror.children {
                    if child.label == "configPath", let value = child.value as? String {
                        configPath = value
                        break
                    }
                }
                let socketPathStr = self.socketPath
                let watcherRunning = recordingsWatcher != nil
                let folderWatcherRunning = superwhisperFolderWatcher != nil
                let watchPath = defaults.watch
                let expandedWatchPath = (watchPath as NSString).expandingTildeInPath
                let recordingsPath = "\(expandedWatchPath)/recordings"
                let recordingsFolderExists = FileManager.default.fileExists(atPath: recordingsPath)
                // Version
                lines.append("Macrowhisper version: \(APP_VERSION)")
                // Socket
                lines.append("Socket path: \(socketPathStr)")
                // Config
                lines.append("Config file: \(configPath ?? ".unknown")")
                // Watcher
                lines.append("Recordings watcher: \(watcherRunning ? "yes" : "no")")
                lines.append("Folder watcher: \(folderWatcherRunning ? "yes (waiting for recordings folder)" : "no")")
                lines.append("Superwhisper folder: \(expandedWatchPath)")
                lines.append("Recordings folder: \(recordingsPath) (exists: \(recordingsFolderExists ? "yes" : "no"))")
                // Active action
                lines.append("Active action: \(activeActionName.isEmpty ? "(none)" : activeActionName)")
                lines.append("Icon: \(icon.isEmpty ? "(none)" : icon)")
                lines.append("moveTo: \(moveTo.isEmpty ? "(none)" : moveTo)")
                // Auto-return and scheduled action
                lines.append("Auto-return: \(autoReturnEnabled ? "enabled" : "disabled")")
                lines.append("Scheduled action: \(scheduledActionName ?? "(none)")")
                // Settings
                lines.append("noUpdates: \(defaults.noUpdates ? "yes" : "no")")
                lines.append("noNoti: \(defaults.noNoti ? "yes" : "no")")
                lines.append("noEsc: \(defaults.noEsc ? "yes" : "no")")
                lines.append("simKeypress: \(defaults.simKeypress ? "yes" : "no")")
                lines.append(String(format: "actionDelay: %.2fs", defaults.actionDelay))
                lines.append("pressReturn: \(defaults.pressReturn ? "yes" : "no")")
                lines.append(String(format: "returnDelay: %.2fs", defaults.returnDelay))
                if let history = defaults.history {
                    lines.append("history retention: \(history == 0 ? "keep only most recent" : "\(history) days")")
                } else {
                    lines.append("history retention: (disabled)")
                }
                // Health checks
                if !recordingsFolderExists && !folderWatcherRunning {
                    lines.append("Warning: Recordings folder does not exist and no folder watcher is active.")
                }
                if folderWatcherRunning {
                    lines.append("Info: Waiting for recordings folder to appear at expected path.")
                }
                if watcherRunning && !recordingsFolderExists {
                    lines.append("Warning: Recordings watcher is running but recordings folder is missing!")
                }
                // Print all lines
                response = lines.joined(separator: "\n")
                write(clientSocket, response, response.utf8.count)
                
            case .debug:
                response = "Server status:\n- Socket path: \(socketPath)\n- Server socket descriptor: \(serverSocket)"
                write(clientSocket, response, response.utf8.count)
                
            case .listInserts:
                let inserts = configMgr.config.inserts
                let activeActionName = configMgr.config.defaults.activeAction ?? ""
                if inserts.isEmpty {
                    response = "No inserts configured."
                } else {
                    response = inserts.keys.sorted().map { "\($0)\($0 == activeActionName ? " (active)" : "")" }.joined(separator: "\n")
                }
                write(clientSocket, response, response.utf8.count)
                
            case .getIcon:
                let (activeType, activeAction, _) = getActiveAction(configManager: configMgr)
                var icon: String?
                
                if let action = activeAction {
                    // Get icon based on action type
                    switch activeType {
                    case .insert:
                        if let insert = action as? AppConfiguration.Insert {
                            icon = insert.icon
                        }
                    case .url:
                        if let url = action as? AppConfiguration.Url {
                            icon = url.icon
                        }
                    case .shortcut:
                        if let shortcut = action as? AppConfiguration.Shortcut {
                            icon = shortcut.icon
                        }
                    case .shell:
                        if let shell = action as? AppConfiguration.ScriptShell {
                            icon = shell.icon
                        }
                    case .appleScript:
                        if let script = action as? AppConfiguration.ScriptAppleScript {
                            icon = script.icon
                        }
                    }
                    
                    // Fall back to default if action icon is nil or empty
                    if icon == nil || icon?.isEmpty == true {
                        icon = configMgr.config.defaults.icon
                    }
                } else {
                    // No active action, use default
                    icon = configMgr.config.defaults.icon
                }
                
                // Handle special values and return appropriate response
                if icon == ".none" {
                    response = " "  // Explicit no icon
                } else if let iconValue = icon, !iconValue.isEmpty {
                    response = iconValue  // Use the icon
                } else {
                    response = " "  // No icon defined (nil or empty)
                }
                
                logInfo("Returning icon: '\(response)'")
                write(clientSocket, response, response.utf8.count)
                
            case .getInsert:
                if let insertName = commandMessage.arguments?["name"], !insertName.isEmpty {
                    if let insert = configMgr.config.inserts[insertName] {
                        if let lastValidJson = findLastValidJsonFile(configManager: configMgr) {
                            let (processedAction, _) = processInsertAction(insert.action, metaJson: lastValidJson)
                            response = processedAction
                            logInfo("Returning processed action for insert '\(insertName)'.")
                        } else {
                            response = "No valid JSON file found with results"
                            logError("No valid JSON file found for get-insert <name>")
                        }
                    } else {
                        response = "Insert not found: \(insertName)"
                        logError("Insert not found for get-insert: \(insertName)")
                    }
                } else {
                    let activeActionName = configMgr.config.defaults.activeAction ?? ""
                    if activeActionName.isEmpty {
                        response = "No active action is set."
                        logInfo("No active action is set for get-insert.")
                    } else {
                        response = activeActionName
                        logInfo("Returning active action: '\(response)'")
                    }
                }
                write(clientSocket, response, response.utf8.count)
                
            case .autoReturn:
                if let enableStr = commandMessage.arguments?["enable"], let enable = Bool(enableStr) {
                    autoReturnEnabled = enable
                    // Cancel scheduled action if auto-return is enabled
                    if enable {
                        scheduledActionName = nil
                        // Cancel scheduled action timeout
                        scheduledActionTimeoutTimer?.invalidate()
                        scheduledActionTimeoutTimer = nil
                        // Start auto-return timeout
                        startAutoReturnTimeout()
                    } else {
                        // Cancel auto-return timeout if disabling
                        cancelAutoReturnTimeout()
                    }
                    response = autoReturnEnabled ? "Auto-return enabled for next result" : "Auto-return disabled"
                    logInfo(response)
                } else {
                    response = "Missing or invalid enable parameter"
                    logError(response)
                }
                write(clientSocket, response, response.utf8.count)
                
            case .scheduleAction:
                if let actionName = commandMessage.arguments?["name"] {
                    if actionName.isEmpty {
                        // Cancel scheduled action
                        scheduledActionName = nil
                        // Cancel scheduled action timeout
                        cancelScheduledActionTimeout()
                        response = "Scheduled action cancelled"
                        logInfo("Scheduled action cancelled")
                    } else {
                        // Cancel auto-return if scheduling an action
                        autoReturnEnabled = false
                        // Cancel auto-return timeout
                        cancelAutoReturnTimeout()
                        scheduledActionName = actionName
                        // Start scheduled action timeout
                        startScheduledActionTimeout()
                        response = "Action '\(actionName)' scheduled for next recording"
                        logInfo("Action '\(actionName)' scheduled for next recording")
                    }
                } else {
                    response = "Missing action name parameter"
                    logError(response)
                }
                write(clientSocket, response, response.utf8.count)
                
            case .execInsert:
                if let insertName = commandMessage.arguments?["name"], let insert = configMgr.config.inserts[insertName] {
                    if let lastValidJson = findLastValidJsonFile(configManager: configMgr) {
                        // Ensure autoReturn and scheduled action are always false for exec-insert
                        autoReturnEnabled = false
                        scheduledActionName = nil
                        // Cancel timeouts
                        cancelAutoReturnTimeout()
                        cancelScheduledActionTimeout()
                        let (processedAction, isAutoPasteResult) = processInsertAction(insert.action, metaJson: lastValidJson)
                        applyInsertForExec(processedAction, activeInsert: insert, isAutoPaste: insert.action == ".autoPaste" || isAutoPasteResult)
                        response = "Executed insert '\(insertName)'"
                        logInfo("Successfully executed insert: \(insertName)")
                    } else {
                        response = "No valid JSON file found with results"
                        logError("No valid JSON file found for exec-insert")
                        notify(title: "Macrowhisper", message: "No valid result found for insert: \(insertName). Please check Superwhisper recordings.")
                    }
                } else {
                    response = "Insert not found or name missing"
                    logError(response)
                    notify(title: "Macrowhisper", message: "Insert not found or name missing for exec-insert.")
                }
                write(clientSocket, response, response.utf8.count)
                
            case .addUrl:
                if let name = commandMessage.arguments?["name"] {
                    if actionNameExists(name, configManager: configMgr) {
                        response = "Action name '\(name)' already exists"
                        notify(title: "Macrowhisper", message: "Action name '\(name)' already exists")
                    } else {
                        configMgr.config.urls[name] = AppConfiguration.Url(action: "", icon: "", openBackground: false)
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                        response = "URL action '\(name)' added"
                    }
                } else { response = "Missing name for URL action" }
                write(clientSocket, response, response.utf8.count)
                
            case .addShortcut:
                 if let name = commandMessage.arguments?["name"] {
                    if actionNameExists(name, configManager: configMgr) {
                        response = "Action name '\(name)' already exists"
                        notify(title: "Macrowhisper", message: "Action name '\(name)' already exists")
                    } else {
                        configMgr.config.shortcuts[name] = AppConfiguration.Shortcut(action: "", icon: "")
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                        response = "Shortcut action '\(name)' added"
                    }
                } else { response = "Missing name for Shortcut action" }
                write(clientSocket, response, response.utf8.count)
                
            case .addShell:
                 if let name = commandMessage.arguments?["name"] {
                    if actionNameExists(name, configManager: configMgr) {
                        response = "Action name '\(name)' already exists"
                        notify(title: "Macrowhisper", message: "Action name '\(name)' already exists")
                    } else {
                        configMgr.config.scriptsShell[name] = AppConfiguration.ScriptShell(action: "", icon: "")
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                        response = "Shell script action '\(name)' added"
                    }
                } else { response = "Missing name for Shell script action" }
                write(clientSocket, response, response.utf8.count)
                
            case .addAppleScript:
                 if let name = commandMessage.arguments?["name"] {
                    if actionNameExists(name, configManager: configMgr) {
                        response = "Action name '\(name)' already exists"
                        notify(title: "Macrowhisper", message: "Action name '\(name)' already exists")
                    } else {
                        configMgr.config.scriptsAS[name] = AppConfiguration.ScriptAppleScript(action: "", icon: "")
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                        response = "AppleScript action '\(name)' added"
                    }
                } else { response = "Missing name for AppleScript action" }
                write(clientSocket, response, response.utf8.count)
                
            case .addInsert:
                if let name = commandMessage.arguments?["name"] {
                    if actionNameExists(name, configManager: configMgr) {
                        response = "Action name '\(name)' already exists"
                        notify(title: "Macrowhisper", message: "Action name '\(name)' already exists")
                    } else {
                        let newInsert = AppConfiguration.Insert(action: "", icon: "")
                        configMgr.config.inserts[name] = newInsert
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                        response = "Insert '\(name)' added"
                    }
                } else {
                    response = "Missing name for insert"
                }
                write(clientSocket, response, response.utf8.count)
                
            case .removeAction:
                guard let name = commandMessage.arguments?["name"] else {
                    response = "Missing name for action"
                    write(clientSocket, response, response.utf8.count)
                    return
                }
                
                var actionRemoved = false
                var actionType = ""
                
                // Try to remove from each action type
                if configMgr.config.inserts.removeValue(forKey: name) != nil {
                    actionRemoved = true
                    actionType = "insert"
                } else if configMgr.config.urls.removeValue(forKey: name) != nil {
                    actionRemoved = true
                    actionType = "URL"
                } else if configMgr.config.shortcuts.removeValue(forKey: name) != nil {
                    actionRemoved = true
                    actionType = "shortcut"
                } else if configMgr.config.scriptsShell.removeValue(forKey: name) != nil {
                    actionRemoved = true
                    actionType = "shell script"
                } else if configMgr.config.scriptsAS.removeValue(forKey: name) != nil {
                    actionRemoved = true
                    actionType = "AppleScript"
                }
                
                if actionRemoved {
                    // Clear active action if it was the one being removed
                    if configMgr.config.defaults.activeAction == name {
                        configMgr.config.defaults.activeAction = ""
                    }
                    configMgr.saveConfig()
                    configMgr.onConfigChanged?(nil)
                    response = "\(actionType.capitalized) action '\(name)' removed"
                } else {
                    response = "Action '\(name)' not found"
                }
                write(clientSocket, response, response.utf8.count)
                
            case .version:
                response = "macrowhisper version \(APP_VERSION)"
                write(clientSocket, response, response.utf8.count)
                
            case .versionState:
                let versionChecker = VersionChecker()
                response = versionChecker.getStateString()
                write(clientSocket, response, response.utf8.count)
                
            case .forceUpdateCheck:
                let versionChecker = VersionChecker()
                versionChecker.forceUpdateCheck()
                response = "Forced update check initiated (all timing constraints reset). Check logs for results."
                write(clientSocket, response, response.utf8.count)
                
            case .versionClear:
                let versionChecker = VersionChecker()
                versionChecker.clearAllUserDefaults()
                response = "All version checker UserDefaults cleared. Next check will start fresh."
                write(clientSocket, response, response.utf8.count)
                
            // Service management commands
            case .serviceStatus:
                let serviceManager = ServiceManager()
                response = serviceManager.getServiceStatus()
                write(clientSocket, response, response.utf8.count)
                
            case .serviceInstall:
                let serviceManager = ServiceManager()
                let result = serviceManager.installService()
                response = result.message
                write(clientSocket, response, response.utf8.count)
                
            case .serviceStart:
                let serviceManager = ServiceManager()
                let result = serviceManager.startService()
                response = result.message
                write(clientSocket, response, response.utf8.count)
                
            case .serviceStop:
                let serviceManager = ServiceManager()
                let result = serviceManager.stopService()
                response = result.message
                write(clientSocket, response, response.utf8.count)
                
            case .serviceRestart:
                let serviceManager = ServiceManager()
                let result = serviceManager.restartService()
                response = result.message
                write(clientSocket, response, response.utf8.count)
                
            case .serviceUninstall:
                let serviceManager = ServiceManager()
                let result = serviceManager.uninstallService()
                response = result.message
                write(clientSocket, response, response.utf8.count)
                
            // New unified action commands
            case .listActions:
                let inserts = configMgr.config.inserts
                let urls = configMgr.config.urls
                let shortcuts = configMgr.config.shortcuts
                let shells = configMgr.config.scriptsShell
                let scripts = configMgr.config.scriptsAS
                let activeActionName = configMgr.config.defaults.activeAction ?? ""
                
                var actionsList: [String] = []
                actionsList.append(contentsOf: inserts.keys.map { "INSERT: \($0)\($0 == activeActionName ? " (active)" : "")" })
                actionsList.append(contentsOf: urls.keys.map { "URL: \($0)\($0 == activeActionName ? " (active)" : "")" })
                actionsList.append(contentsOf: shortcuts.keys.map { "SHORTCUT: \($0)\($0 == activeActionName ? " (active)" : "")" })
                actionsList.append(contentsOf: shells.keys.map { "SHELL: \($0)\($0 == activeActionName ? " (active)" : "")" })
                actionsList.append(contentsOf: scripts.keys.map { "APPLESCRIPT: \($0)\($0 == activeActionName ? " (active)" : "")" })
                
                response = actionsList.sorted().joined(separator: "\n")
                write(clientSocket, response, response.utf8.count)
                
            case .listUrls:
                let urls = configMgr.config.urls.keys.sorted()
                let activeActionName = configMgr.config.defaults.activeAction ?? ""
                response = urls.map { "\($0)\($0 == activeActionName ? " (active)" : "")" }.joined(separator: "\n")
                write(clientSocket, response, response.utf8.count)
                
            case .listShortcuts:
                let shortcuts = configMgr.config.shortcuts.keys.sorted()
                let activeActionName = configMgr.config.defaults.activeAction ?? ""
                response = shortcuts.map { "\($0)\($0 == activeActionName ? " (active)" : "")" }.joined(separator: "\n")
                write(clientSocket, response, response.utf8.count)
                
            case .listShell:
                let shells = configMgr.config.scriptsShell.keys.sorted()
                let activeActionName = configMgr.config.defaults.activeAction ?? ""
                response = shells.map { "\($0)\($0 == activeActionName ? " (active)" : "")" }.joined(separator: "\n")
                write(clientSocket, response, response.utf8.count)
                
            case .listAppleScript:
                let scripts = configMgr.config.scriptsAS.keys.sorted()
                let activeActionName = configMgr.config.defaults.activeAction ?? ""
                response = scripts.map { "\($0)\($0 == activeActionName ? " (active)" : "")" }.joined(separator: "\n")
                write(clientSocket, response, response.utf8.count)
                
            case .execAction:
                if let actionName = commandMessage.arguments?["name"] {
                    let (actionType, action) = findActionByName(actionName, configManager: configMgr)
                    
                    if let action = action {
                        if let lastValidJson = findLastValidJsonFile(configManager: configMgr) {
                            autoReturnEnabled = false
                            scheduledActionName = nil
                            // Cancel timeouts
                            cancelAutoReturnTimeout()
                            cancelScheduledActionTimeout()
                            
                            // Enhance metaJson with CLI-specific data
                            let enhancedMetaJson = enhanceMetaJsonForCLI(metaJson: lastValidJson, configManager: configMgr)
                            
                            // Execute based on action type using CLI-specific methods
                            switch actionType {
                            case .insert:
                                if let insert = action as? AppConfiguration.Insert {
                                    let (processedAction, isAutoPasteResult) = processInsertAction(insert.action, metaJson: enhancedMetaJson)
                                    applyInsertForExec(processedAction, activeInsert: insert, isAutoPaste: insert.action == ".autoPaste" || isAutoPasteResult)
                                }
                            case .url:
                                if let url = action as? AppConfiguration.Url {
                                    executeUrlForCLI(url, metaJson: enhancedMetaJson)
                                }
                            case .shortcut:
                                if let shortcut = action as? AppConfiguration.Shortcut {
                                    executeShortcutForCLI(shortcut, shortcutName: actionName, metaJson: enhancedMetaJson)
                                }
                            case .shell:
                                if let shell = action as? AppConfiguration.ScriptShell {
                                    executeShellForCLI(shell, metaJson: enhancedMetaJson)
                                }
                            case .appleScript:
                                if let script = action as? AppConfiguration.ScriptAppleScript {
                                    executeAppleScriptForCLI(script, metaJson: enhancedMetaJson)
                                }
                            }
                            
                            response = "Executed \(actionType) action '\(actionName)'"
                            logInfo("Successfully executed \(actionType) action: \(actionName)")
                        } else {
                            response = "No valid JSON file found with results"
                            logError("No valid JSON file found for exec-action")
                            notify(title: "Macrowhisper", message: "No valid result found for action: \(actionName). Please check Superwhisper recordings.")
                        }
                    } else {
                        response = "Action not found: \(actionName)"
                        logError(response)
                        notify(title: "Macrowhisper", message: "Action not found: \(actionName)")
                    }
                } else {
                    response = "Action name missing"
                    logError(response)
                }
                write(clientSocket, response, response.utf8.count)
                
            case .getAction:
                if let actionName = commandMessage.arguments?["name"], !actionName.isEmpty {
                    let (actionType, action) = findActionByName(actionName, configManager: configMgr)
                    
                    if let action = action {
                        if let lastValidJson = findLastValidJsonFile(configManager: configMgr) {
                            // Enhance metaJson with CLI-specific data
                            let enhancedMetaJson = enhanceMetaJsonForCLI(metaJson: lastValidJson, configManager: configMgr)
                            
                            // Return processed action content based on type
                            switch actionType {
                            case .insert:
                                if let insert = action as? AppConfiguration.Insert {
                                    let (processedAction, _) = processInsertAction(insert.action, metaJson: enhancedMetaJson)
                                    response = processedAction
                                    logInfo("Returning processed action for \(actionType) '\(actionName)'.")
                                }
                            case .url:
                                if let url = action as? AppConfiguration.Url {
                                    let processedAction = processAllPlaceholders(action: url.action, metaJson: enhancedMetaJson, actionType: .url)
                                    response = processedAction
                                    logInfo("Returning processed action for URL '\(actionName)'.")
                                }
                            case .shortcut:
                                if let shortcut = action as? AppConfiguration.Shortcut {
                                    let processedAction = processAllPlaceholders(action: shortcut.action, metaJson: enhancedMetaJson, actionType: .shortcut)
                                    response = processedAction
                                    logInfo("Returning processed action for shortcut '\(actionName)'.")
                                }
                            case .shell:
                                if let shell = action as? AppConfiguration.ScriptShell {
                                    let processedAction = processAllPlaceholders(action: shell.action, metaJson: enhancedMetaJson, actionType: .shell)
                                    response = processedAction
                                    logInfo("Returning processed action for shell script '\(actionName)'.")
                                }
                            case .appleScript:
                                if let script = action as? AppConfiguration.ScriptAppleScript {
                                    let processedAction = processAllPlaceholders(action: script.action, metaJson: enhancedMetaJson, actionType: .appleScript)
                                    response = processedAction
                                    logInfo("Returning processed action for AppleScript '\(actionName)'.")
                                }
                            }
                        } else {
                            response = "No valid JSON file found with results"
                            logError("No valid JSON file found for get-action <name>")
                        }
                    } else {
                        response = "Action not found: \(actionName)"
                        logError("Action not found for get-action: \(actionName)")
                    }
                } else {
                    // No action name provided, return the active action name
                    let activeActionName = configMgr.config.defaults.activeAction ?? ""
                    if activeActionName.isEmpty {
                        response = "No active action is set."
                        logInfo("No active action is set for get-action.")
                    } else {
                        response = activeActionName
                        logInfo("Returning active action: '\(response)'")
                    }
                }
                write(clientSocket, response, response.utf8.count)
                
            case .quit:
                logInfo("Received quit command, shutting down.")
                let response = "Quitting macrowhisper..."
                write(clientSocket, response, response.utf8.count)
                // Give the response a moment to flush
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    exit(0)
                }
                return
            }
        } catch {
            let response = "Failed to parse command: \(error)"
            logError(response)
            write(clientSocket, response, response.utf8.count)
        }
    }

    func sendCommand(_ command: Command, arguments: [String: String]? = nil) -> String? {
        // Check if socket file exists first - if not, no point in trying to connect
        guard FileManager.default.fileExists(atPath: socketPath) else {
            // Only return a simple failure message, no logging
            return nil
        }
        
        let message = CommandMessage(command: command, arguments: arguments)
        guard let data = try? JSONEncoder().encode(message) else { return "Failed to encode command" }
        
        let clientSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard clientSocket >= 0 else { return "Failed to create socket: \(errno)" }
        defer { close(clientSocket) }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLength = min(socketPath.utf8.count, Int(UNIX_PATH_MAX) - 1)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            socketPath.withCString { strncpy(ptr, $0, pathLength) }
        }
        
        // Try to connect - but don't spam warnings if it fails
        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(clientSocket, $0, addrSize) }
        }
        
        guard connectResult == 0 else {
            // Simply return nil if connection fails - no scary messages
            return nil
        }
        
        // Only log for debugging commands or when explicitly needed for troubleshooting
        let debugCommands: [Command] = [.debug, .versionState, .versionClear, .forceUpdateCheck]
        if debugCommands.contains(command) {
            logDebug("Sending command: \(command.rawValue) to \(socketPath)")
        }
        
        let bytesSent = write(clientSocket, data.withUnsafeBytes { $0.baseAddress }, data.count)
        guard bytesSent == data.count else {
            let err = "Failed to send complete message. Sent \(bytesSent) of \(data.count) bytes."
            logError(err); return err
        }
        
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536); defer { buffer.deallocate() }
        let bytesRead = read(clientSocket, buffer, 65536)
        
        guard bytesRead > 0 else {
            let err = "Failed to read from socket: \(errno) (\(String(cString: strerror(errno))))"
            logError(err); return err
        }
        
        return String(bytes: UnsafeBufferPointer(start: buffer, count: bytesRead), encoding: .utf8)
    }
} 
