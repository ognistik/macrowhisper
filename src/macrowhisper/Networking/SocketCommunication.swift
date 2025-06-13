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
        return configManager.config.inserts.contains { $0.name == insertName }
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
            if !requestAccessibilityPermission() { logWarning("Accessibility permission denied"); return }
            if !isInInputField() {
                logInfo("Auto paste - not in input field, direct paste only")
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
            if !requestAccessibilityPermission() { logWarning("Accessibility permission denied"); return }
            if !isInInputField() {
                logInfo("Exec-insert auto paste - not in input field, direct paste only")
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
            do { try task.run(); task.waitUntilExit() } catch { logError("Failed to simulate keystrokes: \(error)"); pasteUsingClipboard(text) }
        } else {
            pasteUsingClipboard(text)
        }
    }
    
    private func checkAndSimulatePressReturn(activeInsert: AppConfiguration.Insert?) {
        var shouldPressReturn = activeInsert?.pressReturn ?? globalConfigManager?.config.defaults.pressReturn ?? false
        if autoReturnEnabled {
            if !shouldPressReturn {
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
                    configMgr.onConfigChanged?(nil)
                    response = "Configuration reloaded"
                } else {
                    response = "Failed to reload configuration"
                }
                
            case .updateConfig:
                if let args = commandMessage.arguments {
                    if let insertName = args["activeInsert"], !validateInsertExists(insertName, configManager: configMgr) {
                        response = "Error: Insert '\(insertName)' does not exist."
                    } else {
                        configMgr.updateFromCommandLineAsync(arguments: args, completion: nil)
                        response = "Configuration update queued"
                    }
                } else {
                    response = "No arguments for update"
                }
                
            case .status:
                let status: [String: Any] = ["version": APP_VERSION, "watch_path": configMgr.config.defaults.watch]
                if let statusData = try? JSONSerialization.data(withJSONObject: status), let statusString = String(data: statusData, encoding: .utf8) {
                    response = statusString
                } else {
                    response = "Failed to generate status"
                }
                
            case .version:
                response = "macrowhisper version \(APP_VERSION)"
                
            case .debug:
                response = "Server status: OK"
                
            case .listInserts:
                let inserts = configMgr.config.inserts
                if inserts.isEmpty {
                    response = "No inserts configured."
                } else {
                    response = inserts.map { "\($0.name)\($0.name == configMgr.config.defaults.activeInsert ? " (active)" : "")" }.joined(separator: "\n")
                }
                
            case .addInsert:
                if let name = commandMessage.arguments?["name"] {
                    var inserts = configMgr.config.inserts
                    if !inserts.contains(where: { $0.name == name }) {
                        inserts.append(AppConfiguration.Insert(name: name, action: ""))
                        configMgr.config.inserts = inserts
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                    }
                    response = "Insert '\(name)' added/updated"
                } else {
                    response = "Missing name for insert"
                }
                
            case .removeInsert:
                if let name = commandMessage.arguments?["name"] {
                    var inserts = configMgr.config.inserts
                    let initialCount = inserts.count
                    inserts.removeAll { $0.name == name }
                    if inserts.count < initialCount {
                        configMgr.config.inserts = inserts
                        if configMgr.config.defaults.activeInsert == name {
                            configMgr.config.defaults.activeInsert = nil
                        }
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                        response = "Insert '\(name)' removed"
                    } else {
                        response = "Insert '\(name)' not found"
                    }
                } else {
                    response = "No insert name provided"
                }
                
            case .getIcon:
                if let activeInsertName = configMgr.config.defaults.activeInsert, !activeInsertName.isEmpty, let activeInsert = configMgr.config.inserts.first(where: { $0.name == activeInsertName }) {
                    response = activeInsert.icon ?? configMgr.config.defaults.icon ?? " "
                } else {
                    response = configMgr.config.defaults.icon ?? " "
                }
                if response.isEmpty { response = " " }


            case .getInsert:
                response = configMgr.config.defaults.activeInsert ?? " "
                
            case .autoReturn:
                if let enableStr = commandMessage.arguments?["enable"], let enable = Bool(enableStr) {
                    autoReturnEnabled = enable
                    response = "Auto-return \(enable ? "enabled" : "disabled") for next interaction."
                } else {
                    response = "Missing or invalid 'enable' parameter for auto-return."
                }
                
            case .execInsert:
                if let name = commandMessage.arguments?["name"], let insert = configMgr.config.inserts.first(where: { $0.name == name }) {
                    if let json = findLastValidJsonFile(configManager: configMgr) {
                        let (processed, isAuto) = processInsertAction(insert.action, metaJson: json)
                        applyInsertForExec(processed, activeInsert: insert, isAutoPaste: isAuto)
                        response = "Executed insert '\(name)'"
                    } else {
                        response = "No valid recent transcription found to execute insert '\(name)'."
                    }
                } else {
                    response = "Insert name missing or not found for exec-insert."
                }

            case .addUrl:
                if let name = commandMessage.arguments?["name"] {
                    var urls = configMgr.config.urls
                    if !urls.contains(where: { $0.name == name }) {
                        urls.append(AppConfiguration.Url(name: name, action: ""))
                        configMgr.config.urls = urls
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                    }
                    response = "URL action '\(name)' added/updated"
                } else { response = "Missing name for URL action" }

            case .addShortcut:
                 if let name = commandMessage.arguments?["name"] {
                    var shortcuts = configMgr.config.shortcuts
                    if !shortcuts.contains(where: { $0.name == name }) {
                        shortcuts.append(AppConfiguration.Shortcut(name: name, action: ""))
                        configMgr.config.shortcuts = shortcuts
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                    }
                    response = "Shortcut action '\(name)' added/updated"
                } else { response = "Missing name for Shortcut action" }

            case .addShell:
                 if let name = commandMessage.arguments?["name"] {
                    var scripts = configMgr.config.scriptsShell
                    if !scripts.contains(where: { $0.name == name }) {
                        scripts.append(AppConfiguration.ScriptShell(name: name, action: ""))
                        configMgr.config.scriptsShell = scripts
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                    }
                    response = "Shell script action '\(name)' added/updated"
                } else { response = "Missing name for Shell script action" }

            case .addAppleScript:
                 if let name = commandMessage.arguments?["name"] {
                    var scripts = configMgr.config.scriptsAS
                    if !scripts.contains(where: { $0.name == name }) {
                        scripts.append(AppConfiguration.ScriptAppleScript(name: name, action: ""))
                        configMgr.config.scriptsAS = scripts
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                    }
                    response = "AppleScript action '\(name)' added/updated"
                } else { response = "Missing name for AppleScript action" }
            }
            
            write(clientSocket, response, response.utf8.count)
        } catch {
            logError("Failed to parse command: \(error)")
            let response = "Failed to parse command: \(error)"
            write(clientSocket, response, response.utf8.count)
        }
    }

    func sendCommand(_ command: Command, arguments: [String: String]? = nil) -> String? {
        if !FileManager.default.fileExists(atPath: socketPath) { return "Socket file does not exist." }
        let message = CommandMessage(command: command, arguments: arguments)
        guard let data = try? JSONEncoder().encode(message) else { return "Failed to encode command" }
        let clientSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard clientSocket >= 0 else { return "Failed to create socket" }
        defer { close(clientSocket) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let pathLength = min(socketPath.utf8.count, Int(UNIX_PATH_MAX) - 1)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in socketPath.withCString { strncpy(ptr, $0, pathLength) } }
        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(clientSocket, $0, addrSize) } }
        guard connectResult == 0 else { return "Failed to connect to socket" }
        let bytesSent = write(clientSocket, data.withUnsafeBytes { $0.baseAddress }, data.count)
        guard bytesSent == data.count else { return "Failed to send complete message" }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024); defer { buffer.deallocate() }
        let bytesRead = read(clientSocket, buffer, 1024)
        guard bytesRead > 0 else { return "Failed to read response" }
        return String(bytes: UnsafeBufferPointer(start: buffer, count: bytesRead), encoding: .utf8)
    }
} 