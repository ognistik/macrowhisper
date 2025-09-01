import Foundation

/// Unified UserDefaults manager for macrowhisper
/// Ensures all preferences are stored in a single, consistent domain
/// regardless of how the app is launched (Xcode, Terminal, Homebrew, etc.)
class UserDefaultsManager {
    
    // MARK: - Singleton
    static let shared = UserDefaultsManager()
    
    // MARK: - Constants
    private static let suiteName = "com.macrowhisper.preferences"
    
    // MARK: - UserDefaults Suite
    private let userDefaults: UserDefaults
    
    // MARK: - Key Definitions
    /// Configuration-related keys
    struct ConfigKeys {
        static let configPath = "MacrowhisperConfigPath"
    }
    
    /// Update system keys
    struct UpdateKeys {
        static let lastCheckDate = "com.macrowhisper.updates.lastCheckDate"
        static let lastFailedCheckDate = "com.macrowhisper.updates.lastFailedCheckDate"
        static let lastReminderDate = "com.macrowhisper.updates.lastReminderDate"
        static let lastRemindedVersion = "com.macrowhisper.updates.lastRemindedVersion"
    }
    
    // MARK: - Initialization
    private init() {
        // Use dedicated suite with fallback to standard if suite creation fails
        self.userDefaults = UserDefaults(suiteName: Self.suiteName) ?? UserDefaults.standard
        
        // Log which UserDefaults we're actually using for debugging
        if UserDefaults(suiteName: Self.suiteName) != nil {
            logDebug("UserDefaultsManager: Using dedicated suite '\(Self.suiteName)'")
        } else {
            logWarning("UserDefaultsManager: Failed to create dedicated suite, falling back to standard UserDefaults")
        }
        
        // Perform one-time migration from scattered domains
        migrateFromScatteredDomains()
    }
    
    // MARK: - Configuration Methods
    
    /// Get the saved configuration path
    func getConfigPath() -> String? {
        return userDefaults.string(forKey: ConfigKeys.configPath)
    }
    
    /// Set the configuration path
    func setConfigPath(_ path: String) {
        userDefaults.set(path, forKey: ConfigKeys.configPath)
        synchronize()
    }
    
    /// Remove the saved configuration path
    func removeConfigPath() {
        userDefaults.removeObject(forKey: ConfigKeys.configPath)
        synchronize()
    }
    
    // MARK: - Update System Methods
    
    /// Get last update check date
    func getLastCheckDate() -> Date? {
        let timestamp = userDefaults.double(forKey: UpdateKeys.lastCheckDate)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }
    
    /// Set last update check date
    func setLastCheckDate(_ date: Date?) {
        if let date = date {
            userDefaults.set(date.timeIntervalSince1970, forKey: UpdateKeys.lastCheckDate)
        } else {
            userDefaults.removeObject(forKey: UpdateKeys.lastCheckDate)
        }
        synchronize()
    }
    
    /// Get last failed check date
    func getLastFailedCheckDate() -> Date? {
        let timestamp = userDefaults.double(forKey: UpdateKeys.lastFailedCheckDate)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }
    
    /// Set last failed check date
    func setLastFailedCheckDate(_ date: Date?) {
        if let date = date {
            userDefaults.set(date.timeIntervalSince1970, forKey: UpdateKeys.lastFailedCheckDate)
        } else {
            userDefaults.removeObject(forKey: UpdateKeys.lastFailedCheckDate)
        }
        synchronize()
    }
    
    /// Get last reminder date
    func getLastReminderDate() -> Date? {
        let timestamp = userDefaults.double(forKey: UpdateKeys.lastReminderDate)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }
    
    /// Set last reminder date
    func setLastReminderDate(_ date: Date?) {
        if let date = date {
            userDefaults.set(date.timeIntervalSince1970, forKey: UpdateKeys.lastReminderDate)
        } else {
            userDefaults.removeObject(forKey: UpdateKeys.lastReminderDate)
        }
        synchronize()
    }
    
    /// Get last reminded version
    func getLastRemindedVersion() -> String? {
        let version = userDefaults.string(forKey: UpdateKeys.lastRemindedVersion)
        return version?.isEmpty == false ? version : nil
    }
    
    /// Set last reminded version
    func setLastRemindedVersion(_ version: String?) {
        if let version = version {
            userDefaults.set(version, forKey: UpdateKeys.lastRemindedVersion)
        } else {
            userDefaults.removeObject(forKey: UpdateKeys.lastRemindedVersion)
        }
        synchronize()
    }
    
    // MARK: - Utility Methods
    
    /// Force synchronization to disk
    private func synchronize() {
        userDefaults.synchronize()
    }
    
