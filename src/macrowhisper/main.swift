#!/usr/bin/env swift

import Foundation
import Swifter
import Dispatch
import Darwin
import UserNotifications
import ApplicationServices
import Cocoa
import Carbon.HIToolbox

let APP_VERSION = "1.0.0"
private let UNIX_PATH_MAX = 104

// MARK: - Socket Communication System

// Socket helper function - completely bypasses the Unix socket system
func ensureSocketWorks() {
    // First check if socket file exists, if yes, remove it
    if FileManager.default.fileExists(atPath: "/tmp/macrowhisper.sock") {
        try? FileManager.default.removeItem(atPath: "/tmp/macrowhisper.sock")
        print("Removed existing socket file")
    }
    
    // Make sure the directory exists
    try? FileManager.default.createDirectory(atPath: "/tmp", withIntermediateDirectories: true)
    
    // Create a dummy file to use for basic IPC
    FileManager.default.createFile(atPath: "/tmp/macrowhisper.sock", contents: nil)
    
    // Set permissions so any process can access it
    try? FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: "/tmp/macrowhisper.sock")
    
    // Log success
    print("Created socket file at /tmp/macrowhisper.sock")
}

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
    }
    
    struct CommandMessage: Codable {
        let command: Command
        let arguments: [String: String]?
    }
    
    init(socketPath: String) {
        self.socketPath = socketPath
    }
    
    func startServer(configManager: ConfigurationManager) {
        // Store a strong reference to configManager
        self.configManagerRef = configManager
        
        // First make sure socket directory exists
        let socketDir = (socketPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: socketDir) {
            do {
                try FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                logError("Failed to create socket directory: \(error)")
            }
        }
        
        // First, make sure any existing socket file is removed
        if FileManager.default.fileExists(atPath: socketPath) {
            do {
                try FileManager.default.removeItem(atPath: socketPath)
                logInfo("Removed existing socket file")
            } catch {
                logError("Failed to remove existing socket file: \(error)")
            }
        }
        
        // Create the socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        if serverSocket < 0 {
            logError("Failed to create socket: \(errno)")
            return
        }
        
        // Log more details during server setup
        logInfo("Socket created with descriptor: \(serverSocket)")
        
        // Set up the socket address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        
        // Copy the path to the socket address
        let pathLength = min(socketPath.utf8.count, Int(UNIX_PATH_MAX) - 1)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            socketPath.withCString {
                strncpy(ptr, $0, pathLength)
            }
        }
        
        // Bind the socket
        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, addrSize)
            }
        }
        
        if bindResult != 0 {
            logError("Failed to bind socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }
        
        logInfo("Socket bound successfully")
        
        // Set permissions on the socket file
        chmod(socketPath, 0o777)
        logInfo("Set socket file permissions to 0777")
        
        // Listen for connections
        if listen(serverSocket, 5) != 0 {
            logError("Failed to listen on socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }
        
        logInfo("Socket listening successfully")
        
        // Create a dispatch source for the socket
        server = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        
        // Set up the event handler with a strong capture of configManager
        server?.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            // Accept the connection
            let clientSocket = accept(self.serverSocket, nil, nil)
            if clientSocket < 0 {
                logError("Failed to accept connection: \(errno)")
                return
            }
            
            // Handle the connection in a background queue
            self.queue.async {
                self.handleConnection(clientSocket: clientSocket, configManager: globalConfigManager)
            }
        }
        
        // Set up the cancel handler
        server?.setCancelHandler { [weak self] in
            guard let self = self else { return }
            close(self.serverSocket)
            self.serverSocket = -1
            try? FileManager.default.removeItem(atPath: self.socketPath)
        }
        
        // Resume the dispatch source
        server?.resume()
        logInfo("Socket server started at \(socketPath) with descriptor \(serverSocket)")
    }

    private func findLastValidJsonFile(configManager: ConfigurationManager) -> [String: Any]? {
        let recordingsPath = configManager.config.defaults.watch + "/recordings"
        
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: recordingsPath),
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            return nil
        }
        
        // Filter for directories only and sort by creation date (newest first)
        let directories = contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }.sorted { dir1, dir2 in
            let date1 = try? dir1.resourceValues(forKeys: [.creationDateKey]).creationDate
            let date2 = try? dir2.resourceValues(forKeys: [.creationDateKey]).creationDate
            return (date1 ?? Date.distantPast) > (date2 ?? Date.distantPast)
        }
        
        // Look for the first directory with a valid meta.json that has results
        for directory in directories {
            let metaJsonPath = directory.appendingPathComponent("meta.json").path
            
            if FileManager.default.fileExists(atPath: metaJsonPath),
               let data = try? Data(contentsOf: URL(fileURLWithPath: metaJsonPath)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                
                // Check if result key exists and has a non-null, non-empty value
                if let result = json["result"],
                   !(result is NSNull),
                   !String(describing: result).isEmpty {
                    return json
                }
            }
        }
        
        return nil
    }
    
    private func validateInsertExists(_ insertName: String, configManager: ConfigurationManager) -> Bool {
        // Empty string is valid (means disable active insert)
        if insertName.isEmpty {
            return true
        }
        
        // Check if insert exists in configuration
        return configManager.config.inserts.contains { $0.name == insertName }
    }

    private func processInsertAction(_ action: String, metaJson: [String: Any]) -> (String, Bool) {
        // Check if this is the special .autoPaste action
        let isAutoPaste = action == ".autoPaste"
        
        // If action is ".none", return empty string
        if action == ".none" {
            return ("", false)
        }
        
        // For .autoPaste, we'll use the swResult value directly
        if isAutoPaste {
            let swResult: String
            if let llm = metaJson["llmResult"] as? String, !llm.isEmpty {
                swResult = llm
            } else if let res = metaJson["result"] as? String, !res.isEmpty {
                swResult = res
            } else {
                swResult = ""
            }
            return (swResult, true)
        }
        
        var result = action
        
        // Process XML tags in llmResult if present
        var processedLlmResult = ""
        var extractedTags: [String: String] = [:]
        
        if let llmResult = metaJson["llmResult"] as? String, !llmResult.isEmpty {
            // Process XML tags and get cleaned llmResult and extracted tags
            let processed = processXmlPlaceholders(action: action, llmResult: llmResult)
            processedLlmResult = processed.0
            extractedTags = processed.1
            
            // Update the metaJson with the cleaned llmResult
            var updatedMetaJson = metaJson
            updatedMetaJson["llmResult"] = processedLlmResult
            
            // If swResult would be derived from llmResult, update it too
            if metaJson["result"] == nil || (metaJson["result"] as? String)?.isEmpty == true {
                updatedMetaJson["swResult"] = processedLlmResult
            }
            
            // Process all dynamic placeholders using updatedMetaJson
            result = processDynamicPlaceholders(action: result, metaJson: updatedMetaJson)
        } else {
            // No llmResult to process, just handle regular placeholders
            result = processDynamicPlaceholders(action: result, metaJson: metaJson)
            
            // Process XML placeholders with regular result if llmResult doesn't exist
            if let regularResult = metaJson["result"] as? String, !regularResult.isEmpty {
                let processed = processXmlPlaceholders(action: action, llmResult: regularResult)
                extractedTags = processed.1
            }
        }
        
        // Replace XML placeholders with extracted content or remove them
        result = replaceXmlPlaceholders(action: result, extractedTags: extractedTags)
        
        // Process newlines - convert literal "\n" to actual newlines
        result = result.replacingOccurrences(of: "\\n", with: "\n")
        
        return (result, false)
    }

    private func applyInsertDirectly(_ text: String, activeInsert: AppConfiguration.Insert?, isAutoPaste: Bool = false) {
        // If text is empty or just whitespace, do nothing (no ESC press as requested)
        if text.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == ".none" {
            return
        }
        
        // Get the delay value - insert-specific overrides global default
        let delay: Double
        if let insert = activeInsert, let insertDelay = insert.actionDelay {
            delay = insertDelay
        } else {
            delay = globalConfigManager?.config.defaults.actionDelay ?? 0.0
        }
        
        // Apply delay if it's greater than 0
        if delay > 0 {
            logInfo("Applying configured delay of \(delay) seconds before exec-insert action")
            Thread.sleep(forTimeInterval: delay)
        }
        
        // For .autoPaste, check if we're in an input field
        if isAutoPaste {
            if !requestAccessibilityPermission() {
                logWarning("Accessibility permission denied - cannot check for input field")
                return
            }
            
            let inInputField = isInInputField()
            
            if !inInputField {
                logInfo("Exec-insert auto paste - not in an input field, proceeding with direct paste only")
                
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                
                self.simulateKeyDown(key: 9, flags: .maskCommand) // 9 is the keycode for 'V'
                
                // Check for pressReturn after auto paste
                checkAndSimulatePressReturnForExecInsert(activeInsert: activeInsert)
                return
            }
            
            logInfo("Exec-insert auto paste - in input field, proceeding with standard paste")
        }
        
        // NO ESC key press as requested by user
        
        // Check if we should simulate key presses
        let shouldSimulateKeypresses: Bool
        if let insert = activeInsert, let insertSimKeypress = insert.simKeypress {
            shouldSimulateKeypresses = insertSimKeypress
        } else {
            shouldSimulateKeypresses = globalConfigManager?.config.defaults.simKeypress ?? false
        }
        
        if shouldSimulateKeypresses {
            let lines = text.components(separatedBy: "\n")
            
            let scriptLines = lines.enumerated().map { index, line -> String in
                let escapedLine = line.replacingOccurrences(of: "\\", with: "\\\\")
                                     .replacingOccurrences(of: "\"", with: "\\\"")
                
                if index > 0 {
                    return "keystroke return\nkeystroke \"\(escapedLine)\""
                } else {
                    return "keystroke \"\(escapedLine)\""
                }
            }.joined(separator: "\n")
            
            let script = """
            tell application "System Events"
                \(scriptLines)
            end tell
            """
            
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            
            do {
                try task.run()
                task.waitUntilExit()
                logInfo("Applied exec-insert text using simulated keystrokes")
            } catch {
                logError("Failed to simulate keystrokes for exec-insert: \(error.localizedDescription)")
                self.pasteUsingClipboardDirectly(text)
            }
        } else {
            self.pasteUsingClipboardDirectly(text)
        }
        
        // Check for pressReturn after exec-insert
        checkAndSimulatePressReturnForExecInsert(activeInsert: activeInsert)
    }

    private func checkAndSimulatePressReturnForExecInsert(activeInsert: AppConfiguration.Insert?) {
        // Check if pressReturn should be applied
        let shouldPressReturn: Bool
        
        // autoReturn always takes precedence
        if autoReturnEnabled {
            // autoReturn will handle its own return press, so we don't interfere
            return
        }
        
        // Check insert-specific pressReturn setting first
        if let insert = activeInsert, let insertPressReturn = insert.pressReturn {
            shouldPressReturn = insertPressReturn
        } else {
            // Fall back to global default
            shouldPressReturn = globalConfigManager?.config.defaults.pressReturn ?? false
        }
        
        if shouldPressReturn {
            logInfo("Simulating return key press due to pressReturn setting for exec-insert")
            self.simulateReturnKeyPress()
        }
    }
    
    private func simulateReturnKeyPress() {
        // Add a delay before simulating the Return key press
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { // delay
            // 36 is the keycode for Return key
            self.simulateKeyDown(key: 36)
        }
    }

    private func pasteUsingClipboardDirectly(_ text: String) {
        let pasteboard = NSPasteboard.general
        let originalClipboardContent = pasteboard.string(forType: .string)
        
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // Paste using accessibility APIs
        self.simulateKeyDown(key: 9, flags: .maskCommand) // 9 is the keycode for 'V'
        
        // Restore the original clipboard content after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.clearContents()
            if let originalContent = originalClipboardContent {
                pasteboard.setString(originalContent, forType: .string)
            }
        }
    }

    private func simulateKeyDown(key: Int, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode = CGKeyCode(key)
        
        let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDownEvent?.flags = flags

        let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUpEvent?.flags = flags

        keyDownEvent?.post(tap: .cghidEventTap)
        keyUpEvent?.post(tap: .cghidEventTap)
    }
    
    private func handleConnection(clientSocket: Int32, configManager: ConfigurationManager?) {
        let safeConfigManager = self.configManagerRef ?? configManager ?? globalConfigManager

        // Check if socket is valid
        var error = 0
        var len = socklen_t(MemoryLayout<Int>.size)
        if getsockopt(clientSocket, SOL_SOCKET, SO_ERROR, &error, &len) != 0 || error != 0 {
            logError("Socket error detected in handleConnection: \(error)")
            close(clientSocket)
            return
        }

        guard let configMgr = safeConfigManager else {
            logError("CRITICAL ERROR: No valid configuration manager available")
            let response = "Server error: Configuration manager unavailable"
            write(clientSocket, response, response.utf8.count)
            return
        }
        
        defer {
            close(clientSocket)
        }
        
        // Read from the socket
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer {
            buffer.deallocate()
        }
        
        let bytesRead = read(clientSocket, buffer, bufferSize)
        guard bytesRead > 0 else {
            logError("Failed to read from socket or connection closed")
            return
        }
        
        // Convert the bytes to a string
        let data = Data(bytes: buffer, count: bytesRead)
        
        do {
            // Parse the command
            let commandMessage = try JSONDecoder().decode(CommandMessage.self, from: data)
            
            logInfo("Received command: \(commandMessage.command.rawValue)")
            
            // Handle the command
            switch commandMessage.command {

            case .listInserts:
                logInfo("Received command to list inserts")
                
                let inserts = configMgr.config.inserts
                let activeInsert = configMgr.config.defaults.activeInsert ?? "none"
                
                if inserts.isEmpty {
                    let response = "No inserts configured."
                    write(clientSocket, response, response.utf8.count)
                } else {
                    var response = ""
                    for insert in inserts {
                                let isActive = insert.name == activeInsert ? " (active)" : ""
                                response += "\(insert.name)\(isActive)\n"
                    }
                    // Remove the trailing newline
                    response = String(response.dropLast())
                    write(clientSocket, response, response.utf8.count)
                }

            case .addInsert:
                logInfo("Received command to add insert")
                
                if let name = commandMessage.arguments?["name"] {
                    // Check if insert with this name already exists
                    var inserts = configMgr.config.inserts
                    if let index = inserts.firstIndex(where: { $0.name == name }) {
                        // Update existing insert
                        inserts[index] = AppConfiguration.Insert(name: name, action: "")
                        configMgr.config.inserts = inserts
                        configMgr.saveConfig()
                        
                        let response = "Insert '\(name)' updated"
                        write(clientSocket, response, response.utf8.count)
                    } else {
                        // Add new insert
                        inserts.append(AppConfiguration.Insert(name: name, action: ""))
                        configMgr.config.inserts = inserts
                        configMgr.saveConfig()
                        
                        let response = "Insert '\(name)' added"
                        write(clientSocket, response, response.utf8.count)
                    }
                    
                    // Trigger config changed callback
                    configMgr.onConfigChanged?(nil)
                } else {
                    let response = "Missing name for insert"
                    write(clientSocket, response, response.utf8.count)
                }

            case .removeInsert:
                logInfo("Received command to remove insert")
                
                if let name = commandMessage.arguments?["name"] {
                    var inserts = configMgr.config.inserts
                    let initialCount = inserts.count
                    
                    inserts.removeAll { $0.name == name }
                    
                    if inserts.count < initialCount {
                        configMgr.config.inserts = inserts
                        
                        // If the removed insert was active, clear the active insert
                        if configMgr.config.defaults.activeInsert == name {
                            configMgr.config.defaults.activeInsert = nil
                        }
                        
                        configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                        
                        let response = "Insert '\(name)' removed"
                        write(clientSocket, response, response.utf8.count)
                    } else {
                        let response = "Insert '\(name)' not found"
                        write(clientSocket, response, response.utf8.count)
                    }
                } else {
                    let response = "No insert name provided"
                    write(clientSocket, response, response.utf8.count)
                }
                
            case .getIcon:
                logInfo("Received command to get active insert icon")
                
                // Check if there's an active insert configured
                if let activeInsertName = configMgr.config.defaults.activeInsert,
                   !activeInsertName.isEmpty {
                    
                    // Try to find the active insert in the configuration
                    if let activeInsert = configMgr.config.inserts.first(where: { $0.name == activeInsertName }) {
                        // Check if the insert has an icon
                        if let icon = activeInsert.icon {
                            if icon == ".none" {
                                // Special value to explicitly use no icon
                                let response = " "
                                write(clientSocket, response, response.utf8.count)
                                logInfo("Using explicit 'no icon' setting for active insert: \(activeInsertName)")
                            } else if !icon.isEmpty {
                                // Return the icon
                                write(clientSocket, icon, icon.utf8.count)
                                logInfo("Returned icon for active insert: \(activeInsertName)")
                            } else {
                                // Empty string in icon field, fall back to default icon
                                if let defaultIcon = configMgr.config.defaults.icon {
                                    if defaultIcon == ".none" {
                                        // Special value to explicitly use no icon
                                        let response = " "
                                        write(clientSocket, response, response.utf8.count)
                                        logInfo("Using explicit 'no icon' default setting")
                                    } else if !defaultIcon.isEmpty {
                                        write(clientSocket, defaultIcon, defaultIcon.utf8.count)
                                        logInfo("Using default icon for active insert: \(activeInsertName)")
                                    } else {
                                        // Empty default icon
                                        let response = " "
                                        write(clientSocket, response, response.utf8.count)
                                        logInfo("No icon defined for active insert: \(activeInsertName) and empty default icon")
                                    }
                                } else {
                                    // No default icon available
                                    let response = " "
                                    write(clientSocket, response, response.utf8.count)
                                    logInfo("No icon defined for active insert: \(activeInsertName) and no default icon set")
                                }
                            }
                        } else {
                            // No icon defined for this insert, use defaultIcon if available
                            if let defaultIcon = configMgr.config.defaults.icon {
                                if defaultIcon == ".none" {
                                    // Special value to explicitly use no icon
                                    let response = " "
                                    write(clientSocket, response, response.utf8.count)
                                    logInfo("Using explicit 'no icon' default setting")
                                } else if !defaultIcon.isEmpty {
                                    write(clientSocket, defaultIcon, defaultIcon.utf8.count)
                                    logInfo("Using default icon for active insert: \(activeInsertName)")
                                } else {
                                    // Empty default icon
                                    let response = " "
                                    write(clientSocket, response, response.utf8.count)
                                    logInfo("No icon defined for active insert: \(activeInsertName) and empty default icon")
                                }
                            } else {
                                // No default icon available
                                let response = " "
                                write(clientSocket, response, response.utf8.count)
                                logInfo("No icon defined for active insert: \(activeInsertName) and no default icon set")
                            }
                        }
                    } else {
                        // Insert not found in configuration, use defaultIcon if available
                        if let defaultIcon = configMgr.config.defaults.icon {
                            if defaultIcon == ".none" {
                                // Special value to explicitly use no icon
                                let response = " "
                                write(clientSocket, response, response.utf8.count)
                                logInfo("Using explicit 'no icon' default setting")
                            } else if !defaultIcon.isEmpty {
                                write(clientSocket, defaultIcon, defaultIcon.utf8.count)
                                logInfo("Using default icon because active insert '\(activeInsertName)' not found")
                            } else {
                                // Empty default icon
                                let response = " "
                                write(clientSocket, response, response.utf8.count)
                                logInfo("Active insert '\(activeInsertName)' not found and empty default icon")
                            }
                        } else {
                            // No default icon available
                            let response = " "
                            write(clientSocket, response, response.utf8.count)
                            logInfo("Active insert '\(activeInsertName)' not found and no default icon set")
                        }
                    }
                } else {
                    // No active insert configured, use defaultIcon if available
                    if let defaultIcon = configMgr.config.defaults.icon {
                        if defaultIcon == ".none" {
                            // Special value to explicitly use no icon
                            let response = " "
                            write(clientSocket, response, response.utf8.count)
                            logInfo("Using explicit 'no icon' default setting")
                        } else if !defaultIcon.isEmpty {
                            write(clientSocket, defaultIcon, defaultIcon.utf8.count)
                            logInfo("Using default icon because no active insert is configured")
                        } else {
                            // Empty default icon
                            let response = " "
                            write(clientSocket, response, response.utf8.count)
                            logInfo("No active insert and empty default icon")
                        }
                    } else {
                        // No default icon available
                        let response = " "
                        write(clientSocket, response, response.utf8.count)
                        logInfo("No active insert and no default icon set")
                    }
                }
                
            case .getInsert:
                logInfo("Received command to get active insert name")
                
                // Check if there's an active insert configured
                if let activeInsertName = configMgr.config.defaults.activeInsert,
                   !activeInsertName.isEmpty {
                    // Return the active insert name
                    write(clientSocket, activeInsertName, activeInsertName.utf8.count)
                    logInfo("Returned active insert name: \(activeInsertName)")
                } else {
                    // No active insert configured
                    let response = " "
                    write(clientSocket, response, response.utf8.count)
                    logInfo("No active insert")
                }
                
            case .reloadConfig:
                logInfo("Processing command to reload configuration")
                // Reload the configuration from disk
                if let loadedConfig = configMgr.loadConfig() {
                    configMgr.config = loadedConfig
                    configMgr.configurationSuccessfullyLoaded() // Reset notification flag
                    configMgr.onConfigChanged?(nil)
                    configMgr.resetFileWatcher()
                    
                    // Send success response
                    let response = "Configuration reloaded successfully"
                    write(clientSocket, response, response.utf8.count)
                    logInfo("Configuration reload successful")
                    
                } else {
                    // Send error response
                    let response = "Failed to reload configuration"
                    write(clientSocket, response, response.utf8.count)
                    logError("Configuration reload failed")
                }
                
            case .autoReturn:
                logInfo("Received command to toggle auto-return")
                
                if let enableStr = commandMessage.arguments?["enable"],
                   let enable = Bool(enableStr) {
                    autoReturnEnabled = enable
                    
                    let response = autoReturnEnabled
                        ? "Auto-return enabled for next result"
                        : "Auto-return disabled"
                    write(clientSocket, response, response.utf8.count)
                    logInfo(response)
                } else {
                    let response = "Missing or invalid enable parameter (should be 'true' or 'false')"
                    write(clientSocket, response, response.utf8.count)
                    logError(response)
                }
                
            case .execInsert:
                logInfo("Received command to execute insert")
                
                if let insertName = commandMessage.arguments?["name"] {
                    // Find the insert in the configuration
                    if let insert = configMgr.config.inserts.first(where: { $0.name == insertName }) {
                        // Find the last valid JSON file with a result
                        if let lastValidJson = self.findLastValidJsonFile(configManager: configMgr) {
                            // Process the insert action with the meta.json values
                            let (processedAction, isAutoPasteResult) = self.processInsertAction(insert.action, metaJson: lastValidJson)
                            
                            // Apply the insert without ESC (as requested) and without moveTo
                            self.applyInsertDirectly(processedAction, activeInsert: insert, isAutoPaste: insert.action == ".autoPaste" || isAutoPasteResult)
                            
                            let response = "Executed insert '\(insertName)'"
                            write(clientSocket, response, response.utf8.count)
                            logInfo("Successfully executed insert: \(insertName)")
                        } else {
                            let response = "No valid JSON file found with results"
                            write(clientSocket, response, response.utf8.count)
                            logError("No valid JSON file found for exec-insert")
                        }
                    } else {
                        let response = "Insert '\(insertName)' not found"
                        write(clientSocket, response, response.utf8.count)
                        logError("Insert not found: \(insertName)")
                    }
                } else {
                    let response = "Missing insert name"
                    write(clientSocket, response, response.utf8.count)
                    logError("Missing insert name for exec-insert command")
                }
                
            case .updateConfig:
                logInfo("Received command to update configuration")
                
                // Extract arguments
                if let args = commandMessage.arguments {
                    logInfo("Updating config with arguments: \(args)")
                    
                    // Validate insert name if provided
                    if let insertName = args["activeInsert"], !insertName.isEmpty {
                        if !self.validateInsertExists(insertName, configManager: configMgr) {
                            let response = "Error: Insert '\(insertName)' does not exist. Use --list-inserts to see available inserts."
                            write(clientSocket, response, response.utf8.count)
                            notify(title: "Macrowhisper", message: "Non-existent insert: \(insertName)")
                            logError("Attempted to set non-existent insert: \(insertName)")
                            return
                        }
                    }
                    
                    // Send immediate success response
                    let response = "Configuration update queued successfully"
                    write(clientSocket, response, response.utf8.count)
                    
                    // Process the update asynchronously
                    configMgr.updateFromCommandLineAsync(arguments: args) {
                        logInfo("Configuration updated successfully in background")
                    }
                } else {
                    // Send error response
                    let response = "No arguments provided for configuration update"
                    write(clientSocket, response, response.utf8.count)
                }
                return  // Prevent fall-through
                
            case .status:
                logInfo("Received command to get status")
                
                // Create status information
                let status: [String: Any] = [
                    "version": APP_VERSION,
                    "watcher_running": recordingsWatcher != nil,
                    "watch_path": configMgr.config.defaults.watch,
                    "updates_disabled": configMgr.config.defaults.noUpdates,
                    "notifications_disabled": configMgr.config.defaults.noNoti
                ]
                
                // Convert to JSON
                if let statusData = try? JSONSerialization.data(withJSONObject: status),
                   let statusString = String(data: statusData, encoding: .utf8) {
                    write(clientSocket, statusString, statusString.utf8.count)
                } else {
                    let response = "Failed to generate status"
                    write(clientSocket, response, response.utf8.count)
                }
            
            case .version:
                logInfo("Received version command")
                let versionResponse = "macrowhisper version \(APP_VERSION)"
                write(clientSocket, versionResponse, versionResponse.utf8.count)
                
            case .debug:
                logInfo("Received debug command")
                let status = """
                Server status:
                - Socket path: \(socketPath)
                - Server socket descriptor: \(serverSocket)
                """
                write(clientSocket, status, status.utf8.count)
            case .addUrl:
                logInfo("Received command to add URL action")
                
                if let name = commandMessage.arguments?["name"] {
                    // Check if URL action with this name already exists
                    var urls = configMgr.config.urls
                    if let index = urls.firstIndex(where: { $0.name == name }) {
                        // Update existing URL action
                        urls[index] = AppConfiguration.Url(name: name, action: "")
                        configMgr.config.urls = urls
                        configMgr.saveConfig()
                        
                        let response = "URL action '\(name)' updated"
                        write(clientSocket, response, response.utf8.count)
                    } else {
                        // Add new URL action
                        urls.append(AppConfiguration.Url(name: name, action: ""))
                        configMgr.config.urls = urls
                        configMgr.saveConfig()
                        
                        let response = "URL action '\(name)' added"
                        write(clientSocket, response, response.utf8.count)
                    }
                    
                    // Trigger config changed callback
                    configMgr.onConfigChanged?(nil)
                } else {
                    let response = "Missing name for URL action"
                    write(clientSocket, response, response.utf8.count)
                }
            
            case .addShortcut:
                logInfo("Received command to add shortcut action")
                
                if let name = commandMessage.arguments?["name"] {
                    // Check if shortcut action with this name already exists
                    var shortcuts = configMgr.config.shortcuts
                    if let index = shortcuts.firstIndex(where: { $0.name == name }) {
                        // Update existing shortcut action
                        shortcuts[index] = AppConfiguration.Shortcut(name: name, action: "")
                        configMgr.config.shortcuts = shortcuts
                        configMgr.saveConfig()
                        
                        let response = "Shortcut action '\(name)' updated"
                        write(clientSocket, response, response.utf8.count)
                    } else {
                        // Add new shortcut action
                        shortcuts.append(AppConfiguration.Shortcut(name: name, action: ""))
                        configMgr.config.shortcuts = shortcuts
                        configMgr.saveConfig()
                        
                        let response = "Shortcut action '\(name)' added"
                        write(clientSocket, response, response.utf8.count)
                    }
                    
                    // Trigger config changed callback
                    configMgr.onConfigChanged?(nil)
                } else {
                    let response = "Missing name for shortcut action"
                    write(clientSocket, response, response.utf8.count)
                }
            }
            
        } catch {
            logError("Failed to parse command: \(error)")
            let response = "Failed to parse command: \(error)"
            write(clientSocket, response, response.utf8.count)
        }
    }
    
    func stopServer() {
        server?.cancel()
        server = nil
    }
    
    func sendCommand(_ command: Command, arguments: [String: String]? = nil) -> String? {
        logInfo("Attempting to send command: \(command.rawValue) to socket at \(socketPath)")
        
        // First check if socket file exists
        if !FileManager.default.fileExists(atPath: socketPath) {
            logError("Socket file doesn't exist at \(socketPath)")
            return "Socket file doesn't exist. Server is not running."
        }

        // Create the command message
        let message = CommandMessage(command: command, arguments: arguments)

        // Encode the message
        guard let data = try? JSONEncoder().encode(message) else {
            return "Failed to encode command"
        }

        // Create a socket
        let clientSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard clientSocket >= 0 else {
            return "Failed to create socket: \(errno)"
        }

        defer {
            close(clientSocket)
        }

        // Set up the socket address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy the path to the socket address
        let pathLength = min(socketPath.utf8.count, Int(UNIX_PATH_MAX) - 1)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            socketPath.withCString {
                strncpy(ptr, $0, pathLength)
            }
        }

        // Connect to the socket with a retry mechanism
        var connectResult: Int32 = -1
        for attempt in 1...3 {
            let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
            connectResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(clientSocket, $0, addrSize)
                }
            }
            
            if connectResult == 0 {
                break // Connection successful
            } else {
                logWarning("Connect attempt \(attempt) failed: \(errno). Retrying...")
                Thread.sleep(forTimeInterval: 0.1) // Wait before retrying
            }
        }

        guard connectResult == 0 else {
            return "Failed to connect to socket after multiple attempts: \(errno) (\(String(cString: strerror(errno)))). Is the server running?"
        }

        // Write to the socket
        let bytesSent = write(clientSocket, data.withUnsafeBytes { $0.baseAddress }, data.count)
        guard bytesSent == data.count else {
            let errorMessage = "Failed to send complete message. Sent \(bytesSent) of \(data.count) bytes."
            logError(errorMessage)
            return errorMessage
        }

        // Read the response
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer {
            buffer.deallocate()
        }

        let bytesRead = read(clientSocket, buffer, bufferSize)
        guard bytesRead > 0 else {
            let errorDescription = String(cString: strerror(errno))
            let errorMessage = "Failed to read from socket or connection closed: \(errno) (\(errorDescription))"
            logError(errorMessage)
            return errorMessage
        }

        // Convert the bytes to a string
        return String(bytes: UnsafeBufferPointer(start: buffer, count: bytesRead), encoding: .utf8)
    }
}


