import Foundation
import Darwin

var suppressConsoleLogging = false
var redactedLogsEnabled = true

enum LogDetailMode {
    case normal
    case verbose
}

var logDetailMode: LogDetailMode = .normal

private let logSuppressionQueue = DispatchQueue(label: "com.macrowhisper.logsuppression")
private var rateLimitedLogState: [String: Date] = [:]

class Logger {
    private let logFilePath: String
    private let logLockFilePath: String
    private let maxLogSize: Int = 5 * 1024 * 1024 // 5 MB in bytes
    private let dateFormatter: DateFormatter
    private let dateFormatterLock = NSLock()
    private let fileManager = FileManager.default
    private var consoleLogLevel: LogLevel = .info // Only show INFO and above in console by default
    private let consoleLogLevelLock = NSLock()
    private let maxLogFiles: Int = 1 // Keep only 1 backup log file (plus current)
    
    init(logDirectory: String) {
        // Create logs directory if it doesn't exist
        if !fileManager.fileExists(atPath: logDirectory) {
            try? fileManager.createDirectory(atPath: logDirectory, withIntermediateDirectories: true)
        }
        
        let standardizedLogDirectory = (logDirectory as NSString).standardizingPath
        self.logFilePath = "\(standardizedLogDirectory)/macrowhisper.log"
        // Keep the coordination file outside the backup filename prefix so cleanup
        // can never mistake it for a rotated log.
        self.logLockFilePath = "\(standardizedLogDirectory)/.macrowhisper-log.lock"
        
        // Setup date formatter for log entries
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        
        // Coordinate initial creation, rotation, and cleanup with every other
        // Logger instance and process using this directory.
        withLogFileLock {
            ensureCurrentLogExistsLocked()
            rotateLogIfNeededLocked()
            cleanupOldLogsLocked()
        }
    }
    
    /// Set the minimum log level to show in console (file logging is unaffected)
    func setConsoleLogLevel(_ level: LogLevel) {
        consoleLogLevelLock.lock()
        defer { consoleLogLevelLock.unlock() }
        consoleLogLevel = level
    }
    
    func log(_ message: String, level: LogLevel = .info) {
        let timestamp = formattedTimestamp()
        let logEntry = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
        
        // Print to console when running interactively AND console logging is not suppressed
        // AND the log level is at or above the console threshold
        printToConsoleIfNeeded(logEntry, level: level)

        guard let data = logEntry.data(using: .utf8) else { return }
        withLogFileLock {
            guard appendDataLocked(data) else { return }
            rotateLogIfNeededLocked()
        }
    }

    private func formattedTimestamp() -> String {
        dateFormatterLock.lock()
        defer { dateFormatterLock.unlock() }
        return dateFormatter.string(from: Date())
    }

    private func printToConsoleIfNeeded(_ logEntry: String, level: LogLevel) {
        consoleLogLevelLock.lock()
        let shouldPrint = isatty(STDOUT_FILENO) != 0
            && !suppressConsoleLogging
            && level.priority >= consoleLogLevel.priority
        consoleLogLevelLock.unlock()

        if shouldPrint {
            print(logEntry, terminator: "")
        }
    }

    /// Runs a log-file operation while holding a stable advisory lock. The lock
    /// file is never renamed or removed, so all processes continue to coordinate
    /// across creation and rotation of the active log.
    private func withLogFileLock(_ operation: () -> Void) {
        let lockDescriptor = Darwin.open(logLockFilePath, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard lockDescriptor >= 0 else { return }
        defer { _ = Darwin.close(lockDescriptor) }

        while flock(lockDescriptor, LOCK_EX) == -1 {
            if errno == EINTR { continue }
            return
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }
        operation()
    }

    private func ensureCurrentLogExistsLocked() {
        let descriptor = Darwin.open(logFilePath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, mode_t(0o644))
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }

    /// Writes one complete record with O_APPEND while holding the directory's
    /// advisory lock. Short writes are continued and EINTR is retried.
    private func appendDataLocked(_ data: Data) -> Bool {
        let descriptor = Darwin.open(logFilePath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, mode_t(0o644))
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }

        return data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    private func rotateLogIfNeededLocked() {
        guard let attributes = try? fileManager.attributesOfItem(atPath: logFilePath),
              let fileSize = attributes[.size] as? Int else {
            return
        }
        
        if fileSize > maxLogSize {
            let dateStr = formattedTimestamp().replacingOccurrences(of: ":", with: "-")
            let rotatedLogPath = nextRotatedLogPathLocked(timestamp: dateStr)
            do {
                try fileManager.moveItem(atPath: logFilePath, toPath: rotatedLogPath)
                // A rename preserves the old file's modification date. Refresh it
                // so retention consistently keeps the newest rotation.
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: rotatedLogPath)
            } catch {
                return
            }

            // Clean up old logs after rotation
            cleanupOldLogsLocked()

            // Append the rotation notice directly while retaining the current
            // lock. Calling logInfo here would recursively acquire the lock.
            let rotationEntry = "[\(formattedTimestamp())] [INFO] Log file rotated due to size limit\n"
            printToConsoleIfNeeded(rotationEntry, level: .info)
            if let data = rotationEntry.data(using: .utf8) {
                _ = appendDataLocked(data)
            }
        }
    }

    private func nextRotatedLogPathLocked(timestamp: String) -> String {
        let basePath = "\(logFilePath).\(timestamp)"
        guard fileManager.fileExists(atPath: basePath) else { return basePath }

        var suffix = 1
        while true {
            let candidate = "\(basePath).\(suffix)"
            if !fileManager.fileExists(atPath: candidate) {
                return candidate
            }
            suffix += 1
        }
    }
    
