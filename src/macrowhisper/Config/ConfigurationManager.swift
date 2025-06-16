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
    private var lastInternalSaveTime: Date?
    
    init(configPath: String?) {
        let defaultConfigPath = ("~/.config/macrowhisper/macrowhisper.json" as NSString).expandingTildeInPath
        self.configPath = configPath ?? defaultConfigPath
        
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
            
            // Validate activeInsert after loading config
            _config = config // update _config so validation uses latest
            validateActiveInsertAndNotifyIfNeeded()
            
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
        logDebug("saveConfig() called")
        
        // Don't overwrite an existing file that failed to load (has invalid JSON)
        // BUT: Don't reload the config here as that would overwrite our in-memory changes!
        if fileManager.fileExists(atPath: configPath) {
            logDebug("Config file exists, checking if JSON is valid without reloading...")
            // Just check if the file can be parsed without overwriting our _config
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
                _ = try JSONDecoder().decode(AppConfiguration.self, from: data)
                logDebug("Existing config file is valid JSON, proceeding with save")
            } catch {
                logWarning("Not saving configuration because the existing file has invalid JSON that needs to be fixed manually")
                logWarning("JSON error: \(error.localizedDescription)")
                return
            }
        } else {
            logDebug("Config file doesn't exist, proceeding with save")
        }
        
        // Record the time of this internal save to distinguish from external changes
        lastInternalSaveTime = Date()
        logDebug("Recorded internal save time: \(lastInternalSaveTime!)")
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        // Create a custom encoding strategy for paths
        let pathEncodingStrategy: JSONEncoder.KeyEncodingStrategy = .useDefaultKeys
        encoder.keyEncodingStrategy = pathEncodingStrategy
        
        do {
            logDebug("Encoding configuration to JSON...")
            logDebug("Current activeInsert value before encoding: '\(_config.defaults.activeInsert ?? "nil")'")
            let data = try encoder.encode(_config)
            logDebug("Configuration encoded successfully, size: \(data.count) bytes")
            
            // Convert the data to a string to handle path formatting
            if let jsonString = String(data: data, encoding: .utf8) {
                logDebug("JSON string created successfully")
                // Replace escaped forward slashes with regular forward slashes
                let formattedJson = jsonString.replacingOccurrences(of: "\\/", with: "/")
                // Write the formatted JSON back to data
                if let formattedData = formattedJson.data(using: .utf8) {
                    logDebug("Formatted JSON data created, size: \(formattedData.count) bytes")
                    let configDir = (configPath as NSString).deletingLastPathComponent
                    logDebug("Config directory: \(configDir)")
                    
                    if !fileManager.fileExists(atPath: configDir) {
                        logDebug("Creating config directory...")
                        try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
                        logDebug("Config directory created successfully")
                    } else {
                        logDebug("Config directory already exists")
                    }
                    
                    // Use atomic writing with temporary file to avoid conflicts
                    let tempPath = configPath + ".temp"
                    logDebug("Writing to temporary file: \(tempPath)")
                    try formattedData.write(to: URL(fileURLWithPath: tempPath))
                    logDebug("Temporary file written successfully")
                    
                    // Atomically move the temporary file to the final location
                    logDebug("Moving temporary file to final location: \(configPath)")
                    _ = try fileManager.replaceItem(at: URL(fileURLWithPath: configPath), 
                                                    withItemAt: URL(fileURLWithPath: tempPath), 
                                                    backupItemName: nil, 
                                                    options: [], 
                                                    resultingItemURL: nil)
                    
                    logDebug("Configuration saved successfully to \(configPath)")
                } else {
                    logError("Failed to create formatted JSON data")
                }
            } else {
                logError("Failed to convert encoded data to JSON string")
            }
        } catch {
            // Clean up temporary file if it exists
            let tempPath = configPath + ".temp"
            if fileManager.fileExists(atPath: tempPath) {
                try? fileManager.removeItem(atPath: tempPath)
            }
            
            logError("Failed to save configuration: \(error.localizedDescription)")
            notify(title: "Macrowhisper", message: "Failed to save configuration: \(error.localizedDescription)")
        }
    }
    
    func updateFromCommandLine(watchPath: String? = nil, watcher: Bool? = nil, noUpdates: Bool? = nil, noNoti: Bool? = nil, activeInsert: String? = nil, icon: String? = nil, moveTo: String? = nil, noEsc: Bool? = nil, simKeypress: Bool? = nil, history: Int?? = nil, pressReturn: Bool? = nil, actionDelay: Double? = nil, returnDelay: Double? = nil) {
        
        logDebug("updateFromCommandLine called with activeInsert: \(activeInsert ?? "nil")")
        
        var shouldSave = false
        
        if let watchPath = watchPath { 
            logDebug("Setting watch path to: \(watchPath)")
            _config.defaults.watch = watchPath; shouldSave = true 
        }
        if let noUpdates = noUpdates { 
            logDebug("Setting noUpdates to: \(noUpdates)")
            _config.defaults.noUpdates = noUpdates; shouldSave = true 
        }
        if let noNoti = noNoti { 
            logDebug("Setting noNoti to: \(noNoti)")
            _config.defaults.noNoti = noNoti; shouldSave = true 
        }
        if let activeInsert = activeInsert { 
            logDebug("Setting activeInsert to: '\(activeInsert)'")
            _config.defaults.activeInsert = activeInsert.isEmpty ? "" : activeInsert; shouldSave = true 
        }
        if let icon = icon { 
            logDebug("Setting icon to: \(icon)")
            _config.defaults.icon = icon.isEmpty ? nil : icon; shouldSave = true 
        }
        if let moveTo = moveTo { 
            logDebug("Setting moveTo to: \(moveTo)")
            _config.defaults.moveTo = moveTo; shouldSave = true 
        }
        if let noEsc = noEsc { 
            logDebug("Setting noEsc to: \(noEsc)")
            _config.defaults.noEsc = noEsc; shouldSave = true 
        }
        if let simKeypress = simKeypress { 
            logDebug("Setting simKeypress to: \(simKeypress)")
            _config.defaults.simKeypress = simKeypress; shouldSave = true 
        }
        if let pressReturn = pressReturn { 
            logDebug("Setting pressReturn to: \(pressReturn)")
            _config.defaults.pressReturn = pressReturn; shouldSave = true 
        }
        if let actionDelay = actionDelay { 
            logDebug("Setting actionDelay to: \(actionDelay)")
            _config.defaults.actionDelay = actionDelay; shouldSave = true 
        }
        if let returnDelay = returnDelay { 
            logDebug("Setting returnDelay to: \(returnDelay)")
            _config.defaults.returnDelay = returnDelay; shouldSave = true 
        }

        if let history = history {
            logDebug("Setting history to: \(String(describing: history))")
            _config.defaults.history = history
            shouldSave = true
        }

        logDebug("shouldSave is: \(shouldSave)")

        // Validate activeInsert after updating config
        validateActiveInsertAndNotifyIfNeeded()

        if shouldSave {
            logDebug("Calling saveConfig() because shouldSave is true")
            saveConfig()
        } else {
            logDebug("NOT calling saveConfig() because shouldSave is false")
        }
    }

    func updateFromCommandLineAsync(arguments: [String: String], completion: (() -> Void)?) {
        logDebug("updateFromCommandLineAsync called with arguments: \(arguments)")
        
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            
            logDebug("Processing arguments in syncQueue...")
            
            self.updateFromCommandLine(
                watchPath: arguments["watch"],  // Fixed: use "watch" instead of "watchPath"
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
                actionDelay: arguments["actionDelay"].flatMap { Double($0) },  // Added missing actionDelay
                returnDelay: arguments["returnDelay"].flatMap { Double($0) }
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
            logDebug("Configuration file change detected. Checking if external change.")
            guard let self = self else { return }
            
            // Check if this change happened very recently after our internal save
            let now = Date()
            if let lastSave = self.lastInternalSaveTime, 
               now.timeIntervalSince(lastSave) < 2.0 {  // Within 2 seconds of our save
                logDebug("Ignoring file change - likely from our own save (\(now.timeIntervalSince(lastSave)) seconds ago)")
                return
            }
            
            logDebug("Processing external file change...")
            
            // Add a small delay to ensure any atomic file operations are complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.syncQueue.async {
                    if let newConfig = self.loadConfig() {
                        self._config = newConfig
                        self.configurationSuccessfullyLoaded()
                        DispatchQueue.main.async {
                            self.onConfigChanged?("configFileChanged")
                        }
                        logDebug("Configuration automatically reloaded after external file change")
                    } else {
                        logError("Failed to reload configuration after file change")
                        // Notify user if reload fails (but not for JSON error, which is already handled)
                        DispatchQueue.main.async {
                            notify(title: "Macrowhisper", message: "Failed to reload configuration after file change. Please check your configuration file.")
                        }
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
