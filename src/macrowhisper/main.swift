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
                
                if let name = commandMessage.arguments?["name"],
                   let action = commandMessage.arguments?["action"] {
                                        
                    // Check if insert with this name already exists
                    var inserts = configMgr.config.inserts
                    if let index = inserts.firstIndex(where: { $0.name == name }) {
                        // Update existing insert
                        inserts[index] = AppConfiguration.Insert(name: name, action: action)
                        configMgr.config.inserts = inserts
                        configMgr.saveConfig()
                        
                        let response = "Insert '\(name)' updated"
                        write(clientSocket, response, response.utf8.count)
                    } else {
                        // Add new insert
                        inserts.append(AppConfiguration.Insert(name: name, action: action))
                        configMgr.config.inserts = inserts
                        configMgr.saveConfig()
                        
                        let response = "Insert '\(name)' added"
                        write(clientSocket, response, response.utf8.count)
                    }
                    
                    // Trigger config changed callback
                    configMgr.onConfigChanged?()
                } else {
                    let response = "Missing name or action for insert"
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
                        configMgr.onConfigChanged?()
                        
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
                    configMgr.onConfigChanged?()
                    
                    // Send success response
                    let response = "Configuration reloaded successfully"
                    write(clientSocket, response, response.utf8.count)
                    logInfo("Configuration reload successful")
                    
                    // Notify the user
                    notify(title: "Macrowhisper", message: "Configuration reloaded successfully")
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
                
            case .updateConfig:
                logInfo("Received command to update configuration")
                
                // Extract arguments
                if let args = commandMessage.arguments {
                    logInfo("Updating config with arguments: \(args)")
                    
                    // Create local variables with proper null checking
                    let watchPath = args["watch"]
                    let activeInsert = args["activeInsert"]
                    let icon = args["icon"]
                    let moveTo = args["moveTo"]
                    
                    // Parse boolean values from strings
                    let serverStr = args["server"]
                    let watcherStr = args["watcher"]
                    let noUpdatesStr = args["noUpdates"]
                    let noNotiStr = args["noNoti"]
                    let noEscStr = args["noEsc"]
                    let simKeypressStr = args["simKeypress"]
                    
                    // Log the parameters before updating
                    logInfo("Parameters: watchPath=\(watchPath as Any), server=\(serverStr as Any), watcher=\(watcherStr as Any), noUpdates=\(noUpdatesStr as Any), noNoti=\(noNotiStr as Any), activeInsert=\(activeInsert as Any), noEsc=\(noEscStr as Any)")
                    
                    // Convert string values to boolean values
                    let server = serverStr == "true" ? true : (serverStr == "false" ? false : nil)
                    let watcher = watcherStr == "true" ? true : (watcherStr == "false" ? false : nil)
                    let noUpdates = noUpdatesStr == "true" ? true : (noUpdatesStr == "false" ? false : nil)
                    let noNoti = noNotiStr == "true" ? true : (noNotiStr == "false" ? false : nil)
                    let noEsc = noEscStr == "true" ? true : (noEscStr == "false" ? false : nil)
                    let simKeypress = simKeypressStr == "true" ? true : (simKeypressStr == "false" ? false : nil)
                    
                    // Update configuration with null-safe values using the safe reference
                    configMgr.updateFromCommandLine(
                        watchPath: watchPath,
                        server: server,
                        watcher: watcher,
                        noUpdates: noUpdates,
                        noNoti: noNoti,
                        activeInsert: activeInsert,
                        icon: icon,
                        moveTo: moveTo,
                        noEsc: noEsc,
                        simKeypress: simKeypress
                    )
                    
                    // IMPORTANT: After updating the config, explicitly call the onConfigChanged callback
                    configMgr.onConfigChanged?()
                    
                    logInfo("Configuration updated successfully")
                    
                    // Send success response
                    let response = "Configuration updated successfully"
                    write(clientSocket, response, response.utf8.count)
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
        
        static func defaultValues() -> Defaults {
            return Defaults(
                watch: ("~/Documents/superwhisper" as NSString).expandingTildeInPath,
                noUpdates: false,
                noNoti: false,
                activeInsert: "",
                icon: "",
                moveTo: "",
                noEsc: false,
                simKeypress: false
            )
        }
    }
    
    struct Insert: Codable {
        var name: String
        var action: String
        var icon: String?
        var moveTo: String?
        var noEsc: Bool?
        var simKeypress: Bool?
    }
    
    var defaults: Defaults
    var inserts: [Insert]
    
    static func defaultConfig() -> AppConfiguration {
        return AppConfiguration(
            defaults: Defaults.defaultValues(),
            inserts: []
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
    
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
    ) { _ in
        logInfo("System woke from sleep, checking socket health")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if !checkSocketHealth() {
                logWarning("Socket unhealthy after wake, recovering")
                recoverSocket()
            } else {
                logInfo("Socket is healthy after wake")
            }
        }
    }
}

