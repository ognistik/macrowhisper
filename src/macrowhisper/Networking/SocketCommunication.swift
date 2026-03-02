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

    private struct LatestValidRecording {
        let metaJson: [String: Any]
        let recordingPath: String
    }

    private enum CLIActionMetaSourceKind {
        case latestValid
        case recordingsFolderName
        case folderPath
        case jsonFilePath
    }

    private struct CLIActionMetaSource {
        let metaJson: [String: Any]
        let recordingPath: String?
        let description: String
        let kind: CLIActionMetaSourceKind
    }

    private struct CLIResolvedActionStep {
        let name: String
        let type: ActionType
        let action: Any
    }

    struct ProcessedInsertAction {
        let text: String
        let isAutoPaste: Bool
        let hadSmartCasingBlockingTransform: Bool
    }

    private enum CLIActionChainError: LocalizedError {
        case duplicateActionName(String)
        case missingAction(String)
        case cycleDetected(String)
        case multipleInsertActions(first: String, second: String)

        var errorDescription: String? {
            switch self {
            case .duplicateActionName(let name):
                return "Duplicate action name '\(name)' exists across multiple action types. Names must be unique."
            case .missingAction(let name):
                return "Chained nextAction '\(name)' was not found."
            case .cycleDetected(let name):
                return "Action chain cycle detected at '\(name)'. Chained actions cannot repeat."
            case .multipleInsertActions(let first, let second):
                return "Action chain contains multiple insert actions ('\(first)' and '\(second)'). Only one insert action is allowed per chain."
            }
        }
    }

    private enum CLIActionMetaSourceError: LocalizedError {
        case latestValidNotFound
        case recordingFolderNotFound(String)
        case metaSourcePathNotFound(String)
        case metaSourceDirectoryMissingMetaJson(String)
        case metaSourceFileReadFailed(String)
        case metaSourceJsonInvalid(String)
        case metaSourceJsonNotDictionary(String)
        case metaSourceJsonInvalidContent(String)

        var errorDescription: String? {
            switch self {
            case .latestValidNotFound:
                return "No valid JSON file found with results"
            case .recordingFolderNotFound(let folderName):
                return "Recording folder not found for --meta: \(folderName)"
            case .metaSourcePathNotFound(let path):
                return "Meta source path not found: \(path)"
            case .metaSourceDirectoryMissingMetaJson(let path):
                return "meta.json not found in folder: \(path)"
            case .metaSourceFileReadFailed(let path):
                return "Failed to read meta source file: \(path)"
            case .metaSourceJsonInvalid(let path):
                return "Invalid JSON in meta source file: \(path)"
            case .metaSourceJsonNotDictionary(let path):
                return "Meta source JSON must be an object: \(path)"
            case .metaSourceJsonInvalidContent(let path):
                return "Meta source JSON does not contain a valid result: \(path)"
            }
        }
    }
    
    enum Command: String, Codable {
        case reloadConfig
        case switchConfigPath
        case updateConfig
        case status
        case debug
        case version
        case listInserts
        case addInsert
        case getIcon
        case autoReturn
        case scheduleAction
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
        case copyAction
        case removeAction
        case folderName
        case folderPath
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

    private func findLastValidRecording(configManager: ConfigurationManager) -> LatestValidRecording? {
        guard let firstReference = getLatestValidRecordingReference(configManager: configManager) else {
            return nil
        }
        return LatestValidRecording(metaJson: firstReference.metaJson, recordingPath: firstReference.path)
    }

    private func shouldTreatMetaValueAsPath(_ value: String) -> Bool {
        value.contains("/") || value.hasPrefix("~") || value.hasPrefix(".")
    }

    private func loadMetaJsonFile(path: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIActionMetaSourceError.metaSourcePathNotFound(path)
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw CLIActionMetaSourceError.metaSourceFileReadFailed(path)
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) else {
            throw CLIActionMetaSourceError.metaSourceJsonInvalid(path)
        }

        guard let json = jsonObject as? [String: Any] else {
            throw CLIActionMetaSourceError.metaSourceJsonNotDictionary(path)
        }

        guard isValidRecordingMetaJson(json) else {
            throw CLIActionMetaSourceError.metaSourceJsonInvalidContent(path)
        }

        return json
    }

    private func resolveCLIActionMetaSource(metaValue: String?, configManager: ConfigurationManager) throws -> CLIActionMetaSource {
        guard let metaValue, !metaValue.isEmpty else {
            guard let latestRecording = findLastValidRecording(configManager: configManager) else {
                throw CLIActionMetaSourceError.latestValidNotFound
            }

            return CLIActionMetaSource(
                metaJson: latestRecording.metaJson,
                recordingPath: latestRecording.recordingPath,
                description: "latest valid recording '\(latestRecording.recordingPath)'",
                kind: .latestValid
            )
        }

        if shouldTreatMetaValueAsPath(metaValue) {
            let expandedPath = (metaValue as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
                throw CLIActionMetaSourceError.metaSourcePathNotFound(expandedPath)
            }

            if isDirectory.boolValue {
                let metaJsonPath = URL(fileURLWithPath: expandedPath).appendingPathComponent("meta.json").path
                guard FileManager.default.fileExists(atPath: metaJsonPath) else {
                    throw CLIActionMetaSourceError.metaSourceDirectoryMissingMetaJson(expandedPath)
                }

                let json = try loadMetaJsonFile(path: metaJsonPath)
                return CLIActionMetaSource(
                    metaJson: json,
                    recordingPath: expandedPath,
                    description: "folder path '\(expandedPath)'",
                    kind: .folderPath
                )
            }

            let json = try loadMetaJsonFile(path: expandedPath)
            return CLIActionMetaSource(
                metaJson: json,
                recordingPath: nil,
                description: "json file '\(expandedPath)'",
                kind: .jsonFilePath
            )
        }

        let expandedWatchPath = (configManager.config.defaults.watch as NSString).expandingTildeInPath
        let recordingsPath = URL(fileURLWithPath: expandedWatchPath).appendingPathComponent("recordings").path
        let recordingFolderPath = URL(fileURLWithPath: recordingsPath).appendingPathComponent(metaValue).path

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: recordingFolderPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIActionMetaSourceError.recordingFolderNotFound(metaValue)
        }

        let metaJsonPath = URL(fileURLWithPath: recordingFolderPath).appendingPathComponent("meta.json").path
        guard FileManager.default.fileExists(atPath: metaJsonPath) else {
            throw CLIActionMetaSourceError.metaSourceDirectoryMissingMetaJson(recordingFolderPath)
        }

        let json = try loadMetaJsonFile(path: metaJsonPath)
        return CLIActionMetaSource(
            metaJson: json,
            recordingPath: recordingFolderPath,
            description: "recordings folder '\(metaValue)' at '\(recordingFolderPath)'",
            kind: .recordingsFolderName
        )
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

    private func findUniqueActionByName(_ name: String, configManager: ConfigurationManager) throws -> (type: ActionType, action: Any)? {
        let config = configManager.config
        var matches: [(type: ActionType, action: Any)] = []
        if let insert = config.inserts[name] { matches.append((type: .insert, action: insert)) }
        if let url = config.urls[name] { matches.append((type: .url, action: url)) }
        if let shortcut = config.shortcuts[name] { matches.append((type: .shortcut, action: shortcut)) }
        if let shell = config.scriptsShell[name] { matches.append((type: .shell, action: shell)) }
        if let script = config.scriptsAS[name] { matches.append((type: .appleScript, action: script)) }
        if matches.count > 1 {
            throw CLIActionChainError.duplicateActionName(name)
        }
        return matches.first
    }

    private func getEffectiveNextActionNameForCLI(
        action: Any,
        actionName: String,
        type: ActionType,
        isFirstStep: Bool,
        configManager: ConfigurationManager
    ) -> String? {
        let actionLevel: String?
        switch type {
        case .insert:
            actionLevel = (action as? AppConfiguration.Insert)?.nextAction
        case .url:
            actionLevel = (action as? AppConfiguration.Url)?.nextAction
        case .shortcut:
            actionLevel = (action as? AppConfiguration.Shortcut)?.nextAction
        case .shell:
            actionLevel = (action as? AppConfiguration.ScriptShell)?.nextAction
        case .appleScript:
            actionLevel = (action as? AppConfiguration.ScriptAppleScript)?.nextAction
        }
        let normalizedActionLevel = actionLevel?.trimmingCharacters(in: .whitespacesAndNewlines)

        if isFirstStep {
            if let normalizedActionLevel {
                return normalizedActionLevel.isEmpty ? nil : normalizedActionLevel
            }
            let defaultsNext = configManager.config.defaults.nextAction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return defaultsNext.isEmpty ? nil : defaultsNext
        }

        // Never re-apply defaults.nextAction after first action.
        return (normalizedActionLevel ?? "").isEmpty ? nil : normalizedActionLevel
    }

    private func executeActionChainForCLI(
        initialAction: Any,
        initialActionName: String,
        initialActionType: ActionType,
        metaJson: [String: Any],
        configManager: ConfigurationManager
    ) throws -> CLIResolvedActionStep {
        var currentName = initialActionName
        var currentType = initialActionType
        var currentAction: Any = initialAction
        var isFirstStep = true
        var visited: Set<String> = []
        var firstInsertActionName: String?
        var finalStep: CLIResolvedActionStep?

        while true {
            if visited.contains(currentName) {
                throw CLIActionChainError.cycleDetected(currentName)
            }
            visited.insert(currentName)

            switch currentType {
            case .insert:
                if let first = firstInsertActionName, first != currentName {
                    throw CLIActionChainError.multipleInsertActions(first: first, second: currentName)
                }
                firstInsertActionName = currentName
            case .url, .shortcut, .shell, .appleScript:
                break
            }

            let resolvedStep: CLIResolvedActionStep
            switch currentType {
            case .insert:
                guard let insert = currentAction as? AppConfiguration.Insert else {
                    throw CLIActionChainError.missingAction(currentName)
                }
                let (resolvedInsert, isAutoPasteTemplate) = resolveInsertForCLIExecution(insert)
                let processedInsert = processInsertAction(
                    resolvedInsert.action,
                    metaJson: metaJson,
                    activeInsert: resolvedInsert
                )
                applyInsertForExec(
                    processedInsert.text,
                    activeInsert: resolvedInsert,
                    isAutoPaste: isAutoPasteTemplate || processedInsert.isAutoPaste,
                    hadSmartCasingBlockingTransform: processedInsert.hadSmartCasingBlockingTransform
                )
                resolvedStep = CLIResolvedActionStep(name: currentName, type: currentType, action: resolvedInsert)
            case .url:
                guard let url = currentAction as? AppConfiguration.Url else {
                    throw CLIActionChainError.missingAction(currentName)
                }
                let resolvedUrl = resolveUrlForCLIExecution(url)
                executeUrlForCLI(resolvedUrl, metaJson: metaJson)
                resolvedStep = CLIResolvedActionStep(name: currentName, type: currentType, action: resolvedUrl)
            case .shortcut:
                guard let shortcut = currentAction as? AppConfiguration.Shortcut else {
                    throw CLIActionChainError.missingAction(currentName)
                }
                let resolvedShortcut = resolveShortcutForCLIExecution(shortcut)
                executeShortcutForCLI(resolvedShortcut, shortcutName: currentName, metaJson: metaJson)
                resolvedStep = CLIResolvedActionStep(name: currentName, type: currentType, action: resolvedShortcut)
            case .shell:
                guard let shell = currentAction as? AppConfiguration.ScriptShell else {
                    throw CLIActionChainError.missingAction(currentName)
                }
                let resolvedShell = resolveShellForCLIExecution(shell)
                executeShellForCLI(resolvedShell, metaJson: metaJson)
                resolvedStep = CLIResolvedActionStep(name: currentName, type: currentType, action: resolvedShell)
            case .appleScript:
                guard let ascript = currentAction as? AppConfiguration.ScriptAppleScript else {
                    throw CLIActionChainError.missingAction(currentName)
                }
                let resolvedAppleScript = resolveAppleScriptForCLIExecution(ascript)
                executeAppleScriptForCLI(resolvedAppleScript, metaJson: metaJson)
                resolvedStep = CLIResolvedActionStep(name: currentName, type: currentType, action: resolvedAppleScript)
            }

            finalStep = resolvedStep
            let nextActionName = getEffectiveNextActionNameForCLI(
                action: resolvedStep.action,
                actionName: resolvedStep.name,
                type: resolvedStep.type,
                isFirstStep: isFirstStep,
                configManager: configManager
            )

            guard let nextActionName, !nextActionName.isEmpty else {
                break
            }

            guard let next = try findUniqueActionByName(nextActionName, configManager: configManager) else {
                throw CLIActionChainError.missingAction(nextActionName)
            }

            currentName = nextActionName
            currentType = next.type
            currentAction = next.action
            isFirstStep = false
        }

        guard let finalStep else {
            throw CLIActionChainError.missingAction(initialActionName)
        }
        return finalStep
    }

    private func applyMoveToForCLI(
        recordingPath: String,
        finalActionType: ActionType,
        finalAction: Any,
        configManager: ConfigurationManager
    ) {
        var actionMoveTo: String?
        switch finalActionType {
        case .insert:
            actionMoveTo = (finalAction as? AppConfiguration.Insert)?.moveTo
        case .url:
            actionMoveTo = (finalAction as? AppConfiguration.Url)?.moveTo
        case .shortcut:
            actionMoveTo = (finalAction as? AppConfiguration.Shortcut)?.moveTo
        case .shell:
            actionMoveTo = (finalAction as? AppConfiguration.ScriptShell)?.moveTo
        case .appleScript:
            actionMoveTo = (finalAction as? AppConfiguration.ScriptAppleScript)?.moveTo
        }

        var moveTo: String?
        if let actionMoveTo = actionMoveTo, !actionMoveTo.isEmpty {
            moveTo = actionMoveTo
        } else {
            moveTo = configManager.config.defaults.moveTo
        }

        guard let path = moveTo, !path.isEmpty else {
            return
        }

        if path == ".delete" {
            logInfo("Deleting processed recording folder after CLI exec-action: \(recordingPath)")
            try? FileManager.default.removeItem(atPath: recordingPath)
        } else if path == ".none" {
            logInfo("Keeping recording folder in place after CLI exec-action as requested by .none setting")
        } else {
            let expandedPath = (path as NSString).expandingTildeInPath
            let destinationUrl = URL(fileURLWithPath: expandedPath).appendingPathComponent((recordingPath as NSString).lastPathComponent)
            logInfo("Moving processed recording folder after CLI exec-action to: \(destinationUrl.path)")
            try? FileManager.default.moveItem(atPath: recordingPath, toPath: destinationUrl.path)
        }
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

    func processInsertAction(
        _ action: String,
        metaJson: [String: Any],
        activeInsert: AppConfiguration.Insert? = nil
    ) -> ProcessedInsertAction {
        _ = activeInsert
        if action == ".none" {
            return ProcessedInsertAction(text: "", isAutoPaste: false, hadSmartCasingBlockingTransform: false)
        }
        if action == ".autoPaste" {
            let swResult = (metaJson["llmResult"] as? String) ?? (metaJson["result"] as? String) ?? ""
            return ProcessedInsertAction(text: swResult, isAutoPaste: true, hadSmartCasingBlockingTransform: false)
        }
        let result = processAllPlaceholders(action: action, metaJson: metaJson, actionType: .insert)
        return ProcessedInsertAction(
            text: result.text,
            isAutoPaste: false,
            hadSmartCasingBlockingTransform: result.hadSmartCasingBlockingTransform
        )
    }

    /// Returns processed action content for a concrete action/type pair.
    private func processedActionContent(actionType: ActionType, action: Any, actionName: String, metaJson: [String: Any]) -> String? {
        switch actionType {
        case .insert:
            if let insert = action as? AppConfiguration.Insert {
                return processInsertAction(insert.action, metaJson: metaJson, activeInsert: insert).text
            }
        case .url:
            if let url = action as? AppConfiguration.Url {
                return processAllPlaceholders(action: url.action, metaJson: metaJson, actionType: .url).text
            }
        case .shortcut:
            if let shortcut = action as? AppConfiguration.Shortcut {
                return processAllPlaceholders(action: shortcut.action, metaJson: metaJson, actionType: .shortcut).text
            }
        case .shell:
            if let shell = action as? AppConfiguration.ScriptShell {
                return processAllPlaceholders(action: shell.action, metaJson: metaJson, actionType: .shell).text
            }
        case .appleScript:
            if let script = action as? AppConfiguration.ScriptAppleScript {
                return processAllPlaceholders(action: script.action, metaJson: metaJson, actionType: .appleScript).text
            }
        }

        logError("Failed to process action content for '\(actionName)' due to type cast mismatch.")
        return nil
    }

    /// Writes plain clipboard text for user-visible copy operations.
    private func writeClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Prevents Macrowhisper clipboard writes from polluting clipboardContext capture.
    private func suppressSelfClipboardCapture(_ text: String) {
        clipboardMonitorRef?.suppressNextClipboardCapture(for: text)
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
        if !shouldApplyToken("restoreClipboardDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboardDelay = nil
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
        if !shouldApplyToken("restoreClipboardDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboardDelay = nil
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
        if !shouldApplyToken("restoreClipboardDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboardDelay = nil
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
        if !shouldApplyToken("scriptAsync", tokens: tokens, isInInputField: isInInputField) {
            resolved.scriptAsync = nil
        }
        if !shouldApplyToken("scriptWaitTimeout", tokens: tokens, isInInputField: isInInputField) {
            resolved.scriptWaitTimeout = nil
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
        if !shouldApplyToken("restoreClipboardDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboardDelay = nil
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
        if !shouldApplyToken("scriptAsync", tokens: tokens, isInInputField: isInInputField) {
            resolved.scriptAsync = nil
        }
        if !shouldApplyToken("scriptWaitTimeout", tokens: tokens, isInInputField: isInInputField) {
            resolved.scriptWaitTimeout = nil
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
        if !shouldApplyToken("restoreClipboardDelay", tokens: tokens, isInInputField: isInInputField) {
            resolved.restoreClipboardDelay = nil
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
        if !shouldApplyToken("scriptAsync", tokens: tokens, isInInputField: isInInputField) {
            resolved.scriptAsync = nil
        }
        if !shouldApplyToken("scriptWaitTimeout", tokens: tokens, isInInputField: isInInputField) {
            resolved.scriptWaitTimeout = nil
        }

        return resolved
    }

    private func resolveSmartInsertTextIfNeeded(
        _ text: String,
        activeInsert: AppConfiguration.Insert?,
        hadSmartCasingBlockingTransform: Bool = false
    ) -> String {
        let smartInsertEnabled = activeInsert?.smartInsert ?? globalConfigManager?.config.defaults.smartInsert ?? false
        if !smartInsertEnabled {
            return text
        }

        let shouldApplySmartCasing = !hadSmartCasingBlockingTransform
        var resolved = text

        resolved = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolved.isEmpty || resolved == ".none" {
            return resolved
        }

        guard requestAccessibilityPermission() else {
            logDebug("[SmartInsert] Accessibility permission unavailable, skipping smart insertion")
            return resolved
        }

        guard let initialContext = getInputInsertionContext() else {
            logDebug("[SmartInsert] Input insertion context unavailable, skipping smart insertion")
            return resolved
        }

        let original = resolved
        var context = initialContext
        var lowConfidenceContext = false

        if shouldRetryInsertionContextRead(initialContext, insertionText: resolved) {
            if let retryContext = getInputInsertionContext() {
                if contextsDifferForSmartInsert(initialContext, retryContext) {
                    lowConfidenceContext = true
                    context = retryContext
                    logDebug("[SmartInsert] Context changed between consecutive AX reads; entering low-confidence mode")
                }
            } else {
                lowConfidenceContext = true
                logDebug("[SmartInsert] AX context retry failed after suspicious boundary; entering low-confidence mode")
            }
        }

        let isIntraWordInsertion = (context.leftCharacter.map { isWordCharacter($0) } ?? false) &&
            (context.rightCharacter.map { isWordCharacter($0) } ?? false)

        if isIntraWordInsertion {
            logDebug("[SmartInsert] Intra-word insertion boundary detected, applying mid-sentence casing and punctuation/spacing rules")
        }
        if lowConfidenceContext {
            logDebug("[SmartInsert] Low-confidence context: skipping risky smart transforms (casing and punctuation stripping)")
        }

        if shouldApplySmartCasing && !lowConfidenceContext {
            resolved = applySmartCasing(
                to: resolved,
                leftCharacter: context.leftCharacter,
                leftNonWhitespaceCharacter: context.leftNonWhitespaceCharacter,
                leftLinePrefix: context.leftLinePrefix
            )
        }
        if !lowConfidenceContext {
            resolved = applySmartTrailingPunctuation(
                to: resolved,
                leftCharacter: context.leftCharacter,
                leftNonWhitespaceCharacter: context.leftNonWhitespaceCharacter,
                leftLinePrefix: context.leftLinePrefix,
                rightCharacter: context.rightCharacter,
                rightNonWhitespaceCharacter: context.rightNonWhitespaceCharacter,
                rightHasLineBreakBeforeNextNonWhitespace: context.rightHasLineBreakBeforeNextNonWhitespace
            )
        }
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
            "[SmartInsert] Context left=\(summarizeForLogs(leftChar, maxPreview: 40)) leftNonWs=\(summarizeForLogs(leftNonWs, maxPreview: 40)) " +
            "right=\(summarizeForLogs(rightChar, maxPreview: 40)) rightNonWs=\(summarizeForLogs(rightNonWs, maxPreview: 40)) " +
            "rightHasLineBreak=\(context.rightHasLineBreakBeforeNextNonWhitespace) " +
            "linePrefix=\(summarizeForLogs(context.leftLinePrefix, maxPreview: 80))"
        )
        logDebug("[SmartInsert] Text before: \(summarizeForLogs(original, maxPreview: 120)) | after: \(summarizeForLogs(resolved, maxPreview: 120))")
        logDebug(
            "[SmartInsert] After stats: len=\(resolved.count) leadingSpaces=\(countLeadingSpaces(resolved)) " +
            "visible=\(summarizeForLogs(visibleWhitespace(resolved), maxPreview: 120))"
        )
        if hadSmartCasingBlockingTransform {
            logDebug("[SmartInsert] Smart casing disabled because a smart-casing-blocking placeholder transform was detected")
        }

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

    private func shouldRetryInsertionContextRead(_ context: InputInsertionContext, insertionText: String) -> Bool {
        guard isSentenceLikeInsertionText(insertionText) else {
            return false
        }

        let leftIsWord = context.leftCharacter.map { isWordCharacter($0) } ?? false
        let rightIsWord = context.rightCharacter.map { isWordCharacter($0) } ?? false
        let rightIsPunctuation = context.rightCharacter.map { ".,;:!?".contains($0) } ?? false
        return (leftIsWord && rightIsWord) || (leftIsWord && rightIsPunctuation)
    }

    private func contextsDifferForSmartInsert(_ lhs: InputInsertionContext, _ rhs: InputInsertionContext) -> Bool {
        if lhs.leftCharacter != rhs.leftCharacter { return true }
        if lhs.leftNonWhitespaceCharacter != rhs.leftNonWhitespaceCharacter { return true }
        if lhs.rightCharacter != rhs.rightCharacter { return true }
        if lhs.rightNonWhitespaceCharacter != rhs.rightNonWhitespaceCharacter { return true }
        if lhs.rightHasLineBreakBeforeNextNonWhitespace != rhs.rightHasLineBreakBeforeNextNonWhitespace { return true }
        return lhs.leftLinePrefix != rhs.leftLinePrefix
    }

    private func isSentenceLikeInsertionText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.contains(where: { $0.isWhitespace }) else { return false }
        guard let firstLetter = trimmed.first(where: { String($0).rangeOfCharacter(from: .letters) != nil }) else {
            return false
        }
        return String(firstLetter).rangeOfCharacter(from: .uppercaseLetters) != nil
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
        leftLinePrefix: String,
        rightCharacter: Character?,
        rightNonWhitespaceCharacter: Character?,
        rightHasLineBreakBeforeNextNonWhitespace: Bool
    ) -> String {
        // At line starts, preserve terminal punctuation when right-side text
        // looks like a new sentence (uppercase). If right-side starts lowercase,
        // treat as continuation and allow stripping.
        if isLineStartBoundary(leftCharacter) && !isLowercaseLetter(rightNonWhitespaceCharacter) {
            return text
        }

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
            leftLinePrefix: leftLinePrefix,
            rightCharacter: rightCharacter,
            rightNonWhitespaceCharacter: rightNonWhitespaceCharacter
        ) {
            return text
        }

        if isLikelySentenceBoundaryBeforeUppercaseRight(
            leftCharacter: leftCharacter,
            leftNonWhitespaceCharacter: leftNonWhitespaceCharacter,
            leftLinePrefix: leftLinePrefix,
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
        leftLinePrefix: String,
        rightCharacter: Character?,
        rightNonWhitespaceCharacter: Character?
    ) -> Bool {
        let boundaryBaseLeft: Character?
        if let leftCharacter = leftCharacter, !leftCharacter.isWhitespace {
            boundaryBaseLeft = leftCharacter
        } else {
            boundaryBaseLeft = leftNonWhitespaceCharacter
        }
        let effectiveLeft = effectiveLeftContextCharacter(
            leftCharacter: boundaryBaseLeft,
            leftLinePrefix: leftLinePrefix
        )

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

        let effectiveLeft = effectiveLeftContextCharacter(
            leftCharacter: leftCharacter,
            leftLinePrefix: leftLinePrefix
        )

        if let first = updated.first {
            let shouldInsertLeadingSpaceForMarkdownList =
                shouldInsertLeadingSpaceForMarkdownListPrefix(leftLinePrefix) &&
                !(leftCharacter?.isWhitespace ?? false)
            let shouldInsertLeadingSpaceAfterWord = effectiveLeft.map { isWordCharacter($0) } ?? false
            let punctuationNeedingTrailingSpace = ".,;:!?)]}\""
            let shouldInsertLeadingSpaceAfterPunctuation = effectiveLeft.map { punctuationNeedingTrailingSpace.contains($0) } ?? false
            let startsWithBoundaryNeedingLeadingSpace = isWordCharacter(first) || isOpeningWrapperCharacter(first)
            let shouldInsertLeadingSpaceBeforeOpeningWrapper = (effectiveLeft.map { isWordCharacter($0) } ?? false) && isOpeningWrapperCharacter(first)

            if startsWithBoundaryNeedingLeadingSpace &&
                (shouldInsertLeadingSpaceForMarkdownList ||
                 shouldInsertLeadingSpaceAfterWord ||
                 shouldInsertLeadingSpaceAfterPunctuation ||
                 shouldInsertLeadingSpaceBeforeOpeningWrapper) {
                updated = " " + updated
            }
        }

        if let right = rightCharacter, isWordCharacter(right), let last = updated.last {
            if isWordCharacter(last) || ".,;:!?".contains(last) || isClosingWrapperCharacter(last) {
                updated += " "
            }
        }

        return updated
    }

    private func shouldLowercaseForMidSentence(
        leftCharacter: Character?,
        leftNonWhitespaceCharacter: Character?,
        leftLinePrefix: String
    ) -> Bool {
        if isMarkdownHeadingLineStart(leftLinePrefix) {
            return false
        }

        if isMarkdownListLineStart(leftLinePrefix) {
            return false
        }

        guard let leftCharacter = leftCharacter else {
            return false
        }
        if isIgnorableBoundaryCharacter(leftCharacter) {
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
            let effectivePrevious = effectiveLeftContextCharacter(
                leftCharacter: previous,
                leftLinePrefix: leftLinePrefix
            )
            guard let effectivePrevious else {
                return false
            }
            if isIgnorableBoundaryCharacter(effectivePrevious) {
                return false
            }
            return !".!?".contains(effectivePrevious)
        }

        let effectiveLeft = effectiveLeftContextCharacter(
            leftCharacter: leftCharacter,
            leftLinePrefix: leftLinePrefix
        ) ?? leftCharacter
        return !".!?".contains(effectiveLeft)
    }

    private func isLikelySentenceBoundaryBeforeUppercaseRight(
        leftCharacter: Character?,
        leftNonWhitespaceCharacter: Character?,
        leftLinePrefix: String,
        rightCharacter: Character?,
        rightNonWhitespaceCharacter: Character?
    ) -> Bool {
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
        guard rightString.rangeOfCharacter(from: .uppercaseLetters) != nil else {
            return false
        }

        if let leftCharacter, let rightCharacter, isWordCharacter(leftCharacter), isWordCharacter(rightCharacter) {
            return false
        }

        if isLineStartBoundary(leftCharacter) {
            return true
        }

        if leftCharacter?.isWhitespace == true {
            let effectiveLeft = effectiveLeftContextCharacter(
                leftCharacter: leftNonWhitespaceCharacter,
                leftLinePrefix: leftLinePrefix
            )
            guard let effectiveLeft else {
                return false
            }
            return isWordCharacter(effectiveLeft) || isClosingWrapperCharacter(effectiveLeft) || ".,;:!?".contains(effectiveLeft)
        }

        let effectiveLeft = effectiveLeftContextCharacter(
            leftCharacter: leftCharacter,
            leftLinePrefix: leftLinePrefix
        )
        guard let effectiveLeft else {
            return false
        }

        return ".,;:!?".contains(effectiveLeft) || isClosingWrapperCharacter(effectiveLeft)
    }

    private func effectiveLeftContextCharacter(
        leftCharacter: Character?,
        leftLinePrefix: String
    ) -> Character? {
        guard let leftCharacter else {
            return nil
        }
        if !isSkippableTrailingDelimiterForBoundary(leftCharacter) {
            return leftCharacter
        }

        for character in leftLinePrefix.reversed() {
            if character.isWhitespace || isIgnorableBoundaryCharacter(character) {
                continue
            }
            if isSkippableTrailingDelimiterForBoundary(character) {
                continue
            }
            return character
        }

        return leftCharacter
    }

    private func isSkippableTrailingDelimiterForBoundary(_ character: Character) -> Bool {
        "*_~`)]}\"'".contains(character)
    }

    private func isMarkdownHeadingLineStart(_ leftLinePrefix: String) -> Bool {
        if let regex = try? NSRegularExpression(pattern: #"^\s{0,3}#{1,6}\s+$"#),
           regex.firstMatch(in: leftLinePrefix, options: [], range: NSRange(location: 0, length: (leftLinePrefix as NSString).length)) != nil {
            return true
        }
        return false
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

    private func applyEnglishTitleCase(in text: String, locale: Locale) -> String {
        applyTitleCaseWithRules(
            in: text,
            locale: locale,
            minorWords: englishMinorTitleCaseWords(),
            forceUppercasePredicate: shouldForceUppercaseInEnglishTitleCase
        )
    }

    private func applySpanishTitleCase(in text: String, locale: Locale) -> String {
        applyTitleCaseWithRules(
            in: text,
            locale: locale,
            minorWords: spanishMinorTitleCaseWords()
        )
    }

    private func applyAutoDetectedTitleCase(in text: String, locale: Locale) -> String {
        switch detectTitleCaseLanguage(in: text, locale: locale) {
        case .english:
            return applyEnglishTitleCase(in: text, locale: locale)
        case .spanish:
            return applySpanishTitleCase(in: text, locale: locale)
        }
    }

    private enum TitleCaseLanguage {
        case english
        case spanish
    }

    private func detectTitleCaseLanguage(in text: String, locale: Locale) -> TitleCaseLanguage {
        guard let regex = titleCaseWordRegex else {
            return .english
        }

        let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        if matches.isEmpty {
            return .english
        }

        let englishWords = englishMinorTitleCaseWords()
        let spanishWords = spanishMinorTitleCaseWords()
        var englishScore: Double = 0
        var spanishScore: Double = 0

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let token = String(text[range])
            let normalized = token.lowercased(with: locale)

            if englishWords.contains(normalized) {
                englishScore += 2.0
            }
            if spanishWords.contains(normalized) {
                spanishScore += 2.0
            }
            if hasSpanishCharacterCue(normalized) {
                spanishScore += 1.5
            }
            if hasEnglishContractionCue(normalized) {
                englishScore += 1.5
            }
        }

        if englishScore == 0 && spanishScore == 0 {
            return .english
        }

        // Ambiguous/mixed content defaults to English.
        if spanishScore > englishScore && (spanishScore - englishScore) >= 1.0 {
            return .spanish
        }
        return .english
    }

    private func applyTitleCaseWithRules(
        in text: String,
        locale: Locale,
        minorWords: Set<String>,
        forceUppercasePredicate: (String) -> Bool = { _ in false }
    ) -> String {
        guard let regex = titleCaseWordRegex else {
            return text
        }

        let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        if matches.isEmpty {
            return text
        }

        var output = text
        for (index, match) in matches.enumerated().reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let token = String(text[range])
            let normalized = token.lowercased(with: locale)
            let isFirst = index == 0
            let isLast = index == matches.count - 1
            let followsTitleBoundary = isWordAfterTitleBoundary(text: text, wordRange: range)

            let replacement: String
            if shouldPreserveOriginalWordCase(token) {
                replacement = token
            } else if isFirst || isLast || followsTitleBoundary || forceUppercasePredicate(normalized) {
                replacement = uppercasingFirstLetter(in: token)
            } else if minorWords.contains(normalized) {
                replacement = lowercasingFirstLetter(in: token)
            } else {
                replacement = uppercasingFirstLetter(in: token)
            }

            output.replaceSubrange(range, with: replacement)
        }

        return output
    }

    private func englishMinorTitleCaseWords() -> Set<String> {
        [
            "a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet",
            "as", "at", "by", "in", "of", "on", "per", "to", "via",
            "from", "into", "onto", "over", "with", "than", "upon"
        ]
    }

    private func spanishMinorTitleCaseWords() -> Set<String> {
        [
            "a", "al", "de", "del", "el", "la", "los", "las", "un", "una", "unos", "unas",
            "y", "e", "o", "u", "en", "con", "por", "para", "sin", "sobre", "tras",
            "entre", "hacia", "hasta", "desde", "contra", "segun", "según", "que"
        ]
    }

    private func hasSpanishCharacterCue(_ normalizedToken: String) -> Bool {
        normalizedToken.unicodeScalars.contains { scalar in
            CharacterSet(charactersIn: "ñÑáéíóúüÁÉÍÓÚÜ").contains(scalar)
        }
    }

    private func hasEnglishContractionCue(_ normalizedToken: String) -> Bool {
        let normalizedApostrophes = normalizedToken.replacingOccurrences(of: "’", with: "'")
        let cues = ["'m", "'re", "'ve", "'ll", "'d", "n't", "'s"]
        return cues.contains { normalizedApostrophes.contains($0) }
    }

    private func shouldForceUppercaseInEnglishTitleCase(_ normalizedToken: String) -> Bool {
        if normalizedToken == "i" {
            return true
        }
        if normalizedToken.hasPrefix("i'") || normalizedToken.hasPrefix("i’") {
            return true
        }
        return false
    }

    private func isWordAfterTitleBoundary(text: String, wordRange: Range<String.Index>) -> Bool {
        guard wordRange.lowerBound > text.startIndex else {
            return false
        }

        let ignoredPrefixCharacters = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'’`([{"))
        let boundaryCharacters = CharacterSet(charactersIn: ":;!?")

        var index = text.index(before: wordRange.lowerBound)
        while true {
            let scalarView = String(text[index]).unicodeScalars
            if scalarView.allSatisfy({ ignoredPrefixCharacters.contains($0) }) {
                if index == text.startIndex {
                    return false
                }
                index = text.index(before: index)
                continue
            }
            return scalarView.allSatisfy { boundaryCharacters.contains($0) }
        }
    }

    private func applyTitleCaseAll(in text: String) -> String {
        guard let regex = titleCaseWordRegex else {
            return text
        }

        let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        if matches.isEmpty {
            return text
        }

        var output = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let token = String(text[range])
            let replacement = shouldPreserveOriginalWordCase(token) ? token : uppercasingFirstLetter(in: token)
            output.replaceSubrange(range, with: replacement)
        }

        return output
    }

    private var titleCaseWordRegex: NSRegularExpression? {
        try? NSRegularExpression(pattern: #"(?=[[:alnum:]]*[[:alpha:]])[[:alnum:]]+(?:['’][[:alnum:]]+)*"#)
    }

    private func shouldPreserveOriginalWordCase(_ token: String) -> Bool {
        let letters = token.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if letters.count > 1 && letters.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }) {
            return true
        }

        var seenFirstLetter = false
        for scalar in token.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                if !seenFirstLetter {
                    seenFirstLetter = true
                    continue
                }
                if CharacterSet.uppercaseLetters.contains(scalar) {
                    return true
                }
            }
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

    private func uppercasingFirstLetter(in text: String) -> String {
        var result = text
        for index in result.indices {
            let character = result[index]
            let charString = String(character)
            if charString.rangeOfCharacter(from: .letters) != nil {
                result.replaceSubrange(index...index, with: charString.uppercased())
                break
            }
        }

        return result
    }

    private func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    private func isLineStartBoundary(_ leftCharacter: Character?) -> Bool {
        if leftCharacter == nil {
            return true
        }
        if let leftCharacter, isIgnorableBoundaryCharacter(leftCharacter) {
            return true
        }
        return leftCharacter?.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) == true
    }

    private func isLowercaseLetter(_ character: Character?) -> Bool {
        guard let character = character else { return false }
        return String(character).rangeOfCharacter(from: .lowercaseLetters) != nil
    }

    private func isIgnorableBoundaryCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            scalar == "\u{FEFF}" ||
            scalar == "\u{200B}" ||
            scalar == "\u{200C}" ||
            scalar == "\u{200D}" ||
            scalar == "\u{2060}" ||
            scalar == "\u{FFFC}" ||
            scalar.properties.isJoinControl
        }
    }

    private func isOpeningWrapperCharacter(_ character: Character) -> Bool {
        "([{\"".contains(character)
    }

    private func isClosingWrapperCharacter(_ character: Character) -> Bool {
        ")]}\"".contains(character)
    }

    // This version is for the main watcher flow and respects the 'noEsc' setting
    func applyInsert(
        _ text: String,
        activeInsert: AppConfiguration.Insert?,
        isAutoPaste: Bool = false,
        hadSmartCasingBlockingTransform: Bool = false
    ) {
        let resolvedText = resolveSmartInsertTextIfNeeded(
            text,
            activeInsert: activeInsert,
            hadSmartCasingBlockingTransform: hadSmartCasingBlockingTransform
        )

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
                suppressSelfClipboardCapture(resolvedText)
                let pasteboard = NSPasteboard.general; pasteboard.clearContents(); pasteboard.setString(resolvedText, forType: .string)
                simulateKeyDown(key: 9, flags: .maskCommand) // Cmd+V
                checkAndSimulatePressReturn(activeInsert: activeInsert); return
            }
        }
        simulateEscKeyPress(activeInsert: activeInsert)
        pasteText(resolvedText, activeInsert: activeInsert)
        checkAndSimulatePressReturn(activeInsert: activeInsert)
    }
    
    // This version is for CLI action execution and does NOT press ESC.
    func applyInsertForExec(
        _ text: String,
        activeInsert: AppConfiguration.Insert?,
        isAutoPaste: Bool = false,
        hadSmartCasingBlockingTransform: Bool = false
    ) {
        let resolvedText = resolveSmartInsertTextIfNeeded(
            text,
            activeInsert: activeInsert,
            hadSmartCasingBlockingTransform: hadSmartCasingBlockingTransform
        )

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
                logInfo("CLI exec auto paste - not in input field, direct paste only")
                suppressSelfClipboardCapture(resolvedText)
                let pasteboard = NSPasteboard.general; pasteboard.clearContents(); pasteboard.setString(resolvedText, forType: .string)
                simulateKeyDown(key: 9, flags: .maskCommand) // Cmd+V
                checkAndSimulatePressReturn(activeInsert: activeInsert); return
            }
        }
        // No ESC key press for CLI execution
        if restoreClipboard {
            pasteText(resolvedText, activeInsert: activeInsert)
        } else {
            pasteTextNoRestore(resolvedText, activeInsert: activeInsert)
        }
        checkAndSimulatePressReturn(activeInsert: activeInsert)
    }
    
    // This version is for clipboard-monitored insert actions and does NOT press ESC or apply actionDelay
    // (ESC and delay are handled by ClipboardMonitor)
    func applyInsertWithoutEsc(
        _ text: String,
        activeInsert: AppConfiguration.Insert?,
        isAutoPaste: Bool = false,
        hadSmartCasingBlockingTransform: Bool = false
    ) -> Bool {
        let resolvedText = resolveSmartInsertTextIfNeeded(
            text,
            activeInsert: activeInsert,
            hadSmartCasingBlockingTransform: hadSmartCasingBlockingTransform
        )

        if resolvedText.isEmpty || resolvedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resolvedText == ".none" {
            // For empty or .none actions, do nothing since delay is handled by ClipboardMonitor
            return true
        }
        
        if isAutoPaste {
            if !requestAccessibilityPermission() { logWarning("Accessibility permission denied"); return false }
            if !isInInputField() {
                logDebug("Clipboard-monitored auto paste - not in input field, direct paste only")
                suppressSelfClipboardCapture(resolvedText)
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
        
        let processedAction = processAllPlaceholders(action: urlAction.action, metaJson: metaJson, actionType: .url).text
        logDebug("[URL-CLI] Processed action: \(summarizeForLogs(processedAction, maxPreview: 120))")
        let normalized = processedAction.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == ".none" {
            logDebug("[URL-CLI] Action is empty or '.none' - skipping URL execution")
            return
        }
        
        // Try to create URL directly from processed action
        // Placeholders are now URL-encoded individually during processing
        guard let url = URL(string: processedAction) else {
            logError("Invalid URL after processing: \(summarizeForLogs(processedAction, maxPreview: 120))")
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
            logDebug("URL opened \(inBackground ? "in background" : "normally") via CLI: \(summarizeForLogs(url.absoluteString, maxPreview: 120))")
        } catch {
            logError("Failed to open URL \(inBackground ? "in background" : "normally") via CLI: \(error)")
            // Ultimate fallback to standard opening
            NSWorkspace.shared.open(url)
        }
    }
    
    func executeShortcutForCLI(_ shortcut: AppConfiguration.Shortcut, shortcutName: String, metaJson: [String: Any]) {
        let actionDelay = shortcut.actionDelay ?? globalConfigManager?.config.defaults.actionDelay ?? 0.0
        if actionDelay > 0 { Thread.sleep(forTimeInterval: actionDelay) }
        
        let processedAction = processAllPlaceholders(action: shortcut.action, metaJson: metaJson, actionType: .shortcut).text
        logDebug("[Shortcut-CLI] Processed action: \(summarizeForLogs(processedAction, maxPreview: 120))")
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
        
        let processedAction = processAllPlaceholders(action: shell.action, metaJson: metaJson, actionType: .shell).text
        logDebug("[Shell-CLI] Processed action: \(summarizeForLogs(processedAction, maxPreview: 120))")
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
        
        let processedAction = processAllPlaceholders(action: ascript.action, metaJson: metaJson, actionType: .appleScript).text
        logDebug("[AppleScript-CLI] Processed action: \(summarizeForLogs(processedAction, maxPreview: 120))")
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
            pasteUsingClipboard(text, activeInsert: activeInsert)
        }
    }

    // Version of pasteText that doesn't save/restore clipboard (used with ClipboardMonitor)
    private func pasteTextNoRestore(_ text: String, activeInsert: AppConfiguration.Insert?) {
        let shouldSimulate = activeInsert?.simKeypress ?? globalConfigManager?.config.defaults.simKeypress ?? false
        if shouldSimulate {
            // Use the new comprehensive CGEvent-based typing
            typeText(text)
        } else {
            pasteUsingClipboardNoRestore(text, activeInsert: activeInsert)
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

    private func pasteUsingClipboard(_ text: String, activeInsert: AppConfiguration.Insert?) {
        let pasteboard = NSPasteboard.general
        let originalContent = pasteboard.string(forType: .string)
        let shouldLogSmartInsertClipboard = activeInsert?.smartInsert ?? globalConfigManager?.config.defaults.smartInsert ?? false
        if shouldLogSmartInsertClipboard {
            logDebug(
                "[SmartInsert] Clipboard insert payload (restore): len=\(text.count) " +
                "leadingSpaces=\(countLeadingSpaces(text)) visible=\(summarizeForLogs(visibleWhitespace(text), maxPreview: 120))"
            )
        }
        suppressSelfClipboardCapture(text)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if shouldLogSmartInsertClipboard {
            let confirm = pasteboard.string(forType: .string) ?? ""
            logDebug(
                "[SmartInsert] Pasteboard confirmed (restore): len=\(confirm.count) " +
                "leadingSpaces=\(countLeadingSpaces(confirm)) visible=\(summarizeForLogs(visibleWhitespace(confirm), maxPreview: 120))"
            )
        }
        simulateKeyDown(key: 9, flags: .maskCommand) // Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.clearContents()
            if let original = originalContent { pasteboard.setString(original, forType: .string) }
        }
    }
    
    // Version of pasteUsingClipboard that doesn't save/restore clipboard (used with ClipboardMonitor)
    private func pasteUsingClipboardNoRestore(_ text: String, activeInsert: AppConfiguration.Insert?) {
        let pasteboard = NSPasteboard.general
        let shouldLogSmartInsertClipboard = activeInsert?.smartInsert ?? globalConfigManager?.config.defaults.smartInsert ?? false
        if shouldLogSmartInsertClipboard {
            logDebug(
                "[SmartInsert] Clipboard insert payload (no-restore): len=\(text.count) " +
                "leadingSpaces=\(countLeadingSpaces(text)) visible=\(summarizeForLogs(visibleWhitespace(text), maxPreview: 120))"
            )
        }
        suppressSelfClipboardCapture(text)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if shouldLogSmartInsertClipboard {
            let confirm = pasteboard.string(forType: .string) ?? ""
            logDebug(
                "[SmartInsert] Pasteboard confirmed (no-restore): len=\(confirm.count) " +
                "leadingSpaces=\(countLeadingSpaces(confirm)) visible=\(summarizeForLogs(visibleWhitespace(confirm), maxPreview: 120))"
            )
        }
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

            case .switchConfigPath:
                guard let arguments = commandMessage.arguments,
                      let requestedPath = arguments["path"],
                      !requestedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    response = "Missing required argument: path"
                    _ = sendResponse(response, to: clientSocket)
                    break
                }

                if configMgr.switchConfigPath(to: requestedPath) {
                    let currentPath = configMgr.getCurrentConfigPath()
                    response = "Configuration path switched successfully to: \(currentPath)"
                    logInfo(response)
                } else {
                    response = "Failed to switch configuration path"
                    logError("\(response): \(requestedPath)")
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
                    
                    // Empty string is explicit no icon; only nil inherits defaults.
                    if icon == nil {
                        icon = configMgr.config.defaults.icon
                    }
                } else {
                    // No active action, use default
                    icon = configMgr.config.defaults.icon
                }
                
                if let iconValue = icon, !iconValue.isEmpty {
                    response = iconValue  // Use the icon
                } else {
                    response = " "  // No icon defined (nil or empty)
                }
                
                logInfo("Returning icon: '\(response)'")
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
                
            case .addUrl:
                if let name = commandMessage.arguments?["name"] {
                    if actionNameExists(name, configManager: configMgr) {
                        response = "Action name '\(name)' already exists"
                        notify(title: "Macrowhisper", message: "Action name '\(name)' already exists")
                    } else {
                        configMgr.config.urls[name] = AppConfiguration.Url(action: "")
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
                        configMgr.config.shortcuts[name] = AppConfiguration.Shortcut(action: "")
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
                        configMgr.config.scriptsShell[name] = AppConfiguration.ScriptShell(action: "")
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
                        configMgr.config.scriptsAS[name] = AppConfiguration.ScriptAppleScript(action: "")
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
                        let newInsert = AppConfiguration.Insert(action: "")
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
                    do {
                        guard let (actionType, action) = try findUniqueActionByName(actionName, configManager: configMgr) else {
                            response = "Action not found: \(actionName)"
                            logError(response)
                            notify(title: "Macrowhisper", message: "Action not found: \(actionName)")
                            _ = sendResponse(response, to: clientSocket)
                            break
                        }

                        let resolvedMetaSource = try resolveCLIActionMetaSource(
                            metaValue: commandMessage.arguments?["meta"],
                            configManager: configMgr
                        )
                        logInfo("Using meta source for exec-action '\(actionName)': \(resolvedMetaSource.description)")

                        let recordingSessionIsActive = recordingsWatcher?.hasActiveRecordingSessions() ?? false
                        if !recordingSessionIsActive {
                            globalState.autoReturnEnabled = false
                            globalState.scheduledActionName = nil
                            // Cancel timeouts only when no recording session is active.
                            cancelAutoReturnTimeout()
                            cancelScheduledActionTimeout()
                        }
                        
                        // Enhance metaJson with CLI-specific data
                        let enhancedMetaJson = enhanceMetaJsonForCLI(metaJson: resolvedMetaSource.metaJson, configManager: configMgr)

                        let finalStep = try executeActionChainForCLI(
                            initialAction: action,
                            initialActionName: actionName,
                            initialActionType: actionType,
                            metaJson: enhancedMetaJson,
                            configManager: configMgr
                        )
                        if let recordingPath = resolvedMetaSource.recordingPath {
                            applyMoveToForCLI(
                                recordingPath: recordingPath,
                                finalActionType: finalStep.type,
                                finalAction: finalStep.action,
                                configManager: configMgr
                            )
                        } else if resolvedMetaSource.kind == .jsonFilePath {
                            logInfo("Skipping moveTo for exec-action '\(actionName)' because --meta points to a direct JSON file")
                        }
                        
                        // Trigger clipboard cleanup for CLI actions to prevent contamination
                        clipboardMonitorRef?.triggerClipboardCleanupForCLI()
                        
                        response = "Executed \(actionType) action '\(actionName)'"
                        logInfo("Successfully executed \(actionType) action: \(actionName)")
                    } catch {
                        response = error.localizedDescription
                        logError(response)
                        if commandMessage.arguments?["meta"] == nil && response == "No valid JSON file found with results" {
                            notify(title: "Macrowhisper", message: "No valid result found for action: \(actionName). Please check Superwhisper recordings.")
                        }
                    }
                } else {
                    response = "Action name missing"
                    logError(response)
                }
                _ = sendResponse(response, to: clientSocket)
                
            case .getAction:
                if let actionName = commandMessage.arguments?["name"], !actionName.isEmpty {
                    do {
                        guard let (actionType, action) = try findUniqueActionByName(actionName, configManager: configMgr) else {
                            response = "Action not found: \(actionName)"
                            logError("Action not found for get-action: \(actionName)")
                            _ = sendResponse(response, to: clientSocket)
                            break
                        }

                        let resolvedMetaSource = try resolveCLIActionMetaSource(
                            metaValue: commandMessage.arguments?["meta"],
                            configManager: configMgr
                        )
                        logInfo("Using meta source for get-action '\(actionName)': \(resolvedMetaSource.description)")

                        // Enhance metaJson with CLI-specific data
                        let enhancedMetaJson = enhanceMetaJsonForCLI(metaJson: resolvedMetaSource.metaJson, configManager: configMgr)

                        if let processedAction = processedActionContent(
                            actionType: actionType,
                            action: action,
                            actionName: actionName,
                            metaJson: enhancedMetaJson
                        ) {
                            response = processedAction
                            logInfo("Returning processed action for \(actionType) '\(actionName)'.")
                        } else {
                            response = "Failed to process action: \(actionName)"
                            logError(response)
                        }
                    } catch {
                        response = error.localizedDescription
                        logError(response)
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
                
            case .copyAction:
                if let actionName = commandMessage.arguments?["name"], !actionName.isEmpty {
                    do {
                        guard let (actionType, action) = try findUniqueActionByName(actionName, configManager: configMgr) else {
                            response = "Action not found: \(actionName)"
                            logError("Action not found for copy-action: \(actionName)")
                            _ = sendResponse(response, to: clientSocket)
                            break
                        }

                        let resolvedMetaSource = try resolveCLIActionMetaSource(
                            metaValue: commandMessage.arguments?["meta"],
                            configManager: configMgr
                        )
                        logInfo("Using meta source for copy-action '\(actionName)': \(resolvedMetaSource.description)")

                        let enhancedMetaJson = enhanceMetaJsonForCLI(metaJson: resolvedMetaSource.metaJson, configManager: configMgr)
                        if let processedAction = processedActionContent(
                            actionType: actionType,
                            action: action,
                            actionName: actionName,
                            metaJson: enhancedMetaJson
                        ) {
                            // Suppress Macrowhisper's own capture for this specific clipboard write,
                            // while keeping the clipboard content plain/visible to other apps.
                            clipboardMonitorRef?.suppressNextClipboardCapture(for: processedAction)
                            writeClipboard(processedAction)
                            response = "Copied processed action '\(actionName)' to clipboard"
                            logInfo("Copied processed action for \(actionType) '\(actionName)' to clipboard")
                        } else {
                            response = "Failed to process action: \(actionName)"
                            logError(response)
                        }
                    } catch {
                        response = error.localizedDescription
                        logError(response)
                    }
                } else {
                    response = "Action name missing"
                    logError(response)
                }
                _ = sendResponse(response, to: clientSocket)

            case .folderName:
                let rawIndex = commandMessage.arguments?["index"] ?? "0"
                guard let index = Int(rawIndex), index >= 0 else {
                    response = "Invalid index '\(rawIndex)'. Index must be a non-negative integer."
                    _ = sendResponse(response, to: clientSocket)
                    break
                }

                let resolvedPath = resolveRecordingFolderPath(
                    configManager: configMgr,
                    recordingsWatcher: recordingsWatcher,
                    index: index
                ) ?? ""
                response = resolvedPath.isEmpty ? "" : (resolvedPath as NSString).lastPathComponent
                _ = sendResponse(response, to: clientSocket)

            case .folderPath:
                let rawIndex = commandMessage.arguments?["index"] ?? "0"
                guard let index = Int(rawIndex), index >= 0 else {
                    response = "Invalid index '\(rawIndex)'. Index must be a non-negative integer."
                    _ = sendResponse(response, to: clientSocket)
                    break
                }

                response = resolveRecordingFolderPath(
                    configManager: configMgr,
                    recordingsWatcher: recordingsWatcher,
                    index: index
                ) ?? ""
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