// MARK: - Logging System

class Logger {
    private let logFilePath: String
    private let maxLogSize: Int = 5 * 1024 * 1024 // 5 MB in bytes
    private let dateFormatter: DateFormatter
    private let fileManager = FileManager.default
    
    init(logDirectory: String) {
        // Create logs directory if it doesn't exist
        if !fileManager.fileExists(atPath: logDirectory) {
            try? fileManager.createDirectory(atPath: logDirectory, withIntermediateDirectories: true)
        }
        
        self.logFilePath = "\(logDirectory)/macrowhisper.log"
        
        // Setup date formatter for log entries
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        
        // Rotate log if needed
        checkAndRotateLog()
    }
    
    func log(_ message: String, level: LogLevel = .info) {
        let timestamp = dateFormatter.string(from: Date())
        let logEntry = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
        
        // Print to console when running interactively AND console logging is not suppressed
        if isatty(STDOUT_FILENO) != 0 && !suppressConsoleLogging {
            print(logEntry, terminator: "")
        }
        
        // Append to log file (this part stays the same)
        if let data = logEntry.data(using: .utf8) {
            if let fileHandle = FileHandle(forWritingAtPath: logFilePath) {
                defer { fileHandle.closeFile() }
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
            } else {
                // Create file if it doesn't exist
                try? data.write(to: URL(fileURLWithPath: logFilePath), options: .atomic)
            }
        }
        
        // Check if we need to rotate logs after writing
        checkAndRotateLog()
    }
    
    private func checkAndRotateLog() {
        guard let attributes = try? fileManager.attributesOfItem(atPath: logFilePath),
              let fileSize = attributes[.size] as? Int else {
            return
        }
        
        if fileSize > maxLogSize {
            // Rename current log to include timestamp
            let dateStr = dateFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let rotatedLogPath = "\(logFilePath).\(dateStr)"
            
            try? fileManager.moveItem(atPath: logFilePath, toPath: rotatedLogPath)
            
            // Log the rotation
            log("Log file rotated due to size limit", level: .info)
        }
    }
    
    enum LogLevel: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
    }
}

// MARK: - Notification System

class NotificationManager {
    func sendNotification(title: String, body: String) {
        // Just log instead if notifications aren't available
        print("NOTIFICATION: \(title) - \(body)")
        
        // Use AppleScript for notifications
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }
}

// MARK: - Global instances
// Global variables
var disableUpdates: Bool = false
var disableNotifications: Bool = false
var globalConfigManager: ConfigurationManager?
var suppressConsoleLogging = false
var autoReturnEnabled = false
private var lastDetectedFrontApp: NSRunningApplication?
var actionDelayValue: Double? = nil
var socketHealthTimer: Timer?
var historyManager: HistoryManager?

// Create default paths for logs
let logDirectory = ("~/Library/Logs/Macrowhisper" as NSString).expandingTildeInPath

// Initialize logger and notification manager
let logger = Logger(logDirectory: logDirectory)
let notificationManager = NotificationManager()

// MARK: - Helper functions for logging and notifications

func logInfo(_ message: String) {
    logger.log(message, level: .info)
}

func logWarning(_ message: String) {
    logger.log(message, level: .warning)
}

func logError(_ message: String) {
    logger.log(message, level: .error)
}

func logDebug(_ message: String) {
    logger.log(message, level: .debug)
}

func notify(title: String, message: String) {
    if !disableNotifications {
            notificationManager.sendNotification(title: title, body: message)
        }
}

// MARK: - Updater

class VersionChecker {
    private var lastFailedCheckDate: Date?
    private let failedCheckBackoffInterval: TimeInterval = 3600 // 1 hour
    private var updateCheckInProgress = false
    private let currentCLIVersion = APP_VERSION
    private let versionsURL = "https://raw.githubusercontent.com/ognistik/macrowhisper-cli/main/versions.json"
    private var lastCheckDate: Date?
    private let checkInterval: TimeInterval = 24 * 60 * 60 // 24 hours
    private let reminderInterval: TimeInterval = 4 * 24 * 60 * 60 // 4 days
    private var lastReminderDate: Date?
    
    func shouldCheckForUpdates() -> Bool {
        guard let lastCheck = lastCheckDate else { return true }
        return Date().timeIntervalSince(lastCheck) >= checkInterval
    }
    
    func resetLastCheckDate() {
        // Reset the last check date to trigger a check after the next interaction
        lastCheckDate = nil
        logInfo("Version checker state reset - will check after next interaction")
    }
    
    func checkForUpdates() {
        // Don't run if updates are disabled
        guard !disableUpdates else { return }
        
        // Don't run if we've checked recently (within 24 hours)
        guard shouldCheckForUpdates() else { return }
        
        // Don't run if we're already checking
        guard !updateCheckInProgress else { return }
        
        // Don't run if we've had a recent failure and are backing off
        if let lastFailed = lastFailedCheckDate,
           Date().timeIntervalSince(lastFailed) < failedCheckBackoffInterval {
            return
        }
        
        logInfo("Checking for updates...")
        updateCheckInProgress = true
        
        // Create request with timeout
        guard let url = URL(string: versionsURL) else {
            logError("Invalid versions URL")
            updateCheckInProgress = false
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0 // 10 second timeout
        
        // Use background queue for network request
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.performVersionCheck(request: request)
        }
    }
    
    private func performVersionCheck(request: URLRequest) {
            defer {
                // Always reset the in-progress flag when done
                updateCheckInProgress = false
            }
            
            let semaphore = DispatchSemaphore(value: 0)
            var resultData: Data?
            var resultError: Error?
            
            let session = URLSession(configuration: .default)
            session.dataTask(with: request) { data, response, error in
                resultData = data
                resultError = error
                semaphore.signal()
            }.resume()
            
            // Wait with timeout
            let result = semaphore.wait(timeout: .now() + 15.0)
            
            if result == .timedOut {
                logInfo("Version check timed out - continuing offline")
                lastFailedCheckDate = Date() // Track the failure
                return
            }
            
            if let error = resultError {
                logInfo("Version check failed: \(error.localizedDescription) - continuing offline")
                lastFailedCheckDate = Date() // Track the failure
                return
            }
            
            guard let data = resultData else {
                logInfo("No data received from version check - continuing offline")
                lastFailedCheckDate = Date() // Track the failure
                return
            }
            
            // Clear the failed check date since we succeeded
            lastFailedCheckDate = nil
            
            // Update last check date - this is critical
            lastCheckDate = Date()
            
            processVersionResponse(data)
        }
    
    private func processVersionResponse(_ data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logError("Invalid JSON in versions response")
                return
            }
            
            // Check CLI version
            var cliUpdateAvailable = false
            var kmUpdateAvailable = false
            var cliMessage = ""
            var kmMessage = ""
            
            if let cliInfo = json["cli"] as? [String: Any],
               let latestCLI = cliInfo["latest"] as? String {
                if isNewerVersion(latest: latestCLI, current: currentCLIVersion) {
                    cliUpdateAvailable = true
                    cliMessage = "CLI: \(currentCLIVersion) → \(latestCLI)"
                }
            }
            
            // Check Keyboard Maestro version
            if let kmInfo = json["km_macros"] as? [String: Any],
               let latestKM = kmInfo["latest"] as? String {
                let currentKMVersion = getCurrentKeyboardMaestroVersion()
                
                // Only check for updates if we have a valid current version (not empty, not "missing value")
                if !currentKMVersion.isEmpty &&
                   currentKMVersion != "missing value" &&
                   isNewerVersion(latest: latestKM, current: currentKMVersion) {
                    kmUpdateAvailable = true
                    kmMessage = "KM Macros: \(currentKMVersion) → \(latestKM)"
                } else if currentKMVersion.isEmpty || currentKMVersion == "missing value" {
                    logInfo("Skipping KM version check - macro not available or not installed")
                }
            }
            
