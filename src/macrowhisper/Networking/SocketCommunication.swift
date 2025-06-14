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
    private let logger: Logger
    
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
    }
    
    struct CommandMessage: Codable {
        let command: Command
        let arguments: [String: String]?
    }
    
    init(socketPath: String, logger: Logger) {
        self.socketPath = socketPath
        self.logger = logger
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
            logger.log("Failed to create socket: \(errno)", level: .error)
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
            logger.log("Failed to bind socket: \(errno)", level: .error); close(serverSocket); return
        }
        chmod(socketPath, 0o777)
        guard listen(serverSocket, 5) == 0 else {
            logger.log("Failed to listen on socket: \(errno)", level: .error); close(serverSocket); return
        }
        server = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        server?.setEventHandler { [weak self] in
            guard let self = self else { return }
            let clientSocket = accept(self.serverSocket, nil, nil)
            guard clientSocket >= 0 else { self.logger.log("Failed to accept connection: \(errno)", level: .error); return }
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
        logger.log("Socket server started at \(socketPath)", level: .info)
    }

    func stopServer() {
        server?.cancel()
        server = nil
    }

    private func findLastValidJsonFile(configManager: ConfigurationManager) -> [String: Any]? {
        let recordingsPath = configManager.config.defaults.watch + "/recordings"
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
        var result = action
        var updatedMetaJson = metaJson
        if let llmResult = metaJson["llmResult"] as? String, !llmResult.isEmpty {
            let (cleaned, tags) = processXmlPlaceholders(action: action, llmResult: llmResult)
            updatedMetaJson["llmResult"] = cleaned
            result = replaceXmlPlaceholders(action: result, extractedTags: tags)
        } else if let regularResult = metaJson["result"] as? String, !regularResult.isEmpty {
            let (_, tags) = processXmlPlaceholders(action: action, llmResult: regularResult)
            result = replaceXmlPlaceholders(action: result, extractedTags: tags)
        }
        result = processDynamicPlaceholders(action: result, metaJson: updatedMetaJson)
        return (result.replacingOccurrences(of: "\\n", with: "\n"), false)
    }

    // This version is for the main watcher flow and respects the 'noEsc' setting
    func applyInsert(_ text: String, activeInsert: AppConfiguration.Insert?, isAutoPaste: Bool = false) {
        if text.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == ".none" {
            simulateEscKeyPress(activeInsert: activeInsert); return
        }
        let delay = activeInsert?.actionDelay ?? globalConfigManager?.config.defaults.actionDelay ?? 0.0
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if isAutoPaste {
            if !requestAccessibilityPermission() { logger.log("Accessibility permission denied", level: .warning); return }
            if !isInInputField() {
                logger.log("Auto paste - not in input field, direct paste only", level: .info)
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
        if text.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == ".none" { return }
        let delay = activeInsert?.actionDelay ?? globalConfigManager?.config.defaults.actionDelay ?? 0.0
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if isAutoPaste {
            if !requestAccessibilityPermission() { logger.log("Accessibility permission denied", level: .warning); return }
            if !isInInputField() {
                logger.log("Exec-insert auto paste - not in input field, direct paste only", level: .info)
                let pasteboard = NSPasteboard.general; pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
                simulateKeyDown(key: 9, flags: .maskCommand) // Cmd+V
                checkAndSimulatePressReturn(activeInsert: activeInsert); return
            }
        }
        // No ESC key press for exec-insert
        pasteText(text, activeInsert: activeInsert)
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
            do { try task.run(); task.waitUntilExit() } catch { logger.log("Failed to simulate keystrokes: \(error)", level: .error); pasteUsingClipboard(text) }
        } else {
            pasteUsingClipboard(text)
        }
    }
    
    private func checkAndSimulatePressReturn(activeInsert: AppConfiguration.Insert?) {
        let shouldPressReturn = activeInsert?.pressReturn ?? globalConfigManager?.config.defaults.pressReturn ?? false
        if autoReturnEnabled {
            if !shouldPressReturn {
                logger.log("Simulating return key press due to auto-return", level: .info)
                simulateReturnKeyPress()
            }
            autoReturnEnabled = false
        } else if shouldPressReturn {
            logger.log("Simulating return key press due to pressReturn setting", level: .info)
            simulateReturnKeyPress()
        }
    }

    private func simulateReturnKeyPress() {
        DispatchQueue.main.async { simulateKeyDown(key: 36) }
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

    private func handleConnection(clientSocket: Int32, configManager: ConfigurationManager?) {
        guard let configMgr = self.configManagerRef ?? configManager ?? globalConfigManager else {
            logger.log("No valid config manager", level: .error); close(clientSocket); return
        }
        defer { close(clientSocket) }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096); defer { buffer.deallocate() }
        let bytesRead = read(clientSocket, buffer, 4096)
        guard bytesRead > 0 else { logger.log("Failed to read from socket", level: .error); return }
        let data = Data(bytes: buffer, count: bytesRead)
        
        do {
            let commandMessage = try JSONDecoder().decode(CommandMessage.self, from: data)
            logger.log("Received command: \(commandMessage.command.rawValue)", level: .info)
            var response = ""
            
            switch commandMessage.command {
            case .reloadConfig:
                if let loadedConfig = configMgr.loadConfig() {
                    configMgr.config = loadedConfig
                    configMgr.configurationSuccessfullyLoaded()
                    configMgr.onConfigChanged?(nil)
                    configMgr.resetFileWatcher()
                    response = "Configuration reloaded successfully"
                    logger.log(response, level: .info)
                } else {
                    response = "Failed to reload configuration"
                    logger.log(response, level: .error)
                }
                write(clientSocket, response, response.utf8.count)
                
            case .updateConfig:
                if let args = commandMessage.arguments {
                    if let insertName = args["activeInsert"], !insertName.isEmpty, !validateInsertExists(insertName, configManager: configMgr) {
                        response = "Error: Insert '\(insertName)' does not exist."
                        write(clientSocket, response, response.utf8.count)
                        logger.log("Attempted to set non-existent insert: \(insertName)", level: .error)
                        notify(title: "Macrowhisper", message: "Non-existent insert: \(insertName)")
                        return
                    }
                    configMgr.updateFromCommandLineAsync(arguments: args) {
                        self.logger.log("Configuration updated successfully in background", level: .info)
                    }
                    response = "Configuration update queued"
                } else {
                    response = "No arguments for config update"
                }
                write(clientSocket, response, response.utf8.count)
                
            case .status:
                let status: [String: Any] = [ "version": APP_VERSION, "watcher_running": recordingsWatcher != nil, "watch_path": configMgr.config.defaults.watch ]
                if let statusData = try? JSONSerialization.data(withJSONObject: status), let statusString = String(data: statusData, encoding: .utf8) {
                    response = statusString
                } else {
                    response = "Failed to generate status"
                }
                write(clientSocket, response, response.utf8.count)
                
            case .debug:
                response = "Server status:\n- Socket path: \(socketPath)\n- Server socket descriptor: \(serverSocket)"
                write(clientSocket, response, response.utf8.count)
                
            case .listInserts:
                let inserts = configMgr.config.inserts
                let activeInsert = configMgr.config.defaults.activeInsert ?? "none"
                if inserts.isEmpty {
                    response = "No inserts configured."
                } else {
                    response = inserts.map { "\($0.key)\($0.key == activeInsert ? " (active)" : "")" }.joined(separator: "\n")
                }
                write(clientSocket, response, response.utf8.count)
                
            case .getIcon:
                let activeInsertName = configMgr.config.defaults.activeInsert
                var icon: String?
                if let activeInsertName = activeInsertName, let activeInsert = configMgr.config.inserts[activeInsertName] {
                    icon = activeInsert.icon
                } else {
                    icon = configMgr.config.defaults.icon
                }
                response = (icon == ".none" || icon == nil || icon == "") ? " " : icon!
                logger.log("Returning icon: '\(response)'", level: .info)
                write(clientSocket, response, response.utf8.count)
                
            case .getInsert:
                response = configMgr.config.defaults.activeInsert ?? " "
                logger.log("Returning active insert: '\(response)'", level: .info)
                write(clientSocket, response, response.utf8.count)
                
            case .autoReturn:
                if let enableStr = commandMessage.arguments?["enable"], let enable = Bool(enableStr) {
                    autoReturnEnabled = enable
                    response = autoReturnEnabled ? "Auto-return enabled for next result" : "Auto-return disabled"
                    logger.log(response, level: .info)
                } else {
                    response = "Missing or invalid enable parameter"
                    logger.log(response, level: .error)
                }
                write(clientSocket, response, response.utf8.count)
                
            case .execInsert:
                if let insertName = commandMessage.arguments?["name"], let insert = configMgr.config.inserts[insertName] {
                    if let lastValidJson = findLastValidJsonFile(configManager: configMgr) {
                        let (processedAction, isAutoPasteResult) = processInsertAction(insert.action, metaJson: lastValidJson)
                        applyInsertForExec(processedAction, activeInsert: insert, isAutoPaste: insert.action == ".autoPaste" || isAutoPasteResult)
                        response = "Executed insert '\(insertName)'"
                        logger.log("Successfully executed insert: \(insertName)", level: .info)
                    } else {
                        response = "No valid JSON file found with results"
                        logger.log("No valid JSON file found for exec-insert", level: .error)
                    }
                } else {
                    response = "Insert not found or name missing"
                    logger.log(response, level: .error)
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
                    if configMgr.config.defaults.activeInsert == name { configMgr.config.defaults.activeInsert = nil }
                    configMgr.saveConfig()
                    configMgr.onConfigChanged?(nil)
                    response = "Insert '\(name)' removed"
                } else {
                    response = "Insert '\(name)' not found"
                }
                write(clientSocket, response, response.utf8.count)
                
            case .version:
                response = "macrowhisper version \(APP_VERSION)"
                write(clientSocket, response, response.utf8.count)
            }
        } catch {
            let response = "Failed to parse command: \(error)"
            logger.log(response, level: .error)
            write(clientSocket, response, response.utf8.count)
        }
    }

    func sendCommand(_ command: Command, arguments: [String: String]? = nil) -> String? {
        let quietCommands: [Command] = [.status, .version, .listInserts, .getIcon, .getInsert]
        if !quietCommands.contains(command) {
            logger.log("Sending command: \(command.rawValue) to \(socketPath)", level: .info)
        }
        
        guard FileManager.default.fileExists(atPath: socketPath) else {
            logger.log("Socket file does not exist", level: .error)
            return "Socket file does not exist. Server is not running."
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
        
        var connectResult: Int32 = -1
        for attempt in 1...3 {
            let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
            connectResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(clientSocket, $0, addrSize) }
            }
            if connectResult == 0 { break }
            logger.log("Connect attempt \(attempt) failed: \(errno). Retrying...", level: .warning)
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        guard connectResult == 0 else {
            return "Failed to connect to socket: \(errno) (\(String(cString: strerror(errno)))). Is server running?"
        }
        
        let bytesSent = write(clientSocket, data.withUnsafeBytes { $0.baseAddress }, data.count)
        guard bytesSent == data.count else {
            let err = "Failed to send complete message. Sent \(bytesSent) of \(data.count) bytes."
            logger.log(err, level: .error); return err
        }
        
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096); defer { buffer.deallocate() }
        let bytesRead = read(clientSocket, buffer, 4096)
        
        guard bytesRead > 0 else {
            let err = "Failed to read from socket: \(errno) (\(String(cString: strerror(errno))))"
            logger.log(err, level: .error); return err
        }
        
        return String(bytes: UnsafeBufferPointer(start: buffer, count: bytesRead), encoding: .utf8)
    }
} 