import Foundation

class ConfigurationManager {
    private var _config: AppConfiguration
    var config: AppConfiguration {
        get {
            syncQueue.sync {
                return _config
            }
        }
        set {
            syncQueue.sync {
                _config = newValue
            }
        }
    }
    
    private var configPath: String
    var onConfigChanged: ((String?) -> Void)?
    
    private let fileManager = FileManager.default
    private let syncQueue = DispatchQueue(label: "com.macrowhisper.configsync")
    private var fileWatcher: ConfigChangeWatcher?
    private let commandQueue = DispatchQueue(label: "com.macrowhisper.commandqueue", qos: .userInitiated)
    private var pendingCommands: [(arguments: [String: String], completion: (() -> Void)?)] = []
    private var isProcessingCommands = false
    
    // Add properties to track JSON error state and prevent reload loops
    private var hasNotifiedAboutJsonError = false
    private var suppressNextConfigReload = false
    
    // UserDefaults for persistent config path storage
    private static let userDefaultsKey = "MacrowhisperConfigPath"
    private static let appDefaults = UserDefaults(suiteName: "com.macrowhisper.preferences") ?? UserDefaults.standard
    
    init(configPath: String?) {
        let defaultConfigPath = ("~/.config/macrowhisper/macrowhisper.json" as NSString).expandingTildeInPath
        
        // Priority order:
        // 1. Explicitly provided configPath parameter (--config flag)
        // 2. Saved user preference 
        // 3. Default path
        if let explicitPath = configPath {
            self.configPath = Self.normalizeConfigPath(explicitPath)
            // Save this as the user's preferred path for future runs
            Self.appDefaults.set(self.configPath, forKey: Self.userDefaultsKey)
            logDebug("Using explicit config path: \(self.configPath)")
        } else if let savedPath = Self.appDefaults.string(forKey: Self.userDefaultsKey),
                  !savedPath.isEmpty {
            self.configPath = savedPath
            logDebug("Using saved config path: \(savedPath)")
        } else {
            self.configPath = defaultConfigPath
            logDebug("Using default config path: \(defaultConfigPath)")
        }
        
        // Initialize with default config first
        self._config = AppConfiguration()
        
        // Check if config file exists before attempting to load
        let fileExistedBefore = fileManager.fileExists(atPath: self.configPath)
        
        if fileExistedBefore {
            // If file exists, attempt to load it
            if let loadedConfig = Self.loadConfig(from: self.configPath) {
                self._config = loadedConfig
                logDebug("Configuration loaded from \(self.configPath)")
                // Reset notification flag on successful load
                hasNotifiedAboutJsonError = false
            } else {
                // If loading fails but file exists, don't overwrite it - show notification
                logWarning("Failed to load configuration due to invalid JSON. Using defaults in memory only.")
                showJsonErrorNotification()
            }
        } else {
            // File doesn't exist, create it with defaults
            logInfo("No configuration file found at \(self.configPath). Creating a new one with default settings.")
            syncQueue.async {
                self.saveConfig()
            }
        }
        
        setupFileWatcher()
    }
    
