import Foundation
import Cocoa

class HistoryManager {
    private let configManager: ConfigurationManager
    private var lastHistoryCheck: Date?
    private let historyCheckInterval: TimeInterval = 24 * 60 * 60 // 24 hours
    
    init(configManager: ConfigurationManager) {
        self.configManager = configManager
    }
    
    func shouldPerformHistoryCleanup() -> Bool {
        // Check if history management is enabled
        guard configManager.getHistoryRetentionDays() != nil else {
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
              let historyDays = configManager.getHistoryRetentionDays() else {
            return
        }
        
        logInfo("Starting history cleanup with \(historyDays) days retention")
        
        // Expand tilde in the watch path
        let expandedWatchPath = (configManager.config.defaults.watch as NSString).expandingTildeInPath
        let recordingsPath = expandedWatchPath + "/recordings"
        
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