    /// Clear all update-related UserDefaults (for debugging)
    func clearAllUpdateDefaults() {
        userDefaults.removeObject(forKey: UpdateKeys.lastCheckDate)
        userDefaults.removeObject(forKey: UpdateKeys.lastFailedCheckDate)
        userDefaults.removeObject(forKey: UpdateKeys.lastReminderDate)
        userDefaults.removeObject(forKey: UpdateKeys.lastRemindedVersion)
        synchronize()
        logDebug("All update-related UserDefaults cleared from unified domain")
    }
    
    /// Get debug state string for all preferences
    func getDebugStateString() -> String {
        var lines: [String] = []
        lines.append("=== UserDefaults State (Unified Domain) ===")
        lines.append("Suite: \(Self.suiteName)")
        
        // Configuration
        lines.append("")
        lines.append("Configuration:")
        if let configPath = getConfigPath() {
            lines.append("  Config Path: \(configPath)")
        } else {
            lines.append("  Config Path: (not set)")
        }
        
        // Update system
        lines.append("")
        lines.append("Update System:")
        if let lastCheck = getLastCheckDate() {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            lines.append("  Last Check: \(formatter.string(from: lastCheck))")
        } else {
            lines.append("  Last Check: (never)")
        }
        
        if let lastFailed = getLastFailedCheckDate() {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            lines.append("  Last Failed: \(formatter.string(from: lastFailed))")
        } else {
            lines.append("  Last Failed: (never)")
        }
        
        if let lastReminder = getLastReminderDate() {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            lines.append("  Last Reminder: \(formatter.string(from: lastReminder))")
        } else {
            lines.append("  Last Reminder: (never)")
        }
        
        if let lastVersion = getLastRemindedVersion() {
            lines.append("  Last Version: \(lastVersion)")
        } else {
            lines.append("  Last Version: (never)")
        }
        
        // Raw values for debugging
        lines.append("")
        lines.append("Raw UserDefaults values:")
        lines.append("  \(UpdateKeys.lastCheckDate): \(userDefaults.double(forKey: UpdateKeys.lastCheckDate))")
        lines.append("  \(UpdateKeys.lastFailedCheckDate): \(userDefaults.double(forKey: UpdateKeys.lastFailedCheckDate))")
        lines.append("  \(UpdateKeys.lastReminderDate): \(userDefaults.double(forKey: UpdateKeys.lastReminderDate))")
        lines.append("  \(UpdateKeys.lastRemindedVersion): \(userDefaults.string(forKey: UpdateKeys.lastRemindedVersion) ?? "nil")")
        
        lines.append("==========================================")
        
        return lines.joined(separator: "\n")
    }
    
    // MARK: - Migration
    
    /// One-time migration from scattered UserDefaults domains
    private func migrateFromScatteredDomains() {
        // Only migrate if we haven't done so before and we have scattered data
        let migrationKey = "com.macrowhisper.migration.completed"
        if userDefaults.bool(forKey: migrationKey) {
            return // Already migrated
        }
        
        var migratedAny = false
        
        // Try to migrate from various scattered domains
        let scatteredDomains: [UserDefaults] = [
            UserDefaults(suiteName: "test-macrowhisper") ?? UserDefaults.standard,
            UserDefaults(suiteName: "downloaded-macrowhisper") ?? UserDefaults.standard,
            UserDefaults.standard // This will check the standard domain too
        ]
        
        for sourceDefaults in scatteredDomains {
            
            // Migrate old version checker keys
            let oldKeys = [
                "macrowhisper.lastCheckDate",
                "macrowhisper.lastFailedCheckDate", 
                "macrowhisper.lastReminderDate",
                "macrowhisper.lastRemindedVersion"
            ]
            
            let newKeys = [
                UpdateKeys.lastCheckDate,
                UpdateKeys.lastFailedCheckDate,
                UpdateKeys.lastReminderDate,
                UpdateKeys.lastRemindedVersion
            ]
            
            for (oldKey, newKey) in zip(oldKeys, newKeys) {
                // Only migrate if we don't already have the new key and the old key exists
                if userDefaults.object(forKey: newKey) == nil {
                    if oldKey.contains("Version") {
                        // String value
                        if let value = sourceDefaults.string(forKey: oldKey) {
                            userDefaults.set(value, forKey: newKey)
                            migratedAny = true
                            logDebug("Migrated \(oldKey) -> \(newKey): \(value)")
                        }
                    } else {
                        // Double value (timestamp)
                        let value = sourceDefaults.double(forKey: oldKey)
                        if value > 0 {
                            userDefaults.set(value, forKey: newKey)
                            migratedAny = true
                            logDebug("Migrated \(oldKey) -> \(newKey): \(value)")
                        }
                    }
                }
            }
        }
        
        if migratedAny {
            logInfo("Successfully migrated UserDefaults from scattered domains to unified domain")
            synchronize()
        }
        
        // Mark migration as completed
        userDefaults.set(true, forKey: migrationKey)
        synchronize()
    }
}