            // Now show the appropriate notification
            if cliUpdateAvailable && !kmUpdateAvailable {
                // CLI only: show terminal command
                showCLIUpdateDialog(message: cliMessage)
            } else if !cliUpdateAvailable && kmUpdateAvailable {
                // KM only: show open releases dialog
                showKMUpdateNotification(message: kmMessage)
            } else if cliUpdateAvailable && kmUpdateAvailable {
                // Both: show both messages, offer both instructions and button
                showBothUpdatesNotification(cliMessage: cliMessage, kmMessage: kmMessage)
            } else {
                // No update
                logInfo("All components are up to date")
            }
        } catch {
            logError("Error parsing versions JSON: \(error)")
        }
    }
    
    private func getCurrentKeyboardMaestroVersion() -> String {
        let script = """
        tell application "Keyboard Maestro Engine"
            try
                set result to do script "MW Mbar" with parameter "versionCheck"
                return result
            on error
                return ""
            end try
        end tell
        """
        
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice  // Redirect error output to prevent console errors
        
        do {
            try task.run()
            task.waitUntilExit()
            
            // Check exit status
            if task.terminationStatus != 0 {
                logInfo("Keyboard Maestro macro check failed - Keyboard Maestro might not be running")
                return ""
            }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            // If the macro doesn't exist or doesn't return a proper version, we'll get empty output
            if output.isEmpty || output == "missing value" {
                logInfo("Keyboard Maestro macro version check returned empty result - macro might not be installed")
            }
            
            return output
        } catch {
            logInfo("Failed to check Keyboard Maestro macro version: \(error.localizedDescription)")
            return ""
        }
    }
    
    private func isNewerVersion(latest: String, current: String) -> Bool {
        let latestComponents = latest.split(separator: ".").compactMap { Int($0) }
        let currentComponents = current.split(separator: ".").compactMap { Int($0) }
        
        let maxCount = max(latestComponents.count, currentComponents.count)
        
        for i in 0..<maxCount {
            let latestPart = i < latestComponents.count ? latestComponents[i] : 0
            let currentPart = i < currentComponents.count ? currentComponents[i] : 0
            
            if latestPart > currentPart {
                return true
            } else if latestPart < currentPart {
                return false
            }
        }
        
        return false
    }

    private func showKMUpdateNotification(message: String) {
        // Your current dialog logic with Open Release button
        showUpdateNotification(message: message)
    }

    private func showBothUpdatesNotification(cliMessage: String, kmMessage: String) {
        let brewCommand = "brew upgrade ognistik/tap/macrowhisper-cli"
        let fullMessage = "\(cliMessage)\n\(kmMessage)\n\nTo update CLI:\n\(brewCommand)\n\nWould you like to open the KM Macros release page?"
        // Show dialog with Open Release button and brew instructions
        showUpdateNotification(message: fullMessage)
    }
    
    private func showUpdateNotification(message: String) {
        DispatchQueue.main.async {
            // Check if we should show reminder (not too frequent)
            if let lastReminder = self.lastReminderDate,
               Date().timeIntervalSince(lastReminder) < self.reminderInterval {
                return
            }
            
            self.lastReminderDate = Date()
            
            let title = "Macrowhisper"
            let fullMessage = "Macrowhisper update available:\n\n\(message)"
            
            // Use AppleScript for interactive dialog
            let script = """
            display dialog "\(fullMessage.replacingOccurrences(of: "\"", with: "\\\""))" ¬
                with title "\(title)" ¬
                buttons {"Remind Later", "Open Release"} ¬
                default button "Open Release" ¬
            """
            
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            
            do {
                try task.run()
                task.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                if output.contains("Open Release") {
                    self.openDownloadPage()
                }
            } catch {
                // User cancelled or error occurred
                logInfo("Update dialog cancelled or failed")
            }
        }
    }
    
    private func openDownloadPage() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["https://github.com/ognistik/macrowhisper/releases/latest"]
        try? task.run()
    }
    
    private func showCLIUpdateDialog(message: String) {
        let brewCommand = "brew upgrade ognistik/tap/macrowhisper-cli"
        let fullMessage = """
        Macrowhisper update available:
        \(message)

        To update, run:
        \(brewCommand)
        """
        let script = """
        display dialog "\(fullMessage.replacingOccurrences(of: "\"", with: "\\\""))" ¬
            with title "Macrowhisper" ¬
            buttons {"Remind Later", "Copy Command", "Open Release"} ¬
            default button "Open Release" ¬
        """
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if output.contains("Copy Command") {
                // Copy command to clipboard
                let pbTask = Process()
                pbTask.launchPath = "/usr/bin/pbcopy"
                let inputPipe = Pipe()
                pbTask.standardInput = inputPipe
                pbTask.launch()
                inputPipe.fileHandleForWriting.write(brewCommand.data(using: .utf8)!)
                inputPipe.fileHandleForWriting.closeFile()
            } else if output.contains("Open Release") {
                // Open CLI release page
                openCLIReleasePage()
            }
            // If "Remind Later" is pressed, do nothing (optionally, implement snooze logic)
        } catch {
            logError("Failed to show CLI update dialog: \(error)")
        }
    }
    
    private func openCLIReleasePage() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["https://github.com/ognistik/macrowhisper-cli/releases/latest"]
        try? task.run()
    }
}

// MARK: - Configuration Manager

struct AppConfiguration: Codable {
    struct Defaults: Codable {
        var watch: String
        var noUpdates: Bool
        var noNoti: Bool
        var activeInsert: String?
        var icon: String?
        var moveTo: String?
        var noEsc: Bool
        var simKeypress: Bool
        var actionDelay: Double
        var history: Int?
        var pressReturn: Bool
        
        // Add these coding keys and custom encoding
        enum CodingKeys: String, CodingKey {
            case watch, noUpdates, noNoti, activeInsert, icon, moveTo, noEsc, simKeypress, actionDelay, history, pressReturn
        }
        
        // Custom encoding to preserve null values
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(watch, forKey: .watch)
            try container.encode(noUpdates, forKey: .noUpdates)
            try container.encode(noNoti, forKey: .noNoti)
            try container.encode(activeInsert, forKey: .activeInsert)
            try container.encode(icon, forKey: .icon)
            try container.encode(moveTo, forKey: .moveTo)
            try container.encode(noEsc, forKey: .noEsc)
            try container.encode(simKeypress, forKey: .simKeypress)
            try container.encode(actionDelay, forKey: .actionDelay)
            try container.encode(history, forKey: .history)
            try container.encode(pressReturn, forKey: .pressReturn)
        }
        
        static func defaultValues() -> Defaults {
            return Defaults(
                watch: ("~/Documents/superwhisper" as NSString).expandingTildeInPath,
                noUpdates: false,
                noNoti: false,
                activeInsert: "",
                icon: "",
                moveTo: "",
                noEsc: false,
                simKeypress: false,
                actionDelay: 0.0,
                history: nil,
                pressReturn: false
            )
        }
    }
    
    struct Insert: Codable {
        var name: String
        var action: String
        var icon: String? = ""  // Default to empty string
        var moveTo: String? = ""  // Default to empty string
        var noEsc: Bool?
        var simKeypress: Bool?
        var actionDelay: Double?
        var pressReturn: Bool?
        // --- Trigger fields for future extensibility ---
        /// Voice trigger regex (matches start of phrase)
        var triggerVoice: String? = ""
        /// App trigger regex (matches app name or bundle ID)
        var triggerApps: String? = ""
        /// Mode trigger regex (matches modeName)
        var triggerModes: String? = ""
        /// Logic for combining triggers ("and"/"or")
        var triggerLogic: String? = "or"
        // ---------------------------------------------
        
        enum CodingKeys: String, CodingKey {
            case name, action, icon, moveTo, noEsc, simKeypress, actionDelay, pressReturn
            case triggerVoice, triggerApps, triggerModes, triggerLogic
        }
        
        // Custom encoding to preserve null values and ensure trigger fields are always present
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(action, forKey: .action)
            try container.encode(icon, forKey: .icon)
            try container.encode(moveTo, forKey: .moveTo)
            try container.encode(noEsc, forKey: .noEsc)
            try container.encode(simKeypress, forKey: .simKeypress)
            try container.encode(actionDelay, forKey: .actionDelay)
            try container.encode(pressReturn, forKey: .pressReturn)
            // Always encode trigger fields, defaulting to "" if nil
            try container.encode(triggerVoice ?? "", forKey: .triggerVoice)
            try container.encode(triggerApps ?? "", forKey: .triggerApps)
            try container.encode(triggerModes ?? "", forKey: .triggerModes)
            try container.encode(triggerLogic ?? "or", forKey: .triggerLogic)
        }
        // Custom decoding to ensure trigger fields are always present
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            action = try container.decode(String.self, forKey: .action)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)
            noEsc = try container.decodeIfPresent(Bool.self, forKey: .noEsc)
            simKeypress = try container.decodeIfPresent(Bool.self, forKey: .simKeypress)
            actionDelay = try container.decodeIfPresent(Double.self, forKey: .actionDelay)
            pressReturn = try container.decodeIfPresent(Bool.self, forKey: .pressReturn)
            triggerVoice = try container.decodeIfPresent(String.self, forKey: .triggerVoice) ?? ""
            triggerApps = try container.decodeIfPresent(String.self, forKey: .triggerApps) ?? ""
            triggerModes = try container.decodeIfPresent(String.self, forKey: .triggerModes) ?? ""
            triggerLogic = try container.decodeIfPresent(String.self, forKey: .triggerLogic) ?? "or"
        }
        // Default initializer for new inserts
        init(name: String, action: String, icon: String? = "", moveTo: String? = "", noEsc: Bool? = nil, simKeypress: Bool? = nil, actionDelay: Double? = nil, pressReturn: Bool? = nil, triggerVoice: String? = "", triggerApps: String? = "", triggerModes: String? = "", triggerLogic: String? = "or") {
            self.name = name
            self.action = action
            self.icon = icon
            self.moveTo = moveTo
            self.noEsc = noEsc
            self.simKeypress = simKeypress
            self.actionDelay = actionDelay
            self.pressReturn = pressReturn
            self.triggerVoice = triggerVoice ?? ""
            self.triggerApps = triggerApps ?? ""
            self.triggerModes = triggerModes ?? ""
            self.triggerLogic = triggerLogic ?? "or"
        }
    }
    
    struct Url: Codable {
        var name: String
        var action: String
        var moveTo: String? = ""  // Default to empty string
        var noEsc: Bool?
        var actionDelay: Double?
        // --- Trigger fields for future extensibility ---
        /// Voice trigger regex (matches start of phrase)
        var triggerVoice: String? = ""
        /// App trigger regex (matches app name or bundle ID)
        var triggerApps: String? = ""
        /// Mode trigger regex (matches modeName)
        var triggerModes: String? = ""
        /// Logic for combining triggers ("and"/"or")
        var triggerLogic: String? = "or"
        // ---------------------------------------------
        var openWith: String? = ""
        
        enum CodingKeys: String, CodingKey {
            case name, action, moveTo, noEsc, actionDelay
            case triggerVoice, triggerApps, triggerModes, triggerLogic
            case openWith
        }
        
        // Custom encoding to preserve null values and ensure trigger fields are always present
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(action, forKey: .action)
            try container.encode(moveTo, forKey: .moveTo)
            try container.encode(noEsc, forKey: .noEsc)
            try container.encode(actionDelay, forKey: .actionDelay)
            // Always encode trigger fields, defaulting to "" if nil
            try container.encode(triggerVoice ?? "", forKey: .triggerVoice)
            try container.encode(triggerApps ?? "", forKey: .triggerApps)
            try container.encode(triggerModes ?? "", forKey: .triggerModes)
            try container.encode(triggerLogic ?? "or", forKey: .triggerLogic)
            try container.encode(openWith ?? "", forKey: .openWith)
        }
        // Custom decoding to ensure trigger fields are always present
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            action = try container.decode(String.self, forKey: .action)
            moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)
            noEsc = try container.decodeIfPresent(Bool.self, forKey: .noEsc)
            actionDelay = try container.decodeIfPresent(Double.self, forKey: .actionDelay)
            triggerVoice = try container.decodeIfPresent(String.self, forKey: .triggerVoice) ?? ""
            triggerApps = try container.decodeIfPresent(String.self, forKey: .triggerApps) ?? ""
            triggerModes = try container.decodeIfPresent(String.self, forKey: .triggerModes) ?? ""
            triggerLogic = try container.decodeIfPresent(String.self, forKey: .triggerLogic) ?? "or"
            openWith = try container.decodeIfPresent(String.self, forKey: .openWith) ?? ""
        }
        // Default initializer for new URLs
        init(name: String, action: String, moveTo: String? = "", noEsc: Bool? = nil, actionDelay: Double? = nil, triggerVoice: String? = "", triggerApps: String? = "", triggerModes: String? = "", triggerLogic: String? = "or", openWith: String? = "") {
            self.name = name
            self.action = action
            self.moveTo = moveTo
            self.noEsc = noEsc
            self.actionDelay = actionDelay
            self.triggerVoice = triggerVoice ?? ""
            self.triggerApps = triggerApps ?? ""
            self.triggerModes = triggerModes ?? ""
            self.triggerLogic = triggerLogic ?? "or"
            self.openWith = openWith ?? ""
        }
    }
    
    struct Shortcut: Codable {
        var name: String
        var action: String
        var moveTo: String? = ""  // Default to empty string
        var noEsc: Bool?
        var actionDelay: Double?
        // --- Trigger fields for future extensibility ---
        /// Voice trigger regex (matches start of phrase)
        var triggerVoice: String? = ""
        /// App trigger regex (matches app name or bundle ID)
        var triggerApps: String? = ""
        /// Mode trigger regex (matches modeName)
        var triggerModes: String? = ""
        /// Logic for combining triggers ("and"/"or")
        var triggerLogic: String? = "or"
        
        enum CodingKeys: String, CodingKey {
            case name, action, moveTo, noEsc, actionDelay
            case triggerVoice, triggerApps, triggerModes, triggerLogic
        }
        
        // Custom encoding to preserve null values and ensure trigger fields are always present
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(action, forKey: .action)
            try container.encode(moveTo, forKey: .moveTo)
            try container.encode(noEsc, forKey: .noEsc)
            try container.encode(actionDelay, forKey: .actionDelay)
            // Always encode trigger fields, defaulting to "" if nil
            try container.encode(triggerVoice ?? "", forKey: .triggerVoice)
            try container.encode(triggerApps ?? "", forKey: .triggerApps)
            try container.encode(triggerModes ?? "", forKey: .triggerModes)
            try container.encode(triggerLogic ?? "or", forKey: .triggerLogic)
        }
        
        // Custom decoding to ensure trigger fields are always present
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            action = try container.decode(String.self, forKey: .action)
            moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)
            noEsc = try container.decodeIfPresent(Bool.self, forKey: .noEsc)
            actionDelay = try container.decodeIfPresent(Double.self, forKey: .actionDelay)
            triggerVoice = try container.decodeIfPresent(String.self, forKey: .triggerVoice) ?? ""
            triggerApps = try container.decodeIfPresent(String.self, forKey: .triggerApps) ?? ""
            triggerModes = try container.decodeIfPresent(String.self, forKey: .triggerModes) ?? ""
            triggerLogic = try container.decodeIfPresent(String.self, forKey: .triggerLogic) ?? "or"
        }
        
        // Default initializer for new shortcuts
        init(name: String, action: String, moveTo: String? = "", noEsc: Bool? = nil, actionDelay: Double? = nil, triggerVoice: String? = "", triggerApps: String? = "", triggerModes: String? = "", triggerLogic: String? = "or") {
            self.name = name
            self.action = action
            self.moveTo = moveTo
            self.noEsc = noEsc
            self.actionDelay = actionDelay
            self.triggerVoice = triggerVoice ?? ""
            self.triggerApps = triggerApps ?? ""
            self.triggerModes = triggerModes ?? ""
            self.triggerLogic = triggerLogic ?? "or"
        }
    }
    
    var defaults: Defaults
    var inserts: [Insert]
    var urls: [Url]
    var shortcuts: [Shortcut]
    
    static func defaultConfig() -> AppConfiguration {
        return AppConfiguration(
            defaults: Defaults.defaultValues(),
            inserts: [],
            urls: [],
            shortcuts: []
        )
    }
}

// MARK: - Helpers

func checkSocketHealth() -> Bool {
    // Try to send a simple status command to yourself
    return socketCommunication.sendCommand(.status) != nil
}

func recoverSocket() {
    logInfo("Attempting to recover socket connection...")
    
    // Cancel and close existing socket
    socketCommunication.stopServer()
    
    // Remove socket file
    if FileManager.default.fileExists(atPath: socketPath) {
        do {
            try FileManager.default.removeItem(atPath: socketPath)
            logInfo("Removed existing socket file during recovery")
        } catch {
            logError("Failed to remove socket file during recovery: \(error)")
        }
    }
    
    // Recreate socket
    ensureSocketDirectoryExists()
    
    // Safely unwrap the globalConfigManager
    if let configManager = globalConfigManager {
        socketCommunication.startServer(configManager: configManager)
        logInfo("Socket server restarted after recovery attempt")
    } else {
        logError("Failed to restart socket server: globalConfigManager is nil")
        
        // Try to create a new configuration manager as fallback
        let fallbackConfigManager = ConfigurationManager()
        socketCommunication.startServer(configManager: fallbackConfigManager)
        globalConfigManager = fallbackConfigManager
        logInfo("Socket server restarted with fallback configuration manager")
    }
}

func registerForSleepWakeNotifications() {
    logInfo("Registering for sleep/wake notifications")
    
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
    ) { _ in
        logInfo("System woke from sleep, restarting socket health monitor")
        startSocketHealthMonitor()
    }

    center.addObserver(
        forName: NSWorkspace.willSleepNotification,
        object: nil,
        queue: .main
    ) { _ in
        logInfo("System going to sleep, stopping socket health monitor")
        stopSocketHealthMonitor()
    }
}

func startSocketHealthMonitor() {
    // Invalidate previous timer if any
    socketHealthTimer?.invalidate()
    socketHealthTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { _ in
        logInfo("Performing periodic socket health check")
        if !checkSocketHealth() {
            logWarning("Socket appears to be unhealthy, attempting recovery")
            recoverSocket()
        }
    }
    socketHealthTimer?.tolerance = 10.0
    RunLoop.main.add(socketHealthTimer!, forMode: .common)
    logInfo("Socket health monitor started")
}

func stopSocketHealthMonitor() {
    socketHealthTimer?.invalidate()
    socketHealthTimer = nil
    logInfo("Socket health monitor stopped")
}

func initializeWatcher(_ path: String) {
    let recordingsPath = "\(path)/recordings"
    
    if !FileManager.default.fileExists(atPath: recordingsPath) {
        logWarning("Recordings folder not found at \(recordingsPath)")
        notify(title: "Macrowhisper", message: "Recordings folder not found. Please check the path.")
        
        // Update config to disable watcher
        configManager.updateFromCommandLine(watcher: false)
        return
    }
    
    recordingsWatcher = RecordingsFolderWatcher(basePath: path)
    if recordingsWatcher == nil {
        logWarning("Failed to initialize recordings folder watcher")
        notify(title: "Macrowhisper", message: "Failed to initialize watcher")
        
        // Update config to disable watcher
        configManager.updateFromCommandLine(watcher: false)
    } else {
        logInfo("Watching recordings folder at \(recordingsPath)")
    }
}


