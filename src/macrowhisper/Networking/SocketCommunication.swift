import Foundation
import Dispatch
import Darwin
import Cocoa
import Carbon.HIToolbox

private let UNIX_PATH_MAX = 104
private let SOCKET_TIMEOUT_SECONDS = 10 // 10 second timeout for socket operations

// Helper functions for fd_set operations (Darwin-specific)
private func fdZero(_ set: inout fd_set) {
    set.fds_bits = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let index = Int(fd) / 32
    let bit = Int(fd) % 32
    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        let intPtr = ptr.withMemoryRebound(to: Int32.self, capacity: 32) { $0 }
        intPtr[index] |= (1 << bit)
    }
}

private func fdIsSet(_ fd: Int32, _ set: inout fd_set) -> Bool {
    let index = Int(fd) / 32
    let bit = Int(fd) % 32
    return withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        let intPtr = ptr.withMemoryRebound(to: Int32.self, capacity: 32) { $0 }
        return (intPtr[index] & (1 << bit)) != 0
    }
}

class SocketCommunication {
    private let socketPath: String
    private var server: DispatchSourceRead?
    private var serverSocket: Int32 = -1
    private let queue = DispatchQueue(label: "com.macrowhisper.socket", qos: .utility)
    private var configManagerRef: ConfigurationManager?
    private var clipboardMonitorRef: ClipboardMonitor?
    
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
    
    /// Sets the clipboard monitor reference for CLI action cleanup
    func setClipboardMonitor(_ clipboardMonitor: ClipboardMonitor) {
        self.clipboardMonitorRef = clipboardMonitor
    }
    
    /// Reads from socket with timeout to prevent blocking indefinitely
    /// Returns the number of bytes read, or -1 on error/timeout
    private func readWithTimeout(_ socket: Int32, _ buffer: UnsafeMutablePointer<UInt8>, _ bufferSize: Int) -> Int {
        // Set socket to non-blocking mode
        let flags = fcntl(socket, F_GETFL)
        _ = fcntl(socket, F_SETFL, flags | O_NONBLOCK)
        
        // Setup select for timeout
        var readSet = fd_set()
        fdZero(&readSet)
        fdSet(socket, &readSet)
        
        var timeout = timeval(tv_sec: Int(SOCKET_TIMEOUT_SECONDS), tv_usec: 0)
        let selectResult = select(socket + 1, &readSet, nil, nil, &timeout)
        
        // Restore blocking mode
        _ = fcntl(socket, F_SETFL, flags)
        
        if selectResult > 0 && fdIsSet(socket, &readSet) {
            // Socket is ready for reading
            return read(socket, buffer, bufferSize)
        } else if selectResult == 0 {
            logWarning("Socket read timeout after \(SOCKET_TIMEOUT_SECONDS) seconds")
            return -1
        } else {
            logError("Socket select error: \(errno)")
            return -1
        }
    }
    
    /// Writes to socket with timeout to prevent blocking indefinitely
    /// Returns the number of bytes written, or -1 on error/timeout
    private func writeWithTimeout(_ socket: Int32, _ data: UnsafeRawPointer, _ dataSize: Int) -> Int {
        // Set socket to non-blocking mode
        let flags = fcntl(socket, F_GETFL)
        _ = fcntl(socket, F_SETFL, flags | O_NONBLOCK)
        
        // Setup select for timeout
        var writeSet = fd_set()
        fdZero(&writeSet)
        fdSet(socket, &writeSet)
        
        var timeout = timeval(tv_sec: Int(SOCKET_TIMEOUT_SECONDS), tv_usec: 0)
        let selectResult = select(socket + 1, nil, &writeSet, nil, &timeout)
        
        // Restore blocking mode
        _ = fcntl(socket, F_SETFL, flags)
        
        if selectResult > 0 && fdIsSet(socket, &writeSet) {
            // Socket is ready for writing
            return write(socket, data, dataSize)
        } else if selectResult == 0 {
            logWarning("Socket write timeout after \(SOCKET_TIMEOUT_SECONDS) seconds")
            return -1
        } else {
            logError("Socket select error: \(errno)")
            return -1
        }
    }
    