    // Static method to normalize config path (handle folders vs files)
    static func normalizeConfigPath(_ path: String) -> String {
        let expandedPath = (path as NSString).expandingTildeInPath
        
        // Check if the path points to a directory
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                // Path points to a directory, append the default filename
                return (expandedPath as NSString).appendingPathComponent("macrowhisper.json")
            }
        } else {
            // Path doesn't exist yet - check if it ends with a directory-like pattern
            let lastComponent = (expandedPath as NSString).lastPathComponent
            if !lastComponent.contains(".") {
                // Looks like a directory path, append the default filename
                return (expandedPath as NSString).appendingPathComponent("macrowhisper.json")
            }
        }
        
        // Path points to a file or looks like a file path
        return expandedPath
    }
    
    // Method to set a new default config path
    static func setDefaultConfigPath(_ path: String) -> Bool {
        let normalizedPath = normalizeConfigPath(path)
        let parentDir = (normalizedPath as NSString).deletingLastPathComponent
        
        // Validate that the parent directory exists or can be created
        do {
            if !FileManager.default.fileExists(atPath: parentDir) {
                try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true, attributes: nil)
            }
            appDefaults.set(normalizedPath, forKey: userDefaultsKey)
            return true
        } catch {
            return false
        }
    }
    
    // Method to reset to default config path
    static func resetToDefaultConfigPath() {
        appDefaults.removeObject(forKey: userDefaultsKey)
    }
    
    // Method to get current saved config path
    static func getSavedConfigPath() -> String? {
        return appDefaults.string(forKey: userDefaultsKey)
    }
    
    // Method to get the config path that would be used (for --get-config)
    static func getEffectiveConfigPath() -> String {
        if let savedPath = getSavedConfigPath(), !savedPath.isEmpty {
            return savedPath
        } else {
            return ("~/.config/macrowhisper/macrowhisper.json" as NSString).expandingTildeInPath
        }
    }
    
    // Method to get current config path from instance
    func getCurrentConfigPath() -> String {
        return configPath
    }
    
    private static func loadConfig(from path: String) -> AppConfiguration? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        let decoder = JSONDecoder()
        return try? decoder.decode(AppConfiguration.self, from: data)
    }

    func loadConfig() -> AppConfiguration? {
        guard fileManager.fileExists(atPath: configPath) else {
            return nil
        }
        
        do {
            // Create a fresh URL with no caching
            let url = URL(fileURLWithPath: configPath)
            let data = try Data(contentsOf: url, options: .uncached)
            let decoder = JSONDecoder()
            let config = try decoder.decode(AppConfiguration.self, from: data)
            
            // JSON loaded successfully, reset notification flag
            hasNotifiedAboutJsonError = false
            

            
            return config
        } catch {
            // Log the error
            logError("Error loading configuration: \(error.localizedDescription)")
            
            // Show notification if we haven't already notified
            showJsonErrorNotification()
            
            return nil
        }
    }
    
    private func showJsonErrorNotification() {
        // Only show notification if we haven't already notified
        if !hasNotifiedAboutJsonError {
            hasNotifiedAboutJsonError = true
            
            // Show a comprehensive notification
            notify(title: "Macrowhisper - Configuration Error",
                   message: "Your configuration file contains invalid JSON. Please fix.")
            
            // Reset the file watcher to recover from JSON error
            resetFileWatcher()
        }
    }
    
    func saveConfig() {
        // Don't overwrite an existing file that failed to load (has invalid JSON)
        if fileManager.fileExists(atPath: configPath) &&
            loadConfig() == nil {
            logWarning("Not saving configuration because the existing file has invalid JSON that needs to be fixed manually")
            // Don't show another notification here - we've already notified in loadConfig()
            return
        }
        
        // Set suppression flag before writing config to prevent reload loop
        suppressNextConfigReload = true
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        // Create a custom encoding strategy for paths
        let pathEncodingStrategy: JSONEncoder.KeyEncodingStrategy = .useDefaultKeys
        encoder.keyEncodingStrategy = pathEncodingStrategy
        
        do {
            let data = try encoder.encode(_config)
            // Convert the data to a string to handle path formatting
            if let jsonString = String(data: data, encoding: .utf8) {
                // Replace escaped forward slashes with regular forward slashes
                let formattedJson = jsonString.replacingOccurrences(of: "\\/", with: "/")
                // Write the formatted JSON back to data
                if let formattedData = formattedJson.data(using: .utf8) {
                    let configDir = (configPath as NSString).deletingLastPathComponent
                    if !fileManager.fileExists(atPath: configDir) {
                        try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
                    }
                    try formattedData.write(to: URL(fileURLWithPath: configPath))
                    logDebug("Configuration saved to \(configPath)")
                }
            }
        } catch {
            logError("Failed to save configuration: \(error.localizedDescription)")
            notify(title: "Macrowhisper", message: "Failed to save configuration: \(error.localizedDescription)")
        }
    }
    
    func updateFromCommandLine(watchPath: String? = nil, watcher: Bool? = nil, noUpdates: Bool? = nil, noNoti: Bool? = nil, activeInsert: String? = nil, icon: String? = nil, moveTo: String? = nil, noEsc: Bool? = nil, simKeypress: Bool? = nil, history: Int?? = nil, pressReturn: Bool? = nil, actionDelay: Double? = nil, returnDelay: Double? = nil, restoreClipboard: Bool? = nil) {
        
        var shouldSave = false
        
        if let watchPath = watchPath { _config.defaults.watch = watchPath; shouldSave = true }
        if let noUpdates = noUpdates { _config.defaults.noUpdates = noUpdates; shouldSave = true }
        if let noNoti = noNoti { _config.defaults.noNoti = noNoti; shouldSave = true }
        if let activeInsert = activeInsert { _config.defaults.activeInsert = activeInsert.isEmpty ? "" : activeInsert; shouldSave = true }
        if let icon = icon { _config.defaults.icon = icon; shouldSave = true }
        if let moveTo = moveTo { _config.defaults.moveTo = moveTo; shouldSave = true }
        if let noEsc = noEsc { _config.defaults.noEsc = noEsc; shouldSave = true }
        if let simKeypress = simKeypress { _config.defaults.simKeypress = simKeypress; shouldSave = true }
        if let pressReturn = pressReturn { _config.defaults.pressReturn = pressReturn; shouldSave = true }
        if let actionDelay = actionDelay { _config.defaults.actionDelay = actionDelay; shouldSave = true }
        if let returnDelay = returnDelay { _config.defaults.returnDelay = returnDelay; shouldSave = true }
        if let restoreClipboard = restoreClipboard { _config.defaults.restoreClipboard = restoreClipboard; shouldSave = true }

        if let history = history {
            _config.defaults.history = history
            shouldSave = true
        }

        // Validate activeInsert after updating config
        validateActiveInsertAndNotifyIfNeeded()

        if shouldSave {
            saveConfig()
        }
    }

    func updateFromCommandLineAsync(arguments: [String: String], completion: (() -> Void)?) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.updateFromCommandLine(
                watchPath: arguments["watchPath"],
                watcher: arguments["watcher"].flatMap { Bool($0) },
                noUpdates: arguments["noUpdates"].flatMap { Bool($0) },
                noNoti: arguments["noNoti"].flatMap { Bool($0) },
                activeInsert: arguments["activeInsert"],
                icon: arguments["icon"],
                moveTo: arguments["moveTo"],
                noEsc: arguments["noEsc"].flatMap { Bool($0) },
                simKeypress: arguments["simKeypress"].flatMap { Bool($0) },
                history: arguments["history"].map { $0 == "null" ? nil : Int($0) } as Int??,
                pressReturn: arguments["pressReturn"].flatMap { Bool($0) },
                actionDelay: arguments["actionDelay"].flatMap { Double($0) },
                returnDelay: arguments["returnDelay"].flatMap { Double($0) },
                restoreClipboard: arguments["restoreClipboard"].flatMap { Bool($0) }
            )
            
            DispatchQueue.main.async {
                completion?()
                self.onConfigChanged?("commandLineUpdate")
            }
        }
    }
    
    private func setupFileWatcher() {
        fileWatcher?.stop()
        
        logDebug("Setting up file watcher for configuration at: \(configPath)")
        
        fileWatcher = ConfigChangeWatcher(filePath: configPath, onChanged: { [weak self] in
            logDebug("Configuration file change detected. Reloading.")
            guard let self = self else { return }
            
            // Suppress reload if this was an internal config write
            if self.suppressNextConfigReload {
                logDebug("Suppressed config reload after internal write.")
                self.suppressNextConfigReload = false
                return
            }
            
            self.syncQueue.async {
                if let newConfig = self.loadConfig() {
                    self._config = newConfig
                    self.configurationSuccessfullyLoaded()
                    // Validate activeInsert after loading config from external file change
                    self.validateActiveInsertAndNotifyIfNeeded()
                    DispatchQueue.main.async {
                        self.onConfigChanged?("configFileChanged")
                    }
                    logDebug("Configuration automatically reloaded after file change")
                } else {
                    logError("Failed to reload configuration after file change")
                    // Notify user if reload fails (but not for JSON error, which is already handled)
                    DispatchQueue.main.async {
                        notify(title: "Macrowhisper", message: "Failed to reload configuration after file change. Please check your configuration file.")
                    }
                }
            }
        })
        
        fileWatcher?.start()
    }

    func resetFileWatcher() {
        logDebug("Resetting file watcher due to previous JSON error...")
        
        // Stop and clean up the current file watcher
        fileWatcher?.stop()
        fileWatcher = nil
        
        // Set up a new file watcher with a small delay to ensure clean state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.setupFileWatcher()
            logDebug("File watcher has been reset and reinitialized")
        }
    }

    func configurationSuccessfullyLoaded() {
        // Reset the notification flag when config is successfully reloaded
        hasNotifiedAboutJsonError = false
    }
    
    func getHistoryRetentionDays() -> Int? {
        return syncQueue.sync {
            _config.defaults.history
        }
    }
    
    // MARK: - Validation for activeInsert
    /// Checks if the activeInsert in config.defaults exists in config.inserts. Notifies user if not.
    private func validateActiveInsertAndNotifyIfNeeded() {
        let activeInsert = _config.defaults.activeInsert ?? ""
        if !activeInsert.isEmpty && _config.inserts[activeInsert] == nil {
            notify(title: "Macrowhisper - Invalid Insert",
                   message: "Your configuration references an active insert named '\(activeInsert)', but no such insert exists. Please check your configuration.")
        }
    }

} 