func acquireSingleInstanceLock(lockFilePath: String, socketCommunication: SocketCommunication) -> Bool {
    // Try to create and lock the file
    let fd = open(lockFilePath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    if fd == -1 {
        logWarning("Could not open lock file: \(lockFilePath)")
        notify(title: "Macrowhisper", message: "Could not open lock file.")
        return false
    }
    
    // Try to acquire exclusive lock, non-blocking
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        close(fd)
        
        // Another instance is running
        suppressConsoleLogging = true
        
        // Instead of using socket communication, use process communication
        let args = CommandLine.arguments
        
        // Handle help command specifically
        if args.contains("-h") || args.contains("--help") {
            // Print help directly without trying to communicate with the running instance
            printHelp()
            exit(0)
        }
        
        // Handle version command specifically
        if args.contains("-v") || args.contains("--version") {
            if let response = socketCommunication.sendCommand(.version) {
                print(response)
            } else {
                print("macrowhisper version \(APP_VERSION)")
            }
            exit(0)
        }
        
        // Check for status command
        if args.contains("-s") || args.contains("--status") {
            print("Macrowhisper is running. (Version \(APP_VERSION))")
            exit(0)
        }
        
        if args.contains("--get-icon") {
            if let response = socketCommunication.sendCommand(.getIcon) {
                print(response)
            } else {
                print("Failed to get icon.")
            }
            exit(0)
        }
        
        if args.contains("--exec-insert") {
            let execInsertIndex = args.firstIndex(where: { $0 == "--exec-insert" })
            if let index = execInsertIndex, index + 1 < args.count {
                let insertName = args[index + 1]
                let arguments: [String: String] = ["name": insertName]
                
                if let response = socketCommunication.sendCommand(.execInsert, arguments: arguments) {
                    print(response)
                } else {
                    print("Failed to execute insert")
                }
            } else {
                print("Missing insert name after --exec-insert")
            }
            exit(0)
        }
        
        if args.contains("--get-insert") {
            if let response = socketCommunication.sendCommand(.getInsert) {
                print(response)
            } else {
                print("Failed to get active insert.")
            }
            exit(0)
        }

        if args.contains("--list-inserts") {
            if let response = socketCommunication.sendCommand(.listInserts) {
                print(response)
            } else {
                print("Failed to list inserts")
            }
            exit(0)
        }

        if args.contains("--auto-return") {
            let autoReturnIndex = args.firstIndex(where: { $0 == "--auto-return" })
            
            var arguments: [String: String] = [:]
            
            if let index = autoReturnIndex, index + 1 < args.count && !args[index + 1].starts(with: "--") {
                arguments["enable"] = args[index + 1]
            } else {
                arguments["enable"] = "true"
            }
            
            if let response = socketCommunication.sendCommand(.autoReturn, arguments: arguments) {
                print(response)
            } else {
                print("Failed to set auto-return")
            }
            exit(0)
        }
        
        if args.contains("--add-url") {
            let addUrlIndex = args.firstIndex(where: { $0 == "--add-url" })
            if let index = addUrlIndex, index + 1 < args.count {
                let urlName = args[index + 1]
                let arguments: [String: String] = ["name": urlName]
                
                if let response = socketCommunication.sendCommand(.addUrl, arguments: arguments) {
                    print(response)
                } else {
                    print("Failed to add URL action")
                }
            } else {
                print("Missing name after --add-url")
            }
            exit(0)
        }
        
        if args.contains("--add-shortcut") {
            let addShortcutIndex = args.firstIndex(where: { $0 == "--add-shortcut" })
            if let index = addShortcutIndex, index + 1 < args.count {
                let shortcutName = args[index + 1]
                let arguments: [String: String] = ["name": shortcutName]
                
                if let response = socketCommunication.sendCommand(.addShortcut, arguments: arguments) {
                    print(response)
                } else {
                    print("Failed to add shortcut action")
                }
            } else {
                print("Missing name after --add-shortcut")
            }
            exit(0)
        }

        if args.contains("--add-insert") {
            let addInsertIndex = args.firstIndex(where: { $0 == "--add-insert" })
            if let index = addInsertIndex, index + 1 < args.count {
                let insertName = args[index + 1]
                let arguments: [String: String] = ["name": insertName]
                
                if let response = socketCommunication.sendCommand(.addInsert, arguments: arguments) {
                    print(response)
                } else {
                    print("Failed to add insert")
                }
            } else {
                print("Missing name after --add-insert")
            }
            exit(0)
        }
        
        // For reload configuration or no arguments, use socket communication
        if args.count == 1 || args.contains("--watcher") ||
           args.contains("-w") || args.contains("--watch") ||
           args.contains("--no-updates") || args.contains("--no-noti") ||
           args.contains("--insert") || args.contains("--icon") ||
           args.contains("--move-to") || args.contains("--no-esc") ||
           args.contains("--sim-keypress") || args.contains("--action-delay") ||
           args.contains("--history") || args.contains("--press-return") {
            
            // Create command arguments if there are any
            var arguments: [String: String] = [:]
            
            // Extract arguments from command line
            if let watchIndex = args.firstIndex(where: { $0 == "-w" || $0 == "--watch" }),
               watchIndex + 1 < args.count {
                arguments["watch"] = args[watchIndex + 1]
            }
            
            if let watcherIndex = args.firstIndex(where: { $0 == "--watcher" }),
               watcherIndex + 1 < args.count {
                arguments["watcher"] = args[watcherIndex + 1]
            }
            
            if args.contains("--no-updates") {
                let noUpdatesIndex = args.firstIndex(where: { $0 == "--no-updates" })
                if let index = noUpdatesIndex, index + 1 < args.count {
                    arguments["noUpdates"] = args[index + 1]
                } else {
                    arguments["noUpdates"] = "true"
                }
            }

            if args.contains("--no-noti") {
                let noNotiIndex = args.firstIndex(where: { $0 == "--no-noti" })
                if let index = noNotiIndex, index + 1 < args.count {
                    arguments["noNoti"] = args[index + 1]
                } else {
                    arguments["noNoti"] = "true"
                }
            }
            
            if args.contains("--insert") {
                let insertIndex = args.firstIndex(where: { $0 == "--insert" })
                if let index = insertIndex, index + 1 < args.count && !args[index + 1].starts(with: "--") {
                    arguments["activeInsert"] = args[index + 1]
                } else {
                    arguments["activeInsert"] = ""
                }
            }
            
            if args.contains("--no-esc") {
                let noEscIndex = args.firstIndex(where: { $0 == "--no-esc" })
                if let index = noEscIndex, index + 1 < args.count {
                    arguments["noEsc"] = args[index + 1]
                } else {
                    arguments["noEsc"] = "true"
                }
            }
            
            if args.contains("--sim-keypress") {
                let simKeyPressIndex = args.firstIndex(where: { $0 == "--sim-keypress" })
                if let index = simKeyPressIndex, index + 1 < args.count {
                    arguments["simKeypress"] = args[index + 1]
                } else {
                    arguments["simKeypress"] = "true"
                }
            }
            
            if args.contains("--press-return") {
                let pressReturnIndex = args.firstIndex(where: { $0 == "--press-return" })
                if let index = pressReturnIndex, index + 1 < args.count {
                    arguments["pressReturn"] = args[index + 1]
                } else {
                    arguments["pressReturn"] = "true"
                }
            }
            
            if args.contains("--icon") {
                let iconIndex = args.firstIndex(where: { $0 == "--icon" })
                if let index = iconIndex, index + 1 < args.count && !args[index + 1].starts(with: "--") {
                    arguments["icon"] = args[index + 1]
                } else {
                    arguments["icon"] = ""
                }
            }
            
            if args.contains("--action-delay") {
                let actionDelayIndex = args.firstIndex(where: { $0 == "--action-delay" })
                if let index = actionDelayIndex, index + 1 < args.count {
                    arguments["actionDelay"] = args[index + 1]
                }
            }
            
            if args.contains("--history") {
                let historyIndex = args.firstIndex(where: { $0 == "--history" })
                if let index = historyIndex, index + 1 < args.count && !args[index + 1].starts(with: "--") {
                    let historyArg = args[index + 1]
                    if historyArg.lowercased() == "null" {
                        arguments["history"] = "null"
                    } else {
                        arguments["history"] = historyArg
                    }
                } else {
                    arguments["history"] = "null"
                }
            }
            
            if args.contains("--move-to") {
                let moveToIndex = args.firstIndex(where: { $0 == "--move-to" })
                if let index = moveToIndex, index + 1 < args.count && !args[index + 1].starts(with: "--") {
                    arguments["moveTo"] = args[index + 1]
                } else {
                    arguments["moveTo"] = ""
                }
            }
            
            // If there are arguments, send updateConfig, otherwise send reloadConfig
            let command = arguments.isEmpty ? SocketCommunication.Command.reloadConfig : SocketCommunication.Command.updateConfig
            
            // Send the command to the running instance
            if let response = socketCommunication.sendCommand(command, arguments: arguments.isEmpty ? nil : arguments) {
                print("Response from running instance: \(response)")
            } else {
                print("Failed to communicate with running instance.")
            }
            
            exit(0)
        }
        
        // For any unrecognized command, provide helpful feedback
        print("Error: Unrecognized command or invalid arguments.")
        print("Use --help for available options.")
        exit(1)
    }
    
    // Keep fd open for the lifetime of the process to hold the lock
    return true
}

let lockPath = "/tmp/macrowhisper.lock"

// Initialize socket communication
let configDir = ("~/.config/macrowhisper" as NSString).expandingTildeInPath
let socketPath = "\(configDir)/macrowhisper.sock"

// Make sure socket directory exists
func ensureSocketDirectoryExists() {
    if !FileManager.default.fileExists(atPath: configDir) {
        do {
            try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
            logInfo("Created socket directory at \(configDir)")
        } catch {
            logError("Failed to create socket directory: \(error)")
        }
    }
}
ensureSocketDirectoryExists()

let socketCommunication = SocketCommunication(socketPath: socketPath)

if !acquireSingleInstanceLock(lockFilePath: lockPath, socketCommunication: socketCommunication) {
    logError("Failed to acquire single instance lock. Exiting.")
    exit(1)
}

logInfo("Socket file created at \(socketPath)")

// Start the socket server
logInfo("About to start socket server...")
socketCommunication.startServer(configManager: configManager)
logInfo("Socket server started at \(socketPath)")

// Add a deinit to stop the server when the app terminates
defer {
    socketCommunication.stopServer()
}

func exitWithError(_ message: String) -> Never {
    logError("Error: \(message)")
    notify(title: "Macrowhisper", message: "Error: \(message)")
    exit(1)
}

func checkWatcherAvailability() -> Bool {
    let watchPath = configManager.config.defaults.watch
    let exists = FileManager.default.fileExists(atPath: watchPath)
    
    if !exists {
        logWarning("Superwhisper folder not found at: \(watchPath)")
        notify(title: "Macrowhisper", message: "Superwhisper folder not found. Please check the path.")
        return false
    }
    
    return exists
}

func requestAccessibilityPermission() -> Bool {
    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
    return AXIsProcessTrustedWithOptions(options)
}

func isInInputField() -> Bool {

    
    // Get the frontmost application with a small delay to ensure accuracy
    var frontApp: NSRunningApplication?
    
    // Use a semaphore to make this synchronous
    let semaphore = DispatchSemaphore(value: 0)
    
    DispatchQueue.main.async {
        // Get fresh reference to frontmost app
        frontApp = NSWorkspace.shared.frontmostApplication
        semaphore.signal()
    }
    
    // Wait for the main thread to get the frontmost app
    _ = semaphore.wait(timeout: .now() + 0.1)
    
    guard let app = frontApp else {
        lastDetectedFrontApp = nil
        return false
    }
    
    // Log the detected app
    logInfo("Detected app: \(app)")
    
    // Store reference to current app
    lastDetectedFrontApp = app
    
    // Get the application's process ID and create accessibility element
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    
    // Get the focused UI element in the application
    var focusedElement: AnyObject?
    let focusedError = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    
    if focusedError != .success || focusedElement == nil {
        return false
    }
    
    let axElement = focusedElement as! AXUIElement
    
    // Check role (fastest check)
    var roleValue: AnyObject?
    if AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue) == .success,
       let role = roleValue as? String {
        
        // Definitive input field roles - quick return
        let definiteInputRoles = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
        if definiteInputRoles.contains(role) {
            return true
        }
    }
    
    // Check subrole
    var subroleValue: AnyObject?
    if AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subroleValue) == .success,
       let subrole = subroleValue as? String {
        
        let definiteInputSubroles = ["AXSearchField", "AXSecureTextField", "AXTextInput"]
        if definiteInputSubroles.contains(subrole) {
            return true
        }
    }
    
    // Check editable attribute
    var editableValue: AnyObject?
    if AXUIElementCopyAttributeValue(axElement, "AXEditable" as CFString, &editableValue) == .success,
       let isEditable = editableValue as? Bool,
       isEditable {
        return true
    }
    
    // Only check actions if we haven't determined it's an input field yet
    var actionsRef: CFArray?
    if AXUIElementCopyActionNames(axElement, &actionsRef) == .success,
       let actions = actionsRef as? [String] {
        
        let inputActions = ["AXInsertText", "AXDelete"]
        if actions.contains(where: inputActions.contains) {
            return true
        }
    }
    
    return false
}


final class FileChangeWatcher {
    private let filePath: String
    private let onChanged: () -> Void
    private let onMissing: () -> Void
    private let queue = DispatchQueue(label: "com.macrowhisper.filewatcher", qos: .utility)
    
    private var lastModificationDate: Date?
    private var lastFileSize: UInt64 = 0
    private var directoryDescriptor: Int32 = -1
    private var fileDescriptor: Int32 = -1
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileName: String
    private var directoryPath: String
    
    init(filePath: String, onChanged: @escaping () -> Void, onMissing: @escaping () -> Void) {
        self.filePath = filePath
        self.onChanged = onChanged
        self.onMissing = onMissing
        
        // Get directory and filename
        self.directoryPath = (filePath as NSString).deletingLastPathComponent
        self.fileName = (filePath as NSString).lastPathComponent
        
        // Create initial temp file before setting up watchers
        createInitialTempFile()
        
        // Initial check
        updateFileMetadata()
        
        // Set up both watchers
        setupDirectoryWatcher()
        setupFileWatcher()
        
        // Force an immediate content check after setup
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.checkFile()
        }
    }
    
    func checkForChangesNow() {
        logInfo("Manual check for changes to file: \(filePath)")
        
        // Check if file exists
        if !FileManager.default.fileExists(atPath: filePath) {
            logInfo("File doesn't exist during manual check: \(filePath)")
            onMissing()
            return
        }
        
        // Force a file metadata update and comparison
        if hasFileChanged() {
            logInfo("Manual check detected file change: \(filePath)")
            onChanged()
            updateFileMetadata()
        } else {
            logInfo("Manual check: No changes detected in file: \(filePath)")
        }
    }
    
    func forceInitialMetadataCheck() {
        // Create a dispatch semaphore to ensure synchronization
        let semaphore = DispatchSemaphore(value: 0)
        
        queue.async {
            // Make sure file exists
            guard FileManager.default.fileExists(atPath: self.filePath) else {
                semaphore.signal()
                return
            }
            
            // Create a snapshot of current content
            self.createTemporaryContentSnapshot()
            
            // Force update the file metadata to establish baseline
            self.updateFileMetadata()
            
            // Check for changes immediately
            self.checkFile()
            
            // Log this action
            logInfo("Established initial file metadata baseline for: \(self.filePath)")
            
            // Signal completion
            semaphore.signal()
        }
        
        // Wait for the queue operations to complete (with timeout)
        _ = semaphore.wait(timeout: .now() + 2.0)
    }
    
    private func setupDirectoryWatcher() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Clean up existing watcher if any
            if self.directoryDescriptor >= 0 {
                self.directorySource?.cancel()
                close(self.directoryDescriptor)
                self.directoryDescriptor = -1
                self.directorySource = nil
            }
            
            // Open directory for monitoring
            self.directoryDescriptor = open(self.directoryPath, O_RDONLY)
            if self.directoryDescriptor < 0 {
                logWarning("Failed to open directory for watching: \(self.directoryPath)")
                return
            }
            
            // Create dispatch source for directory events
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: self.directoryDescriptor,
                eventMask: [.write, .delete, .rename, .link],
                queue: self.queue
            )
            
            source.setEventHandler { [weak self] in
                guard let self = self else { return }
                logInfo("Directory event detected for: \(self.directoryPath)")
                
                // Check if our file exists
                let fileExists = FileManager.default.fileExists(atPath: self.filePath)
                
                // If file doesn't exist and we were previously watching it
                if !fileExists && self.fileDescriptor >= 0 {
                    logInfo("File no longer exists: \(self.filePath)")
                    self.onMissing()
                    
                    // Clean up file watcher
                    self.fileSource?.cancel()
                    close(self.fileDescriptor)
                    self.fileDescriptor = -1
                    self.fileSource = nil
                }
                // If file exists but we weren't watching it (it was restored)
                else if fileExists && self.fileDescriptor < 0 {
                    logInfo("File has been restored: \(self.filePath)")
                    self.setupFileWatcher()
                    self.onChanged() // Trigger the change callback
                }
                // If file exists and we're already watching it
                else if fileExists {
                    // Reset file watcher since the file might have been replaced
                    self.setupFileWatcher()
                }
            }
            
            source.setCancelHandler { [weak self] in
                guard let self = self, self.directoryDescriptor >= 0 else { return }
                close(self.directoryDescriptor)
                self.directoryDescriptor = -1
            }
            
            source.resume()
            self.directorySource = source
            logInfo("Directory watcher set up for: \(self.directoryPath)")
        }
    }
    
    private func setupFileWatcher() {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Clean up existing file watcher if any
            if self.fileDescriptor >= 0 {
                self.fileSource?.cancel()
                close(self.fileDescriptor)
                self.fileDescriptor = -1
                self.fileSource = nil
            }
            
            // Make sure file exists before trying to watch it
            guard FileManager.default.fileExists(atPath: self.filePath) else {
                logWarning("File doesn't exist, can't set up file watcher: \(self.filePath)")
                return
            }
            
            // Update file metadata for initial state
            self.updateFileMetadata()
            
            // Open file for monitoring
            self.fileDescriptor = open(self.filePath, O_RDONLY)
            if self.fileDescriptor < 0 {
                logWarning("Failed to open file for watching: \(self.filePath)")
                return
            }
            
            // Create dispatch source for file events
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: self.fileDescriptor,
                eventMask: [.write, .delete, .extend, .attrib, .rename],
                queue: self.queue
            )
            
            source.setEventHandler { [weak self] in
                guard let self = self else { return }
                
                // Add a small delay to ensure file is completely written
                self.queue.asyncAfter(deadline: .now() + 0.1) {
                    if FileManager.default.fileExists(atPath: self.filePath) {
                        logInfo("File event detected for: \(self.filePath)")
                        
                        // Check if content has actually changed
                        if self.hasFileChanged() {
                            logInfo("File content has changed: \(self.filePath)")
                            self.updateFileMetadata()
                            self.onChanged()
                        }
                    } else {
                        // File doesn't exist anymore
                        logInfo("File no longer exists in file watcher: \(self.filePath)")
                        self.onMissing()
                    }
                }
            }
            
            source.setCancelHandler { [weak self] in
                guard let self = self, self.fileDescriptor >= 0 else { return }
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
            
            source.resume()
            self.fileSource = source
            logInfo("File watcher set up for: \(self.filePath)")
        }
    }
    
    private func checkFile() {
        let fileExists = FileManager.default.fileExists(atPath: filePath)
        
        if !fileExists {
            // File doesn't exist anymore
            logInfo("File no longer exists: \(filePath)")
            onMissing()
            return
        }
        
        // Check if file has changed
        if hasFileChanged() {
            logInfo("File has changed: \(filePath)")
            onChanged()
            updateFileMetadata()
        }
    }
    
    private func hasFileChanged() -> Bool {
        // First check if file exists
        guard FileManager.default.fileExists(atPath: filePath) else {
            return false
        }
        
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: filePath) else {
            return false
        }
        
        let currentModDate = attributes[.modificationDate] as? Date ?? Date()
        let currentSize = attributes[.size] as? UInt64 ?? 0
        
        // If we haven't checked before, update metadata and return true
        if lastModificationDate == nil {
            lastModificationDate = currentModDate
            lastFileSize = currentSize
            return true // Important: Return true for newly created files
        }
        
        // Check if either modification date or size has changed
        let dateChanged = lastModificationDate != currentModDate
        let sizeChanged = lastFileSize != currentSize
        
        // Create a temporary snapshot before checking content
        if dateChanged || sizeChanged {
            createTemporaryContentSnapshot()
        }
        
        // Only do expensive content check if necessary
        let contentChanged = if dateChanged || sizeChanged {
            // For files with changed metadata, do a content check
            if FileManager.default.fileExists(atPath: filePath + ".temp") {
                !FileManager.default.contentsEqual(atPath: filePath, andPath: filePath + ".temp")
            } else {
                // If no temp file to compare against, assume content changed
                true
            }
        } else {
            false // No metadata changes, no need to check content
        }
        
        // Log detailed information for debugging
        if dateChanged || sizeChanged || contentChanged {
            logInfo("File change detected: \(filePath)")
            if dateChanged {
                logInfo("  - Modification date changed: \(String(describing: lastModificationDate)) -> \(currentModDate)")
            }
            if sizeChanged {
                logInfo("  - File size changed: \(lastFileSize) -> \(currentSize)")
            }
            if contentChanged {
                logInfo("  - Content changed detected")
            }
        }
        
        return dateChanged || sizeChanged || contentChanged
    }

    func createInitialTempFile() {
        // Only create if the main file exists but temp doesn't
        if FileManager.default.fileExists(atPath: filePath) &&
           !FileManager.default.fileExists(atPath: filePath + ".temp") {
            try? FileManager.default.copyItem(atPath: filePath, toPath: filePath + ".temp")
            logInfo("Created initial .temp file for comparison at: \(filePath + ".temp")")
        }
    }
    
    private func createTemporaryContentSnapshot() {
        // Create a temporary copy of the file to compare against later
        if FileManager.default.fileExists(atPath: filePath) {
            try? FileManager.default.copyItem(atPath: filePath, toPath: filePath + ".temp")
        }
    }
    
    private func updateFileMetadata() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: filePath) else {
            return
        }
        
        lastModificationDate = attributes[.modificationDate] as? Date
        lastFileSize = attributes[.size] as? UInt64 ?? 0
    }
    
    deinit {
        if directoryDescriptor >= 0 {
            directorySource?.cancel()
            close(directoryDescriptor)
        }
        if fileDescriptor >= 0 {
            fileSource?.cancel()
            close(fileDescriptor)
        }
    }
}