    /// Safely sends response to client socket with timeout protection
    /// Returns true if successful, false if failed or timed out
    private func sendResponse(_ response: String, to clientSocket: Int32) -> Bool {
        let bytesToWrite = response.utf8.count
        let bytesWritten = response.withCString { cString in
            writeWithTimeout(clientSocket, cString, bytesToWrite)
        }
        
        if bytesWritten != bytesToWrite {
            if bytesWritten == -1 {
                logError("Failed to send response: write timeout or error")
            } else {
                logError("Incomplete response sent: \(bytesWritten)/\(bytesToWrite) bytes")
            }
            return false
        }
        return true
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
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                // NEW VALIDATION LOGIC: Check based on languageModelName and llmResult/result
                var isValid = false

                // First, check if languageModelName exists and is not empty
                if let languageModelName = json["languageModelName"] as? String, !languageModelName.isEmpty {
                    // languageModelName is not empty, check for llmResult
                    if let llmResult = json["llmResult"], !(llmResult is NSNull) {
                        // llmResult must be a non-empty string
                        if let llmResultString = llmResult as? String, !llmResultString.isEmpty {
                            isValid = true
                        }
                    }
                } else {
                    // languageModelName is empty or missing, check for result
                    if let result = json["result"], !(result is NSNull) {
                        // result must be a non-empty string
                        if let resultString = result as? String, !resultString.isEmpty {
                            isValid = true
                        }
                    }
                }

                if isValid {
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

    private typealias ParsedInputCondition = [String: Bool]

    private func resolveInsertForCLIExecution(_ insert: AppConfiguration.Insert) -> (AppConfiguration.Insert, Bool) {
        let (templateInsert, isAutoPasteTemplate) = applyLegacyInsertTemplateOverrides(insert)
        let needsInputConditionEvaluation = isAutoPasteTemplate || !((templateInsert.inputCondition ?? "").isEmpty)

        var isInInputFieldValue = false
        if needsInputConditionEvaluation {
            if requestAccessibilityPermission() {
                isInInputFieldValue = isInInputField()
            } else {
                isInInputFieldValue = false
            }
        }

        let resolvedInsert = applyInputCondition(to: templateInsert, isInInputField: isInInputFieldValue)
        let isAutoPaste = isAutoPasteTemplate || resolvedInsert.action == ".autoPaste"
        return (resolvedInsert, isAutoPaste)
    }

    private func resolveUrlForCLIExecution(_ url: AppConfiguration.Url) -> AppConfiguration.Url {
        let (templateUrl, isLegacyNoopTemplate) = applyLegacyNoopTemplateOverrides(url)
        let needsInputConditionEvaluation = isLegacyNoopTemplate || !((templateUrl.inputCondition ?? "").isEmpty)
        let isInInputFieldValue = resolveInputFieldStateForCLI(needsEvaluation: needsInputConditionEvaluation)
        return applyInputCondition(to: templateUrl, isInInputField: isInInputFieldValue)
    }

    private func resolveShellForCLIExecution(_ shell: AppConfiguration.ScriptShell) -> AppConfiguration.ScriptShell {
        let (templateShell, isLegacyNoopTemplate) = applyLegacyNoopTemplateOverrides(shell)
        let needsInputConditionEvaluation = isLegacyNoopTemplate || !((templateShell.inputCondition ?? "").isEmpty)
        let isInInputFieldValue = resolveInputFieldStateForCLI(needsEvaluation: needsInputConditionEvaluation)
        return applyInputCondition(to: templateShell, isInInputField: isInInputFieldValue)
    }

    private func resolveAppleScriptForCLIExecution(_ ascript: AppConfiguration.ScriptAppleScript) -> AppConfiguration.ScriptAppleScript {
        let (templateAppleScript, isLegacyNoopTemplate) = applyLegacyNoopTemplateOverrides(ascript)
        let needsInputConditionEvaluation = isLegacyNoopTemplate || !((templateAppleScript.inputCondition ?? "").isEmpty)
        let isInInputFieldValue = resolveInputFieldStateForCLI(needsEvaluation: needsInputConditionEvaluation)
        return applyInputCondition(to: templateAppleScript, isInInputField: isInInputFieldValue)
    }

    private func resolveShortcutForCLIExecution(_ shortcut: AppConfiguration.Shortcut) -> AppConfiguration.Shortcut {
        let (templateShortcut, isLegacyNoopTemplate) = applyLegacyNoopTemplateOverrides(shortcut)
        let needsInputConditionEvaluation = isLegacyNoopTemplate || !((templateShortcut.inputCondition ?? "").isEmpty)
        let isInInputFieldValue = resolveInputFieldStateForCLI(needsEvaluation: needsInputConditionEvaluation)
        return applyInputCondition(to: templateShortcut, isInInputField: isInInputFieldValue)
    }

    private func resolveInputFieldStateForCLI(needsEvaluation: Bool) -> Bool {
        guard needsEvaluation else { return false }
        if requestAccessibilityPermission() {
            return isInInputField()
        }
        return false
    }

    private func applyLegacyInsertTemplateOverrides(_ insert: AppConfiguration.Insert) -> (AppConfiguration.Insert, Bool) {
        var resolved = insert

        if insert.action == ".autoPaste" {
            resolved.inputCondition = "!restoreClipboard|!noEsc"
            resolved.noEsc = true
            resolved.restoreClipboard = false
            return (resolved, true)
        }

        if insert.action == ".none" {
            resolved.action = ""
            resolved.inputCondition = ""
            resolved.noEsc = true
            resolved.restoreClipboard = false
            return (resolved, false)
        }

        return (resolved, false)
    }

    private func applyLegacyNoopTemplateOverrides(_ url: AppConfiguration.Url) -> (AppConfiguration.Url, Bool) {
        var resolved = url

        if url.action == ".none" {
            resolved.action = ""
            resolved.inputCondition = ""
            resolved.noEsc = true
            resolved.restoreClipboard = false
            return (resolved, true)
        }

        return (resolved, false)
    }

    private func applyLegacyNoopTemplateOverrides(_ shell: AppConfiguration.ScriptShell) -> (AppConfiguration.ScriptShell, Bool) {
        var resolved = shell

        if shell.action == ".none" {
            resolved.action = ""
            resolved.inputCondition = ""
            resolved.noEsc = true
            resolved.restoreClipboard = false
            return (resolved, true)
        }

        return (resolved, false)
    }

    private func applyLegacyNoopTemplateOverrides(_ ascript: AppConfiguration.ScriptAppleScript) -> (AppConfiguration.ScriptAppleScript, Bool) {
        var resolved = ascript

        if ascript.action == ".none" {
            resolved.action = ""
            resolved.inputCondition = ""
            resolved.noEsc = true
            resolved.restoreClipboard = false
            return (resolved, true)
        }

        return (resolved, false)
    }

    private func applyLegacyNoopTemplateOverrides(_ shortcut: AppConfiguration.Shortcut) -> (AppConfiguration.Shortcut, Bool) {
        var resolved = shortcut

        if shortcut.action == ".none" {
            resolved.action = ""
            resolved.inputCondition = ""
            resolved.noEsc = true
            resolved.restoreClipboard = false
            return (resolved, true)
        }

        return (resolved, false)
    }

    private func parseInputCondition(_ rawValue: String?) -> ParsedInputCondition {
        let normalized = rawValue ?? ""
        if normalized.isEmpty {
            return [:]
        }

        var tokens: ParsedInputCondition = [:]
        for rawToken in normalized.components(separatedBy: "|") {
            if rawToken.isEmpty {
                continue
            }

            let appliesOutsideInput = rawToken.hasPrefix("!")
            let tokenName = appliesOutsideInput ? String(rawToken.dropFirst()) : rawToken
            if tokenName.isEmpty {
                continue
            }
            tokens[tokenName] = appliesOutsideInput ? false : true
        }

        return tokens
    }

    private func shouldApplyToken(
        _ token: String,
        tokens: ParsedInputCondition,
        isInInputField: Bool
    ) -> Bool {
        guard let appliesInInput = tokens[token] else {
            return true
        }
        return appliesInInput ? isInInputField : !isInInputField
    }

    private func applyInputCondition(
        to insert: AppConfiguration.Insert,
        isInInputField: Bool
    ) -> AppConfiguration.Insert {
        let tokens = parseInputCondition(insert.inputCondition)
        if tokens.isEmpty {
            return insert
        }

        var resolved = insert
        if !shouldApplyToken("restoreClipboard", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboard = nil
        }
        if !shouldApplyToken("pressReturn", tokens: tokens, isInInputField: isInInputField) {
            resolved.pressReturn = nil
        }
        if !shouldApplyToken("noEsc", tokens: tokens, isInInputField: isInInputField) {
            resolved.noEsc = nil
        }
        if !shouldApplyToken("nextAction", tokens: tokens, isInInputField: isInInputField) {
            resolved.nextAction = nil
        }
        if !shouldApplyToken("moveTo", tokens: tokens, isInInputField: isInInputField) {
            resolved.moveTo = nil
        }
        if !shouldApplyToken("action", tokens: tokens, isInInputField: isInInputField) {
            resolved.action = ""
        }
        if !shouldApplyToken("actionDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.actionDelay = nil
        }
        if !shouldApplyToken("simKeypress", tokens: tokens, isInInputField: isInInputField) {
            resolved.simKeypress = nil
        }
        if !shouldApplyToken("smartInsert", tokens: tokens, isInInputField: isInInputField) {
            resolved.smartInsert = nil
        }

        return resolved
    }

    private func applyInputCondition(
        to url: AppConfiguration.Url,
        isInInputField: Bool
    ) -> AppConfiguration.Url {
        let tokens = parseInputCondition(url.inputCondition)
        if tokens.isEmpty {
            return url
        }

        var resolved = url
        if !shouldApplyToken("restoreClipboard", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboard = nil
        }
        if !shouldApplyToken("noEsc", tokens: tokens, isInInputField: isInInputField) {
            resolved.noEsc = nil
        }
        if !shouldApplyToken("nextAction", tokens: tokens, isInInputField: isInInputField) {
            resolved.nextAction = nil
        }
        if !shouldApplyToken("moveTo", tokens: tokens, isInInputField: isInInputField) {
            resolved.moveTo = nil
        }
        if !shouldApplyToken("action", tokens: tokens, isInInputField: isInInputField) {
            resolved.action = ""
        }
        if !shouldApplyToken("actionDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.actionDelay = nil
        }

        return resolved
    }

    private func applyInputCondition(
        to shell: AppConfiguration.ScriptShell,
        isInInputField: Bool
    ) -> AppConfiguration.ScriptShell {
        let tokens = parseInputCondition(shell.inputCondition)
        if tokens.isEmpty {
            return shell
        }

        var resolved = shell
        if !shouldApplyToken("restoreClipboard", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboard = nil
        }
        if !shouldApplyToken("noEsc", tokens: tokens, isInInputField: isInInputField) {
            resolved.noEsc = nil
        }
        if !shouldApplyToken("nextAction", tokens: tokens, isInInputField: isInInputField) {
            resolved.nextAction = nil
        }
        if !shouldApplyToken("moveTo", tokens: tokens, isInInputField: isInInputField) {
            resolved.moveTo = nil
        }
        if !shouldApplyToken("action", tokens: tokens, isInInputField: isInInputField) {
            resolved.action = ""
        }
        if !shouldApplyToken("actionDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.actionDelay = nil
        }

        return resolved
    }

    private func applyInputCondition(
        to ascript: AppConfiguration.ScriptAppleScript,
        isInInputField: Bool
    ) -> AppConfiguration.ScriptAppleScript {
        let tokens = parseInputCondition(ascript.inputCondition)
        if tokens.isEmpty {
            return ascript
        }

        var resolved = ascript
        if !shouldApplyToken("restoreClipboard", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboard = nil
        }
        if !shouldApplyToken("noEsc", tokens: tokens, isInInputField: isInInputField) {
            resolved.noEsc = nil
        }
        if !shouldApplyToken("nextAction", tokens: tokens, isInInputField: isInInputField) {
            resolved.nextAction = nil
        }
        if !shouldApplyToken("moveTo", tokens: tokens, isInInputField: isInInputField) {
            resolved.moveTo = nil
        }
        if !shouldApplyToken("action", tokens: tokens, isInInputField: isInInputField) {
            resolved.action = ""
        }
        if !shouldApplyToken("actionDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.actionDelay = nil
        }

        return resolved
    }

    private func applyInputCondition(
        to shortcut: AppConfiguration.Shortcut,
        isInInputField: Bool
    ) -> AppConfiguration.Shortcut {
        let tokens = parseInputCondition(shortcut.inputCondition)
        if tokens.isEmpty {
            return shortcut
        }

        var resolved = shortcut
        if !shouldApplyToken("restoreClipboard", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboard = nil
        }
        if !shouldApplyToken("noEsc", tokens: tokens, isInInputField: isInInputField) {
            resolved.noEsc = nil
        }
        if !shouldApplyToken("nextAction", tokens: tokens, isInInputField: isInInputField) {
            resolved.nextAction = nil
        }
        if !shouldApplyToken("moveTo", tokens: tokens, isInInputField: isInInputField) {
            resolved.moveTo = nil
        }
        if !shouldApplyToken("action", tokens: tokens, isInInputField: isInInputField) {
            resolved.action = ""
        }
        if !shouldApplyToken("actionDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.actionDelay = nil
        }

        return resolved
    }

    private func resolveSmartInsertTextIfNeeded(_ text: String, activeInsert: AppConfiguration.Insert?) -> String {
        let smartInsertEnabled = activeInsert?.smartInsert ?? globalConfigManager?.config.defaults.smartInsert ?? false
        guard smartInsertEnabled else {
            return text
        }

        guard requestAccessibilityPermission() else {
            logDebug("[SmartInsert] Accessibility permission unavailable, skipping smart insertion")
            return text
        }

        guard let context = getInputInsertionContext() else {
            logDebug("[SmartInsert] Input insertion context unavailable, skipping smart insertion")
            return text
        }

        var resolved = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolved.isEmpty || resolved == ".none" {
            return resolved
        }

        let original = resolved

        resolved = applySmartCasing(
            to: resolved,
            leftCharacter: context.leftCharacter,
            leftNonWhitespaceCharacter: context.leftNonWhitespaceCharacter,
            leftLinePrefix: context.leftLinePrefix
        )
        resolved = applySmartTrailingPunctuation(
            to: resolved,
            leftCharacter: context.leftCharacter,
            leftNonWhitespaceCharacter: context.leftNonWhitespaceCharacter,
            rightCharacter: context.rightCharacter,
            rightNonWhitespaceCharacter: context.rightNonWhitespaceCharacter,
            rightHasLineBreakBeforeNextNonWhitespace: context.rightHasLineBreakBeforeNextNonWhitespace
        )
        resolved = applySmartBoundarySpacing(
            to: resolved,
            leftCharacter: context.leftCharacter,
            leftLinePrefix: context.leftLinePrefix,
            rightCharacter: context.rightCharacter
        )

        let leftChar = context.leftCharacter.map { String($0) } ?? "nil"
        let leftNonWs = context.leftNonWhitespaceCharacter.map { String($0) } ?? "nil"
        let rightChar = context.rightCharacter.map { String($0) } ?? "nil"
        let rightNonWs = context.rightNonWhitespaceCharacter.map { String($0) } ?? "nil"
        logDebug(
            "[SmartInsert] Context left=\(redactForLogs(leftChar)) leftNonWs=\(redactForLogs(leftNonWs)) " +
            "right=\(redactForLogs(rightChar)) rightNonWs=\(redactForLogs(rightNonWs)) " +
            "rightHasLineBreak=\(context.rightHasLineBreakBeforeNextNonWhitespace) " +
            "linePrefix=\(redactForLogs(context.leftLinePrefix))"
        )
        logDebug("[SmartInsert] Text before: \(redactForLogs(original)) | after: \(redactForLogs(resolved))")
        logDebug(
            "[SmartInsert] After stats: len=\(resolved.count) leadingSpaces=\(countLeadingSpaces(resolved)) " +
            "visible=\(redactForLogs(visibleWhitespace(resolved)))"
        )

        return resolved
    }

    private func countLeadingSpaces(_ value: String) -> Int {
        value.prefix(while: { $0 == " " }).count
    }

    private func visibleWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: " ", with: "␠")
            .replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\t", with: "⇥")
    }

