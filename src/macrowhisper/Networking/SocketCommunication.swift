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
        case listInserts
        case addInsert
        case removeInsert
        case getIcon
        case getInsert
        case autoReturn
        case execInsert
        case addUrl
        case addShortcut
        case addShell
        case addAppleScript
        case removeUrl
        case removeShortcut
        case removeShell
        case removeAppleScript
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
               let result = json["result"], !(result is NSNull), !String(describing: result).isEmpty {
                return json
            }
        }
        return nil
    }

    private func validateInsertExists(_ insertName: String, configManager: ConfigurationManager) -> Bool {
        if insertName.isEmpty { return true }
        return configManager.config.inserts[insertName] != nil
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
        
        // Check if clipboard restoration is disabled
        let restoreClipboard = globalConfigManager?.config.defaults.restoreClipboard ?? true
        
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

    private func pasteText(_ text: String, activeInsert: AppConfiguration.Insert?) {
        let shouldSimulate = activeInsert?.simKeypress ?? globalConfigManager?.config.defaults.simKeypress ?? false
        if shouldSimulate {
            let lines = text.components(separatedBy: "\n")
            let scriptLines = lines.enumerated().map { index, line -> String in
                let escapedLine = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                return (index > 0 ? "keystroke return\n" : "") + "keystroke \"\(escapedLine)\""
            }.joined(separator: "\n")
            let script = "tell application \"System Events\"\n\(scriptLines)\nend tell"
            let task = Process(); task.launchPath = "/usr/bin/osascript"; task.arguments = ["-e", script]
            do { try task.run(); task.waitUntilExit() } catch { logError("Failed to simulate keystrokes: \(error)"); pasteUsingClipboard(text) }
        } else {
            pasteUsingClipboard(text)
        }
    }
    
    // Version of pasteText that doesn't save/restore clipboard (used with ClipboardMonitor)
    private func pasteTextNoRestore(_ text: String, activeInsert: AppConfiguration.Insert?) {
        let shouldSimulate = activeInsert?.simKeypress ?? globalConfigManager?.config.defaults.simKeypress ?? false
        if shouldSimulate {
            let lines = text.components(separatedBy: "\n")
            let scriptLines = lines.enumerated().map { index, line -> String in
                let escapedLine = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                return (index > 0 ? "keystroke return\n" : "") + "keystroke \"\(escapedLine)\""
            }.joined(separator: "\n")
            let script = "tell application \"System Events\"\n\(scriptLines)\nend tell"
            let task = Process(); task.launchPath = "/usr/bin/osascript"; task.arguments = ["-e", script]
            do { try task.run(); task.waitUntilExit() } catch { logError("Failed to simulate keystrokes: \(error)"); pasteUsingClipboardNoRestore(text) }
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
                    
                    // Update active insert with validation
                    if let activeInsert = arguments["activeInsert"] {
                        // Validate insert exists if it's not empty
                        if !activeInsert.isEmpty && !validateInsertExists(activeInsert, configManager: configMgr) {
                            response = "Error: Insert '\(activeInsert)' does not exist."
                            write(clientSocket, response, response.utf8.count)
                            logError("Attempted to set non-existent insert: \(activeInsert)")
                            notify(title: "Macrowhisper", message: "Non-existent insert: \(activeInsert)")
                            return
                        }
                        configMgr.config.defaults.activeInsert = activeInsert
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
                let activeInsert = defaults.activeInsert ?? ""
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
                // Active insert
                lines.append("Active insert: \(activeInsert.isEmpty ? "(none)" : activeInsert)")
                lines.append("Icon: \(icon.isEmpty ? "(none)" : icon)")
                lines.append("moveTo: \(moveTo.isEmpty ? "(none)" : moveTo)")
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
                let activeInsert = configMgr.config.defaults.activeInsert ?? ""
                let displayActiveInsert = activeInsert.isEmpty ? "none" : activeInsert
                if inserts.isEmpty {
                    response = "No inserts configured."
                } else {
                    response = inserts.map { "\($0.key)\($0.key == displayActiveInsert ? " (active)" : "")" }.joined(separator: "\n")
                }
                write(clientSocket, response, response.utf8.count)
                
            case .getIcon:
                let activeInsertName = configMgr.config.defaults.activeInsert
                var icon: String?
                
                // Check if there's an active insert and get its icon
                if let activeInsertName = activeInsertName, !activeInsertName.isEmpty, let activeInsert = configMgr.config.inserts[activeInsertName] {
                    if let insertIcon = activeInsert.icon, !insertIcon.isEmpty {
                        // Insert has an explicit icon value (including ".none")
                        icon = insertIcon
                    } else {
                        // Insert icon is nil or empty, fall back to default
                        icon = configMgr.config.defaults.icon
                    }
                } else {
                    // No active insert, use default
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
                    let activeInsert = configMgr.config.defaults.activeInsert ?? ""
                    if activeInsert.isEmpty {
                        response = "No active insert is set."
                        logInfo("No active insert is set for get-insert.")
                    } else {
                        response = activeInsert
                        logInfo("Returning active insert: '\(response)'")
                    }
                }
                write(clientSocket, response, response.utf8.count)
                
            case .autoReturn:
                if let enableStr = commandMessage.arguments?["enable"], let enable = Bool(enableStr) {
                    autoReturnEnabled = enable
                    response = autoReturnEnabled ? "Auto-return enabled for next result" : "Auto-return disabled"
                    logInfo(response)
                } else {
                    response = "Missing or invalid enable parameter"
                    logError(response)
                }
                write(clientSocket, response, response.utf8.count)
                
            case .execInsert:
                if let insertName = commandMessage.arguments?["name"], let insert = configMgr.config.inserts[insertName] {
                    if let lastValidJson = findLastValidJsonFile(configManager: configMgr) {
                        // Ensure autoReturn is always false for exec-insert
                        autoReturnEnabled = false
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
                    if configMgr.config.urls[name] == nil {
                        configMgr.config.urls[name] = AppConfiguration.Url(action: "")
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                        response = "URL action '\(name)' added"
                    } else {
                        response = "URL action '\(name)' already exists"
                    }
                } else { response = "Missing name for URL action" }
                write(clientSocket, response, response.utf8.count)
                
            case .addShortcut:
                 if let name = commandMessage.arguments?["name"] {
                    if configMgr.config.shortcuts[name] == nil {
                        configMgr.config.shortcuts[name] = AppConfiguration.Shortcut(action: "")
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                        response = "Shortcut action '\(name)' added"
                    } else {
                        response = "Shortcut action '\(name)' already exists"
                    }
                } else { response = "Missing name for Shortcut action" }
                write(clientSocket, response, response.utf8.count)
                
            case .addShell:
                 if let name = commandMessage.arguments?["name"] {
                    if configMgr.config.scriptsShell[name] == nil {
                        configMgr.config.scriptsShell[name] = AppConfiguration.ScriptShell(action: "")
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                        response = "Shell script action '\(name)' added"
                    } else {
                        response = "Shell script action '\(name)' already exists"
                    }
                } else { response = "Missing name for Shell script action" }
                write(clientSocket, response, response.utf8.count)
                
            case .addAppleScript:
                 if let name = commandMessage.arguments?["name"] {
                    if configMgr.config.scriptsAS[name] == nil {
                        configMgr.config.scriptsAS[name] = AppConfiguration.ScriptAppleScript(action: "")
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                        response = "AppleScript action '\(name)' added"
                    } else {
                        response = "AppleScript action '\(name)' already exists"
                    }
                } else { response = "Missing name for AppleScript action" }
                write(clientSocket, response, response.utf8.count)
                
            case .addInsert:
                if let name = commandMessage.arguments?["name"] {
                    if configMgr.config.inserts[name] == nil {
                        let newInsert = AppConfiguration.Insert(action: "", icon: "")
                        configMgr.config.inserts[name] = newInsert
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                        response = "Insert '\(name)' added"
                    } else {
                        response = "Insert '\(name)' already exists"
                    }
                } else {
                    response = "Missing name for insert"
                }
                write(clientSocket, response, response.utf8.count)
                
            case .removeInsert:
                 guard let name = commandMessage.arguments?["name"] else {
                    response = "Missing name for action"; write(clientSocket, response, response.utf8.count); return
                }
                if configMgr.config.inserts.removeValue(forKey: name) != nil {
                    if configMgr.config.defaults.activeInsert == name { configMgr.config.defaults.activeInsert = "" }
                    configMgr.saveConfig()
                    configMgr.onConfigChanged?(nil)
                    response = "Insert '\(name)' removed"
                } else {
                    response = "Insert '\(name)' not found"
                }
                write(clientSocket, response, response.utf8.count)
                
            case .removeUrl:
                guard let name = commandMessage.arguments?["name"] else {
                    response = "Missing name for URL action"; write(clientSocket, response, response.utf8.count); return
                }
                if configMgr.config.urls.removeValue(forKey: name) != nil {
                    configMgr.saveConfig()
                    configMgr.onConfigChanged?(nil)
                    response = "URL action '\(name)' removed"
                } else {
                    response = "URL action '\(name)' not found"
                }
                write(clientSocket, response, response.utf8.count)
                
            case .removeShortcut:
                guard let name = commandMessage.arguments?["name"] else {
                    response = "Missing name for Shortcut action"; write(clientSocket, response, response.utf8.count); return
                }
                if configMgr.config.shortcuts.removeValue(forKey: name) != nil {
                    configMgr.saveConfig()
                    configMgr.onConfigChanged?(nil)
                    response = "Shortcut action '\(name)' removed"
                } else {
                    response = "Shortcut action '\(name)' not found"
                }
                write(clientSocket, response, response.utf8.count)
                
            case .removeShell:
                guard let name = commandMessage.arguments?["name"] else {
                    response = "Missing name for Shell script action"; write(clientSocket, response, response.utf8.count); return
                }
                if configMgr.config.scriptsShell.removeValue(forKey: name) != nil {
                    configMgr.saveConfig()
                    configMgr.onConfigChanged?(nil)
                    response = "Shell script action '\(name)' removed"
                } else {
                    response = "Shell script action '\(name)' not found"
                }
                write(clientSocket, response, response.utf8.count)
                
            case .removeAppleScript:
                guard let name = commandMessage.arguments?["name"] else {
                    response = "Missing name for AppleScript action"; write(clientSocket, response, response.utf8.count); return
                }
                if configMgr.config.scriptsAS.removeValue(forKey: name) != nil {
                    configMgr.saveConfig()
                    configMgr.onConfigChanged?(nil)
                    response = "AppleScript action '\(name)' removed"
                } else {
                    response = "AppleScript action '\(name)' not found"
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
        
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096); defer { buffer.deallocate() }
        let bytesRead = read(clientSocket, buffer, 4096)
        
        guard bytesRead > 0 else {
            let err = "Failed to read from socket: \(errno) (\(String(cString: strerror(errno))))"
            logError(err); return err
        }
        
        return String(bytes: UnsafeBufferPointer(start: buffer, count: bytesRead), encoding: .utf8)
    }
} 