class RecordingsFolderWatcher: @unchecked Sendable {
    private let basePath: String
    private let recordingsPath: String
    private var currentWatchedFolder: String?
    private var folderDispatchSource: DispatchSourceFileSystemObject?
    private var fileDispatchSource: DispatchSourceFileSystemObject?
    private var processedMetaJsons = Set<String>()
    private let fileDescriptorQueue = DispatchQueue(label: "com.macrowhisper.filedescriptor", qos: .userInteractive)
    private var metaJsonFileDescriptor: Int32 = -1
    private var recordingsFolderDescriptor: Int32 = -1
    private var basePathWatcher: FileChangeWatcher?
    
    deinit {
        closeFileDescriptor()
        stopWatchingRecordingsFolder()
    }
    
    init?(basePath: String) {
        self.basePath = basePath
        self.recordingsPath = basePath + "/recordings"
        
        // Set up watcher for the base path to detect if recordings folder is deleted/renamed
        self.basePathWatcher = FileChangeWatcher(
            filePath: basePath,
            onChanged: { [weak self] in
                if let self = self, !self.checkRecordingsFolder() {
                    // Folder doesn't exist, schedule a check for its return
                    self.scheduleRecordingsFolderCheck()
                }
            },
            onMissing: { [weak self] in
                logWarning("Warning: Base superwhisper folder was deleted or replaced!")
                notify(title: "Macrowhisper", message: "Base superwhisper folder was deleted or replaced!")
                self?.stopWatchingRecordingsFolder()
                self?.scheduleRecordingsFolderCheck()
            }
        )
        
        // Initial check for recordings folder
        if !checkRecordingsFolder() {
            logError("Error: recordings folder not found at \(recordingsPath)")
            notify(title: "Macrowhisper", message: "Error: recordings folder not found at \(recordingsPath)")
            scheduleRecordingsFolderCheck()
            return nil
        }
        
        // Mark current newest folder as "already processed"
        if let newestFolder = findNewestFolder() {
            currentWatchedFolder = newestFolder
            logInfo("Initial run: Marking current newest folder as already processed")
            
            // Also mark existing meta.json as processed if it exists
            let metaJsonPath = newestFolder + "/meta.json"
            if FileManager.default.fileExists(atPath: metaJsonPath) {
                processedMetaJsons.insert(metaJsonPath)
                logInfo("Initial run: Marking existing meta.json as already processed")
            }
        }
        
        // Start watching recordings folder
        startWatchingRecordingsFolder()
    }
    
    private func simulateReturnKeyPress() {
        // Add a delay before simulating the Return key press
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { // delay
            // 36 is the keycode for Return key
            self.simulateKeyDown(key: 36)
        }
    }
    
    private func processAction(_ action: String, metaJson: [String: Any]) -> (String, Bool) {
        // Check if this is the special .autoPaste action
        let isAutoPaste = action == ".autoPaste"
        
        // If action is ".none", return empty string
        if action == ".none" {
            return ("", false)
        }
        
        // For .autoPaste, we'll use the swResult value directly
        if isAutoPaste {
            let swResult: String
            if let llm = metaJson["llmResult"] as? String, !llm.isEmpty {
                swResult = llm
            } else if let res = metaJson["result"] as? String, !res.isEmpty {
                swResult = res
            } else {
                swResult = ""
            }
            return (swResult, true)
        }
        
        var result = action
        
        // Process XML tags in llmResult if present
        var processedLlmResult = ""
        var extractedTags: [String: String] = [:]
        
        if let llmResult = metaJson["llmResult"] as? String, !llmResult.isEmpty {
            // Process XML tags and get cleaned llmResult and extracted tags
            let processed = processXmlPlaceholders(action: action, llmResult: llmResult)
            processedLlmResult = processed.0  // Store the cleaned result
            extractedTags = processed.1
            
            // Update the metaJson with the cleaned llmResult
            var updatedMetaJson = metaJson
            updatedMetaJson["llmResult"] = processedLlmResult
            
            // If swResult would be derived from llmResult, update it too
            if metaJson["result"] == nil || (metaJson["result"] as? String)?.isEmpty == true {
                updatedMetaJson["swResult"] = processedLlmResult
            }
            
            // Process all dynamic placeholders using updatedMetaJson
            result = processDynamicPlaceholders(action: result, metaJson: updatedMetaJson)
        } else {
            // No llmResult to process, just handle regular placeholders
            result = processDynamicPlaceholders(action: result, metaJson: metaJson)
            
            // Process XML placeholders with regular result if llmResult doesn't exist
            if let regularResult = metaJson["result"] as? String, !regularResult.isEmpty {
                let processed = processXmlPlaceholders(action: action, llmResult: regularResult)
                extractedTags = processed.1
            }
        }
        
        // Replace XML placeholders with extracted content or remove them
        result = replaceXmlPlaceholders(action: result, extractedTags: extractedTags)
        
        // Process newlines - convert literal "\n" to actual newlines
        result = result.replacingOccurrences(of: "\\n", with: "\n")
        
        return (result, false)
    }

    // New helper function to process dynamic placeholders
    private func processDynamicPlaceholders(action: String, metaJson: [String: Any]) -> String {
        logInfo("[DatePlaceholder] processDynamicPlaceholders called with action: \(action)")
        var result = action
        var metaJson = metaJson // Make mutable copy
        // Regex for {{key}} and {{date:...}}
        let placeholderPattern = "\\{\\{([A-Za-z0-9_]+)(?::([^}]+))?\\}\\}"
        let placeholderRegex = try? NSRegularExpression(pattern: placeholderPattern, options: [])
        // --- BEGIN: FrontApp Placeholder Logic ---
        // Only fetch the front app if the placeholder is present and not already in metaJson
        if action.contains("{{frontApp}}") && metaJson["frontApp"] == nil {
            // Use frontAppName from metaJson if present (set by trigger evaluation)
            var appName: String? = nil
            if let fromTrigger = metaJson["frontAppName"] as? String, !fromTrigger.isEmpty {
                appName = fromTrigger
            } else if let app = lastDetectedFrontApp {
                appName = app.localizedName
            } else {
                // Fetch the frontmost application (synchronously, main thread safe)
                if Thread.isMainThread {
                    appName = NSWorkspace.shared.frontmostApplication?.localizedName
                } else {
                    var fetchedApp: NSRunningApplication?
                    let semaphore = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async {
                        fetchedApp = NSWorkspace.shared.frontmostApplication
                        semaphore.signal()
                    }
                    _ = semaphore.wait(timeout: .now() + 0.1)
                    appName = fetchedApp?.localizedName
                }
            }
            metaJson["frontApp"] = appName ?? ""
            logInfo("[FrontAppPlaceholder] Set frontApp in metaJson: \(appName ?? "<none>")")
        }
        // --- END: FrontApp Placeholder Logic ---
        if let matches = placeholderRegex?.matches(in: action, options: [], range: NSRange(action.startIndex..., in: action)) {
            for match in matches.reversed() {
                guard let keyRange = Range(match.range(at: 1), in: action),
                      let fullMatchRange = Range(match.range, in: action) else { continue }
                let key = String(action[keyRange])
                let format: String? = (match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound) ? String(action[Range(match.range(at: 2), in: action)!]) : nil
                logInfo("[DatePlaceholder] Found placeholder: key=\(key), format=\(String(describing: format)) in \(action[fullMatchRange])")
                // Check for date placeholder
                if key == "date" {
                    let dateFormat = format ?? "short"
                    let replacement: String
                    switch dateFormat {
                    case "short":
                        let formatter = DateFormatter()
                        formatter.dateStyle = .short
                        formatter.timeStyle = .none
                        replacement = formatter.string(from: Date())
                    case "long":
                        let formatter = DateFormatter()
                        formatter.dateStyle = .long
                        formatter.timeStyle = .none
                        replacement = formatter.string(from: Date())
                    default:
                        let formatter = DateFormatter()
                        // Heuristic: if format is only letters, treat as template; else treat as literal format string
                        let isTemplate = dateFormat.range(of: "[^A-Za-z]", options: .regularExpression) == nil
                        if isTemplate {
                            formatter.setLocalizedDateFormatFromTemplate(dateFormat)
                            logInfo("[DatePlaceholder] Using UTS 35 template: \(dateFormat) -> \(formatter.dateFormat ?? "nil")")
                        } else {
                            formatter.dateFormat = dateFormat
                            logInfo("[DatePlaceholder] Using literal dateFormat: \(dateFormat)")
                        }
                        replacement = formatter.string(from: Date())
                    }
                    logInfo("[DatePlaceholder] Replacing {{date:\(dateFormat)}} with \(replacement)")
                    result.replaceSubrange(fullMatchRange, with: replacement)
                    continue
                }
                // Handle swResult
                if key == "swResult" {
                    let value: String
                    if let llm = metaJson["llmResult"] as? String, !llm.isEmpty {
                        value = llm
                    } else if let res = metaJson["result"] as? String, !res.isEmpty {
                        value = res
                    } else {
                        value = ""
                    }
                    result.replaceSubrange(fullMatchRange, with: value)
                } else if let jsonValue = metaJson[key] {
                    let value: String
                    if let stringValue = jsonValue as? String {
                        value = stringValue
                    } else if let numberValue = jsonValue as? NSNumber {
                        value = numberValue.stringValue
                    } else if let boolValue = jsonValue as? Bool {
                        value = boolValue ? "true" : "false"
                    } else if jsonValue is NSNull {
                        value = ""
                    } else if let jsonData = try? JSONSerialization.data(withJSONObject: jsonValue),
                              let jsonString = String(data: jsonData, encoding: .utf8) {
                        value = jsonString
                    } else {
                        value = String(describing: jsonValue)
                    }
                    result.replaceSubrange(fullMatchRange, with: value)
                } else {
                    // Key doesn't exist in metaJson, remove the placeholder
                    result.replaceSubrange(fullMatchRange, with: "")
                }
            }
        }
        return result
    }


    private func applyInsert(_ text: String, activeInsert: AppConfiguration.Insert?, isAutoPaste: Bool = false) {
        // If text is empty or just whitespace, just simulate ESC key press and return
        if text.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == ".none" {
            simulateEscKeyPress(activeInsert: activeInsert)
            return
        }
        
        // Get the delay value - insert-specific overrides global default
        let delay: Double
        if let insert = activeInsert, let insertDelay = insert.actionDelay {
            delay = insertDelay
        } else {
            delay = configManager.config.defaults.actionDelay
        }
        
        // Apply delay if it's greater than 0
        if delay > 0 {
            logInfo("Applying configured delay of \(delay) seconds before action")
            Thread.sleep(forTimeInterval: delay)
        }
        
        // For .autoPaste, check if we're in an input field
        if isAutoPaste {
            if !requestAccessibilityPermission() {
                logWarning("Accessibility permission denied - cannot check for input field")
                return
            }
            
            let inInputField = isInInputField()
            
            if !inInputField {
                logInfo("Auto paste - not in an input field, proceeding with direct paste only")
                
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                simulateKeyDown(key: 9, flags: .maskCommand) // 9 is the keycode for 'V'
                
                // Check for pressReturn after auto paste
                checkAndSimulatePressReturn(activeInsert: activeInsert)
                return
            }
            
            logInfo("Auto paste - in input field, proceeding with standard paste")
        }
        
        // First, simulate ESC key press
        simulateEscKeyPress(activeInsert: activeInsert)
        
        // Check if we should simulate key presses
        let shouldSimulateKeypresses: Bool
        if let insert = activeInsert, let insertSimKeypress = insert.simKeypress {
            shouldSimulateKeypresses = insertSimKeypress
        } else {
            shouldSimulateKeypresses = configManager.config.defaults.simKeypress
        }
        
        if shouldSimulateKeypresses {
            let lines = text.components(separatedBy: "\n")
            
            let scriptLines = lines.enumerated().map { index, line -> String in
                let escapedLine = line.replacingOccurrences(of: "\\", with: "\\\\")
                                     .replacingOccurrences(of: "\"", with: "\\\"")
                
                if index > 0 {
                    return "keystroke return\nkeystroke \"\(escapedLine)\""
                } else {
                    return "keystroke \"\(escapedLine)\""
                }
            }.joined(separator: "\n")
            
            let script = """
            tell application "System Events"
                \(scriptLines)
            end tell
            """
            
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            
            do {
                try task.run()
                task.waitUntilExit()
                logInfo("Applied text using simulated keystrokes with line breaks")
            } catch {
                logError("Failed to simulate keystrokes: \(error.localizedDescription)")
                pasteUsingClipboard(text)
            }
        } else {
            pasteUsingClipboard(text)
        }
        
        // Check for pressReturn after normal insert application
        checkAndSimulatePressReturn(activeInsert: activeInsert)
    }

    private func checkAndSimulatePressReturn(activeInsert: AppConfiguration.Insert?) {
        // Check if pressReturn should be applied
        let shouldPressReturn: Bool
        
        // Check insert-specific pressReturn setting first
        if let insert = activeInsert, let insertPressReturn = insert.pressReturn {
            shouldPressReturn = insertPressReturn
            // If the insert has pressReturn enabled and auto-return is enabled,
            // we'll let the insert's pressReturn handle it and disable auto-return
            if shouldPressReturn && autoReturnEnabled {
                autoReturnEnabled = false
                logInfo("Auto-return disabled because insert has pressReturn enabled")
            }
        } else {
            // Fall back to global default if no insert-specific setting
            shouldPressReturn = configManager.config.defaults.pressReturn
        }
        
        // If no insert pressReturn is enabled but auto-return is, use that
        if !shouldPressReturn && autoReturnEnabled {
            logInfo("Simulating return key press due to auto-return")
            simulateReturnKeyPress()
            // Reset the flag after using it
            autoReturnEnabled = false
            return
        }
        
        // Otherwise use the regular pressReturn setting
        if shouldPressReturn {
            logInfo("Simulating return key press due to pressReturn setting")
            simulateReturnKeyPress()
        }
    }

    private func pasteUsingClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let originalClipboardContent = pasteboard.string(forType: .string)
        
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // Paste using accessibility APIs
        simulateKeyDown(key: 9, flags: .maskCommand) // 9 is the keycode for 'V'
        
