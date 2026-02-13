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
    
    // UserDefaults for persistent config path storage - now using unified manager
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
            // Save this as the user's preferred path for future runs using unified manager
            UserDefaultsManager.shared.setConfigPath(self.configPath)
            logDebug("Using explicit config path: \(self.configPath)")
        } else if let savedPath = UserDefaultsManager.shared.getConfigPath(),
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
            // If file exists, attempt to load it (including semantic validation)
            if let loadedConfig = self.loadConfig() {
                self._config = loadedConfig
                logDebug("Configuration loaded from \(self.configPath)")
                // Reset notification flag on successful load
                hasNotifiedAboutJsonError = false
            } else {
                // If loading fails but file exists, don't overwrite it.
                // loadConfig() already emitted the correct notification.
                logWarning("Failed to load configuration. Using defaults in memory only.")
            }
        } else {
            // File doesn't exist, create it with defaults
            logInfo("No configuration file found at \(self.configPath). Creating a new one with default settings.")
            syncQueue.async {
                logDebug("About to create configuration file at \(self.configPath)")
                do {
                    try self.saveConfig()
                } catch {
                    logError("Failed to create initial configuration file: \(error)")
                }
                if self.fileManager.fileExists(atPath: self.configPath) {
                    logDebug("Configuration file successfully created")
                } else {
                    logError("Failed to create configuration file at \(self.configPath)")
                }
            }
        }
        
        // Always set up file watcher - it's now smart enough to handle both existing and non-existing files
        self.setupFileWatcher()
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
            UserDefaultsManager.shared.setConfigPath(normalizedPath)
            return true
        } catch {
            return false
        }
    }
    
    // Method to reset to default config path
    static func resetToDefaultConfigPath() {
        UserDefaultsManager.shared.removeConfigPath()
    }
    
    // Method to get current saved config path
    static func getSavedConfigPath() -> String? {
        return UserDefaultsManager.shared.getConfigPath()
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
        guard let decoded = try? decoder.decode(AppConfiguration.self, from: data) else {
            return nil
        }
        if let duplicateNames = findDuplicateActionNamesAcrossTypes(in: decoded), !duplicateNames.isEmpty {
            logError("Configuration validation failed: duplicate action names across types are not allowed: \(duplicateNames.sorted().joined(separator: ", "))")
            return nil
        }
        let validationErrors = collectConfigurationValidationErrors(in: decoded)
        if !validationErrors.isEmpty {
            logError("Configuration validation failed: \(validationErrors.joined(separator: " | "))")
            return nil
        }
        return decoded
    }

    /// Loads configuration with enhanced error handling and recovery mechanisms
    func loadConfig() -> AppConfiguration? {
        guard fileManager.fileExists(atPath: configPath) else {
            logDebug("Configuration file does not exist at \(configPath)")
            return nil
        }
        
        do {
            // Create a fresh URL with no caching
            let url = URL(fileURLWithPath: configPath)
            let data = try Data(contentsOf: url, options: .uncached)
            
            // Check if file is empty (common edge case)
            if data.isEmpty {
                logWarning("Configuration file is empty. Creating new configuration with defaults.")
                _ = createBackupAndReset(reason: "empty file")
                return AppConfiguration.defaultConfig()
            }
            
            let decoder = JSONDecoder()
            let config = try decoder.decode(AppConfiguration.self, from: data)
            if let duplicateNames = Self.findDuplicateActionNamesAcrossTypes(in: config), !duplicateNames.isEmpty {
                let duplicateList = duplicateNames.sorted().joined(separator: ", ")
                logError("Configuration validation failed: duplicate action names across action types are not allowed: \(duplicateList)")
                showConfigValidationErrorNotification("Duplicate action names across types are not allowed: \(duplicateList)")
                return nil
            }

            let validationErrors = Self.collectConfigurationValidationErrors(in: config)
            if !validationErrors.isEmpty {
                showConfigValidationErrorNotification(validationErrors.joined(separator: "\n"))
                return nil
            }
            
            // JSON loaded successfully, reset notification flag
            hasNotifiedAboutJsonError = false
            
            return config
        } catch let error as DecodingError {
            // Provide specific JSON decoding error details
            let errorDetails = formatDecodingError(error)
            logError("Configuration JSON parsing failed: \(errorDetails)")
            
            showJsonErrorNotification()
            return nil
        } catch {
            // Other file system errors (permissions, etc.)
            logError("Failed to read configuration file: \(error.localizedDescription)")
            
            // Try to create backup and recover
            if createBackupAndReset(reason: "read error: \(error.localizedDescription)") {
                return AppConfiguration.defaultConfig()
            }
            
            return nil
        }
    }

    /// Returns duplicate action names when the same name is defined in more than one action type map.
    private static func findDuplicateActionNamesAcrossTypes(in config: AppConfiguration) -> Set<String>? {
        var counts: [String: Int] = [:]
        for name in config.inserts.keys { counts[name, default: 0] += 1 }
        for name in config.urls.keys { counts[name, default: 0] += 1 }
        for name in config.shortcuts.keys { counts[name, default: 0] += 1 }
        for name in config.scriptsShell.keys { counts[name, default: 0] += 1 }
        for name in config.scriptsAS.keys { counts[name, default: 0] += 1 }
        let duplicates = Set(counts.filter { $0.value > 1 }.map { $0.key })
        return duplicates
    }

    private static func collectConfigurationValidationErrors(in config: AppConfiguration) -> [String] {
        var errors: [String] = []

        // Build unique action name set (duplicate-name check is performed separately).
        var actionNames: Set<String> = []
        actionNames.formUnion(config.inserts.keys)
        actionNames.formUnion(config.urls.keys)
        actionNames.formUnion(config.shortcuts.keys)
        actionNames.formUnion(config.scriptsShell.keys)
        actionNames.formUnion(config.scriptsAS.keys)

        let activeAction = config.defaults.activeAction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaultsNextAction = config.defaults.nextAction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !activeAction.isEmpty && !actionNames.contains(activeAction) {
            errors.append("defaults.activeAction '\(activeAction)' does not exist")
        }
        if !defaultsNextAction.isEmpty && !actionNames.contains(defaultsNextAction) {
            errors.append("defaults.nextAction '\(defaultsNextAction)' does not exist")
        }
        if !activeAction.isEmpty && !defaultsNextAction.isEmpty && activeAction == defaultsNextAction {
            errors.append("defaults.activeAction and defaults.nextAction cannot be the same ('\(activeAction)')")
        }

        var nextActionMap: [String: String] = [:]
        var actionTypeMap: [String: ActionType] = [:]
        func appendNextAction(_ actionName: String, _ rawNextAction: String?) {
            let next = rawNextAction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !next.isEmpty else { return }
            if !actionNames.contains(next) {
                errors.append("Action '\(actionName)' has nextAction '\(next)' which does not exist")
                return
            }
            nextActionMap[actionName] = next
        }

        for (name, insert) in config.inserts { appendNextAction(name, insert.nextAction) }
        for (name, url) in config.urls { appendNextAction(name, url.nextAction) }
        for (name, shortcut) in config.shortcuts { appendNextAction(name, shortcut.nextAction) }
        for (name, shell) in config.scriptsShell { appendNextAction(name, shell.nextAction) }
        for (name, script) in config.scriptsAS { appendNextAction(name, script.nextAction) }

        for (name, insert) in config.inserts {
            errors.append(contentsOf: validateInputCondition(insert.inputCondition, actionName: name))
        }

        for name in config.inserts.keys { actionTypeMap[name] = .insert }
        for name in config.urls.keys { actionTypeMap[name] = .url }
        for name in config.shortcuts.keys { actionTypeMap[name] = .shortcut }
        for name in config.scriptsShell.keys { actionTypeMap[name] = .shell }
        for name in config.scriptsAS.keys { actionTypeMap[name] = .appleScript }

        // Cycle detection for action-level chains
        enum NodeState { case visiting, visited }
        var nodeStates: [String: NodeState] = [:]

        func dfs(_ node: String) {
            if let state = nodeStates[node] {
                if state == .visiting {
                    errors.append("Action chain cycle detected involving '\(node)'")
                }
                return
            }

            nodeStates[node] = .visiting
            if let next = nextActionMap[node] {
                dfs(next)
            }
            nodeStates[node] = .visited
        }

        for name in nextActionMap.keys {
            if nodeStates[name] == nil {
                dfs(name)
            }
        }

        // Validate max one insert action per chain, respecting defaults.nextAction precedence only for first step.
        for start in actionNames {
            var current = start
            var seen: Set<String> = []
            var firstStep = true
            var firstInsertName: String?

            while !current.isEmpty && !seen.contains(current) {
                seen.insert(current)
                if actionTypeMap[current] == .insert {
                    if let firstInsertName = firstInsertName, firstInsertName != current {
                        errors.append("Chain starting at '\(start)' contains multiple insert actions ('\(firstInsertName)' and '\(current)'). Only one insert action is allowed per chain")
                        break
                    }
                    firstInsertName = current
                }

                let next: String
                if firstStep && !defaultsNextAction.isEmpty {
                    next = defaultsNextAction
                } else {
                    next = nextActionMap[current] ?? ""
                }
                firstStep = false

                if next.isEmpty {
                    break
                }
                current = next
            }
        }

        return Array(Set(errors)).sorted()
    }

    private static func validateInputCondition(_ rawValue: String?, actionName: String) -> [String] {
        let normalized = rawValue ?? ""
        if normalized.isEmpty {
            return []
        }

        if normalized.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return ["Action '\(actionName)' has invalid inputCondition '\(normalized)': whitespace is not allowed"]
        }

        let allowedTokens: Set<String> = [
            "restoreClipboard",
            "pressReturn",
            "noEsc",
            "nextAction",
            "moveTo",
            "action",
            "actionDelay",
            "simKeypress"
        ]

        var errors: [String] = []
        let parts = normalized.components(separatedBy: "|")
        for rawToken in parts {
            if rawToken.isEmpty {
                errors.append("Action '\(actionName)' has invalid inputCondition '\(normalized)': empty token is not allowed")
                continue
            }

            let token = rawToken.hasPrefix("!") ? String(rawToken.dropFirst()) : rawToken
            if token.isEmpty {
                errors.append("Action '\(actionName)' has invalid inputCondition '\(normalized)': '!' must be followed by a valid token")
                continue
            }

            if !allowedTokens.contains(token) {
                errors.append("Action '\(actionName)' has invalid inputCondition token '\(rawToken)'")
            }
        }

        return errors
    }
    
    /// Formats decoding errors to be more user-friendly
    private func formatDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(let type, let context):
            return "Type mismatch for \(type) at \(context.codingPath.map { $0.stringValue }.joined(separator: "."))"
        case .valueNotFound(let type, let context):
            return "Missing required value of type \(type) at \(context.codingPath.map { $0.stringValue }.joined(separator: "."))"
        case .keyNotFound(let key, let context):
            return "Missing required key '\(key.stringValue)' at \(context.codingPath.map { $0.stringValue }.joined(separator: "."))"
        case .dataCorrupted(let context):
            return "Data corrupted at \(context.codingPath.map { $0.stringValue }.joined(separator: ".")): \(context.debugDescription)"
        @unknown default:
            return "Unknown decoding error: \(error.localizedDescription)"
        }
    }
    
    /// Creates a backup of corrupted config and resets to defaults
    /// Returns true if backup was created successfully
    private func createBackupAndReset(reason: String) -> Bool {
        let backupPath = configPath + ".backup." + ISO8601DateFormatter().string(from: Date())
        
        do {
            // Create backup of corrupted file
            if fileManager.fileExists(atPath: configPath) {
                try fileManager.copyItem(atPath: configPath, toPath: backupPath)
                logInfo("Created backup of corrupted configuration at: \(backupPath)")
            }
            
            // Reset to defaults
            let defaultConfig = AppConfiguration.defaultConfig()
            self._config = defaultConfig
            try self.saveConfig()
            
            logInfo("Reset configuration to defaults due to: \(reason)")
            
            // Show user-friendly notification
            notify(title: "MacroWhisper - Configuration Reset",
                   message: "Configuration was corrupted and has been reset to defaults. Backup saved.")
            
            return true
        } catch {
            logError("Failed to create backup and reset configuration: \(error)")
            return false
        }
    }
    
    /// Shows user-friendly notification for JSON configuration errors with recovery options
    private func showJsonErrorNotification() {
        // Only show notification if we haven't already notified
        if !hasNotifiedAboutJsonError {
            hasNotifiedAboutJsonError = true
            
            // Show a more helpful notification with recovery options
            notify(title: "MacroWhisper - Configuration Error",
                   message: "Configuration file has invalid JSON. Using default settings until fixed. Use --reveal-config to locate and repair the file.")
            
            logWarning("Configuration file at \(configPath) contains invalid JSON. Application will continue with default settings.")
            logWarning("To fix: Use 'macrowhisper --reveal-config' to open the file and correct the JSON syntax.")
            
            // Reset the file watcher to recover from JSON error
            self.resetFileWatcher()
        }
    }

    private func showConfigValidationErrorNotification(_ details: String) {
        if !hasNotifiedAboutJsonError {
            hasNotifiedAboutJsonError = true
            notify(
                title: "MacroWhisper - Configuration Error",
                message: "Configuration validation failed. Using default settings until fixed. Use --reveal-config to inspect and fix validation errors."
            )
        }
        logWarning("Configuration validation errors in \(configPath): \(details)")
        self.resetFileWatcher()
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

    func saveConfig() throws {
        // Don't overwrite an existing file that failed to load (has invalid JSON)
        if fileManager.fileExists(atPath: configPath) &&
            self.loadConfig() == nil {
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
                let currentSchemaRef = SchemaManager.getSchemaReference()
                
                // Check if schema needs to be updated in the configuration object
                var shouldUpdateSchema = false
                var schemaAction = ""
                
                if let currentSchemaRef = currentSchemaRef {
                    if _config.schema != currentSchemaRef {
                        shouldUpdateSchema = true
                        schemaAction = _config.schema == nil ? "Added" : "Updated"
                        logDebug("Schema reference needs updating: \(_config.schema ?? "nil") -> \(currentSchemaRef)")
                    } else {
                        logDebug("Schema reference is already correct, no update needed")
                    }
                }
                
                if shouldUpdateSchema, let schemaRef = currentSchemaRef {
                    // Update the schema property in the configuration object
                    _config.schema = schemaRef
                    
                    // Re-encode with the updated schema
                    let updatedData = try encoder.encode(_config)
                    if let updatedJsonString = String(data: updatedData, encoding: .utf8) {
                        formattedJson = updatedJsonString.replacingOccurrences(of: "\\/", with: "/")
                        formattedJson = roundDoublesInJson(formattedJson)
                        logInfo("\(schemaAction) schema reference for IDE validation: \(schemaRef)")
                    }
                }
                
                // Write the formatted JSON back to data with atomic write and error recovery
                if let formattedData = formattedJson.data(using: .utf8) {
                    let configDir = (configPath as NSString).deletingLastPathComponent
                    
                    // Ensure parent directory exists with proper error handling
                    do {
                        if !fileManager.fileExists(atPath: configDir) {
                            try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
                            logDebug("Created configuration directory: \(configDir)")
                        }
                        
                        // Perform atomic write to prevent corruption
                        let tempPath = configPath + ".tmp"
                        try formattedData.write(to: URL(fileURLWithPath: tempPath))
                        
                        // Verify the written file can be parsed before replacing original
                        if let _ = Self.loadConfig(from: tempPath) {
                            // Atomic move (replace original with verified temp file)
                            _ = try fileManager.replaceItem(at: URL(fileURLWithPath: configPath), 
                                                       withItemAt: URL(fileURLWithPath: tempPath), 
                                                       backupItemName: nil, 
                                                       options: [], 
                                                       resultingItemURL: nil)
                            logDebug("Configuration saved atomically to \(configPath)")
                        } else {
                            // Generated JSON is invalid (should not happen), clean up temp file
                            try? fileManager.removeItem(atPath: tempPath)
                            throw ConfigurationError.corruptedWrite("Generated configuration JSON failed validation")
                        }
                    } catch {
                        // Handle directory creation or file write errors
                        logError("Failed to write configuration file: \(error.localizedDescription)")
                        
                        // Check for common issues and provide specific guidance
                        if (error as NSError).code == NSFileWriteFileExistsError {
                            logError("Configuration directory cannot be created - file exists with same name")
                        } else if (error as NSError).code == NSFileWriteNoPermissionError {
                            logError("Permission denied writing to configuration directory. Check file permissions.")
                        }
                        
                        throw error
                    }
                }
            }
        } catch {
            logError("Failed to save configuration: \(error.localizedDescription)")
            
            // Provide more specific error notifications
            if error is EncodingError {
                notify(title: "MacroWhisper - Configuration Error", 
                       message: "Failed to encode configuration to JSON. Please check configuration values.")
            } else {
                notify(title: "MacroWhisper - Configuration Error", 
                       message: "Failed to save configuration: \(error.localizedDescription)")
            }
        }
    }
    
    /// Configuration-specific errors for better error handling
    enum ConfigurationError: Error {
        case corruptedWrite(String)
        case invalidJSON(String)
        case permissionDenied(String)
        
        var localizedDescription: String {
            switch self {
            case .corruptedWrite(let details):
                return "Configuration write corruption: \(details)"
            case .invalidJSON(let details):
                return "Invalid JSON configuration: \(details)"
            case .permissionDenied(let details):
                return "Permission denied: \(details)"
            }
        }
    }
    
    func updateFromCommandLine(watcher: Bool? = nil, activeAction: String? = nil) {
        
        var shouldSave = false
        
        if let activeAction = activeAction { _config.defaults.activeAction = activeAction.isEmpty ? "" : activeAction; shouldSave = true }

        // Validate activeAction after updating config
        validateActiveActionAndNotifyIfNeeded()

        if shouldSave {
            do {
                try self.saveConfig()
            } catch {
                logError("Failed to save configuration from command line update: \(error)")
            }
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
                    self._config = AppConfiguration.defaultConfig()
                    DispatchQueue.main.async {
                        self.onConfigChanged?("configValidationFallback")
                    }
                    logWarning("Applied in-memory default configuration due to invalid configuration file")
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
        guard let currentConfig = self.loadConfig() else {
            logError("Failed to load current configuration for update")
            return false
        }
        
        // Update our in-memory config with the loaded data
        syncQueue.sync {
            _config = currentConfig
        }
        
        // Save the configuration, which will apply any new schema changes and formatting
        do {
            try self.saveConfig()
        } catch {
            logError("Failed to save updated configuration: \(error)")
            return false
        }
        
        logInfo("Configuration file updated successfully")
        return true
    }

} 
