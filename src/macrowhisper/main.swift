#!/usr/bin/env swift

import Foundation
import Swifter
import Dispatch
import Darwin
import UserNotifications
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
        // First, make sure any existing socket file is removed
        // Only remove the socket file when we're actually starting the server
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
            case .reloadConfig:
                logInfo("Processing command to reload configuration")
                // Reload the configuration from disk
                if let loadedConfig = configMgr.loadConfig() {
                    configMgr.config = loadedConfig
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
                
            case .updateConfig:
                    logInfo("Received command to update configuration")
                    
                    // Extract arguments
                    if let args = commandMessage.arguments {
                        logInfo("Updating config with arguments: \(args)")
                        
                        // Create local variables with proper null checking
                        let watchPath = args["watch"]
                        
                        // Parse boolean values from strings
                        let serverStr = args["server"]
                        let watcherStr = args["watcher"]
                        let noUpdatesStr = args["noUpdates"]
                        let noNotiStr = args["noNoti"]
                        
                        // Log the parameters before updating
                        logInfo("Parameters: watchPath=\(watchPath as Any), server=\(serverStr as Any), watcher=\(watcherStr as Any), noUpdates=\(noUpdatesStr as Any), noNoti=\(noNotiStr as Any)")
                        
                        // Convert string values to boolean values
                        let server = serverStr == "true" ? true : (serverStr == "false" ? false : nil)
                        let watcher = watcherStr == "true" ? true : (watcherStr == "false" ? false : nil)
                        let noUpdates = noUpdatesStr == "true" ? true : (noUpdatesStr == "false" ? false : nil)
                        let noNoti = noNotiStr == "true" ? true : (noNotiStr == "false" ? false : nil)
                        
                        // Update configuration with null-safe values using the safe reference
                        configMgr.updateFromCommandLine(
                            watchPath: watchPath,
                            server: server,
                            watcher: watcher,
                            noUpdates: noUpdates,
                            noNoti: noNoti
                        )
                        
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
                    "server_running": server != nil,
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
                
            case .debug:
                logInfo("Received debug command")
                let status = """
                Server status:
                - Socket path: \(socketPath)
                - Server socket descriptor: \(serverSocket)
                - Server running: \(server != nil)
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
        
        // Print to console when running interactively
        if isatty(STDOUT_FILENO) != 0 {
            print(logEntry, terminator: "")
        }
        
        // Append to log file
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
            logInfo("Skipping update check due to recent connection failure")
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
                if !currentKMVersion.isEmpty && isNewerVersion(latest: latestKM, current: currentKMVersion) {
                    kmUpdateAvailable = true
                    kmMessage = "KM Macros: \(currentKMVersion) → \(latestKM)"
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
                set result to do script "Setup - Service" with parameter "versionCheck"
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
        task.standardError = FileHandle.nullDevice
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output
        } catch {
            logError("Failed to get Keyboard Maestro version: \(error)")
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
            var server: Bool
            var watcher: Bool
            var noUpdates: Bool
            var noNoti: Bool
            
            static func defaultValues() -> Defaults {
                return Defaults(
                    watch: ("~/Documents/superwhisper" as NSString).expandingTildeInPath,
                    server: false,  // Default off
                    watcher: false, // Default off
                    noUpdates: false,
                    noNoti: false
                )
            }
    }
    
    struct Proxy: Codable {
        var name: String
        var model: String
        var key: String
        var url: String
        
        // Additional proxy properties can be added here
        // For backward compatibility with existing code
        func toDictionary() -> [String: Any] {
            return [
                "model": model,
                "key": key,
                "url": url
            ]
        }
    }
    
    var defaults: Defaults
    var proxies: [Proxy]
    
    static func defaultConfig() -> AppConfiguration {
        return AppConfiguration(
            defaults: Defaults.defaultValues(),
            proxies: [
                Proxy(name: "4oMini", model: "openai/gpt-4o-mini", key: "sk-...", url: "https://openrouter.ai/api/v1/chat/completions"),
                Proxy(name: "GPT4.1", model: "gpt-4.1", key: "sk-...", url: "https://api.openai.com/v1/chat/completions"),
                Proxy(name: "Claude", model: "anthropic/claude-3-sonnet", key: "sk-...", url: "https://openrouter.ai/api/v1/chat/completions")
            ]
        )
    }
}

// MARK: - Helpers

func initializeServer() {
    // Get proxies from configuration
    proxies = configManager.getProxiesDict()
    
    // Create server
    server = HttpServer()
    let port: in_port_t = 11434
    
    // Set up server routes
    setupServerRoutes(server: server!)
    
    do {
        try server!.start(port, forceIPv4: true)
        logInfo("Proxy server running on http://localhost:\(port)")
        notify(title: "Macrowhisper", message: "Proxy server running on http://localhost:\(port)")
    } catch {
        logError("Failed to start server: \(error)")
        notify(title: "Macrowhisper", message: "Failed to start server")
        
        // Update config to disable server
        configManager.updateFromCommandLine(server: false)
    }
}

func initializeWatcher(_ path: String) {
    let recordingsPath = "\(path)/recordings"
    
    if !FileManager.default.fileExists(atPath: recordingsPath) {
        logWarning("Recordings folder not found at \(recordingsPath)")
        notify(title: "Macrowhisper", message: "Recordings folder not found")
        
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
        logInfo("Another instance is already running.")
        
        // Instead of using socket communication, use process communication
        let args = CommandLine.arguments
        
        // Handle help command specifically
        if args.contains("-h") || args.contains("--help") {
            // Print help directly without trying to communicate with the running instance
            printHelp()
            exit(0)
        }
        
        // Check for status command
        if args.contains("-s") || args.contains("--status") {
            print("Macrowhisper is running. (Version \(APP_VERSION))")
            exit(0)
        }
        
        // For reload configuration or no arguments, use socket communication
        if args.count == 1 || args.contains("--server") || args.contains("--watcher") ||
           args.contains("-w") || args.contains("--watch") ||
           args.contains("--no-updates") || args.contains("--no-noti") {
            
            print("Reloading configuration in running instance...")
            
            // Create command arguments if there are any
            var arguments: [String: String] = [:]
            
            // Extract arguments from command line
            if let watchIndex = args.firstIndex(where: { $0 == "-w" || $0 == "--watch" }),
               watchIndex + 1 < args.count {
                arguments["watch"] = args[watchIndex + 1]
            }
            
            if let serverIndex = args.firstIndex(where: { $0 == "--server" }),
               serverIndex + 1 < args.count {
                arguments["server"] = args[serverIndex + 1]
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
let socketPath = "/private/tmp/macrowhisper.sock"  // Use /private/tmp instead of /tmp
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

@preconcurrency
final class ProxyStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let writer: HttpResponseBodyWriter
    let semaphore: DispatchSemaphore

    init(writer: HttpResponseBodyWriter, semaphore: DispatchSemaphore) {
        self.writer = writer
        self.semaphore = semaphore
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Write each chunk as soon as it arrives
        try? writer.write(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Done streaming
        semaphore.signal()
    }
}

func exitWithError(_ message: String) -> Never {
    logError("Error: \(message)")
    notify(title: "Macrowhisper", message: "Error: \(message)")
    exit(1)
}

func buildRequest(url: String, headers: [String: String], json: [String: Any]) -> URLRequest {
    guard let urlObj = URL(string: url) else { exitWithError("Bad URL: \(url)") }
    var req = URLRequest(url: urlObj)
    req.httpMethod = "POST"
    for (k, v) in headers { req.addValue(v, forHTTPHeaderField: k) }
    req.httpBody = try? JSONSerialization.data(withJSONObject: json)
    return req
}

func mergeBody(original: [String: Any], modifications: [String: Any]) -> [String: Any] {
    var out = original
    for (k, v) in modifications { out[k] = v }
    return out
}

func checkWatcherAvailability() -> Bool {
    let watchPath = configManager.config.defaults.watch
    let exists = FileManager.default.fileExists(atPath: watchPath)
    
    if !exists && configManager.config.defaults.watcher {
        logWarning("Superwhisper folder not found. Watcher has been disabled.")
        notify(title: "Macrowhisper", message: "Superwhisper folder not found. Watcher has been disabled.")
        
        // Update config to disable watcher
        configManager.updateFromCommandLine(watcher: false)
        return false
    }
    
    return exists && configManager.config.defaults.watcher
}

func checkServerAvailability() -> Bool {
    let port: in_port_t = 11434
    let available = isPortAvailable(port)
    
    if !available && configManager.config.defaults.server {
        logWarning("Port 11434 is already in use. Server has been disabled.")
        notify(title: "Macrowhisper", message: "Port 11434 is already in use. Server has been disabled.")
        
        // Update config to disable server
        configManager.updateFromCommandLine(server: false)
        return false
    }
    
    return available && configManager.config.defaults.server
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
        let timer = DispatchSource.makeTimerSource(queue: fileDescriptorQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1) // Check every 1 second
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.checkRecordingsFolder() {
                logInfo("recordings folder has been restored. Resuming watching.")
                notify(title: "Macrowhisper", message: "recordings folder has been restored. Resuming watching.")
                timer.cancel()
                self.startWatchingRecordingsFolder()
            }
        }
        timer.resume()
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
            
            // Trigger Keyboard Maestro with high priority
            logInfo("Found valid result in meta.json. Triggering Macro.")
            
            // IMPORTANT: Trigger Keyboard Maestro IMMEDIATELY with highest priority
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                guard let self = self else { return }
                self.triggerKeyboardMaestro()
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
    
    private func triggerKeyboardMaestro() {
        // Use a dedicated high-priority queue for KM triggers
        DispatchQueue.global(qos: .userInteractive).async {
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = [
                "-e",
                "tell application \"Keyboard Maestro Engine\" to do script \"Trigger - Meta\""
            ]
            // Discard all output, fully async
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
            } catch {
                logError("Failed to launch Keyboard Maestro trigger: \(error)")
                notify(title: "Macrowhisper", message: "Failed to launch Keyboard Maestro trigger.")
            }
        }
    }
}

func isPortAvailable(_ port: UInt16) -> Bool {
    // Create a socket
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    if sock < 0 {
        logError("Failed to create socket for port check")
        return false
    }
    defer { close(sock) }
    
    // Set up the socket address
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = INADDR_ANY
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    
    // Try to bind
    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    
    // If bind failed, port is in use
    if bindResult != 0 {
        logError("Port \(port) is already in use (Error: \(errno))")
        return false
    }
    
    // Also try to listen on the port to be double sure
    let listenResult = listen(sock, 1)
    if listenResult != 0 {
        logError("Port \(port) cannot be used for listening (Error: \(errno))")
        return false
    }
    
    logInfo("Port \(port) is available")
    return true
}

func mergeAnnotationsIntoContent(_ data: Data) -> Data {
    guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var choices = root["choices"] as? [[String: Any]] else {
        logInfo("Couldn't parse completion JSON, returning original data.")
        return data
    }
    for i in choices.indices {
        guard var message = choices[i]["message"] as? [String: Any] else { continue }
        if let annotations = message["annotations"] as? [[String: Any]], !annotations.isEmpty {
            logInfo("Found \(annotations.count) annotations, merging into content for choice[\(i)].")
            var content = message["content"] as? String ?? ""
            content += "\n\n---\n"
            for ann in annotations {
                if let urlCitation = ann["url_citation"] as? [String: Any] {
                    let title = urlCitation["title"] as? String ?? "Link"
                    let url = urlCitation["url"] as? String ?? ""
                    content += "- [\(title)](\(url))\n"
                }
            }
            message["content"] = content
            message.removeValue(forKey: "annotations")
            choices[i]["message"] = message
        }
    }
    root["choices"] = choices
    return (try? JSONSerialization.data(withJSONObject: root)) ?? data
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
    
    // Make config publicly accessible
    var config: AppConfiguration
    
    // Callback for configuration changes
    var onConfigChanged: (() -> Void)?
    
    init(configPath: String? = nil) {
        // Initialize ALL stored properties first
        if let path = configPath {
            self.configFilePath = path
        } else {
            let configDir = ("~/.config/macrowhisper" as NSString).expandingTildeInPath
            self.configFilePath = "\(configDir)/macrowhisper.json"
        }
        
        // Initialize config with a default value first
        self.config = AppConfiguration.defaultConfig()
        
        // Create directory if it doesn't exist
        let directory = (self.configFilePath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: directory) {
            try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        
        // Check if config file exists
        let fileExistedBefore = fileManager.fileExists(atPath: self.configFilePath)
        
        // NOW you can call instance methods since all properties are initialized
        if let loadedConfig = loadConfig() {
            self.config = loadedConfig
            logInfo("Configuration loaded from \(self.configFilePath)")
        } else {
            // Keep the default config we already set
            saveConfig()
            logInfo("Default configuration created at \(self.configFilePath)")
        }
        
        // Set up file watcher for config changes
        setupFileWatcher()
        
        // If we just created the file, we need to reinitialize the watcher
        if !fileExistedBefore && fileManager.fileExists(atPath: self.configFilePath) {
            // Add a slight delay to ensure the file system has registered the new file
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.setupFileWatcher()
                logInfo("File watcher reinitialized after creating config file")
            }
        }
    }
    
    private func setupFileWatcher() {
        // No longer watching the file automatically
        // Configuration will be reloaded manually via socket commands
        logInfo("File watching disabled - use 'macrowhisper' command to reload configuration")
        
        // We're intentionally not setting up a file watcher here
        // as configuration changes will be handled via socket commands
    }
    
    // Make this method public
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
            // Log the error as before
            logError("Error loading configuration: \(error.localizedDescription)")
            
            // Add notification for invalid JSON format
            if error is DecodingError {
                notify(title: "Macrowhisper",
                       message: "The configuration file contains invalid JSON. Please check the format.")
            } else {
                notify(title: "Macrowhisper",
                       message: "Failed to load configuration: \(error.localizedDescription)")
            }
            
            return nil
        }
    }
    
    func saveConfig() {
        let fileExistedBefore = fileManager.fileExists(atPath: configFilePath)
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: URL(fileURLWithPath: configFilePath), options: .atomic)
            
            // If file didn't exist before but now does, reinitialize the watcher
            if !fileExistedBefore && fileManager.fileExists(atPath: configFilePath) {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.setupFileWatcher()
                    logInfo("File watcher reinitialized after creating config file")
                }
            }
        } catch {
            logError("Error saving configuration: \(error.localizedDescription)")
        }
    }

    // Update configuration with command line arguments and save
    func updateFromCommandLine(
        watchPath: String? = nil,
        server: Bool? = nil,
        watcher: Bool? = nil,
        noUpdates: Bool? = nil,
        noNoti: Bool? = nil
    ) {
        syncQueue.sync {
            if let watchPath = watchPath {
                config.defaults.watch = watchPath
            }
            if let server = server {
                config.defaults.server = server
            }
            if let watcher = watcher {
                config.defaults.watcher = watcher
            }
            if let noUpdates = noUpdates {
                config.defaults.noUpdates = noUpdates
            }
            if let noNoti = noNoti {
                config.defaults.noNoti = noNoti
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
    
    // Convert proxies to the format expected by the existing code
    func getProxiesDict() -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for proxy in config.proxies {
            result[proxy.name] = proxy.toDictionary()
        }
        return result
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

func printHelp() {
    print("""
    Usage: macrowhisper [OPTIONS]

    Server and/or folder watcher for Superwhisper integration.

    OPTIONS:
      -c, --config <path>           Path to config file (default: ~/.config/macrowhisper/macrowhisper.json)
      -w, --watch <path>            Path to superwhisper folder (overrides config)
          --server true/false       Enable or disable the proxy server (overrides config)
          --watcher true/false      Enable or disable the folder watcher (overrides config)
          --no-updates true/false   Enable or disable automatic update checking (overrides config)
          --no-noti true/false      Enable or disable all notifications (overrides config)
      -s, --status                  Get the status of the background process
      -h, --help                    Show this help message
      -v, --version                 Show version information

    Examples:
      macrowhisper
        # Uses defaults from config file/Reloads config file

      macrowhisper --config ~/custom-config.json

      macrowhisper --watch ~/otherfolder/superwhisper --watcher true --no-updates false

    """)
}

// Argument parsing
let configManager: ConfigurationManager
var configPath: String? = nil
var watchPath: String? = nil
var serverFlag: Bool? = nil
var watcherFlag: Bool? = nil

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
    case "--server":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            exit(1)
        }
        let value = args[i + 1].lowercased()
        serverFlag = value == "true" || value == "yes" || value == "1"
        i += 2
    case "--watcher":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            exit(1)
        }
        let value = args[i + 1].lowercased()
        watcherFlag = value == "true" || value == "yes" || value == "1"
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
    case "-h", "--help":
        printHelp()
        exit(0)
    case "-v", "--version":
        print("macrowhisper version \(APP_VERSION)")
        exit(0)
    default:
        logError("Unknown argument: \(args[i])")
        notify(title: "Macrowhisper", message: "Unknown argument: \(args[i])")
        printHelp()
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
    server: serverFlag,
    watcher: watcherFlag,
    noUpdates: args.contains("--no-updates") ? disableUpdates : nil,
    noNoti: args.contains("--no-noti") ? disableNotifications : nil
)

// Update global variables again after possible configuration changes
disableUpdates = configManager.config.defaults.noUpdates
disableNotifications = configManager.config.defaults.noNoti

// Get the final watch path after possible updates
let watchFolderPath = config.defaults.watch

// Check feature availability
let runServer = checkServerAvailability()
let runWatcher = checkWatcherAvailability()

// Initialize features based on availability
if runServer {
    initializeServer()
}

if runWatcher {
    initializeWatcher(watchFolderPath)
}

// ---
// At this point, continue with initializing server and/or watcher as usual...
logInfo("macrowhisper starting with:")
if runServer { logInfo("  Server: Using configuration at \(configManager.configPath)") }
if runWatcher { logInfo("  Watcher: \(watchFolderPath)/recordings") }

// Server setup - only if jsonPath is provided
// MARK: - Server and Watcher Setup

// Setup proxy server if enabled
var proxies: [String: [String: Any]] = [:]
var server: HttpServer? = nil
var fileWatcher: FileChangeWatcher? = nil

func folderExistsOrExit(_ path: String, what: String) {
    if !FileManager.default.fileExists(atPath: path) {
        logError("Error: \(what) not found: \(path)")
        notify(title: "Macrowhisper", message: "Error: \(what) not found: \(path)")
        exit(1)
    }
}

if runServer {
    // Get proxies from configuration
    proxies = configManager.getProxiesDict()
    
    // Create server
    server = HttpServer()
    let port: in_port_t = 11434
    guard isPortAvailable(port) else {
        notify(title: "Macrowhisper", message: "Error: Port \(port) is already in use.")
        exitWithError("Port \(port) is already in use.")
    }
    
    // Set up server routes
    setupServerRoutes(server: server!)
    
    logInfo("Proxy server running on http://localhost:\(port)")
    notify(title: "Macrowhisper", message: "Proxy server running on http://localhost:\(port)")
    do {
        try server!.start(port, forceIPv4: true)
        logInfo("Server successfully started on port \(port)")
    } catch {
        logError("Failed to start server: \(error)")
        notify(title: "Macrowhisper", message: "Error: Port \(port) is already in use.")
        
        // Update config to disable server
        configManager.updateFromCommandLine(server: false)
        server = nil
    }
    
    // Update getProxies function to use configuration manager
    func getProxies() -> [String: [String: Any]] {
        return configManager.getProxiesDict()
    }
    
    // Set up observer for configuration changes
    NotificationCenter.default.addObserver(forName: .init("ConfigurationUpdated"),
                                          object: nil,
                                          queue: .main) { _ in
        // Only update if server is running
        if runServer && server != nil {
            // Update proxies from configuration
            proxies = configManager.getProxiesDict()
            logInfo("Proxies updated from configuration change")
            notify(title: "Macrowhisper", message: "Proxies configuration reloaded")
        }
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
    logInfo("disableUpdates now set to: \(disableUpdates)")
    disableNotifications = configManager.config.defaults.noNoti
    logInfo("disableNotifications now set to: \(disableNotifications)")
    
    // If updates were disabled but are now enabled, reset the version checker state
    if previousDisableUpdates == true && disableUpdates == false {
        logInfo("Updates were disabled but are now enabled. Resetting update checker state.")
        versionChecker.resetLastCheckDate()
    }
    
    // Check if server should be running
    let shouldRunServer = configManager.config.defaults.server
    if shouldRunServer && server == nil {
        if checkServerAvailability() {
            initializeServer()
        }
    } else if !shouldRunServer && server != nil {
        server?.stop()
        server = nil
        logInfo("Server stopped due to configuration change")
    }
    
    // Check if watcher should be running
    let shouldRunWatcher = configManager.config.defaults.watcher
    let currentWatchPath = configManager.config.defaults.watch
    
    if shouldRunWatcher && recordingsWatcher == nil {
        if checkWatcherAvailability() {
            initializeWatcher(currentWatchPath)
        }
    } else if !shouldRunWatcher && recordingsWatcher != nil {
        recordingsWatcher = nil
        logInfo("Watcher stopped due to configuration change")
    } else if shouldRunWatcher && recordingsWatcher != nil && currentWatchPath != watchFolderPath {
        // Restart watcher with new path
        recordingsWatcher = nil
        initializeWatcher(currentWatchPath)
    }
}

// Function to set up server routes
func setupServerRoutes(server: HttpServer) {
    server["/v1/chat/completions"] = { req in
        // Access the proxies through a function call to ensure it's always up-to-date
        let currentProxies = getProxies()
        
        guard req.method == "POST" else { return .notFound }
        let rawBody = req.body
        
        guard !rawBody.isEmpty else { return .badRequest(.text("Missing body")) }
        guard let jsonBody = try? JSONSerialization.jsonObject(with: Data(rawBody), options: []) as? [String: Any] else {
            return .badRequest(.text("Malformed JSON"))
        }
        guard var model = jsonBody["model"] as? String else {
            return .badRequest(.text("Missing model"))
        }
        
        // If doesn't start with mw|, forward unchanged to original endpoint (Ollama)
        if !model.hasPrefix("mw|") {
            // Forward request to original endpoint (e.g., Ollama)
            let ollamaURL = "http://localhost:11435/v1/chat/completions"
            
            // I don't want to strip all the original header
            var headers = req.headers
            
            if let ua = req.headers["user-agent"] { headers["User-Agent"] = ua }
            let outgoingReq = buildRequest(url: ollamaURL, headers: headers, json: jsonBody)
            
            return HttpResponse.raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                let semaphore = DispatchSemaphore(value: 0)
                let delegate = ProxyStreamDelegate(writer: writer, semaphore: semaphore)
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                let task = session.dataTask(with: outgoingReq)
                task.resume()
                semaphore.wait() // Wait until the streaming is finished
            }
        }
        
        // If starts with mw|, strip and process
        model.removeFirst("mw|".count)
        guard let proxyRule = currentProxies[model] else {
            return .badRequest(.text("No proxy rule for model \(model)"))
        }
        guard let targetURL = proxyRule["url"] as? String else {
            return .badRequest(.text("No url in proxies.json for \(model)"))
        }

        // Prepare headers and body (as already done above)
        var headers = req.headers
        headers.removeValue(forKey: "Content-Length")
        headers.removeValue(forKey: "content-length")
        headers.removeValue(forKey: "Host")
        headers.removeValue(forKey: "host")
        headers.removeValue(forKey: "connection")
        headers.removeValue(forKey: "Connection")
        headers.removeValue(forKey: "User-Agent")
        headers.removeValue(forKey: "user-agent")

        var bodyMods = [String: Any]()
        var newBody = jsonBody
        newBody["model"] = model // Set the default model to be the proxy name (top-level key)
        
        // Process common parameters without requiring "-d " prefix
        let commonBodyParams = ["temperature", "stream", "max_tokens"]
        for param in commonBodyParams {
            if let value = proxyRule[param] {
                bodyMods[param] = value
            }
        }

        for (k, v) in proxyRule {
            if k == "url" { continue }
            if k == "key", let token = v as? String {
                headers["Authorization"] = "Bearer \(token)"
            } else if k == "model" {
                newBody["model"] = v // This overrides the default if specified
            } else if k.hasPrefix("-H "), let val = v as? String {
                let hk = String(k.dropFirst(3))
                headers[hk] = val
            } else if k.hasPrefix("-d ") {
                let bk = String(k.dropFirst(3))
                bodyMods[bk] = v
            }
        }

        newBody = mergeBody(original: newBody, modifications: bodyMods)

        // Special handling for OpenRouter
        if targetURL.contains("openrouter.ai/api/v1/chat/completions") {
            // Force set these headers for OpenRouter, overriding any user settings
            headers["HTTP-Referer"] = "https://by.afadingthought.com/macrowhisper"
            headers["X-Title"] = "Macrowhisper"
        }
        
        let streamDisabled = (proxyRule["-d stream"] as? Bool == false)
        let outgoingReq = buildRequest(url: targetURL, headers: headers, json: newBody)

        if streamDisabled {
            return HttpResponse.raw(200, "OK", ["Content-Type": "text/event-stream"]) { writer in
                let session = URLSession(configuration: .default)
                let semaphore = DispatchSemaphore(value: 0)
                session.dataTask(with: outgoingReq) { data, _, _ in
                    if let data = data {
                        let processed = mergeAnnotationsIntoContent(data)
                        // Parse response
                        if let root = try? JSONSerialization.jsonObject(with: processed) as? [String: Any],
                           let choices = root["choices"] as? [[String: Any]],
                           let message = choices.first?["message"] as? [String: Any],
                           let content = message["content"] as? String {
                            // Stream word by word as OpenAI delta-style
                            var _ = ""
                            // Assume 'content' is your string to stream
                            let deltaChunk: [String: Any] = [
                                "id": root["id"] ?? "chatcmpl-xxx",
                                "object": "chat.completion.chunk",
                                "choices": [[
                                    "delta": ["content": content],
                                    "index": 0,
                                    "finish_reason": nil
                                ]],
                                "model": root["model"] ?? "unknown"
                            ]

                            if let chunkData = try? JSONSerialization.data(withJSONObject: deltaChunk),
                               let chunkString = String(data: chunkData, encoding: .utf8) {
                                let sse = "data: \(chunkString)\n\n"
                                try? writer.write(sse.data(using: .utf8)!)
                                // No sleep, just send it all at once
                            }

                            let done = "data: [DONE]\n\n"
                            try? writer.write(done.data(using: .utf8)!)
                        } else {
                            // If can't parse, fallback, but this may crash some clients
                            let chunk = "data: \(String(data: processed, encoding: .utf8) ?? "")\n\n"
                            let done = "data: [DONE]\n\n"
                            try? writer.write(chunk.data(using: .utf8)!)
                            try? writer.write(done.data(using: .utf8)!)
                        }
                    }
                    semaphore.signal()
                }.resume()
                semaphore.wait()
            }
        } else {
            // Usual streaming passthrough
            return HttpResponse.raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                let semaphore = DispatchSemaphore(value: 0)
                let delegate = ProxyStreamDelegate(writer: writer, semaphore: semaphore)
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                let task = session.dataTask(with: outgoingReq)
                task.resume()
                semaphore.wait()
            }
        }
    }

    server["/api/tags"] = { req in
        // First try to get the actual tags from Ollama
        var tagsList: [[String: Any]] = []
        
        // Try to fetch from Ollama
        let ollamaURL = "http://localhost:11435/api/tags"
        var request = URLRequest(url: URL(string: ollamaURL)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.5 // Short timeout of 0.5 seconds
        
        // Create a special version that doesn't crash on network errors
        func safeNetworkRequest(_ request: URLRequest) -> (Data?, URLResponse?, Error?) {
            let semaphore = DispatchSemaphore(value: 0)
            var resultData: Data? = nil
            var resultResponse: URLResponse? = nil
            var resultError: Error? = nil
            
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = request.timeoutInterval
            let session = URLSession(configuration: config)
            
            session.dataTask(with: request) { data, response, error in
                resultData = data
                resultResponse = response
                resultError = error
                semaphore.signal()
            }.resume()
            
            _ = semaphore.wait(timeout: .now() + request.timeoutInterval + 0.1)
            return (resultData, resultResponse, resultError)
        }
        
        // Use our safe network request function
        let (data, response, error) = safeNetworkRequest(request)
        
        if let error = error {
            logError("Error connecting to Ollama: \(error.localizedDescription)")
            // Continue with empty tagsList - Ollama is probably not running
        } else if let data = data,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 {
            // Parse the response as before
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["models"] as? [[String: Any]] {
                    tagsList = models
                    logInfo("Successfully retrieved \(models.count) models from Ollama")
                }
            } catch {
                logError("Error parsing Ollama response: \(error)")
            }
        } else {
            logError("Failed to get models from Ollama: status code \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        
        // Add a default placeholder model if Ollama/LMStudio is running but returned no models
        if tagsList.isEmpty && error == nil && (response as? HTTPURLResponse)?.statusCode == 200 {
            let defaultModel: [String: Any] = [
                "name": "-",
                "modified_at": ISO8601DateFormatter().string(from: Date()),
                "size": 0,
                "digest": "default-model",
                "details": [
                    "format": "unknown",
                    "family": "default",
                    "parameter_size": "N/A",
                    "quantization_level": "none"
                ]
            ]
            tagsList.append(defaultModel)
        }
        
        // For each proxy in your proxies dictionary, add an entry
        for (proxyName, _) in getProxies() {
            let customProxyModel: [String: Any] = [
                "name": "mw|\(proxyName)",
                "modified_at": ISO8601DateFormatter().string(from: Date()),
                "size": 0,
                "digest": "mw-\(proxyName)",
                "details": [
                    "format": "proxy",
                    "family": "proxy",
                    "parameter_size": "N/A",
                    "quantization_level": "none"
                ]
            ]
            tagsList.append(customProxyModel)
        }
        
        // Return the combined list
        let modelResponse: [String: Any] = ["models": tagsList]
        let jsonData = try! JSONSerialization.data(withJSONObject: modelResponse)
        
        return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
            try? writer.write(jsonData)
        }
    }


    server.notFoundHandler = { req in
        // Forward everything to Ollama, preserving path and method
        let targetURL = "http://localhost:11435\(req.path)"
        let headers = req.headers
        var request = URLRequest(url: URL(string: targetURL)!)
        request.httpMethod = req.method
        for (k, v) in headers { request.addValue(v, forHTTPHeaderField: k) }
        if !req.body.isEmpty {
            request.httpBody = Data(req.body)
        }

        return HttpResponse.raw(200, "OK", headers) { writer in
            let semaphore = DispatchSemaphore(value: 0)
            let delegate = ProxyStreamDelegate(writer: writer, semaphore: semaphore)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: request)
            task.resume()
            semaphore.wait()
        }
    }
}

// Add a helper function to access the proxies
func getProxies() -> [String: [String: Any]] {
    return proxies
}

// Initialize version checker
let versionChecker = VersionChecker()

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