        // Restore the original clipboard content after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.clearContents()
            if let originalContent = originalClipboardContent {
                pasteboard.setString(originalContent, forType: .string)
            }
        }
    }

    private func simulateEscKeyPress(activeInsert: AppConfiguration.Insert?) {
        // First check if there's an insert-specific noEsc setting
        if let insert = activeInsert, let insertNoEsc = insert.noEsc {
            // Use the insert-specific setting if available
            if insertNoEsc {
                logInfo("ESC key simulation disabled by insert-specific noEsc setting")
                return
            }
        }
        // Otherwise fall back to the global setting
        else if configManager.config.defaults.noEsc {
            logInfo("ESC key simulation disabled by global noEsc setting")
            return
        }
        
        // Simulate ESC key press
        simulateKeyDown(key: 53)
    }
    
    private func simulateKeyDown(key: Int, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Convert Int to UInt16 (CGKeyCode)
        let keyCode = CGKeyCode(key)
        
        let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDownEvent?.flags = flags

        let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUpEvent?.flags = flags

        keyDownEvent?.post(tap: .cghidEventTap)
        keyUpEvent?.post(tap: .cghidEventTap)
    }
    
    private func checkRecordingsFolder() -> Bool {
        if !FileManager.default.fileExists(atPath: recordingsPath) {
            logWarning("Warning: recordings folder not found at \(recordingsPath). Waiting for it to be restored.")
            notify(title: "Macrowhisper", message: "Warning: recordings folder not found. Waiting for it to be restored.")
            stopWatchingRecordingsFolder()
            return false
        }
        return true
    }
    
    private func scheduleRecordingsFolderCheck() {
        // Notify the user once about the missing folder
        logWarning("Warning: recordings folder not found. Please check the path.")
        notify(title: "Macrowhisper", message: "Recordings folder not found. Please check the path.")
        
        // No timer or further checks - watcher remains disabled until user reloads config
    }
    
    private func stopWatchingRecordingsFolder() {
        folderDispatchSource?.cancel()
        folderDispatchSource = nil
        
        if recordingsFolderDescriptor >= 0 {
            close(recordingsFolderDescriptor)
            recordingsFolderDescriptor = -1
        }
        
        // Also stop watching any current file
        cancelFileWatcher()
    }
    
    private func startWatchingRecordingsFolder() {
        // Use low-level file descriptor and GCD to watch for changes
        fileDescriptorQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Stop any existing watcher first
            self.stopWatchingRecordingsFolder()
            
            self.recordingsFolderDescriptor = open(self.recordingsPath, O_EVTONLY)
            if self.recordingsFolderDescriptor < 0 {
                logError("Error: Unable to open file descriptor for recordings folder")
                self.scheduleRecordingsFolderCheck()
                return
            }
            
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: self.recordingsFolderDescriptor,
                eventMask: [.write, .link, .rename, .delete],
                queue: self.fileDescriptorQueue
            )
            
            source.setEventHandler { [weak self] in
                guard let self = self else { return }
                
                // Check if recordings folder still exists
                if !FileManager.default.fileExists(atPath: self.recordingsPath) {
                    logWarning("Warning: recordings folder was deleted or replaced!")
                    notify(title: "Macrowhisper", message: "Warning: recordings folder was deleted or replaced!")
                    self.stopWatchingRecordingsFolder()
                    self.scheduleRecordingsFolderCheck()
                    return
                }
                
                self.checkForNewFolder()
            }
            
            source.setCancelHandler { [weak self] in
                if let fd = self?.recordingsFolderDescriptor, fd >= 0 {
                    close(fd)
                    self?.recordingsFolderDescriptor = -1
                }
            }
            
            source.resume()
            self.folderDispatchSource = source
            
            // Do initial check
            self.checkForNewFolder()
        }
    }
    
    private func findNewestFolder() -> String? {
        // Get all subdirectories in recordings folder
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: recordingsPath),
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            logError("Error: Failed to read contents of recordings folder")
            notify(title: "Macrowhisper", message: "Error: Failed to read contents of recordings folder")
            return nil
        }
        
        // Filter for directories only
        let directories = contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
        
        // Sort by creation date (newest first)
        let sortedDirs = directories.sorted { dir1, dir2 in
            let date1 = try? dir1.resourceValues(forKeys: [.creationDateKey]).creationDate
            let date2 = try? dir2.resourceValues(forKeys: [.creationDateKey]).creationDate
            return (date1 ?? Date.distantPast) > (date2 ?? Date.distantPast)
        }
        
        // Get newest directory
        return sortedDirs.first?.path
    }
    
    private func checkForNewFolder() {
        guard let newestFolder = findNewestFolder() else {
            logInfo("No subdirectories found in recordings folder")
            return
        }
        
        // If we're already watching this folder, do nothing
        if newestFolder == currentWatchedFolder {
            return
        }
        
        logInfo("New folder detected: \(URL(fileURLWithPath: newestFolder).lastPathComponent)")
        currentWatchedFolder = newestFolder
        
        // Stop watching old folder
        cancelFileWatcher()
        
        // Watch for meta.json in the new folder
        watchForMetaJson(in: newestFolder)
    }
    
    private func handleMoveToSetting(folderPath: String, activeInsert: AppConfiguration.Insert?) {
        // Get the appropriate moveTo setting (insert overrides default)
        let moveToValue: String?
        
        if let insert = activeInsert, let insertMoveTo = insert.moveTo {
            // Only use insert's moveTo if it's not empty
            if !insertMoveTo.isEmpty {
                moveToValue = insertMoveTo
            } else {
                // Empty string in insert should fall back to default
                moveToValue = configManager.config.defaults.moveTo
            }
        } else {
            // No insert moveTo setting, use default
            moveToValue = configManager.config.defaults.moveTo
        }
        
        // If no moveTo value is set, do nothing
        guard let moveToPath = moveToValue, !moveToPath.isEmpty else {
            return
        }
        
        // Process the moveTo setting
        DispatchQueue.global(qos: .background).async {
            // Add a small delay to ensure all file operations are complete
            Thread.sleep(forTimeInterval: 0.5)
            
            if moveToPath == ".delete" {
                // Delete the folder
                do {
                    try FileManager.default.removeItem(atPath: folderPath)
                    logInfo("Deleted folder: \(folderPath)")
                } catch {
                    logError("Failed to delete folder: \(error.localizedDescription)")
                }
            } else if moveToPath == ".none" {
                // Explicitly do nothing
                logInfo("Keeping folder in place as requested by .none setting")
            } else {
                // Move the folder to the specified path
                let destinationParentPath = (moveToPath as NSString).expandingTildeInPath
                let folderName = (folderPath as NSString).lastPathComponent
                let destinationPath = (destinationParentPath as NSString).appendingPathComponent(folderName)
                
                // Create destination directory if it doesn't exist
                if !FileManager.default.fileExists(atPath: destinationParentPath) {
                    do {
                        try FileManager.default.createDirectory(atPath: destinationParentPath,
                                                              withIntermediateDirectories: true)
                        logInfo("Created destination directory: \(destinationParentPath)")
                    } catch {
                        logError("Failed to create destination directory: \(error.localizedDescription)")
                        return
                    }
                }
                
                // Move the folder
                do {
                    // If destination already exists, remove it first
                    if FileManager.default.fileExists(atPath: destinationPath) {
                        try FileManager.default.removeItem(atPath: destinationPath)
                    }
                    
                    try FileManager.default.moveItem(atPath: folderPath, toPath: destinationPath)
                    logInfo("Moved folder from \(folderPath) to \(destinationPath)")
                } catch {
                    logError("Failed to move folder: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func cancelFileWatcher() {
        fileDispatchSource?.cancel()
        fileDispatchSource = nil
        closeFileDescriptor()
    }
    
    private func closeFileDescriptor() {
        if metaJsonFileDescriptor >= 0 {
            close(metaJsonFileDescriptor)
            metaJsonFileDescriptor = -1
        }
    }
    
    private func watchForMetaJson(in folderPath: String) {
        // Use low-level file descriptor and GCD to watch for changes
        fileDescriptorQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Cancel any existing watcher
            self.cancelFileWatcher()
            
            let fileDescriptor = open(folderPath, O_EVTONLY)
            if fileDescriptor < 0 {
                logError("Error: Unable to open file descriptor for folder")
                return
            }
            
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileDescriptor,
                eventMask: [.write, .link, .rename],
                queue: self.fileDescriptorQueue
            )
            
            source.setEventHandler { [weak self] in
                guard let self = self else { return }
                
                let metaJsonPath = folderPath + "/meta.json"
                if FileManager.default.fileExists(atPath: metaJsonPath) && !self.processedMetaJsons.contains(metaJsonPath) {
                    self.checkMetaJson(at: metaJsonPath)
                }
            }
            
            source.setCancelHandler {
                close(fileDescriptor)
            }
            
            source.resume()
            self.fileDispatchSource = source
            
            // Check immediately if meta.json already exists
            let metaJsonPath = folderPath + "/meta.json"
            if FileManager.default.fileExists(atPath: metaJsonPath) && !self.processedMetaJsons.contains(metaJsonPath) {
                self.checkMetaJson(at: metaJsonPath)
            }
        }
    }
    
    private func checkMetaJson(at path: String) {
        // Directly monitor the meta.json file for changes
        if metaJsonFileDescriptor < 0 {
            metaJsonFileDescriptor = open(path, O_EVTONLY)
            if metaJsonFileDescriptor >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: metaJsonFileDescriptor,
                    eventMask: [.write, .delete],
                    queue: fileDescriptorQueue
                )
                
                source.setEventHandler { [weak self] in
                    self?.readAndProcessMetaJson(at: path)
                }
                
                source.setCancelHandler { [weak self] in
                    self?.closeFileDescriptor()
                }
                
                source.resume()
                self.fileDispatchSource = source
            }
        }
        
        // Also check immediately
        readAndProcessMetaJson(at: path)
    }
    
    private func readAndProcessMetaJson(at path: String) {
        // Don't process if already handled
        if processedMetaJsons.contains(path) {
            return
        }
        
        // Check if file still exists
        if !FileManager.default.fileExists(atPath: path) {
            logInfo("meta.json was deleted")
            
            // Deactivate auto-return if it was active
            if autoReturnEnabled {
                autoReturnEnabled = false
                logInfo("Auto-return disabled because meta.json was deleted")
            }
            
            return
        }
        
        // Read file with low-level APIs for speed
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .uncached),
              let json = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any] else {
            logError("Error: Failed to read meta.json or invalid JSON format")
            return
        }
        
        // Check if result key exists and has a non-null, non-empty value
        if let result = json["result"],
           !(result is NSNull),
           !String(describing: result).isEmpty {
            // Mark this file as processed immediately to prevent duplicate triggers
            processedMetaJsons.insert(path)
            // Always update lastDetectedFrontApp to the current frontmost app for app triggers
            if Thread.isMainThread {
                lastDetectedFrontApp = NSWorkspace.shared.frontmostApplication
            } else {
                var frontApp: NSRunningApplication?
                DispatchQueue.main.sync {
                    frontApp = NSWorkspace.shared.frontmostApplication
                }
                lastDetectedFrontApp = frontApp
            }
            // --- End update front app ---
            
            // Get front app info for app triggers
            var frontAppName: String? = nil
            var frontAppBundleId: String? = nil
            if let app = lastDetectedFrontApp {
                frontAppName = app.localizedName
                frontAppBundleId = app.bundleIdentifier
            }
            let modeName = json["modeName"] as? String
            
            // Store all matched actions with their stripped results
            var matchedTriggerActions: [(action: Any, name: String, strippedResult: String?)] = []
            
            // Evaluate all inserts for triggers
            for insert in configManager.config.inserts {
                let (matched, strippedResult) = triggersMatch(for: insert, result: String(describing: result), modeName: modeName, frontAppName: frontAppName, frontAppBundleId: frontAppBundleId)
                if matched {
                    matchedTriggerActions.append((action: insert, name: insert.name, strippedResult: strippedResult))
                }
            }
            
            // Evaluate all URL actions for triggers
            for url in configManager.config.urls {
                let (matched, strippedResult) = triggersMatch(for: url, result: String(describing: result), modeName: modeName, frontAppName: frontAppName, frontAppBundleId: frontAppBundleId)
                if matched {
                    matchedTriggerActions.append((action: url, name: url.name, strippedResult: strippedResult))
                }
            }
            
            // Evaluate all shortcut actions for triggers
            for shortcut in configManager.config.shortcuts {
                logInfo("[TriggerEval] Checking shortcut action: name=\(shortcut.name), triggerVoice=\(shortcut.triggerVoice ?? "nil"), triggerApps=\(shortcut.triggerApps ?? "nil"), triggerModes=\(shortcut.triggerModes ?? "nil"), triggerLogic=\(shortcut.triggerLogic ?? "nil")")
                let (matched, strippedResult) = triggersMatch(for: shortcut, result: String(describing: result), modeName: modeName, frontAppName: frontAppName, frontAppBundleId: frontAppBundleId)
                if matched {
                    matchedTriggerActions.append((action: shortcut, name: shortcut.name, strippedResult: strippedResult))
                }
            }
            
            if !matchedTriggerActions.isEmpty {
                // Sort actions by name and pick the first
                let (action, name, strippedResult) = matchedTriggerActions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.first!
                logInfo("[TriggerEval] Action '\(name)' selected for execution due to trigger match.")
                
                // Prepare metaJson with updated result and swResult if voice trigger matched
                var updatedJson = json
                if let stripped = strippedResult {
                    updatedJson["result"] = stripped
                    updatedJson["swResult"] = stripped
                }
                
                // Handle the action based on its type
                if let insert = action as? AppConfiguration.Insert {
                    let (processedAction, isAutoPasteResult) = self.processAction(insert.action, metaJson: updatedJson)
                    self.applyInsert(
                        processedAction,
                        activeInsert: insert,
                        isAutoPaste: insert.action == ".autoPaste" || isAutoPasteResult
                    )
                    self.handleMoveToSetting(folderPath: (path as NSString).deletingLastPathComponent, activeInsert: insert)
                } else if let url = action as? AppConfiguration.Url {
                    self.processUrlAction(url, metaJson: updatedJson)
                    self.handleMoveToSetting(folderPath: (path as NSString).deletingLastPathComponent, activeInsert: nil)
                } else if let shortcut = action as? AppConfiguration.Shortcut {
                    self.processShortcutAction(shortcut, metaJson: updatedJson)
                    self.handleMoveToSetting(folderPath: (path as NSString).deletingLastPathComponent, activeInsert: nil)
                }
                
                // Continue processing to allow auto-return to work if enabled
                return
            }
            // --- End Unified Trigger Matching ---
            
            if autoReturnEnabled {
                // Apply the result directly using {{swResult}}
                let resultValue = json["result"] as? String ?? json["llmResult"] as? String ?? ""
                
                // Process the result
                let processedAction = resultValue
                
                // Apply the result (simulate ESC key press and paste the action)
                self.applyInsert(processedAction, activeInsert: nil)
                
                // Simulate a return key press after pasting
                self.simulateReturnKeyPress()
                
                // Reset the flag after using it once
                autoReturnEnabled = false
                
                logInfo("Applied auto-return with result")
            } else if let activeInsertName = configManager.config.defaults.activeInsert,
               !activeInsertName.isEmpty {
                // Find the active insert in the inserts array
                if let insert = configManager.config.inserts.first(where: { $0.name == activeInsertName }) {
                    // Check for .autoPaste special case
                    let isAutoPaste = insert.action == ".autoPaste"
                    
                    // Process the insert action with the meta.json values
                    let (processedAction, isAutoPasteResult) = self.processAction(insert.action, metaJson: json)
                    
                    // Apply the insert (simulate ESC key press and paste the action)
                    self.applyInsert(processedAction, activeInsert: insert, isAutoPaste: isAutoPaste || isAutoPasteResult)
                    
                    logInfo("Applied insert '\(activeInsertName)' with processed action")
                    // Handle moveTo setting after insert is applied
                    self.handleMoveToSetting(folderPath: (path as NSString).deletingLastPathComponent,
                                             activeInsert: insert)
                } else {
                    logWarning("Active insert '\(activeInsertName)' not found in configuration")
                    // Even if insert not found, still handle default moveTo
                    self.handleMoveToSetting(folderPath: (path as NSString).deletingLastPathComponent,
                                            activeInsert: nil)
                }
            } else {
                // No active insert, do nothing
                logInfo("Found valid result in meta.json, but no active insert configured. Taking no action.")
                
                // Still handle default moveTo setting if configured
                self.handleMoveToSetting(folderPath: (path as NSString).deletingLastPathComponent,
                                        activeInsert: nil)
            }
            
            // Move these operations to a background queue to not block the trigger
            DispatchQueue.global(qos: .background).async { [weak self] in
                guard let self = self else { return }
                // Cancel file watcher since we're done with this file
                self.cancelFileWatcher()
                
                // Perform history cleanup if needed
                historyManager?.performHistoryCleanup()
                
                // Add a delay before checking for updates
                DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 25) {
                    // Check for updates after delay
                    versionChecker.checkForUpdates()
                }
            }
        }
    }

    // Add this method inside RecordingsFolderWatcher
    private func processUrlAction(_ urlAction: AppConfiguration.Url, metaJson: [String: Any]) {
        // Process the URL action with placeholders
        let (processedAction, _) = self.processAction(urlAction.action, metaJson: metaJson)
        
        // URL encode the processed action
        guard let encodedUrl = processedAction.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed),
              let url = URL(string: encodedUrl) else {
            logError("Invalid URL after processing: \(processedAction)")
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
                logError("Failed to open URL with specified app: \(error)")
                // Fallback to default URL handling
                NSWorkspace.shared.open(url)
            }
        } else {
            // Open with default handler
            NSWorkspace.shared.open(url)
        }
        
        // Handle ESC key press if not disabled
        if !(urlAction.noEsc ?? false) {
            self.simulateEscKeyPress(activeInsert: nil)
        }
        
        // Handle action delay
        if let delay = urlAction.actionDelay, delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        
        // Disable auto-return if it was enabled
        autoReturnEnabled = false
    }
    
    private func processShortcutAction(_ shortcutAction: AppConfiguration.Shortcut, metaJson: [String: Any]) {
        let (processedAction, _) = self.processAction(shortcutAction.action, metaJson: metaJson)
        let shortcutName = shortcutAction.name

        let task = Process()
        task.launchPath = "/usr/bin/shortcuts"
        task.arguments = ["run", shortcutName, "-i", "-"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        let inputPipe = Pipe()
        task.standardInput = inputPipe

        do {
            try task.run()
            // Write the action to stdin
            if let data = processedAction.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            inputPipe.fileHandleForWriting.closeFile()
            logInfo("Shortcut '\(shortcutName)' launched asynchronously with direct stdin input")
        } catch {
            logError("Failed to execute shortcut action: \(error)")
        }

        if !(shortcutAction.noEsc ?? false) {
            self.simulateEscKeyPress(activeInsert: nil)
        }
        if let delay = shortcutAction.actionDelay, delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        autoReturnEnabled = false
    }
}

class ConfigurationManager {
    private let configFilePath: String
    private var previousWatchPath: String? // Add tracking for watch path changes
    
    // Make configPath accessible
    var configPath: String {
        return self.configFilePath
    }
    
    private let fileManager = FileManager.default
    private let syncQueue = DispatchQueue(label: "com.macrowhisper.configsync")
    private var fileWatcher: FileChangeWatcher?
    private let commandQueue = DispatchQueue(label: "com.macrowhisper.commandqueue", qos: .userInitiated)
    private var pendingCommands: [(arguments: [String: String], completion: (() -> Void)?)] = []
    private var isProcessingCommands = false
    
    // Add a property to track if we've already notified about JSON errors
    private var hasNotifiedAboutJsonError = false
    
    // --- Suppression flag for internal config writes ---
    private var suppressNextConfigReload = false // If true, skip reload on next file watcher event
    // --------------------------------------------------
    
    // Make config publicly accessible
    var config: AppConfiguration
    
    // Callback for configuration changes
    var onConfigChanged: ((_ reason: String?) -> Void)?
    
    init(configPath: String? = nil) {
        // Initialize properties first
        if let path = configPath {
            self.configFilePath = path
        } else {
            let configDir = ("~/.config/macrowhisper" as NSString).expandingTildeInPath
            self.configFilePath = "\(configDir)/macrowhisper.json"
        }
        
        // Initialize config with a default value first
        self.config = AppConfiguration.defaultConfig()
        self.previousWatchPath = self.config.defaults.watch
        hasNotifiedAboutJsonError = false
        
        // Create directory if it doesn't exist
        let directory = (self.configFilePath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: directory) {
            try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        
        // Check if config file exists
        let fileExistedBefore = fileManager.fileExists(atPath: self.configFilePath)
        
        if fileExistedBefore {
            // If file exists, attempt to load it
            if let loadedConfig = loadConfig() {
                self.config = loadedConfig
                logInfo("Configuration loaded from \(self.configFilePath)")
            } else {
                // If loading fails but file exists, don't overwrite it
                logWarning("Failed to load configuration due to invalid JSON. Using defaults in memory only.")
                // We're keeping the default config in memory but NOT saving it to disk
                // Notification is already handled in loadConfig()
            }
        } else {
            // File doesn't exist, create it with defaults
            saveConfig()
            logInfo("Default configuration created at \(self.configFilePath)")
        }
        
        // Set up file watcher for config changes
        setupFileWatcher()
        
        // If we just created the file, reinitialize the watcher
        if !fileExistedBefore && fileManager.fileExists(atPath: self.configFilePath) {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.setupFileWatcher()
                logInfo("File watcher reinitialized after creating config file")
                
                // Force an immediate check
                self?.fileWatcher?.checkForChangesNow()
            }
        }
    }
    