    private func applySmartCasing(
        to text: String,
        leftCharacter: Character?,
        leftNonWhitespaceCharacter: Character?,
        leftLinePrefix: String
    ) -> String {
        guard shouldLowercaseForMidSentence(
            leftCharacter: leftCharacter,
            leftNonWhitespaceCharacter: leftNonWhitespaceCharacter,
            leftLinePrefix: leftLinePrefix
        ) else {
            return text
        }

        let firstToken = extractFirstWordToken(from: text)
        if shouldPreserveLeadingUppercase(for: firstToken) {
            return text
        }

        return lowercasingFirstLetter(in: text)
    }

    private func applySmartTrailingPunctuation(
        to text: String,
        leftCharacter: Character?,
        leftNonWhitespaceCharacter: Character?,
        rightCharacter: Character?,
        rightNonWhitespaceCharacter: Character?,
        rightHasLineBreakBeforeNextNonWhitespace: Bool
    ) -> String {
        // If we're directly before punctuation, avoid duplicate punctuation like ".." or "!!".
        if let rightCharacter = rightCharacter, ".,;:!?".contains(rightCharacter) {
            var updated = text
            while let last = updated.last, ".,;:!?".contains(last) {
                updated.removeLast()
            }
            return updated
        }

        // Preserve trailing punctuation when inserting a full sentence between sentences.
        // Example: "Sentence one. |Sentence two" should keep inserted final period.
        if shouldPreserveTrailingPunctuationForSentenceBoundary(
            leftCharacter: leftCharacter,
            leftNonWhitespaceCharacter: leftNonWhitespaceCharacter,
            rightCharacter: rightCharacter,
            rightNonWhitespaceCharacter: rightNonWhitespaceCharacter
        ) {
            return text
        }

        // Strip trailing punctuation only when we're inserting into ongoing word content.
        // This avoids stripping when only markdown/code delimiters are to the right.
        guard let rightNonWhitespaceCharacter = rightNonWhitespaceCharacter else {
            return text
        }
        if rightHasLineBreakBeforeNextNonWhitespace {
            return text
        }
        guard isWordCharacter(rightNonWhitespaceCharacter) else {
            return text
        }

        var updated = text
        while let last = updated.last, ".,;:!?".contains(last) {
            updated.removeLast()
        }
        return updated
    }