    /// Clean up old log files, keeping only the specified number of backup files
    private func cleanupOldLogsLocked() {
        let logDirectory = (logFilePath as NSString).deletingLastPathComponent
        let logFileName = (logFilePath as NSString).lastPathComponent
        
        do {
            // Get all files in the log directory
            let allFiles = try fileManager.contentsOfDirectory(atPath: logDirectory)
            
            // Filter for log files with timestamps (backup logs)
            let backupLogs = allFiles.filter { fileName in
                return fileName.hasPrefix("\(logFileName).") && fileName != logFileName
            }
            
            // Sort backup logs by modification date (newest first)
            let sortedBackupLogs = backupLogs.compactMap { fileName -> (String, Date)? in
                let filePath = "\(logDirectory)/\(fileName)"
                guard let attributes = try? fileManager.attributesOfItem(atPath: filePath),
                      let modificationDate = attributes[.modificationDate] as? Date else {
                    return nil
                }
                return (fileName, modificationDate)
            }.sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                let leftOrder = rotationSortComponents(for: $0.0, logFileName: logFileName)
                let rightOrder = rotationSortComponents(for: $1.0, logFileName: logFileName)
                if leftOrder.timestamp != rightOrder.timestamp {
                    return leftOrder.timestamp > rightOrder.timestamp
                }
                if leftOrder.suffix != rightOrder.suffix {
                    return leftOrder.suffix > rightOrder.suffix
                }
                return $0.0 > $1.0
            } // Sort by date, newest first, then by collision suffix
            
            // Keep only the specified number of backup files
            let logsToDelete = sortedBackupLogs.dropFirst(maxLogFiles)
            
            for (fileName, _) in logsToDelete {
                let filePath = "\(logDirectory)/\(fileName)"
                do {
                    try fileManager.removeItem(atPath: filePath)
                    // Note: We can't use logDebug here as it might cause recursion
                    // Instead, we'll use print directly for cleanup logs
                    if !suppressConsoleLogging {
                        print("[\(formattedTimestamp())] [INFO] Cleaned up old log file: \(fileName)")
                    }
                } catch {
                    // Similarly, avoid using logError here
                    if !suppressConsoleLogging {
                        print("[\(formattedTimestamp())] [ERROR] Failed to delete old log file \(fileName): \(error)")
                    }
                }
            }
            
        } catch {
            // Avoid using logError here to prevent potential recursion
            if !suppressConsoleLogging {
                print("[\(formattedTimestamp())] [ERROR] Failed to read log directory for cleanup: \(error)")
            }
        }
    }

    private func rotationSortComponents(for fileName: String, logFileName: String) -> (timestamp: String, suffix: Int) {
        let rotationStem = String(fileName.dropFirst(logFileName.count + 1))
        let components = rotationStem.split(separator: ".", omittingEmptySubsequences: false)
        if components.count > 1, let suffix = Int(components.last ?? "") {
            return (components.dropLast().joined(separator: "."), suffix)
        }
        return (rotationStem, 0)
    }
    
    enum LogLevel: String, CaseIterable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
        
        var priority: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warning: return 2
            case .error: return 3
            }
        }
    }
}

// MARK: - Helper functions for logging and notifications

/// Process-wide logger instance initialized from main.swift.
var logger: Logger!

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

func isVerboseLogDetailEnabled() -> Bool {
    logDetailMode == .verbose
}

func redactForLogs(_ value: String?) -> String {
    guard let value = value else {
        return "nil"
    }
    if !redactedLogsEnabled {
        return value
    }
    return value.isEmpty ? "[REDACTED empty]" : "[REDACTED len=\(value.count)]"
}

func redactAnyForLogs(_ value: Any?) -> String {
    guard let value = value else {
        return "nil"
    }
    if let stringValue = value as? String {
        return redactForLogs(stringValue)
    }
    if value is NSNull {
        return "null"
    }
    if !redactedLogsEnabled {
        return String(describing: value)
    }
    return "[REDACTED]"
}

func summarizeForLogs(_ value: String?, maxPreview: Int = 160) -> String {
    guard let value = value else {
        return "nil"
    }
    if redactedLogsEnabled {
        return value.isEmpty ? "[REDACTED empty]" : "[REDACTED len=\(value.count)]"
    }
    let sanitized = value
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: "\\t")
    let limitedPreview: String
    if sanitized.count > maxPreview {
        limitedPreview = String(sanitized.prefix(maxPreview))
    } else {
        limitedPreview = sanitized
    }
    let truncated = sanitized.count > maxPreview
    return "[len=\(value.count) truncated=\(truncated) preview=\"\(limitedPreview)\"]"
}

func summarizeAnyForLogs(_ value: Any?, maxPreview: Int = 160) -> String {
    guard let value = value else {
        return "nil"
    }
    if let stringValue = value as? String {
        return summarizeForLogs(stringValue, maxPreview: maxPreview)
    }
    if value is NSNull {
        return "null"
    }
    if !redactedLogsEnabled {
        return String(describing: value)
    }
    return "[REDACTED]"
}

func shouldEmitRateLimitedLog(key: String, cooldown: TimeInterval) -> Bool {
    logSuppressionQueue.sync {
        let now = Date()
        if let lastEmitted = rateLimitedLogState[key], now.timeIntervalSince(lastEmitted) < cooldown {
            return false
        }
        rateLimitedLogState[key] = now
        return true
    }
}