    func updateFromCommandLineAsync(arguments: [String: String], completion: (() -> Void)? = nil) {
        // Immediately add to queue
        commandQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Add to pending commands
            self.pendingCommands.append((arguments: arguments, completion: completion))
            
            // Start processing if not already doing so
            if !self.isProcessingCommands {
                self.processNextCommand()
            }
        }
    }
    
    private func processNextCommand() {
        commandQueue.async { [weak self] in
            guard let self = self else { return }
            
            // If no commands or already processing, exit
            if self.pendingCommands.isEmpty || self.isProcessingCommands {
                return
            }
            
            // Mark as processing
            self.isProcessingCommands = true
            
            // Get next command
            let command = self.pendingCommands.removeFirst()
            
            // Extract arguments
            let args = command.arguments
            let watchPath = args["watch"]
            let activeInsert = args["activeInsert"]
            let icon = args["icon"]
            let moveTo = args["moveTo"]
            
            // Parse boolean values from strings
            let noUpdatesStr = args["noUpdates"]
            let noNotiStr = args["noNoti"]
            let noEscStr = args["noEsc"]
            let simKeypressStr = args["simKeypress"]
            let pressReturnStr = args["pressReturn"]
            
            // Convert string values to boolean values
            let noUpdates = noUpdatesStr == "true" ? true : (noUpdatesStr == "false" ? false : nil)
            let noNoti = noNotiStr == "true" ? true : (noNotiStr == "false" ? false : nil)
            let noEsc = noEscStr == "true" ? true : (noEscStr == "false" ? false : nil)
            let simKeypress = simKeypressStr == "true" ? true : (simKeypressStr == "false" ? false : nil)
            let pressReturn = pressReturnStr == "true" ? true : (pressReturnStr == "false" ? false : nil)  // Add this line

            // Update configuration with values
            self.syncQueue.sync {
                // First, reload the latest config from disk
                if let freshConfig = self.loadConfig() {
                    self.config = freshConfig
                }
                
                // --- FIX: Store old watch path before updating ---
                let oldWatchPath = self.config.defaults.watch
                // Update config values
                if let watchPath = watchPath {
                    self.config.defaults.watch = watchPath
                }
                if let noUpdates = noUpdates {
                    self.config.defaults.noUpdates = noUpdates
                }
                if let noNoti = noNoti {
                    self.config.defaults.noNoti = noNoti
                }
                if let activeInsert = activeInsert {
                    self.config.defaults.activeInsert = activeInsert
                }
                if let icon = icon {
                    self.config.defaults.icon = icon
                }
                if let moveTo = moveTo {
                    self.config.defaults.moveTo = moveTo
                }
                if let noEsc = noEsc {
                    self.config.defaults.noEsc = noEsc
                }
                if let simKeypress = simKeypress {
                    self.config.defaults.simKeypress = simKeypress
                }
                if let pressReturn = pressReturn {
                    self.config.defaults.pressReturn = pressReturn
                }
                if let actionDelayStr = args["actionDelay"], let actionDelay = Double(actionDelayStr) {
                    self.config.defaults.actionDelay = actionDelay
                }
                if let historyStr = args["history"] {
                    if historyStr == "null" || historyStr.isEmpty {
                        self.config.defaults.history = nil
                    } else if let history = Int(historyStr) {
                        self.config.defaults.history = history
                    }
                }
                
                // Save the configuration
                self.saveConfig()
                
                // Call onConfigChanged callback
                DispatchQueue.main.async {
                    // --- FIX: Compare old and new watch path correctly ---
                    let newWatchPath = self.config.defaults.watch
                    let reason = (oldWatchPath != newWatchPath) ? "watchPathChanged" : nil
                    self.onConfigChanged?(reason)
                    // Execute completion handler if provided
                    command.completion?()
                    // Mark as not processing and check for more commands
                    self.isProcessingCommands = false
                    self.processNextCommand()
                }
            }
        }
    }
    
    func resetFileWatcher() {
        logInfo("Resetting file watcher due to previous JSON error...")
        
        // Stop and clean up the current file watcher
        fileWatcher = nil
        
        // Set up a new file watcher with a small delay to ensure clean state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.setupFileWatcher()
            logInfo("File watcher has been reset and reinitialized")
            
            // Force an immediate check
            self.fileWatcher?.checkForChangesNow()
        }
    }
    
    private func setupFileWatcher() {
        // First, log the exact path we're watching
        logInfo("Setting up file watcher for configuration at: \(configFilePath)")
        // Clean up any existing watcher
        fileWatcher = nil
        // Create a file watcher with explicit logging
        fileWatcher = FileChangeWatcher(
            filePath: configFilePath,
            onChanged: { [weak self] in
                logInfo("*** CONFIG FILE CHANGE DETECTED ***")
                guard let self = self else { return }
                // --- Suppress reload if this was an internal config write ---
                if self.suppressNextConfigReload {
                    logInfo("Suppressed config reload after internal write.")
                    self.suppressNextConfigReload = false
                    return
                }
                // -----------------------------------------------------------
                logInfo("Configuration file change detected, reloading...")
                if let loadedConfig = self.loadConfig() {
                    // Check if watch path changed
                    let watchPathChanged = self.previousWatchPath != loadedConfig.defaults.watch
                    
                    self.config = loadedConfig
                    self.configurationSuccessfullyLoaded()
                    
                    // Call onConfigChanged with appropriate reason
                    if watchPathChanged {
                        logInfo("Watch path changed from \(self.previousWatchPath ?? "none") to \(loadedConfig.defaults.watch)")
                        self.onConfigChanged?("watchPathChanged")
                    } else {
                        self.onConfigChanged?(nil)
                    }
                    
                    logInfo("Configuration automatically reloaded after file change")
                } else {
                    logError("Failed to reload configuration after file change")
                }
            },
            onMissing: {
                logWarning("Configuration file was deleted or moved")
            }
        )
        // Force an immediate metadata check to establish proper baseline
        fileWatcher?.forceInitialMetadataCheck()
        // Add a delay before allowing normal operation to ensure metadata is fully established
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // Force a second check after the delay to ensure everything is synchronized
            self?.fileWatcher?.checkForChangesNow()
            logInfo("Initial file monitoring baseline established")
        }
    }
    
    func loadConfig() -> AppConfiguration? {
        guard fileManager.fileExists(atPath: configFilePath) else {
            return nil
        }
        
        do {
            // Create a fresh URL with no caching
            let url = URL(fileURLWithPath: configFilePath)
            let data = try Data(contentsOf: url, options: .uncached)
            let decoder = JSONDecoder()
            let config = try decoder.decode(AppConfiguration.self, from: data)
            
            // Store current watch path before updating config
            previousWatchPath = self.config.defaults.watch
            
            // JSON loaded successfully, reset notification flag
            hasNotifiedAboutJsonError = false
            
            return config
        } catch {
            // Log the error
            logError("Error loading configuration: \(error.localizedDescription)")
            
            // Only show notification if we haven't already notified
            if !hasNotifiedAboutJsonError {
                hasNotifiedAboutJsonError = true
                
                // Show a single comprehensive notification
                notify(title: "Macrowhisper - Configuration Error",
                       message: "Your configuration file contains invalid JSON. The application is running with default settings.")
                
                // Reset the file watcher to recover from JSON error
                resetFileWatcher()
            }
            
            return nil
        }
    }
    
    func saveConfig() {
        // Don't overwrite an existing file that failed to load
        if fileManager.fileExists(atPath: configFilePath) &&
            loadConfig() == nil {
            logWarning("Not saving configuration because the existing file has invalid JSON that needs to be fixed manually")
            // Don't show another notification here - we've already notified in loadConfig()
            return
        }
        // --- Set suppression flag before writing config ---
        suppressNextConfigReload = true
        // --------------------------------------------------
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
            // Don't encode null values as nil - this will keep them as explicit nulls in the JSON
            encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            let data = try encoder.encode(config)
            try data.write(to: URL(fileURLWithPath: configFilePath), options: .atomic)
            logInfo("Configuration saved to \(configFilePath)")
        } catch {
            logError("Error saving configuration: \(error.localizedDescription)")
        }
    }
    
    // Add this method to reset the notification flag when config is successfully reloaded
    func configurationSuccessfullyLoaded() {
        hasNotifiedAboutJsonError = false
    }
    
    // Update configuration with command line arguments and save
    // Add this to the updateFromCommandLine method in ConfigurationManager
    func updateFromCommandLine(
        watchPath: String? = nil,
        server: Bool? = nil,
        watcher: Bool? = nil,
        noUpdates: Bool? = nil,
        noNoti: Bool? = nil,
        activeInsert: String? = nil,
        icon: String? = nil,
        moveTo: String? = nil,
        noEsc: Bool? = nil,
        simKeypress: Bool? = nil,
        actionDelay: Double? = nil,
        history: Int? = nil,
        pressReturn: Bool? = nil
    ) {
        // Convert parameters to arguments dictionary
        var arguments: [String: String] = [:]
        
        if let watchPath = watchPath {
            arguments["watch"] = watchPath
        }
        if let server = server {
            arguments["server"] = server ? "true" : "false"
        }
        if let watcher = watcher {
            arguments["watcher"] = watcher ? "true" : "false"
        }
        if let noUpdates = noUpdates {
            arguments["noUpdates"] = noUpdates ? "true" : "false"
        }
        if let noNoti = noNoti {
            arguments["noNoti"] = noNoti ? "true" : "false"
        }
        if let activeInsert = activeInsert {
            arguments["activeInsert"] = activeInsert
        }
        if let icon = icon {
            arguments["icon"] = icon
        }
        if let moveTo = moveTo {
            arguments["moveTo"] = moveTo
        }
        if let noEsc = noEsc {
            arguments["noEsc"] = noEsc ? "true" : "false"
        }
        if let simKeypress = simKeypress {
            arguments["simKeypress"] = simKeypress ? "true" : "false"
        }
        if let actionDelay = actionDelay {
            arguments["actionDelay"] = String(actionDelay)
        }
        if let history = history {
            arguments["history"] = String(history)
        }
        if let pressReturn = pressReturn {
            arguments["pressReturn"] = pressReturn ? "true" : "false"
        }
        // Use the async version
        updateFromCommandLineAsync(arguments: arguments)
    }
}

// MARK: - History Manager

class HistoryManager {
    private let configManager: ConfigurationManager
    private var lastHistoryCheck: Date?
    private let historyCheckInterval: TimeInterval = 24 * 60 * 60 // 24 hours
    
    init(configManager: ConfigurationManager) {
        self.configManager = configManager
    }
    
    func shouldPerformHistoryCleanup() -> Bool {
        // Check if history management is enabled
        guard configManager.config.defaults.history != nil else {
            return false // History management disabled
        }
        
        // Check if we've done this recently (within 24 hours)
        if let lastCheck = lastHistoryCheck,
           Date().timeIntervalSince(lastCheck) < historyCheckInterval {
            return false
        }
        
        return true
    }
    
    func performHistoryCleanup() {
        guard shouldPerformHistoryCleanup(),
              let historyDays = configManager.config.defaults.history else {
            return
        }
        
        logInfo("Starting history cleanup with \(historyDays) days retention")
        
        let recordingsPath = configManager.config.defaults.watch + "/recordings"
        
        // Check if recordings folder exists
        guard FileManager.default.fileExists(atPath: recordingsPath) else {
            logWarning("Recordings folder not found for history cleanup: \(recordingsPath)")
            return
        }
        
        do {
            // Get all subdirectories in recordings folder
            let contents = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: recordingsPath),
                includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
                options: .skipsHiddenFiles
            )
            
            // Filter for directories only
            let directories = contents.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            }
            
            // Sort by creation date (newest first)
            let sortedDirectories = directories.sorted { dir1, dir2 in
                let date1 = try? dir1.resourceValues(forKeys: [.creationDateKey]).creationDate
                let date2 = try? dir2.resourceValues(forKeys: [.creationDateKey]).creationDate
                return (date1 ?? Date.distantPast) > (date2 ?? Date.distantPast)
            }
            
            // If historyDays is 0, delete all except the most recent
            if historyDays == 0 {
                let foldersToDelete = Array(sortedDirectories.dropFirst(1)) // Keep only the first (newest)
                deleteFolders(foldersToDelete)
                logInfo("History cleanup (0 days): Deleted \(foldersToDelete.count) folders, kept 1 most recent")
            } else {
                // Delete folders older than historyDays
                let cutoffDate = Calendar.current.date(byAdding: .day, value: -historyDays, to: Date()) ?? Date()
                
                let foldersToDelete = sortedDirectories.filter { directory in
                    if let creationDate = try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate {
                        return creationDate < cutoffDate
                    }
                    return false
                }
                
                deleteFolders(foldersToDelete)
                logInfo("History cleanup (\(historyDays) days): Deleted \(foldersToDelete.count) folders older than \(cutoffDate)")
            }
            
            // Update last check time
            lastHistoryCheck = Date()
            
        } catch {
            logError("Failed to perform history cleanup: \(error.localizedDescription)")
        }
    }
    
    private func deleteFolders(_ folders: [URL]) {
        var deletedCount = 0
        var failedCount = 0
        
        for folder in folders {
            do {
                try FileManager.default.removeItem(at: folder)
                deletedCount += 1
                // Remove this line: logInfo("Deleted folder: \(folder.lastPathComponent)")
            } catch {
                failedCount += 1
                logError("Failed to delete folder \(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        
        // Add a single summary log entry
        if deletedCount > 0 {
            logInfo("Successfully deleted \(deletedCount) folders")
        }
        if failedCount > 0 {
            logInfo("Failed to delete \(failedCount) folders")
        }
    }
}

// MARK: - Argument Parsing and Startup

let defaultSuperwhisperPath = ("~/Documents/superwhisper" as NSString).expandingTildeInPath
let defaultRecordingsPath = "\(defaultSuperwhisperPath)/recordings"

func promptYesNo(_ message: String) -> Bool {
    // When running in terminal
    if isatty(STDOUT_FILENO) != 0 {
        print("\(message) [y/N]: ", terminator: "")
        guard let input = readLine()?.lowercased() else { return false }
        return input == "y" || input == "yes"
    } else {
        // When running as a background process, default to false and notify
        notify(title: "Macrowhisper",
               message: "\(message) - Edit configuration files manually to proceed.")
        return false
    }
}

// Add to the printHelp function
func printHelp() {
    print("""
    Usage: macrowhisper [OPTIONS]

    Automation tools for Superwhisper.

    OPTIONS:
      <no argument>                 Reloads configuration file on running instance
      -c, --config <path>           Path to config file (default: ~/.config/macrowhisper/macrowhisper.json)
      -w, --watch <path>            Path to superwhisper folder
          --no-updates true/false   Enable or disable automatic update checking
          --no-noti true/false      Enable or disable all notifications
          --no-esc true/false       Disable all ESC key simulations when set to true
          --action-delay <seconds>  Set delay in seconds before actions are executed
          --insert <name>           Set the active insert (use empty string to disable)
          --history <days>          Set number of days to keep recordings (0 to keep most recent recording)
                                    Use 'null' or no value to disable history management
          --sim-keypress true/false Simulate key presses for text input
                                    (note: linebreaks are treated as return presses)
          --press-return true/false Simulate return key press after every insert execution
                                    (persistent setting, unlike --auto-return which is one-time)
          --icon <icon>             Set the default icon to use when no insert icon is available
                                    Use '.none' to explicitly use no icon
          --move-to <path>          Set the default path to move folder to after processing
                                    Use '.delete' to delete folder, '.none' to not move
      -s, --status                  Get the status of the background process
      -h, --help                    Show this help message
      -v, --version                 Show version information

    INSERTS COMMANDS:
      --list-inserts                List all configured inserts
      --add-insert <name> <action>  Add or update an insert
      --remove-insert <name>        Remove an insert
      --exec-insert <name>          Execute an insert action using the last valid result
      --auto-return true/false      Insert result and simulate return for one interaction
      --get-icon                    Get the icon of the active insert

    Examples:
      macrowhisper
        # Uses defaults from config file/Reloads config file

      macrowhisper --config ~/custom-config.json

      macrowhisper --watch ~/otherfolder/superwhisper --watcher true --no-updates false

      macrowhisper --insert pasteResult
        # Sets the active insert to pasteResult

    """)
}

// Function to process LLM result based on XML placeholders in the action
func processXmlPlaceholders(action: String, llmResult: String) -> (String, [String: String]) {
    var cleanedLlmResult = llmResult
    var extractedTags: [String: String] = [:]
    
    // First, identify which XML tags are requested in the action
    let placeholderPattern = "\\{\\{xml:([A-Za-z0-9_]+)\\}\\}"
    let placeholderRegex = try? NSRegularExpression(pattern: placeholderPattern, options: [])
    
    var requestedTags: Set<String> = []
    
    // Find all XML placeholders in the action
    if let matches = placeholderRegex?.matches(in: action, options: [], range: NSRange(action.startIndex..., in: action)) {
        for match in matches {
            if let tagNameRange = Range(match.range(at: 1), in: action) {
                let tagName = String(action[tagNameRange])
                requestedTags.insert(tagName)
            }
        }
    }
    
    // If no XML tags are requested, return the original LLM result
    if requestedTags.isEmpty {
        return (cleanedLlmResult, extractedTags)
    }
    
    // For each requested tag, extract content and remove from LLM result
    for tagName in requestedTags {
        // Pattern to match the specific XML tag
        let tagPattern = "<\(tagName)>(.*?)</\(tagName)>"
        let tagRegex = try? NSRegularExpression(pattern: tagPattern, options: [.dotMatchesLineSeparators])
        
        // Find the tag in the LLM result
        if let match = tagRegex?.firstMatch(in: cleanedLlmResult, options: [], range: NSRange(cleanedLlmResult.startIndex..., in: cleanedLlmResult)),
           let contentRange = Range(match.range(at: 1), in: cleanedLlmResult),
           let fullMatchRange = Range(match.range, in: cleanedLlmResult) {
            
            // Extract content and clean it
            var content = String(cleanedLlmResult[contentRange])
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Store the cleaned content
            extractedTags[tagName] = content
            
            // Remove the XML tag and its content from the result
            cleanedLlmResult.replaceSubrange(fullMatchRange, with: "")
        }
    }
    
    // Clean up the LLM result after removing all requested tags
    // Remove any consecutive empty lines
    cleanedLlmResult = cleanedLlmResult.replacingOccurrences(of: "\n\\s*\n+", with: "\n\n", options: .regularExpression)
    
    // Trim leading and trailing whitespace
    cleanedLlmResult = cleanedLlmResult.trimmingCharacters(in: .whitespacesAndNewlines)
    
    return (cleanedLlmResult, extractedTags)
}

// Function to replace XML placeholders in an action string
func replaceXmlPlaceholders(action: String, extractedTags: [String: String]) -> String {
    var result = action
    
    // Find all XML placeholders using regex
    let pattern = "\\{\\{xml:([A-Za-z0-9_]+)\\}\\}"
    let regex = try? NSRegularExpression(pattern: pattern, options: [])
    
    // Get all matches
    if let matches = regex?.matches(in: action, options: [], range: NSRange(action.startIndex..., in: action)) {
        for match in matches.reversed() {
            if let tagNameRange = Range(match.range(at: 1), in: action),
               let fullMatchRange = Range(match.range, in: action) {
                
                let tagName = String(action[tagNameRange])
                
                // Replace the placeholder with the extracted content if available and not empty
                if let content = extractedTags[tagName], !content.isEmpty {
                    result.replaceSubrange(fullMatchRange, with: content)
                } else {
                    // If content is missing or empty, remove the placeholder entirely
                    result.replaceSubrange(fullMatchRange, with: "")
                }
            }
        }
    }
    
    return result
}

// Argument parsing
let configManager: ConfigurationManager
var configPath: String? = nil
var watchPath: String? = nil
var watcherFlag: Bool? = nil
var insertName: String? = nil
var iconValue: String? = nil
var moveToPath: String? = nil
var noEscFlag: Bool? = nil
var simKeypressFlag: Bool? = nil
var pressReturnFlag: Bool? = nil
var historyValue: Int? = nil

let args = CommandLine.arguments
var i = 1
while i < args.count {
    switch args[i] {
    case "-c", "--config":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            notify(title: "Macrowhisper", message: "Missing value after \(args[i])")
            exit(1)
        }
        configPath = args[i + 1]
        i += 2
    case "-w", "--watch":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            notify(title: "Macrowhisper", message: "Missing value after \(args[i])")
            exit(1)
        }
        watchPath = args[i + 1]
        i += 2
    case "--no-updates":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            exit(1)
        }
        let value = args[i + 1].lowercased()
        disableUpdates = value == "true" || value == "yes" || value == "1"
        i += 2
    case "--no-noti":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            exit(1)
        }
        let value = args[i + 1].lowercased()
        disableNotifications = value == "true" || value == "yes" || value == "1"
        i += 2
    case "--no-esc":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            exit(1)
        }
        let value = args[i + 1].lowercased()
        noEscFlag = value == "true" || value == "yes" || value == "1"
        i += 2
    case "--sim-keypress":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            exit(1)
        }
        let value = args[i + 1].lowercased()
        simKeypressFlag = value == "true" || value == "yes" || value == "1"
        i += 2
    case "--action-delay":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            exit(1)
        }
        if let delayValue = Double(args[i + 1]) {
            // Store the delay value in our top-level variable
            actionDelayValue = delayValue
        } else {
            logError("Invalid delay value: \(args[i + 1]). Must be a number in seconds.")
            exit(1)
        }
        i += 2
    case "-h", "--help":
        printHelp()
        exit(0)
    case "--history":
        if i + 1 < args.count && !args[i + 1].starts(with: "--") {
            // A value was provided
            let historyArg = args[i + 1]
            if historyArg.lowercased() == "null" {
                historyValue = nil  // This will be handled specially
                i += 2
            } else if let historyVal = Int(historyArg) {
                historyValue = historyVal
                i += 2
            } else {
                logError("Invalid history value: \(historyArg). Must be a number (days) or 'null'.")
                exit(1)
            }
        } else {
            // No value provided, set to null
            historyValue = nil  // This will be handled specially
            i += 1
        }
    case "-v", "--version":
        print("Macrowhisper version \(APP_VERSION)")
        exit(0)
    case "--insert":
        if i + 1 < args.count && !args[i + 1].starts(with: "--") {
            // A value was provided
            insertName = args[i + 1]
            i += 2
        } else {
            // No value provided, set empty string to clear the active insert
            insertName = ""
            i += 1
        }
    case "--icon":
        if i + 1 < args.count && !args[i + 1].starts(with: "--") {
            // A value was provided
            iconValue = args[i + 1]
            i += 2
        } else {
            // No value provided, set empty string to clear the default icon
            iconValue = ""
            i += 1
        }
    case "--move-to":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            notify(title: "Macrowhisper", message: "Missing value after \(args[i])")
            exit(1)
        }
        moveToPath = args[i + 1]
        i += 2
    case "--list-inserts":
        if let response = socketCommunication.sendCommand(.listInserts) {
            print(response)
        } else {
            print("Failed to list inserts")
        }
        exit(0)
    case "--exec-insert":
        guard i + 1 < args.count else {
            logError("Missing insert name after \(args[i])")
            exit(1)
        }
        let insertName = args[i + 1]
        
        let arguments: [String: String] = [
            "name": insertName
        ]
        
        if let response = socketCommunication.sendCommand(.execInsert, arguments: arguments) {
            print(response)
        } else {
            print("Failed to execute insert")
        }
        exit(0)
    case "--add-insert":
        guard i + 1 < args.count else {
            logError("Missing insert name after \(args[i])")
            exit(1)
        }
        let insertName = args[i + 1]
        
        let arguments: [String: String] = [
            "name": insertName
        ]
        
        if let response = socketCommunication.sendCommand(.addInsert, arguments: arguments) {
            print(response)
        } else {
            print("Failed to add insert")
        }
        exit(0)

    case "--remove-insert":
        guard i + 1 < args.count else {
            logError("Missing insert name after \(args[i])")
            exit(1)
        }
        let insertName = args[i + 1]
        
        let arguments: [String: String] = [
            "name": insertName
        ]
        
        if let response = socketCommunication.sendCommand(.removeInsert, arguments: arguments) {
            print(response)
        } else {
            print("Failed to remove insert")
        }
        exit(0)
    case "--press-return":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            exit(1)
        }
        let value = args[i + 1].lowercased()
        pressReturnFlag = value == "true" || value == "yes" || value == "1"
        i += 2
        
    default:
        logError("Unknown argument: \(args[i])")
        notify(title: "Macrowhisper", message: "Unknown argument: \(args[i])")
        exit(1)
    }
}