    private func shouldPreserveTrailingPunctuationForSentenceBoundary(
        leftCharacter: Character?,
        leftNonWhitespaceCharacter: Character?,
        rightCharacter: Character?,
        rightNonWhitespaceCharacter: Character?
    ) -> Bool {
        let effectiveLeft: Character?
        if let leftCharacter = leftCharacter, !leftCharacter.isWhitespace {
            effectiveLeft = leftCharacter
        } else {
            effectiveLeft = leftNonWhitespaceCharacter
        }

        guard let left = effectiveLeft, ".!?".contains(left) else {
            return false
        }

        let effectiveRight: Character?
        if let rightCharacter = rightCharacter, !rightCharacter.isWhitespace {
            effectiveRight = rightCharacter
        } else {
            effectiveRight = rightNonWhitespaceCharacter
        }

        guard let right = effectiveRight else {
            return false
        }

        let rightString = String(right)
        return rightString.rangeOfCharacter(from: .uppercaseLetters) != nil
    }

    private func applySmartBoundarySpacing(
        to text: String,
        leftCharacter: Character?,
        leftLinePrefix: String,
        rightCharacter: Character?
    ) -> String {
        var updated = text

        if let first = updated.first, isWordCharacter(first) {
            let shouldInsertLeadingSpaceForMarkdownList = shouldInsertLeadingSpaceForMarkdownListPrefix(leftLinePrefix)
            let shouldInsertLeadingSpaceAfterWord = leftCharacter.map { isWordCharacter($0) } ?? false
            let punctuationNeedingTrailingSpace = ".,;:!?)]}\""
            let shouldInsertLeadingSpaceAfterPunctuation = leftCharacter.map { punctuationNeedingTrailingSpace.contains($0) } ?? false

            if shouldInsertLeadingSpaceForMarkdownList || shouldInsertLeadingSpaceAfterWord || shouldInsertLeadingSpaceAfterPunctuation {
                updated = " " + updated
            }
        }

        if let right = rightCharacter,
           isWordCharacter(right),
           let last = updated.last,
           isWordCharacter(last) {
            updated += " "
        } else if let right = rightCharacter,
                  isWordCharacter(right),
                  let last = updated.last,
                  ".!?".contains(last) {
            // Keep sentence separation when we preserve inserted sentence-ending punctuation.
            updated += " "
        }

        return updated
    }

    private func shouldLowercaseForMidSentence(
        leftCharacter: Character?,
        leftNonWhitespaceCharacter: Character?,
        leftLinePrefix: String
    ) -> Bool {
        if isMarkdownListLineStart(leftLinePrefix) {
            return false
        }

        guard let leftCharacter = leftCharacter else {
            return false
        }

        // Start-of-line should behave like sentence start even if previous line
        // ended with a non-terminal character.
        if leftCharacter.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) {
            return false
        }

        if leftCharacter.isWhitespace {
            guard let previous = leftNonWhitespaceCharacter else {
                return false
            }
            return !".!?".contains(previous)
        }

