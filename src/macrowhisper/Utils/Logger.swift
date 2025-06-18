import Foundation

var suppressConsoleLogging = false

class Logger {
    private let logFilePath: String
    private let maxLogSize: Int = 5 * 1024 * 1024 // 5 MB in bytes
    private let dateFormatter: DateFormatter
    private let fileManager = FileManager.default
    private var consoleLogLevel: LogLevel = .info // Only show INFO and above in console by default
    
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
    
    /// Set the minimum log level to show in console (file logging is unaffected)
    func setConsoleLogLevel(_ level: LogLevel) {
        consoleLogLevel = level
    }
    
    func log(_ message: String, level: LogLevel = .info) {
        let timestamp = dateFormatter.string(from: Date())
        let logEntry = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
        
        // Print to console when running interactively AND console logging is not suppressed
        // AND the log level is at or above the console threshold
        if isatty(STDOUT_FILENO) != 0 && !suppressConsoleLogging && level.priority >= consoleLogLevel.priority {
            print(logEntry, terminator: "")
        }
        
        // Append to log file (this part stays the same - all levels go to file)
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
            logInfo("Log file rotated due to size limit")
        }
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
