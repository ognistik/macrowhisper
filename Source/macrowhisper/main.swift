#!/usr/bin/env swift

import Foundation
import Swifter
import Dispatch
import Darwin
import UserNotifications

let APP_VERSION = "1.0.0"

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
    notificationManager.sendNotification(title: title, body: message)
    // logInfo("Notification: \(title) - \(message)")
}

// MARK: - Updater

class VersionChecker {
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
    
    func checkForUpdates() {
        guard shouldCheckForUpdates() else { return }
        
        logInfo("Checking for updates...")
        
        // Create request with timeout
        guard let url = URL(string: versionsURL) else {
            logError("Invalid versions URL")
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
            return
        }
        
        if let error = resultError {
            logInfo("Version check failed: \(error.localizedDescription) - continuing offline")
            return
        }
        
        guard let data = resultData else {
            logInfo("No data received from version check - continuing offline")
            return
        }
        
        processVersionResponse( data)
    }
    
    private func processVersionResponse(_ data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logError("Invalid JSON in versions response")
                return
            }
            
            // Update last check date
            lastCheckDate = Date()
            
            // Check CLI version
            var hasUpdates = false
            var updateMessage = ""
            
            if let cliInfo = json["cli"] as? [String: Any],
               let latestCLI = cliInfo["latest"] as? String {
                if isNewerVersion(latest: latestCLI, current: currentCLIVersion) {
                    hasUpdates = true
                    updateMessage += "CLI: \(currentCLIVersion) → \(latestCLI)\n"
                }
            }
            
            // Check Keyboard Maestro version
            if let kmInfo = json["keyboard_maestro"] as? [String: Any],
               let latestKM = kmInfo["latest"] as? String {
                let currentKMVersion = getCurrentKeyboardMaestroVersion()
                if !currentKMVersion.isEmpty && isNewerVersion(latest: latestKM, current: currentKMVersion) {
                    hasUpdates = true
                    updateMessage += "Keyboard Maestro Macros: \(currentKMVersion) → \(latestKM)"
                }
            }
            