        return !".!?".contains(leftCharacter)
    }

    private func isMarkdownListLineStart(_ leftLinePrefix: String) -> Bool {
        let trimmed = leftLinePrefix.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return false
        }
        return shouldInsertLeadingSpaceForMarkdownListPrefix(leftLinePrefix) || isMarkdownListWithSpacePrefix(leftLinePrefix)
    }

    private func shouldInsertLeadingSpaceForMarkdownListPrefix(_ leftLinePrefix: String) -> Bool {
        let trimmed = leftLinePrefix.trimmingCharacters(in: .whitespaces)
        if ["*", "-", "+", ">"].contains(trimmed) {
            return true
        }
        if let regex = try? NSRegularExpression(pattern: #"^\d+[.)]$"#),
           regex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil {
            return true
        }
        return false
    }

    private func isMarkdownListWithSpacePrefix(_ linePrefix: String) -> Bool {
        if let regex = try? NSRegularExpression(pattern: #"^\s*(\*|\+|-|>|\d+[.)])\s+$"#),
           regex.firstMatch(in: linePrefix, options: [], range: NSRange(location: 0, length: (linePrefix as NSString).length)) != nil {
            return true
        }
        return false
    }

    private func extractFirstWordToken(from text: String) -> String {
        var scalars: [UnicodeScalar] = []
        var started = false

        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                started = true
                continue
            }

            if started && scalar == "'" {
                scalars.append(scalar)
                continue
            }

            if started {
                break
            }
        }

        return String(String.UnicodeScalarView(scalars))
    }

    private func shouldPreserveLeadingUppercase(for firstToken: String) -> Bool {
        if firstToken.isEmpty {
            return false
        }

        let preserveTokens = Set(["I", "I'm", "I've", "I'll", "I'd"])
        if preserveTokens.contains(firstToken) {
            return true
        }

        let lettersOnly = firstToken.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if lettersOnly.count > 1 && lettersOnly.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }) {
            return true
        }

        return false
    }

    private func lowercasingFirstLetter(in text: String) -> String {
        var result = text
        for index in result.indices {
            let character = result[index]
            let charString = String(character)
            if charString.rangeOfCharacter(from: .letters) != nil {
                result.replaceSubrange(index...index, with: charString.lowercased())
                break
            }
        }

        return result
    }

    private func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    // This version is for the main watcher flow and respects the 'noEsc' setting
    func applyInsert(_ text: String, activeInsert: AppConfiguration.Insert?, isAutoPaste: Bool = false) {
        let resolvedText = resolveSmartInsertTextIfNeeded(text, activeInsert: activeInsert)

        if resolvedText.isEmpty || resolvedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolvedText == ".none" {
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
                let pasteboard = NSPasteboard.general; pasteboard.clearContents(); pasteboard.setString(resolvedText, forType: .string)
                simulateKeyDown(key: 9, flags: .maskCommand) // Cmd+V
                checkAndSimulatePressReturn(activeInsert: activeInsert); return
            }
        }
        simulateEscKeyPress(activeInsert: activeInsert)
        pasteText(resolvedText, activeInsert: activeInsert)
        checkAndSimulatePressReturn(activeInsert: activeInsert)
    }
    
    // This version is for the --exec-insert CLI command and does NOT press ESC.
    func applyInsertForExec(_ text: String, activeInsert: AppConfiguration.Insert?, isAutoPaste: Bool = false) {
        let resolvedText = resolveSmartInsertTextIfNeeded(text, activeInsert: activeInsert)

        if resolvedText.isEmpty || resolvedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolvedText == ".none" {
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
                let pasteboard = NSPasteboard.general; pasteboard.clearContents(); pasteboard.setString(resolvedText, forType: .string)
                simulateKeyDown(key: 9, flags: .maskCommand) // Cmd+V
                checkAndSimulatePressReturn(activeInsert: activeInsert); return
            }
        }
        // No ESC key press for exec-insert
        if restoreClipboard {
            pasteText(resolvedText, activeInsert: activeInsert)
        } else {
            pasteTextNoRestore(resolvedText, activeInsert: activeInsert)
        }
        checkAndSimulatePressReturn(activeInsert: activeInsert)
    }
    
    // This version is for clipboard-monitored insert actions and does NOT press ESC or apply actionDelay
    // (ESC and delay are handled by ClipboardMonitor)
    func applyInsertWithoutEsc(_ text: String, activeInsert: AppConfiguration.Insert?, isAutoPaste: Bool = false) -> Bool {
        let resolvedText = resolveSmartInsertTextIfNeeded(text, activeInsert: activeInsert)

        if resolvedText.isEmpty || resolvedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolvedText == ".none" {
            // For empty or .none actions, do nothing since delay is handled by ClipboardMonitor
            return true
        }
        
        if isAutoPaste {
            if !requestAccessibilityPermission() { logWarning("Accessibility permission denied"); return false }
            if !isInInputField() {
                logDebug("Clipboard-monitored auto paste - not in input field, direct paste only")
                let pasteboard = NSPasteboard.general; pasteboard.clearContents(); pasteboard.setString(resolvedText, forType: .string)
                simulateKeyDown(key: 9, flags: .maskCommand) // Cmd+V
                checkAndSimulatePressReturn(activeInsert: activeInsert); return true
            }
        }
        
        // No ESC key press or actionDelay - these are handled by ClipboardMonitor
        pasteTextNoRestore(resolvedText, activeInsert: activeInsert)
        checkAndSimulatePressReturn(activeInsert: activeInsert)
        return true
    }
    
    // MARK: - CLI Execution Methods for Non-Insert Actions
    
    // Simple execution methods for CLI commands (no ESC, no clipboard monitoring, no moveTo handling)
    func executeUrlForCLI(_ urlAction: AppConfiguration.Url, metaJson: [String: Any]) {
        let actionDelay = urlAction.actionDelay ?? globalConfigManager?.config.defaults.actionDelay ?? 0.0
        if actionDelay > 0 { Thread.sleep(forTimeInterval: actionDelay) }
        
        let processedAction = processAllPlaceholders(action: urlAction.action, metaJson: metaJson, actionType: .url)
        let normalized = processedAction.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == ".none" {
            logDebug("[URL-CLI] Action is empty or '.none' - skipping URL execution")
            return
        }
        
        // Try to create URL directly from processed action
        // Placeholders are now URL-encoded individually during processing
        guard let url = URL(string: processedAction) else {
            logError("Invalid URL after processing: \(redactForLogs(processedAction))")
            return
        }
        
        openResolvedUrlCLI(url, with: urlAction)
    }

    private func openResolvedUrlCLI(_ url: URL, with urlAction: AppConfiguration.Url) {
        let shouldOpenInBackground = urlAction.openBackground ?? false
        if let openWith = urlAction.openWith, !openWith.isEmpty {
            let expandedOpenWith = (openWith as NSString).expandingTildeInPath
            let task = Process()
            task.launchPath = "/usr/bin/open"
            if shouldOpenInBackground {
                task.arguments = ["-g", "-a", expandedOpenWith, url.absoluteString]
            } else {
                task.arguments = ["-a", expandedOpenWith, url.absoluteString]
            }
            do {
                try task.run()
            } catch {
                logError("Failed to open URL with specified app: \(error)")
                openUrlCLI(url, inBackground: shouldOpenInBackground)
            }
        } else {
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
            logDebug("URL opened \(inBackground ? "in background" : "normally") via CLI: \(redactForLogs(url.absoluteString))")
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
        let normalized = processedAction.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized == ".run" {
            let task = Process()
            task.launchPath = "/usr/bin/shortcuts"
            task.arguments = ["run", shortcutName]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice

            do {
                try task.run()
            } catch {
                logError("Failed to execute shortcut action without input: \(error)")
            }
            return
        }

        if normalized.isEmpty || normalized == ".none" {
            logDebug("[Shortcut-CLI] Action is empty or '.none' - skipping shortcut execution")
            return
        }
        
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
        let normalized = processedAction.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == ".none" {
            logDebug("[Shell-CLI] Action is empty or '.none' - skipping shell execution")
            return
        }
        
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
        let normalized = processedAction.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == ".none" {
            logDebug("[AppleScript-CLI] Action is empty or '.none' - skipping AppleScript execution")
            return
        }
        
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
        if globalState.autoReturnEnabled {
            if shouldPressReturn {
                // If both autoReturn and pressReturn are set, treat as pressReturn (simulate once, clear globalState.autoReturnEnabled)
                logInfo("Simulating return key press due to pressReturn setting (auto-return was also set)")
                simulateReturnKeyPress()
            } else {
                logInfo("Simulating return key press due to auto-return")
                simulateReturnKeyPress()
            }
            globalState.autoReturnEnabled = false
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
        logDebug(
            "[SmartInsert] Clipboard insert payload (restore): len=\(text.count) " +
            "leadingSpaces=\(countLeadingSpaces(text)) visible=\(redactForLogs(visibleWhitespace(text)))"
        )
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let confirm = pasteboard.string(forType: .string) ?? ""
        logDebug(
            "[SmartInsert] Pasteboard confirmed (restore): len=\(confirm.count) " +
            "leadingSpaces=\(countLeadingSpaces(confirm)) visible=\(redactForLogs(visibleWhitespace(confirm)))"
        )
        simulateKeyDown(key: 9, flags: .maskCommand) // Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.clearContents()
            if let original = originalContent { pasteboard.setString(original, forType: .string) }
        }
    }
    
    // Version of pasteUsingClipboard that doesn't save/restore clipboard (used with ClipboardMonitor)
    private func pasteUsingClipboardNoRestore(_ text: String) {
        let pasteboard = NSPasteboard.general
        logDebug(
            "[SmartInsert] Clipboard insert payload (no-restore): len=\(text.count) " +
            "leadingSpaces=\(countLeadingSpaces(text)) visible=\(redactForLogs(visibleWhitespace(text)))"
        )
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let confirm = pasteboard.string(forType: .string) ?? ""
        logDebug(
            "[SmartInsert] Pasteboard confirmed (no-restore): len=\(confirm.count) " +
            "leadingSpaces=\(countLeadingSpaces(confirm)) visible=\(redactForLogs(visibleWhitespace(confirm)))"
        )
        simulateKeyDown(key: 9, flags: .maskCommand) // Cmd+V
    }

    /// Handles client connections with timeout protection to prevent blocking
    private func handleConnection(clientSocket: Int32, configManager: ConfigurationManager?) {
        guard let configMgr = self.configManagerRef ?? configManager ?? globalConfigManager else {
            logError("No valid config manager"); close(clientSocket); return
        }
        defer { close(clientSocket) }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096); defer { buffer.deallocate() }
        
        // Use timeout-enabled read to prevent indefinite blocking
        let bytesRead = readWithTimeout(clientSocket, buffer, 4096)
        guard bytesRead > 0 else { 
            if bytesRead == -1 {
                logError("Socket read failed or timed out")
            } else {
                logError("Failed to read from socket: no data received")
            }
            return 
        }
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
                _ = sendResponse(response, to: clientSocket)
                
            case .updateConfig:
                // Handle configuration updates
                if let arguments = commandMessage.arguments {
                    var updated = false
                    
                    // Update active action with validation (supports both new activeAction and legacy activeInsert)
                    if let activeAction = arguments["activeAction"] ?? arguments["activeInsert"] {
                        // Validate action exists if it's not empty
                        if !activeAction.isEmpty && !validateActionExists(activeAction, configManager: configMgr) {
                            response = "Error: Action '\(activeAction)' does not exist."
                            _ = sendResponse(response, to: clientSocket)
                            logError("Attempted to set non-existent action: \(activeAction)")
                            notify(title: "Macrowhisper", message: "Non-existent action: \(activeAction)")
                            return
                        }
                        let defaultsNextAction = configMgr.config.defaults.nextAction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !activeAction.isEmpty && !defaultsNextAction.isEmpty && activeAction == defaultsNextAction {
                            response = "Error: activeAction cannot be the same as defaults.nextAction ('\(activeAction)')."
                            _ = sendResponse(response, to: clientSocket)
                            logError("Rejected activeAction update due to defaults.nextAction loop: \(activeAction)")
                            notify(
                                title: "Macrowhisper - Invalid Action",
                                message: "activeAction cannot match defaults.nextAction (\(activeAction))."
                            )
                            return
                        }
                        configMgr.config.defaults.activeAction = activeAction
                        updated = true
                    }
                    
                    if updated {
                        do {
                            try configMgr.saveConfig()
                            configMgr.onConfigChanged?(nil)
                            response = "Configuration has been updated"
                        } catch {
                            response = "Failed to save configuration: \(error.localizedDescription)"
                        }
                    } else {
                        response = "No configuration changes were made"
                    }
                } else {
                    response = "Configuration has been updated"
                }
                _ = sendResponse(response, to: clientSocket)
                
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
                lines.append("Auto-return: \(globalState.autoReturnEnabled ? "enabled" : "disabled")")
                lines.append("Scheduled action: \(globalState.scheduledActionName ?? "(none)")")
                // Settings
                lines.append("noUpdates: \(defaults.noUpdates ? "yes" : "no")")
                lines.append("noNoti: \(defaults.noNoti ? "yes" : "no")")
                lines.append("noEsc: \(defaults.noEsc ? "yes" : "no")")
                lines.append("simKeypress: \(defaults.simKeypress ? "yes" : "no")")
                lines.append("redactedLogs: \(defaults.redactedLogs ? "yes" : "no")")
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
                _ = sendResponse(response, to: clientSocket)
                
            case .debug:
                response = "Server status:\n- Socket path: \(socketPath)\n- Server socket descriptor: \(serverSocket)"
                _ = sendResponse(response, to: clientSocket)
                
            case .listInserts:
                let inserts = configMgr.config.inserts
                let activeActionName = configMgr.config.defaults.activeAction ?? ""
                if inserts.isEmpty {
                    response = "No inserts configured."
                } else {
                    response = inserts.keys.sorted().map { "\($0)\($0 == activeActionName ? " (active)" : "")" }.joined(separator: "\n")
                }
                _ = sendResponse(response, to: clientSocket)
                
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
                _ = sendResponse(response, to: clientSocket)
                
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
                _ = sendResponse(response, to: clientSocket)
                
            case .autoReturn:
                if let enableStr = commandMessage.arguments?["enable"], let enable = Bool(enableStr) {
                    globalState.autoReturnEnabled = enable
                    // Cancel scheduled action if auto-return is enabled
                    if enable {
                        globalState.scheduledActionName = nil
                        // Cancel scheduled action timeout
                        globalState.scheduledActionTimeoutTimer?.invalidate()
                        globalState.scheduledActionTimeoutTimer = nil
                        // Start auto-return timeout
                        startAutoReturnTimeout()
                    } else {
                        // Cancel auto-return timeout if disabling
                        cancelAutoReturnTimeout()
                    }
                    response = globalState.autoReturnEnabled ? "Auto-return enabled for next result" : "Auto-return disabled"
                    logInfo(response)
                } else {
                    response = "Missing or invalid enable parameter"
                    logError(response)
                }
                _ = sendResponse(response, to: clientSocket)
                
            case .scheduleAction:
                if let actionName = commandMessage.arguments?["name"] {
                    if actionName.isEmpty {
                        // Cancel scheduled action
                        globalState.scheduledActionName = nil
                        // Cancel scheduled action timeout
                        cancelScheduledActionTimeout()
                        response = "Scheduled action cancelled"
                        logInfo("Scheduled action cancelled")
                    } else {
                        // Validate the action exists before scheduling
                        if !validateActionExists(actionName, configManager: configMgr) {
                            response = "Action not found: \(actionName)"
                            logError(response)
                            notify(title: "Macrowhisper", message: "Action not found: \(actionName)")
                            _ = sendResponse(response, to: clientSocket)
                            return
                        }
                        // Cancel auto-return if scheduling an action
                        globalState.autoReturnEnabled = false
                        // Cancel auto-return timeout
                        cancelAutoReturnTimeout()
                        globalState.scheduledActionName = actionName
                        // Start scheduled action timeout
                        startScheduledActionTimeout()
                        response = "Action '\(actionName)' scheduled for next recording"
                        logInfo("Action '\(actionName)' scheduled for next recording")
                    }
                } else {
                    response = "Missing action name parameter"
                    logError(response)
                }
                _ = sendResponse(response, to: clientSocket)
                
            case .execInsert:
                if let insertName = commandMessage.arguments?["name"], let insert = configMgr.config.inserts[insertName] {
                    if let lastValidJson = findLastValidJsonFile(configManager: configMgr) {
                        // Ensure autoReturn and scheduled action are always false for exec-insert
                        globalState.autoReturnEnabled = false
                        globalState.scheduledActionName = nil
                        // Cancel timeouts
                        cancelAutoReturnTimeout()
                        cancelScheduledActionTimeout()
                        let (resolvedInsert, isAutoPasteTemplate) = resolveInsertForCLIExecution(insert)
                        let (processedAction, isAutoPasteResult) = processInsertAction(resolvedInsert.action, metaJson: lastValidJson)
                        applyInsertForExec(
                            processedAction,
                            activeInsert: resolvedInsert,
                            isAutoPaste: isAutoPasteTemplate || isAutoPasteResult
                        )
                        
                        // Trigger clipboard cleanup for CLI actions to prevent contamination
                        clipboardMonitorRef?.triggerClipboardCleanupForCLI()
                        
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
                _ = sendResponse(response, to: clientSocket)
                
            case .addUrl:
                if let name = commandMessage.arguments?["name"] {
                    if actionNameExists(name, configManager: configMgr) {
                        response = "Action name '\(name)' already exists"
                        notify(title: "Macrowhisper", message: "Action name '\(name)' already exists")
                    } else {
                        configMgr.config.urls[name] = AppConfiguration.Url(action: "", icon: "", openBackground: false)
                        do {
                            try configMgr.saveConfig()
                            configMgr.onConfigChanged?(nil)
                            response = "URL action '\(name)' added"
                        } catch {
                            response = "Failed to save URL action '\(name)': \(error.localizedDescription)"
                        }
                    }
                } else { response = "Missing name for URL action" }
                _ = sendResponse(response, to: clientSocket)
                
            case .addShortcut:
                 if let name = commandMessage.arguments?["name"] {
                    if actionNameExists(name, configManager: configMgr) {
                        response = "Action name '\(name)' already exists"
                        notify(title: "Macrowhisper", message: "Action name '\(name)' already exists")
                    } else {
                        configMgr.config.shortcuts[name] = AppConfiguration.Shortcut(action: "", icon: "")
                        do {
                            try configMgr.saveConfig()
                            configMgr.onConfigChanged?(nil)
                            response = "Shortcut action '\(name)' added"
                        } catch {
                            response = "Failed to save shortcut action '\(name)': \(error.localizedDescription)"
                        }
                    }
                } else { response = "Missing name for Shortcut action" }
                _ = sendResponse(response, to: clientSocket)
                
            case .addShell:
                 if let name = commandMessage.arguments?["name"] {
                    if actionNameExists(name, configManager: configMgr) {
                        response = "Action name '\(name)' already exists"
                        notify(title: "Macrowhisper", message: "Action name '\(name)' already exists")
                    } else {
                        configMgr.config.scriptsShell[name] = AppConfiguration.ScriptShell(action: "", icon: "")
                        do {
                            try configMgr.saveConfig()
                            configMgr.onConfigChanged?(nil)
                            response = "Shell script action '\(name)' added"
                        } catch {
                            response = "Failed to save shell script action '\(name)': \(error.localizedDescription)"
                        }
                    }
                } else { response = "Missing name for Shell script action" }
                _ = sendResponse(response, to: clientSocket)
                
            case .addAppleScript:
                 if let name = commandMessage.arguments?["name"] {
                    if actionNameExists(name, configManager: configMgr) {
                        response = "Action name '\(name)' already exists"
                        notify(title: "Macrowhisper", message: "Action name '\(name)' already exists")
                    } else {
                        configMgr.config.scriptsAS[name] = AppConfiguration.ScriptAppleScript(action: "", icon: "")
                        do {
                            try configMgr.saveConfig()
                            configMgr.onConfigChanged?(nil)
                            response = "AppleScript action '\(name)' added"
                        } catch {
                            response = "Failed to save AppleScript action '\(name)': \(error.localizedDescription)"
                        }
                    }
                } else { response = "Missing name for AppleScript action" }
                _ = sendResponse(response, to: clientSocket)
                
            case .addInsert:
                if let name = commandMessage.arguments?["name"] {
                    if actionNameExists(name, configManager: configMgr) {
                        response = "Action name '\(name)' already exists"
                        notify(title: "Macrowhisper", message: "Action name '\(name)' already exists")
                    } else {
                        let newInsert = AppConfiguration.Insert(action: "", icon: "")
                        configMgr.config.inserts[name] = newInsert
                        do {
                            try configMgr.saveConfig()
                            configMgr.onConfigChanged?(nil)
                            response = "Insert '\(name)' added"
                        } catch {
                            response = "Failed to save insert '\(name)': \(error.localizedDescription)"
                        }
                    }
                } else {
                    response = "Missing name for insert"
                }
                _ = sendResponse(response, to: clientSocket)
                
            case .removeAction:
                guard let name = commandMessage.arguments?["name"] else {
                    response = "Missing name for action"
                    _ = sendResponse(response, to: clientSocket)
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
                    do {
                        try configMgr.saveConfig()
                        configMgr.onConfigChanged?(nil)
                        response = "\(actionType.capitalized) action '\(name)' removed"
                    } catch {
                        response = "Failed to save after removing '\(name)': \(error.localizedDescription)"
                    }
                } else {
                    response = "Action '\(name)' not found"
                }
                _ = sendResponse(response, to: clientSocket)
                
            case .version:
                response = "macrowhisper version \(APP_VERSION)"
                _ = sendResponse(response, to: clientSocket)
                
            case .versionState:
                let versionChecker = VersionChecker()
                response = versionChecker.getStateString()
                _ = sendResponse(response, to: clientSocket)
                
            case .forceUpdateCheck:
                let versionChecker = VersionChecker()
                versionChecker.forceUpdateCheck()
                response = "Forced update check initiated (all timing constraints reset). Check logs for results."
                _ = sendResponse(response, to: clientSocket)
                
            case .versionClear:
                let versionChecker = VersionChecker()
                versionChecker.clearAllUserDefaults()
                response = "All version checker UserDefaults cleared. Next check will start fresh."
                _ = sendResponse(response, to: clientSocket)
                
            // Service management commands
            case .serviceStatus:
                let serviceManager = ServiceManager()
                response = serviceManager.getServiceStatus()
                _ = sendResponse(response, to: clientSocket)
                
            case .serviceInstall:
                let serviceManager = ServiceManager()
                let result = serviceManager.installService()
                response = result.message
                _ = sendResponse(response, to: clientSocket)
                
            case .serviceStart:
                let serviceManager = ServiceManager()
                let result = serviceManager.startService()
                response = result.message
                _ = sendResponse(response, to: clientSocket)
                
            case .serviceStop:
                let serviceManager = ServiceManager()
                let result = serviceManager.stopService()
                response = result.message
                _ = sendResponse(response, to: clientSocket)
                
            case .serviceRestart:
                let serviceManager = ServiceManager()
                let result = serviceManager.restartService()
                response = result.message
                _ = sendResponse(response, to: clientSocket)
                
            case .serviceUninstall:
                let serviceManager = ServiceManager()
                let result = serviceManager.uninstallService()
                response = result.message
                _ = sendResponse(response, to: clientSocket)
                
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
                _ = sendResponse(response, to: clientSocket)
                
            case .listUrls:
                let urls = configMgr.config.urls.keys.sorted()
                let activeActionName = configMgr.config.defaults.activeAction ?? ""
                response = urls.map { "\($0)\($0 == activeActionName ? " (active)" : "")" }.joined(separator: "\n")
                _ = sendResponse(response, to: clientSocket)
                
            case .listShortcuts:
                let shortcuts = configMgr.config.shortcuts.keys.sorted()
                let activeActionName = configMgr.config.defaults.activeAction ?? ""
                response = shortcuts.map { "\($0)\($0 == activeActionName ? " (active)" : "")" }.joined(separator: "\n")
                _ = sendResponse(response, to: clientSocket)
                
            case .listShell:
                let shells = configMgr.config.scriptsShell.keys.sorted()
                let activeActionName = configMgr.config.defaults.activeAction ?? ""
                response = shells.map { "\($0)\($0 == activeActionName ? " (active)" : "")" }.joined(separator: "\n")
                _ = sendResponse(response, to: clientSocket)
                
            case .listAppleScript:
                let scripts = configMgr.config.scriptsAS.keys.sorted()
                let activeActionName = configMgr.config.defaults.activeAction ?? ""
                response = scripts.map { "\($0)\($0 == activeActionName ? " (active)" : "")" }.joined(separator: "\n")
                _ = sendResponse(response, to: clientSocket)
                
            case .execAction:
                if let actionName = commandMessage.arguments?["name"] {
                    let (actionType, action) = findActionByName(actionName, configManager: configMgr)
                    
                    if let action = action {
                        if let lastValidJson = findLastValidJsonFile(configManager: configMgr) {
                            globalState.autoReturnEnabled = false
                            globalState.scheduledActionName = nil
                            // Cancel timeouts
                            cancelAutoReturnTimeout()
                            cancelScheduledActionTimeout()
                            
                            // Enhance metaJson with CLI-specific data
                            let enhancedMetaJson = enhanceMetaJsonForCLI(metaJson: lastValidJson, configManager: configMgr)
                            
                            // Execute based on action type using CLI-specific methods
                            switch actionType {
                            case .insert:
                                if let insert = action as? AppConfiguration.Insert {
                                    let (resolvedInsert, isAutoPasteTemplate) = resolveInsertForCLIExecution(insert)
                                    let (processedAction, isAutoPasteResult) = processInsertAction(resolvedInsert.action, metaJson: enhancedMetaJson)
                                    applyInsertForExec(
                                        processedAction,
                                        activeInsert: resolvedInsert,
                                        isAutoPaste: isAutoPasteTemplate || isAutoPasteResult
                                    )
                                }
                            case .url:
                                if let url = action as? AppConfiguration.Url {
                                    let resolvedUrl = resolveUrlForCLIExecution(url)
                                    executeUrlForCLI(resolvedUrl, metaJson: enhancedMetaJson)
                                }
                            case .shortcut:
                                if let shortcut = action as? AppConfiguration.Shortcut {
                                    let resolvedShortcut = resolveShortcutForCLIExecution(shortcut)
                                    executeShortcutForCLI(resolvedShortcut, shortcutName: actionName, metaJson: enhancedMetaJson)
                                }
                            case .shell:
                                if let shell = action as? AppConfiguration.ScriptShell {
                                    let resolvedShell = resolveShellForCLIExecution(shell)
                                    executeShellForCLI(resolvedShell, metaJson: enhancedMetaJson)
                                }
                            case .appleScript:
                                if let script = action as? AppConfiguration.ScriptAppleScript {
                                    let resolvedAppleScript = resolveAppleScriptForCLIExecution(script)
                                    executeAppleScriptForCLI(resolvedAppleScript, metaJson: enhancedMetaJson)
                                }
                            }
                            
                            // Trigger clipboard cleanup for CLI actions to prevent contamination
                            clipboardMonitorRef?.triggerClipboardCleanupForCLI()
                            
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
                _ = sendResponse(response, to: clientSocket)
                
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
                _ = sendResponse(response, to: clientSocket)
                
            case .quit:
                logInfo("Received quit command, shutting down.")
                let response = "Quitting macrowhisper..."
                _ = sendResponse(response, to: clientSocket)
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
        
        // Send command with timeout protection
        let bytesSent = data.withUnsafeBytes { bytes in
            writeWithTimeout(clientSocket, bytes.baseAddress!, data.count)
        }
        guard bytesSent == data.count else {
            if bytesSent == -1 {
                logError("Failed to send command: write timeout or error")
                return "Command send timeout"
            } else {
                let err = "Failed to send complete message. Sent \(bytesSent) of \(data.count) bytes."
                logError(err); return err
            }
        }
        
        // Read response with timeout protection
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536); defer { buffer.deallocate() }
        let bytesRead = readWithTimeout(clientSocket, buffer, 65536)
        
        guard bytesRead > 0 else {
            if bytesRead == -1 {
                logError("Failed to read response: read timeout or error")
                return "Response read timeout"
            } else {
                let err = "Failed to read from socket: no response data"
                logError(err); return err
            }
        }
        
        return String(bytes: UnsafeBufferPointer(start: buffer, count: bytesRead), encoding: .utf8)
    }
} 