// Initialize configuration manager with the specified path
configManager = ConfigurationManager(configPath: configPath)
globalConfigManager = configManager

// Initialize history manager
historyManager = HistoryManager(configManager: configManager)

// Apply any stored action delay value if it was set in command line arguments
if let delayValue = actionDelayValue {
    configManager.updateFromCommandLine(actionDelay: delayValue)
}

// Read values from config first
let config = configManager.config
disableUpdates = config.defaults.noUpdates
disableNotifications = config.defaults.noNoti

// Only update config with command line arguments if they were specified
configManager.updateFromCommandLine(
    watchPath: watchPath,
    watcher: watcherFlag,
    noUpdates: args.contains("--no-updates") ? (args.firstIndex(where: { $0 == "--no-updates" }).flatMap { idx in
        idx + 1 < args.count ? (args[idx + 1].lowercased() == "true") : true
    }) : nil,
    noNoti: args.contains("--no-noti") ? (args.firstIndex(where: { $0 == "--no-noti" }).flatMap { idx in
        idx + 1 < args.count ? (args[idx + 1].lowercased() == "true") : true
    }) : nil,
    activeInsert: insertName,
    icon: iconValue,
    moveTo: moveToPath,
    noEsc: noEscFlag,
    simKeypress: simKeypressFlag,
    history: args.contains("--history") ? historyValue : nil,
    pressReturn: pressReturnFlag
)

// Update global variables again after possible configuration changes
disableUpdates = configManager.config.defaults.noUpdates
disableNotifications = configManager.config.defaults.noNoti

// Get the final watch path after possible updates
let watchFolderPath = config.defaults.watch

// Check feature availability
let runWatcher = checkWatcherAvailability()

// ---
// At this point, continue with initializing server and/or watcher as usual...
if runWatcher { logInfo("Watcher: \(watchFolderPath)/recordings") }

// Server setup - only if jsonPath is provided
// MARK: - Server and Watcher Setup
var fileWatcher: FileChangeWatcher? = nil

func folderExistsOrExit(_ path: String, what: String) {
    if !FileManager.default.fileExists(atPath: path) {
        logError("Error: \(what) not found: \(path)")
        notify(title: "Macrowhisper", message: "Error: \(what) not found: \(path)")
        exit(1)
    }
}

// Initialize the recordings folder watcher if enabled
var recordingsWatcher: RecordingsFolderWatcher? = nil
if runWatcher {
    // Validate the watch folder exists
    let recordingsPath = "\(watchFolderPath)/recordings"
    if !FileManager.default.fileExists(atPath: recordingsPath) {
        logError("Error: Recordings folder not found at \(recordingsPath)")
        notify(title: "Macrowhisper", message: "Error: Recordings folder not found at \(recordingsPath)")
        exit(1)
    }
    
    recordingsWatcher = RecordingsFolderWatcher(basePath: watchFolderPath)
    if recordingsWatcher == nil {
        logWarning("Warning: Failed to initialize recordings folder watcher")
        notify(title: "Macrowhisper", message: "Warning: Failed to initialize recordings folder watcher")
    } else {
        logInfo("Watching recordings folder at \(recordingsPath)")
    }
}

// Set up configuration change handler for live updates
configManager.onConfigChanged = { reason in
    // Store previous values to detect changes
    let previousDisableUpdates = disableUpdates
    // Update global variables
    disableUpdates = configManager.config.defaults.noUpdates
    disableNotifications = configManager.config.defaults.noNoti
    // If updates were disabled but are now enabled, reset the version checker state
    if previousDisableUpdates == true && disableUpdates == false {
        versionChecker.resetLastCheckDate()
    }
    
    // Handle watch path changes and validation
    let currentWatchPath = configManager.config.defaults.watch
    let recordingsPath = "\(currentWatchPath)/recordings"
    let recordingsFolderExists = FileManager.default.fileExists(atPath: recordingsPath)
    
    // If watch path changed or watcher needs initialization
    if reason == "watchPathChanged" || recordingsWatcher == nil {
        // Check if the new path exists
        if recordingsFolderExists {
            // Stop any existing watcher before initializing new one
            recordingsWatcher = nil
            initializeWatcher(currentWatchPath)
            logInfo("Watcher initialized/reinitialized for folder: \(currentWatchPath)")
        } else {
            logWarning("Watch path invalid: Recordings folder not found at \(recordingsPath)")
            notify(title: "Macrowhisper", message: "Recordings folder not found. Please check the path.")
            
            // Clean up any existing watcher
            if recordingsWatcher != nil {
                recordingsWatcher = nil
                logInfo("Watcher stopped due to invalid path")
            }
        }
    }
}


// Initialize version checker
let versionChecker = VersionChecker()

registerForSleepWakeNotifications()
startSocketHealthMonitor()
// Log that we're ready
logInfo("Macrowhisper initialized and ready")

// Keep the main thread running
RunLoop.main.run()

// MARK: - URLSession sync helper
// Change the URLSession extension to:
extension URLSession {
    func synchronousDataTask(with request: URLRequest) -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        
        // Use an array for thread safety
        var resultData: Data? = nil
        var resultResponse: URLResponse? = nil
        var resultError: Error? = nil
        
        dataTask(with: request) { data, response, error in
            // Capture on the main thread to avoid concurrency issues
            DispatchQueue.main.async {
                resultData = data
                resultResponse = response
                resultError = error
                semaphore.signal()
            }
        }.resume()
        
        semaphore.wait()
        
        if let e = resultError { exitWithError("Network error: \(e.localizedDescription)") }
        return (resultData ?? Data(), resultResponse!)
    }
}

// MARK: - URL Action Handling
// Helper to evaluate triggers for a given action (insert or URL)
func triggersMatch<T>(for action: T, result: String, modeName: String?, frontAppName: String?, frontAppBundleId: String?) -> (matched: Bool, strippedResult: String?) {
    var voiceMatched = false
    var modeMatched = false
    var appMatched = false
    var strippedResult: String? = nil
    
    // Get trigger values based on action type
    let (triggerVoice, triggerModes, triggerApps, triggerLogic, actionName) = {
        switch action {
        case let insert as AppConfiguration.Insert:
            return (insert.triggerVoice, insert.triggerModes, insert.triggerApps, insert.triggerLogic, insert.name)
        case let url as AppConfiguration.Url:
            return (url.triggerVoice, url.triggerModes, url.triggerApps, url.triggerLogic, url.name)
        case let shortcut as AppConfiguration.Shortcut:
            return (shortcut.triggerVoice, shortcut.triggerModes, shortcut.triggerApps, shortcut.triggerLogic, shortcut.name)
        default:
            return ("", "", "", "or", "unknown")
        }
    }()
    
    // Voice trigger
    if let triggerVoice = triggerVoice, !triggerVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let triggers = triggerVoice.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var matched = false
        var exceptionMatched = false
        logInfo("[TriggerEval] Voice trigger check for action '\(actionName)': patterns=\(triggers)")
        for trigger in triggers {
            let isException = trigger.hasPrefix("!")
            let actualPattern = isException ? String(trigger.dropFirst()) : trigger
            let regexPattern = "^(?i)" + NSRegularExpression.escapedPattern(for: actualPattern)
            if let regex = try? NSRegularExpression(pattern: regexPattern, options: []) {
                let range = NSRange(location: 0, length: result.utf16.count)
                let found = regex.firstMatch(in: result, options: [], range: range) != nil
                logInfo("[TriggerEval] Pattern '\(trigger)' found=\(found) in result.")
                if isException && found { exceptionMatched = true }
                if !isException && found {
                    // Strip the trigger from the start, plus any leading punctuation/whitespace after
                    let match = regex.firstMatch(in: result, options: [], range: range)!
                    let afterTriggerIdx = result.index(result.startIndex, offsetBy: match.range.length)
                    var stripped = String(result[afterTriggerIdx...])
                    let punctuationSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
                    while let first = stripped.unicodeScalars.first, punctuationSet.contains(first) {
                        stripped.removeFirst()
                    }
                    if let first = stripped.first {
                        stripped.replaceSubrange(stripped.startIndex...stripped.startIndex, with: String(first).uppercased())
                    }
                    matched = true
                    strippedResult = stripped
                }
            }
        }
        let hasPositive = triggers.contains { !$0.hasPrefix("!") }
        let hasException = triggers.contains { $0.hasPrefix("!") }
        if hasPositive {
            voiceMatched = matched && !exceptionMatched
        } else if hasException {
            // Only exceptions: match if no exception matched
            voiceMatched = !exceptionMatched
        } else {
            // No patterns at all (shouldn't happen), treat as matched
            voiceMatched = true
        }
        logInfo("[TriggerEval] Voice trigger result for action '\(actionName)': matched=\(voiceMatched)")
    } else {
        // No voice trigger set, treat as matched for AND logic
        voiceMatched = true
    }
    
    // Mode trigger
    if let triggerModes = triggerModes, !triggerModes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let modeName = modeName {
        let patterns = triggerModes.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var matched = false
        var exceptionMatched = false
        logInfo("[TriggerEval] Mode trigger check for action '\(actionName)': modeName=\"\(modeName)\", patterns=\(patterns)")
        for pattern in patterns {
            let isException = pattern.hasPrefix("!")
            let actualPattern = isException ? String(pattern.dropFirst()) : pattern
            let regexPattern: String
            if actualPattern.hasPrefix("(?i)") || actualPattern.hasPrefix("(?-i)") {
                regexPattern = actualPattern
            } else {
                regexPattern = "(?i)" + actualPattern
            }
            if let regex = try? NSRegularExpression(pattern: regexPattern, options: []) {
                let range = NSRange(location: 0, length: modeName.utf16.count)
                let found = regex.firstMatch(in: modeName, options: [], range: range) != nil
                logInfo("[TriggerEval] Pattern '\(pattern)' found=\(found) in modeName=\(modeName)")
                if isException && found { exceptionMatched = true }
                if !isException && found { matched = true }
            }
        }
        let hasPositive = patterns.contains { !$0.hasPrefix("!") }
        let hasException = patterns.contains { $0.hasPrefix("!") }
        if hasPositive {
            modeMatched = matched && !exceptionMatched
        } else if hasException {
            // Only exceptions: match if no exception matched
            modeMatched = !exceptionMatched
        } else {
            // No patterns at all (shouldn't happen), treat as matched
            modeMatched = true
        }
        logInfo("[TriggerEval] Mode trigger result for action '\(actionName)': matched=\(modeMatched)")
    } else {
        // No mode trigger set, treat as matched for AND logic
        modeMatched = true
    }
    
    // App trigger
    if let triggerApps = triggerApps, !triggerApps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if let appName = frontAppName, let bundleId = frontAppBundleId {
            let patterns = triggerApps.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            var matched = false
            var exceptionMatched = false
            logInfo("[TriggerEval] App trigger check for action '\(actionName)': appName=\"\(appName)\", bundleId=\"\(bundleId)\", patterns=\(patterns)")
            for pattern in patterns {
                let isException = pattern.hasPrefix("!")
                let actualPattern = isException ? String(pattern.dropFirst()) : pattern
                let regexPattern: String
                if actualPattern.hasPrefix("(?i)") || actualPattern.hasPrefix("(?-i)") {
                    regexPattern = actualPattern
                } else {
                    regexPattern = "(?i)" + actualPattern
                }
                if let regex = try? NSRegularExpression(pattern: regexPattern, options: []) {
                    let nameRange = NSRange(location: 0, length: appName.utf16.count)
                    let bundleRange = NSRange(location: 0, length: bundleId.utf16.count)
                    let found = regex.firstMatch(in: appName, options: [], range: nameRange) != nil || regex.firstMatch(in: bundleId, options: [], range: bundleRange) != nil
                    logInfo("[TriggerEval] Pattern '\(pattern)' found=\(found) in appName=\(appName), bundleId=\(bundleId)")
                    if isException && found { exceptionMatched = true }
                    if !isException && found { matched = true }
                }
            }
            // After evaluating all patterns, determine match logic for app triggers
            let hasPositive = patterns.contains { !$0.hasPrefix("!") }
            let hasException = patterns.contains { $0.hasPrefix("!") }
            if hasPositive {
                appMatched = matched && !exceptionMatched
            } else if hasException {
                // Only exceptions: match if no exception matched
                appMatched = !exceptionMatched
            } else {
                // No patterns at all (shouldn't happen), treat as matched
                appMatched = true
            }
            logInfo("[TriggerEval] App trigger result for action '\(actionName)': matched=\(appMatched)")
        } else {
            logInfo("[TriggerEval] App trigger set for action '\(actionName)' but appName or bundleId is nil. Not matching.")
            appMatched = false
        }
    } else {
        // No app trigger set, treat as matched for AND logic
        appMatched = true
    }
    
    // Determine logic
    let logic = (triggerLogic ?? "or").lowercased()
    if logic == "and" {
        // All must match
        let allMatch = voiceMatched && modeMatched && appMatched
        return (allMatch, strippedResult)
    } else {
        // OR logic: only non-empty triggers are considered
        let voiceTriggerSet = triggerVoice != nil && !triggerVoice!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let modeTriggerSet = triggerModes != nil && !triggerModes!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let appTriggerSet = triggerApps != nil && !triggerApps!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var anyMatch = false
        if voiceTriggerSet && voiceMatched { anyMatch = true }
        if modeTriggerSet && modeMatched { anyMatch = true }
        if appTriggerSet && appMatched { anyMatch = true }
        return (anyMatch, strippedResult)
    }
}

// MARK: - Dynamic Placeholder Expansion (Refactored)
/// Expands dynamic placeholders in the form {{key}} and (new) {{date:format}} in the action string.
func processDynamicPlaceholders(action: String, metaJson: [String: Any]) -> String {
    var result = action
    // Regex for {{key}} and {{date:...}}
    let placeholderPattern = "\\{\\{([A-Za-z0-9_]+)(?::([^}]+))?\\}\\}"
    let placeholderRegex = try? NSRegularExpression(pattern: placeholderPattern, options: [])
    if let matches = placeholderRegex?.matches(in: action, options: [], range: NSRange(action.startIndex..., in: action)) {
        for match in matches.reversed() {
            guard let keyRange = Range(match.range(at: 1), in: action),
                  let fullMatchRange = Range(match.range, in: action) else { continue }
            let key = String(action[keyRange])
            // Check for date placeholder
            if key == "date", match.numberOfRanges > 2, let formatRange = Range(match.range(at: 2), in: action) {
                let format = String(action[formatRange])
                let replacement: String
                switch format {
                case "short":
                    let formatter = DateFormatter()
                    formatter.dateStyle = .short
                    formatter.timeStyle = .none
                    replacement = formatter.string(from: Date())
                case "long":
                    let formatter = DateFormatter()
                    formatter.dateStyle = .long
                    formatter.timeStyle = .none
                    replacement = formatter.string(from: Date())
                default:
                    // UTS 35 custom format
                    let formatter = DateFormatter()
                    formatter.setLocalizedDateFormatFromTemplate(format)
                    replacement = formatter.string(from: Date())
                }
                result.replaceSubrange(fullMatchRange, with: replacement)
                continue
            }
            // Handle swResult
            if key == "swResult" {
                let value: String
                if let llm = metaJson["llmResult"] as? String, !llm.isEmpty {
                    value = llm
                } else if let res = metaJson["result"] as? String, !res.isEmpty {
                    value = res
                } else {
                    value = ""
                }
                result.replaceSubrange(fullMatchRange, with: value)
            } else if let jsonValue = metaJson[key] {
                let value: String
                if let stringValue = jsonValue as? String {
                    value = stringValue
                } else if let numberValue = jsonValue as? NSNumber {
                    value = numberValue.stringValue
                } else if let boolValue = jsonValue as? Bool {
                    value = boolValue ? "true" : "false"
                } else if jsonValue is NSNull {
                    value = ""
                } else if let jsonData = try? JSONSerialization.data(withJSONObject: jsonValue),
                          let jsonString = String(data: jsonData, encoding: .utf8) {
                    value = jsonString
                } else {
                    value = String(describing: jsonValue)
                }
                result.replaceSubrange(fullMatchRange, with: value)
            } else {
                // Key doesn't exist in metaJson, remove the placeholder
                result.replaceSubrange(fullMatchRange, with: "")
            }
        }
    }
    return result
}