            if hasUpdates {
                showUpdateNotification(message: updateMessage)
            } else {
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
    
    private func showUpdateNotification(message: String) {
        DispatchQueue.main.async {
            // Check if we should show reminder (not too frequent)
            if let lastReminder = self.lastReminderDate,
               Date().timeIntervalSince(lastReminder) < self.reminderInterval {
                return
            }
            
            self.lastReminderDate = Date()
            
            let title = "Macrowhisper Updates Available"
            let fullMessage = "New versions available:\n\n\(message)\n\nWould you like to open the download page?"
            
            // Use AppleScript for interactive dialog
            let script = """
            display dialog "\(fullMessage.replacingOccurrences(of: "\"", with: "\\\""))" ¬
                with title "\(title)" ¬
                buttons {"Remind Later", "Open Downloads"} ¬
                default button "Open Downloads" ¬
                with icon note
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
                
                if output.contains("Open Downloads") {
                    self.openDownloadPage()
                }
            } catch {
                // User cancelled or error occurred
                logInfo("Update dialog cancelled or failed")
            }
        }
    }
    
    private func openDownloadPage() {
        let script = "open \"https://github.com/yourusername/macrowhisper/releases\""
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }
}


// MARK: - Helpers

func acquireSingleInstanceLock(lockFilePath: String) {
    let fd = open(lockFilePath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    if fd == -1 {
        logWarning("Could not open lock file: \(lockFilePath)")
        notify(title: "Macrowhisper", message: "Could not open lock file.")
        exit(1)
    }
    // Try to acquire exclusive lock, non-blocking
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        logWarning("Another instance is already running.")
        notify(title: "Macrowhisper", message: "Another instance is already running.")
        exit(1)
    }
    // Keep fd open for the lifetime of the process to hold the lock
}

// Use this at the very top of your main.swift:
let lockPath = "/tmp/macrowhisper.lock"
acquireSingleInstanceLock(lockFilePath: lockPath)

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

func loadProxies(from path: String) -> [String: [String: Any]] {
    let proxiesFile = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: proxiesFile.path) else {
        logWarning("Warning: proxies.json not found.")
        notify(title: "Macrowhisper", message: "Warning: proxies.json not found.")
        return [:]
    }
    
    do {
        let data = try Data(contentsOf: proxiesFile)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            logWarning("Warning: Malformed proxies.json")
            notify(title: "Macrowhisper", message: "Warning: Malformed proxies.json")
            return [:]
        }
        logInfo("Successfully loaded proxies configuration")
        notify(title: "Macrowhisper", message: "Successfully loaded proxies configuration")
        return dict
    } catch {
        logError("Error reading proxies.json: \(error.localizedDescription)")
        notify(title: "Macrowhisper", message: "Error reading proxies.json")
        return [:]
    }
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

final class FileChangeWatcher {
    private let filePath: String
    private let onChanged: () -> Void
    private let onMissing: () -> Void
    private let queue = DispatchQueue(label: "com.macrowhisper.filewatcher", qos: .utility)

    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var rewatchTimer: DispatchSourceTimer?

    init(filePath: String, onChanged: @escaping () -> Void, onMissing: @escaping () -> Void) {
        self.filePath = filePath
        self.onChanged = onChanged
        self.onMissing = onMissing
        startWatching()
    }

    private func startWatching() {
        guard FileManager.default.fileExists(atPath: filePath) else {
            scheduleRewatch()
            return
        }

        fileDescriptor = open(filePath, O_EVTONLY)
        if fileDescriptor < 0 {
            logWarning("FileChangeWatcher: Failed to open file descriptor for \(filePath)")
            scheduleRewatch()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            // If file is deleted or renamed, stop watcher and schedule rewatch
            if !FileManager.default.fileExists(atPath: self.filePath) {
                logWarning("Warning: proxies.json was deleted or replaced! Proxy functionality is now disabled until the file is restored.")
                notify(title: "Macrowhisper", message: "Warning: proxies.json was deleted or replaced! Proxy functionality is now disabled until the file is restored.")
                self.onMissing()
                self.stopWatching()
                self.scheduleRewatch()
            } else {
                self.onChanged()
            }
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
            }
        }

        source.resume()
        self.dispatchSource = source
    }

    private func stopWatching() {
        dispatchSource?.cancel()
        dispatchSource = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func scheduleRewatch() {
        // Cancel existing timer if any
        rewatchTimer?.cancel()
        rewatchTimer = nil

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1) // Check every 1 second
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if FileManager.default.fileExists(atPath: self.filePath) {
                logInfo("proxies.json has been restored. Reloading configuration.")
                notify(title: "Macrowhisper", message: "proxies.json has been restored. Reloading configuration.")
                self.rewatchTimer?.cancel()
                self.rewatchTimer = nil
                self.startWatching()
                self.onChanged() // Reload proxies now
            }
        }
        timer.resume()
        self.rewatchTimer = timer
    }

    deinit {
        stopWatching()
        rewatchTimer?.cancel()
        rewatchTimer = nil
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
            logInfo("Found valid result in meta.json. Triggering Macro.")
            
            // Mark this file as processed so we don't trigger again
            processedMetaJsons.insert(path)
            
            // Trigger version check when user activity is detected
            versionChecker.checkForUpdates()
            
            // Cancel file watcher since we're done with this file
            cancelFileWatcher()
            
            // Trigger Keyboard Maestro on main thread for UI interaction
            // Store the method reference
            let triggerMethod = self.triggerKeyboardMaestro
            // Use it in the closure without capturing self
            DispatchQueue.main.async {
                triggerMethod()
            }
        }
    }
    
    private func triggerKeyboardMaestro() {
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

func isPortAvailable(_ port: UInt16) -> Bool {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    if sock < 0 { return false }
    defer { close(sock) }
    
    var addr = sockaddr_in(
        sin_len: UInt8(MemoryLayout<sockaddr_in>.stride),
        sin_family: sa_family_t(AF_INET),
        sin_port: port.bigEndian,
        sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
        sin_zero: (0,0,0,0,0,0,0,0)
    )
    let bind_result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
        }
    }
    return bind_result == 0
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

// MARK: - Argument Parsing and Startup

let defaultSuperwhisperPath = ("~/Documents/superwhisper" as NSString).expandingTildeInPath
let defaultProxiesPath = "\(defaultSuperwhisperPath)/proxies.json"
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

func createExampleProxiesJson(at path: String) {
    let example: [String: Any] = [
        "4oMini": [
            "model": "openai/gpt-4o-mini",
            "key": "sk-...",
            "url": "https://openrouter.ai/api/v1/chat/completions"
        ],
        "GPT4.1": [
            "model": "gpt-4.1",
            "key": "sk-...",
            "url": "https://api.openai.com/v1/chat/completions"
        ]
    ]
    if let data = try? JSONSerialization.data(withJSONObject: example, options: .prettyPrinted),
       var jsonString = String(data: data, encoding: .utf8) {
        jsonString = jsonString.replacingOccurrences(of: "\\/", with: "/")
        try? jsonString.write(toFile: path, atomically: true, encoding: .utf8)
        logInfo("Example proxies.json created at \(path)")
        notify(title: "Macrowhisper Setup", message: "Sample proxies.json was created successfully")
    } else {
        logError("Failed to create example proxies.json")
        notify(title: "Macrowhisper Error", message: "Failed to create proxies.json")
    }
}

func printHelp() {
    print("""
    Usage: macrowhisper [OPTIONS]

    Server and/or folder watcher for Superwhisper integration.

    OPTIONS:
      -s, --server <path>   Path to proxies.json (default: \(defaultProxiesPath))
      -w, --watch  <path>   Path to superwhisper folder (default: \(defaultSuperwhisperPath))
          --server-only     Only run proxy server (no folder watching)
          --watch-only      Only run folder watcher (no server)
      -h, --help            Show this help message
      -v, --version         Show version information

    Examples:
      macrowhisper
        # Uses defaults for both server and watch modes

      macrowhisper --server ~/myproxies.json --watch ~/otherfolder/superwhisper

      macrowhisper --watch-only

    """)
}

// Argument parsing
var serverPath: String? = nil
var watchPath: String? = nil
var runServer = true
var runWatcher = true

let args = CommandLine.arguments
var i = 1
while i < args.count {
    switch args[i] {
    case "-s", "--server":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            notify(title: "Macrowhisper", message: "Missing value after \(args[i])")
            exit(1)
        }
        serverPath = args[i + 1]
        i += 2
    case "-w", "--watch":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            notify(title: "Macrowhisper", message: "Missing value after \(args[i])")
            exit(1)
        }
        watchPath = args[i + 1]
        i += 2
    case "--server-only":
        runWatcher = false
        i += 1
    case "--watch-only":
        runServer = false
        i += 1
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

// Set defaults if not provided
if serverPath == nil { serverPath = defaultProxiesPath }
if watchPath == nil { watchPath = defaultSuperwhisperPath }

// Validate required folders
func folderExistsOrExit(_ path: String, what: String) {
    if !FileManager.default.fileExists(atPath: path) {
        logError("Error: \(what) not found: \(path)")
        logError("If folder is in a different location specify with --watch.")
        notify(title: "Macrowhisper", message: "Error: \(what) not found: \(path)")
        exit(1)
    }
}

if runWatcher {
    folderExistsOrExit(watchPath!, what: "Superwhisper folder")
    let recordingsPath = "\(watchPath!)/recordings"
    folderExistsOrExit(recordingsPath, what: "Recordings folder")
}

if runServer {
    let proxiesPath = serverPath!
    let proxiesFolder = (proxiesPath as NSString).deletingLastPathComponent
    folderExistsOrExit(proxiesFolder, what: "Superwhisper folder for proxies.json")

    if !FileManager.default.fileExists(atPath: proxiesPath) {
        logError("Error: proxies.json not found at \(proxiesPath)")
        if promptYesNo("Would you like to create a sample proxies.json?") {
            createExampleProxiesJson(at: proxiesPath)
        } else {
            logInfo("You can create this file yourself, or run with --watch-only if you only want watcher functionality.")
            exit(1)
        }
    }
}

// ---
// At this point, continue with initializing server and/or watcher as usual...
logInfo("macrowhisper starting with:")
if runServer { logInfo("  Server: \(serverPath!)") }
if runWatcher { logInfo("  Watcher: \(watchPath!)/recordings") }

// Server setup - only if jsonPath is provided
var server: HttpServer? = nil
var proxies: [String: [String: Any]] = [:]
var fileWatcher: FileChangeWatcher? = nil

if runServer, let jsonPath = serverPath {
    // The proxies.json existence is already checked earlier!
    proxies = loadProxies(from: jsonPath)
    
    // Create file watcher to reload configuration when it changes
    fileWatcher = FileChangeWatcher(
        filePath: jsonPath,
        onChanged: {
            logInfo("proxies.json changed, reloading configuration...")
            proxies = loadProxies(from: jsonPath)
            logInfo("Configuration reloaded successfully - changes will apply to new requests")
        },
        onMissing: {
            proxies = [:]
            logInfo("All proxy rules cleared. Restore proxies.json to re-enable proxy functionality.")
        }
    )
    
    // Start HTTP server
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
    try! server!.start(port, forceIPv4: true)
}

// Initialize the recordings folder watcher if path provided
var recordingsWatcher: RecordingsFolderWatcher? = nil
if runWatcher, let baseWatchPath = watchPath {
    // The existence of the watchPath and recordings folder is already checked earlier!
    recordingsWatcher = RecordingsFolderWatcher(basePath: baseWatchPath)
    if recordingsWatcher == nil {
        logWarning("Warning: Failed to initialize recordings folder watcher")
        notify(title: "Macrowhisper", message: "Warning: Failed to initialize recordings folder watcher")
    } else {
        logInfo("Watching recordings folder at \(baseWatchPath)/recordings")
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
