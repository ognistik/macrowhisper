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
        self._config = AppConfiguration.defaultConfig()
        
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
                logDebug("About to create configuration file at \(self.configPath)")
                self.saveConfig()
                if self.fileManager.fileExists(atPath: self.configPath) {
                    logDebug("Configuration file successfully created")
                } else {
                    logError("Failed to create configuration file at \(self.configPath)")
                }
            }
        }
        
        // Always set up file watcher - it's now smart enough to handle both existing and non-existing files
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
    
    /// Post-process JSON string to round all floating point numbers to 3 decimal places
    private func roundDoublesInJson(_ jsonString: String) -> String {
        // This regex matches numbers with a decimal point and more than 3 decimals (not in scientific notation)
        let pattern = "(-?\\d+\\.\\d{4,})(?![\\deE])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { 
            return jsonString 
        }
        
        let nsrange = NSRange(jsonString.startIndex..<jsonString.endIndex, in: jsonString)
        var result = jsonString
        let matches = regex.matches(in: jsonString, options: [], range: nsrange)
        
        for match in matches.reversed() {
            if let range = Range(match.range, in: result) {
                let numberString = String(result[range])
                if let number = Double(numberString) {
                    // Round to 3 decimal places, but remove trailing zeros using NumberFormatter
                    let formatter = NumberFormatter()
                    formatter.minimumFractionDigits = 0
                    formatter.maximumFractionDigits = 3
                    formatter.numberStyle = .decimal
                    formatter.usesGroupingSeparator = false
                    
                    if let formatted = formatter.string(from: NSNumber(value: number)) {
                        result.replaceSubrange(range, with: formatted)
                    }
                }
            }
        }
        
        return result
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
        encoder.keyEncodingStrategy = .useDefaultKeys
        do {
            let data = try encoder.encode(_config)
            if let jsonString = String(data: data, encoding: .utf8) {
                var formattedJson = jsonString.replacingOccurrences(of: "\\/", with: "/")
                formattedJson = roundDoublesInJson(formattedJson)
                
                // Auto-manage schema reference for seamless IDE integration
                // This provides automatic schema management without user intervention
                var finalJson = formattedJson
                let currentSchemaRef = SchemaManager.getSchemaReference()
                
                // Check if schema exists in the JSON we're about to write (more reliable than reading from disk)
                var hasExistingSchema = false
                var existingSchemaRef: String? = nil
                
                if let jsonData = formattedJson.data(using: .utf8),
                   let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    existingSchemaRef = jsonObject["$schema"] as? String
                    hasExistingSchema = existingSchemaRef != nil
                }
                
                logDebug("Schema management check:")
                logDebug("  - hasExistingSchema: \(hasExistingSchema)")
                logDebug("  - existingSchemaRef: \(existingSchemaRef ?? "nil")")
                logDebug("  - currentSchemaRef: \(currentSchemaRef ?? "nil")")
                
                var shouldUpdateSchema = false
                var schemaAction = ""
                
                if hasExistingSchema && currentSchemaRef != nil {
                    // Validate existing schema reference is still correct
                    if existingSchemaRef != currentSchemaRef {
                        shouldUpdateSchema = true
                        schemaAction = "Updated"
                        logDebug("Schema reference needs updating: \(existingSchemaRef!) -> \(currentSchemaRef!)")
                    } else {
                        logDebug("Schema reference is already correct, no update needed")
                    }
                } else if !hasExistingSchema && currentSchemaRef != nil {
                    // Add schema reference if not present and schema file is available
                    shouldUpdateSchema = true
                    schemaAction = "Added"
                    logDebug("Auto-adding schema reference to configuration")
                }
                
                if shouldUpdateSchema, let schemaRef = currentSchemaRef {
                    // Parse the JSON, add/update schema, and re-serialize
                    if let jsonData = formattedJson.data(using: .utf8),
                       var jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        jsonObject["$schema"] = schemaRef
                        if let updatedData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
                           let updatedString = String(data: updatedData, encoding: .utf8) {
                            finalJson = updatedString.replacingOccurrences(of: "\\/", with: "/")
                            finalJson = roundDoublesInJson(finalJson)  // Apply rounding again after re-serialization
                            logInfo("\(schemaAction) schema reference for IDE validation: \(schemaRef)")
                        }
                    }
                }
                
                // Write the formatted JSON back to data
                if let formattedData = finalJson.data(using: .utf8) {
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
    
    func updateFromCommandLine(watcher: Bool? = nil, activeAction: String? = nil) {
        
        var shouldSave = false
        
        if let activeAction = activeAction { _config.defaults.activeAction = activeAction.isEmpty ? "" : activeAction; shouldSave = true }

        // Validate activeAction after updating config
        validateActiveActionAndNotifyIfNeeded()

        if shouldSave {
            saveConfig()
        }
    }

    func updateFromCommandLineAsync(arguments: [String: String], completion: (() -> Void)?) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.updateFromCommandLine(
                watcher: arguments["watcher"].flatMap { Bool($0) },
                activeAction: arguments["activeAction"]
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
                    // Validate activeAction after loading config from external file change
                    self.validateActiveActionAndNotifyIfNeeded()
                    DispatchQueue.main.async {
                        self.onConfigChanged?("configFileChanged")
                    }
                    logDebug("Configuration automatically reloaded after file change")
                } else {
                    logError("Failed to reload configuration after file change")
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
    
    // MARK: - Validation for activeAction
    /// Checks if the activeAction in config.defaults exists across all action types. Notifies user if not.
    private func validateActiveActionAndNotifyIfNeeded() {
        let activeActionName = _config.defaults.activeAction ?? ""
        if !activeActionName.isEmpty {
            let actionExists = _config.inserts[activeActionName] != nil ||
                              _config.urls[activeActionName] != nil ||
                              _config.shortcuts[activeActionName] != nil ||
                              _config.scriptsShell[activeActionName] != nil ||
                              _config.scriptsAS[activeActionName] != nil
            
            if !actionExists {
                notify(title: "Macrowhisper - Invalid Action",
                       message: "Your configuration references an active action named '\(activeActionName)', but no such action exists. Please check your configuration.")
            }
        }
    }
    
    // MARK: - Configuration Update
    /// Updates the configuration file by reloading from disk and re-saving
    /// This ensures the configuration is updated with any new schema changes or defaults
    /// while preserving user data
    func updateConfiguration() -> Bool {
        logInfo("Updating configuration file...")
        
        // First, try to load the current configuration from disk
        guard let currentConfig = loadConfig() else {
            logError("Failed to load current configuration for update")
            return false
        }
        
        // Update our in-memory config with the loaded data
        syncQueue.sync {
            _config = currentConfig
        }
        
        // Save the configuration, which will apply any new schema changes and formatting
        saveConfig()
        
        logInfo("Configuration file updated successfully")
        return true
    }

} 