func startSocketHealthMonitor() {
    logInfo("Starting periodic socket health monitor")
    
    let timer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { _ in
        logInfo("Performing periodic socket health check")
        if !checkSocketHealth() {
            logWarning("Socket appears to be unhealthy, attempting recovery")
            recoverSocket()
        }
    }
    timer.tolerance = 10.0 // Allow some flexibility in timing
    RunLoop.main.add(timer, forMode: .common)
}

func initializeWatcher(_ path: String) {
    let recordingsPath = "\(path)/recordings"
    
    if !FileManager.default.fileExists(atPath: recordingsPath) {
        logWarning("Recordings folder not found at \(recordingsPath)")
        notify(title: "Macrowhisper", message: "Recordings folder not found. Please check the location and reload configuration when fixed.")
        
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
        
        // For reload configuration or no arguments, use socket communication
        if args.count == 1 || args.contains("--watcher") ||
           args.contains("-w") || args.contains("--watch") ||
           args.contains("--no-updates") || args.contains("--no-noti") ||
           args.contains("--get-icon") || args.contains("--get-insert") ||
           args.contains("--insert") || args.contains("--auto-return") ||
           args.contains("--list-inserts") || args.contains("--icon") ||
           args.contains("--move-to") || args.contains("--no-esc") ||
           args.contains("--sim-keypress") {
            
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
            
            if args.contains("--icon") {
                let iconIndex = args.firstIndex(where: { $0 == "--icon" })
                if let index = iconIndex, index + 1 < args.count && !args[index + 1].starts(with: "--") {
                    arguments["icon"] = args[index + 1]
                } else {
                    arguments["icon"] = ""
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
            
            if args.contains("--get-icon") {
                // Send the command to the running instance
                if let response = socketCommunication.sendCommand(.getIcon) {
                    print(response)
                } else {
                    print("Failed to get icon.")
                }
                
                exit(0)
            }
            
            if args.contains("--get-insert") {
                // Send the command to the running instance
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
                
                // Create arguments for the autoReturn command
                var arguments: [String: String] = [:]
                
                // Check if there's a value after --auto-return
                if let index = autoReturnIndex, index + 1 < args.count && !args[index + 1].starts(with: "--") {
                    // User provided a value, use it
                    arguments["enable"] = args[index + 1]
                } else {
                    // No value provided or next arg is another flag, default to true
                    arguments["enable"] = "true"
                }
                
                // Send the autoReturn command
                if let response = socketCommunication.sendCommand(.autoReturn, arguments: arguments) {
                    print(response)
                } else {
                    print("Failed to set auto-return")
                }
                exit(0)
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
        
        // For any other command, just notify and exit
        print("Another instance is already running. Use --help for command options.")
        exit(0)
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
    
    func forceInitialMetadataCheck() {
        queue.async {
            // Make sure file exists
            guard FileManager.default.fileExists(atPath: self.filePath) else {
                return
            }
            
            // Create a snapshot of current content
            self.createTemporaryContentSnapshot()
            
            // Force update the file metadata to establish baseline
            self.updateFileMetadata()
            
            // Check for changes immediately
            self.checkFile()
            
            // Clean up temporary file
            try? FileManager.default.removeItem(atPath: self.filePath + ".temp")
            
            // Log this action
            logInfo("Established initial file metadata baseline for: \(self.filePath)")
        }
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
        // This is critical for the file creation case
        if lastModificationDate == nil {
            lastModificationDate = currentModDate
            lastFileSize = currentSize
            return true // Important: Return true for newly created files
        }
        
        // Check if either modification date or size has changed
        let dateChanged = lastModificationDate != currentModDate
        let sizeChanged = lastFileSize != currentSize
        
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

    // Add this helper method to FileChangeWatcher
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
        
        // First, process all standard placeholders - remove them if they don't exist or are empty
        let allPlaceholders = ["llmResult", "swResult", "modeName", "prompt", "result", "rawResult"]
        
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
            
            // Use the updated metaJson for placeholder replacements
            for placeholder in allPlaceholders {
                // Check if the placeholder exists in the action
                if result.contains("{{\(placeholder)}}") {
                    // Check if the value exists in updatedMetaJson and is not empty
                    let value: String
                    if placeholder == "swResult" {
                        // swResult is special - it's either llmResult or result
                        if let llm = updatedMetaJson["llmResult"] as? String, !llm.isEmpty {
                            value = llm
                        } else if let res = updatedMetaJson["result"] as? String, !res.isEmpty {
                            value = res
                        } else {
                            value = ""
                        }
                    } else if let val = updatedMetaJson[placeholder] as? String, !val.isEmpty {
                        value = val
                    } else {
                        value = ""
                    }
                    
                    // Replace the placeholder with the value or remove it if empty
                    result = result.replacingOccurrences(of: "{{\(placeholder)}}", with: value)
                }
            }
        } else {
            // No llmResult to process, just handle regular placeholders
            for placeholder in allPlaceholders {
                if result.contains("{{\(placeholder)}}") {
                    let value: String
                    if placeholder == "swResult" {
                        if let res = metaJson["result"] as? String, !res.isEmpty {
                            value = res
                        } else {
                            value = ""
                        }
                    } else if let val = metaJson[placeholder] as? String, !val.isEmpty {
                        value = val
                    } else {
                        value = ""
                    }
                    
                    result = result.replacingOccurrences(of: "{{\(placeholder)}}", with: value)
                }
            }
            
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


    private func applyInsert(_ text: String, activeInsert: AppConfiguration.Insert?, isAutoPaste: Bool = false) {
        // If text is empty or just whitespace, just simulate ESC key press and return
        if text.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == ".none" {
            simulateEscKeyPress(activeInsert: activeInsert)
            return
        }
        
        // For .autoPaste, check if we're in an input field
        if isAutoPaste {
            // First ensure we have accessibility permissions
            if !requestAccessibilityPermission() {
                logWarning("Accessibility permission denied - cannot check for input field")
                // Mark as processed but do nothing
                return
            }
            
            // Check if we're in an input field
            if !isInInputField() {
                logInfo("Auto paste skipped - not in an input field")
                // Mark as processed but do nothing
                return
            }
            
            // If we are in an input field, continue with normal paste operation
            logInfo("Auto paste - in input field, proceeding with paste")
        }
        
        // First, simulate ESC key press
        simulateEscKeyPress(activeInsert: activeInsert)
        
        // Check if we should simulate key presses
        let shouldSimulateKeypresses: Bool
        if let insert = activeInsert, let insertSimKeypress = insert.simKeypress {
            // Use insert-specific setting if available
            shouldSimulateKeypresses = insertSimKeypress
        } else {
            // Otherwise use the global default
            shouldSimulateKeypresses = configManager.config.defaults.simKeypress
        }
        
        if shouldSimulateKeypresses {
            // Split the text by newlines
            let lines = text.components(separatedBy: "\n")
            
            // Create an AppleScript that handles each line separately
            let scriptLines = lines.enumerated().map { index, line -> String in
                let escapedLine = line.replacingOccurrences(of: "\\", with: "\\\\")
                                     .replacingOccurrences(of: "\"", with: "\\\"")
                
                // For all lines except the first, add a return keystroke before the text
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
                // Fall back to clipboard paste as a backup
                pasteUsingClipboard(text)
            }
        } else {
            // Use the standard clipboard paste method
            pasteUsingClipboard(text)
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
        logWarning("Warning: recordings folder not found. Please check the location and reload configuration when fixed.")
        notify(title: "Macrowhisper", message: "Recordings folder not found. Please check the location and reload configuration when fixed.")
        
        // No timer or further checks - watcher remains disabled until user manually reloads config
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
                
                // Add a delay before checking for updates
                DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 25) {
                    // Check for updates after delay
                    versionChecker.checkForUpdates()
                }
            }
        }
    }
}

class ConfigurationManager {
    private let configFilePath: String
    
    // Make configPath accessible
    var configPath: String {
        return self.configFilePath
    }
    
    private let fileManager = FileManager.default
    private let syncQueue = DispatchQueue(label: "com.macrowhisper.configsync")
    private var fileWatcher: FileChangeWatcher?
    
    // Add a property to track if we've already notified about JSON errors
    private var hasNotifiedAboutJsonError = false
    
    // Make config publicly accessible
    var config: AppConfiguration
    
    // Callback for configuration changes
    var onConfigChanged: (() -> Void)?
    
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
            }
        }
    }
    
    private func setupFileWatcher() {
        // Configuration changes will be handled via socket commands
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
            return try decoder.decode(AppConfiguration.self, from: data)
        } catch {
            // Log the error
            logError("Error loading configuration: \(error.localizedDescription)")
            
            // Only show notification if we haven't already notified
            if !hasNotifiedAboutJsonError {
                hasNotifiedAboutJsonError = true
                
                // Show a single comprehensive notification
                notify(title: "Macrowhisper - Configuration Error",
                       message: "Your configuration file contains invalid JSON. The application is running with default settings. Please fix the file at \(self.configFilePath) and run 'macrowhisper' to reload.")
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
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
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
        simKeypress: Bool? = nil
    ) {
        syncQueue.sync {
            // First, reload the latest config from disk
            if let freshConfig = loadConfig() {
                config = freshConfig
            }
            if let watchPath = watchPath {
                config.defaults.watch = watchPath
            }
            if let noUpdates = noUpdates {
                config.defaults.noUpdates = noUpdates
            }
            if let noNoti = noNoti {
                config.defaults.noNoti = noNoti
            }
            if let activeInsert = activeInsert {
                config.defaults.activeInsert = activeInsert
            }
            if let icon = icon {
                config.defaults.icon = icon
            }
            if let moveTo = moveTo {
                config.defaults.moveTo = moveTo
            }
            if let noEsc = noEsc {  // Add this block
                config.defaults.noEsc = noEsc
            }
            if let simKeypress = simKeypress {  // Add this block
                config.defaults.simKeypress = simKeypress
            }
            
            // Save the configuration
            saveConfig()
            
            // Send notification immediately after successful save
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .init("ConfigurationUpdated"), object: nil)
                logInfo("Configuration updated from command line")
                notify(title: "Macrowhisper", message: "Configuration updated")
            }
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
          --insert <name>           Set the active insert (use empty string to disable)
          --sim-keypress true/false Simulate key presses for text input
                                    (note: linebreaks are treated as return presses)
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
    case "-h", "--help":
        printHelp()
        exit(0)
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

    case "--add-insert":
        guard i + 2 < args.count else {
            logError("Missing insert name or action after \(args[i])")
            exit(1)
        }
        let insertName = args[i + 1]
        let insertAction = args[i + 2]
        
        // Check if an icon is provided (optional)
        var arguments: [String: String] = [
            "name": insertName,
            "action": insertAction
        ]
        
        if i + 3 < args.count && !args[i + 3].starts(with: "--") {
            arguments["icon"] = args[i + 3]
            i += 4
        } else {
            i += 3
        }
        
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
        
    default:
        logError("Unknown argument: \(args[i])")
        notify(title: "Macrowhisper", message: "Unknown argument: \(args[i])")
        exit(1)
    }
}

// Initialize configuration manager with the specified path
configManager = ConfigurationManager(configPath: configPath)
globalConfigManager = configManager

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
    simKeypress: simKeypressFlag
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
logInfo("macrowhisper starting with:")
if runWatcher { logInfo("  Watcher: \(watchFolderPath)/recordings") }

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
configManager.onConfigChanged = {
    // Store previous values to detect changes
    let previousDisableUpdates = disableUpdates

    // Update global variables
    disableUpdates = configManager.config.defaults.noUpdates
    disableNotifications = configManager.config.defaults.noNoti

    // If updates were disabled but are now enabled, reset the version checker state
    if previousDisableUpdates == true && disableUpdates == false {
        versionChecker.resetLastCheckDate()
    }

    // Check if watcher should be running
    let currentWatchPath = configManager.config.defaults.watch

    // Always check if the folder exists and initialize/reinitialize watcher as needed
    if FileManager.default.fileExists(atPath: currentWatchPath) {
        // Folder exists - initialize or reinitialize watcher
        recordingsWatcher = nil  // Force clean reinitialize
        initializeWatcher(currentWatchPath)
        logInfo("Watcher initialized/reinitialized for folder: \(currentWatchPath)")
    } else {
        // Folder doesn't exist - disable watcher
        recordingsWatcher = nil
        logInfo("Watcher disabled because folder doesn't exist: \(currentWatchPath)")
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
