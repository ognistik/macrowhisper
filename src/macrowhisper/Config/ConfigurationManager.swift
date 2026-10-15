import Foundation

enum ConfigValidationIssueKind: String {
    case semantic
    case duplicateName
    case decoding
    case io
}

struct ConfigValidationIssue: Hashable {
    let path: String
    let message: String
    let kind: ConfigValidationIssueKind
    let rawValue: String?
}

struct ConfigValidationReport {
    let isValid: Bool
    let issues: [ConfigValidationIssue]
    let configPath: String
    let summary: String?
}

enum ConfigurationMigrationResult: Equatable {
    case migrated
    case alreadyCurrent
    case failed
}

class ConfigurationManager {
#if CONFIGURATION_V3_TESTING
    static var migrationAfterBackupHook: (() -> Void)?
#endif
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
    
    // Track config-notification state and prevent reload loops
    private var hasNotifiedAboutJsonError = false
    private var hasNotifiedAboutValidationError = false
    private var suppressNextConfigReload = false
    private(set) var hasLegacyConfigOnDisk = false
    
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
                hasNotifiedAboutValidationError = false
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

    private static func resolveSymlink(_ path: String) -> String {
        var current = path
        var seen = Set<String>()
        while !seen.contains(current) {
            seen.insert(current)
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else {
                break
            }
            if dest.hasPrefix("/") {
                current = (dest as NSString).standardizingPath
            } else {
                let dir = (current as NSString).deletingLastPathComponent
                current = ((dir as NSString).appendingPathComponent(dest) as NSString).standardizingPath
            }
        }
        return current
    }

    /// Creates a default configuration file at path when missing.
    /// Returns true when the file exists (already existed or was created successfully).
    static func ensureConfigFileExists(at path: String) -> Bool {
        if FileManager.default.fileExists(atPath: path) {
            return true
        }

        let configDir = (path as NSString).deletingLastPathComponent
        do {
            if !FileManager.default.fileExists(atPath: configDir) {
                try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
            }
            let defaultConfig = AppConfiguration.defaultConfig()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(defaultConfig)
            guard let jsonString = String(data: data, encoding: .utf8),
                  let formattedData = jsonString.replacingOccurrences(of: "\\/", with: "/").data(using: .utf8) else {
                return false
            }
            try formattedData.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            logError("Failed to create default configuration at \(path): \(error)")
            return false
        }
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

    /// Switches this running manager to a new config path and reloads live.
    /// Returns true when the path is active and configuration is loaded.
    func switchConfigPath(to newPath: String) -> Bool {
        let normalizedPath = Self.normalizeConfigPath(newPath)
        let parentDir = (normalizedPath as NSString).deletingLastPathComponent

        do {
            if !fileManager.fileExists(atPath: parentDir) {
                try fileManager.createDirectory(atPath: parentDir, withIntermediateDirectories: true, attributes: nil)
            }
        } catch {
            logError("Failed to prepare config directory for path switch: \(error)")
            return false
        }

        guard Self.ensureConfigFileExists(at: normalizedPath) else {
            return false
        }

        self.configPath = normalizedPath

        guard let loadedConfig = self.loadConfig() else {
            logError("Failed to load configuration after switching to \(normalizedPath)")
            return false
        }

        self._config = loadedConfig

        // Mirror startup behavior: apply auto-update (schema normalization/formatting)
        // immediately after switching paths when enabled by configuration.
        let shouldAutoUpdateConfig = loadedConfig.defaults.autoUpdateConfig
        if shouldAutoUpdateConfig {
            if !self.updateConfiguration() {
                logWarning("Config path switched, but automatic configuration update did not apply changes")
            }
        }

        self.configurationSuccessfullyLoaded()
        self.resetFileWatcher()
        DispatchQueue.main.async {
            self.onConfigChanged?("configPathChanged")
        }
        logInfo("Switched active configuration path to: \(normalizedPath)")
        return true
    }
    
    private static func loadConfig(from path: String) -> AppConfiguration? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        let decoder = JSONDecoder()
        guard var decoded = try? decoder.decode(AppConfiguration.self, from: data) else {
            return nil
        }
        normalizeConfigurationForRuntime(&decoded)
        let issues = sortedIssues(validationIssues(for: decoded))
        if !issues.isEmpty {
            logError("Configuration validation failed: \(issues.map { "\($0.path): \($0.message)" }.joined(separator: " | "))")
            return nil
        }
        return decoded
    }

    static func validateConfig(at path: String) -> ConfigValidationReport {
        let normalizedPath = normalizeConfigPath(path)
        let url = URL(fileURLWithPath: normalizedPath)

        do {
            let data = try Data(contentsOf: url, options: .uncached)
            if data.isEmpty {
                let issue = ConfigValidationIssue(
                    path: "root",
                    message: "configuration file is empty",
                    kind: .io,
                    rawValue: nil
                )
                return ConfigValidationReport(
                    isValid: false,
                    issues: [issue],
                    configPath: normalizedPath,
                    summary: "Configuration is invalid"
                )
            }

            let decoder = JSONDecoder()
            var decoded = try decoder.decode(AppConfiguration.self, from: data)
            normalizeConfigurationForRuntime(&decoded)
            let issues = sortedIssues(validationIssues(for: decoded))
            return ConfigValidationReport(
                isValid: issues.isEmpty,
                issues: issues,
                configPath: normalizedPath,
                summary: issues.isEmpty ? "Configuration is valid" : "Configuration is invalid"
            )
        } catch let error as DecodingError {
            let issue = ConfigValidationIssue(
                path: decodingErrorPath(error) ?? "root",
                message: decodingErrorMessage(error),
                kind: .decoding,
                rawValue: nil
            )
            return ConfigValidationReport(
                isValid: false,
                issues: [issue],
                configPath: normalizedPath,
                summary: "Configuration is invalid"
            )
        } catch {
            let issue = ConfigValidationIssue(
                path: "root",
                message: error.localizedDescription,
                kind: .io,
                rawValue: nil
            )
            return ConfigValidationReport(
                isValid: false,
                issues: [issue],
                configPath: normalizedPath,
                summary: "Configuration is invalid"
            )
        }
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
                let issue = ConfigValidationIssue(
                    path: "root",
                    message: "configuration file is empty",
                    kind: .io,
                    rawValue: nil
                )
                showConfigValidationErrorNotification(ConfigValidationReport(
                    isValid: false,
                    issues: [issue],
                    configPath: configPath,
                    summary: "Configuration is invalid"
                ))
                return nil
            }
            
            let decoder = JSONDecoder()
            var config = try decoder.decode(AppConfiguration.self, from: data)
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let hasLegacyAliases = root.map { Self.containsLegacyKeys(in: $0) } ?? false
            hasLegacyConfigOnDisk = hasLegacyAliases || (config.configVersion ?? 1) < AppConfiguration.currentConfigVersion
            Self.normalizeConfigurationForRuntime(&config)
            let issues = Self.sortedIssues(Self.validationIssues(for: config))
            if !issues.isEmpty {
                let report = ConfigValidationReport(
                    isValid: false,
                    issues: issues,
                    configPath: configPath,
                    summary: "Configuration is invalid"
                )
                showConfigValidationErrorNotification(report)
                return nil
            }
            
            // JSON loaded successfully, reset notification flag
            hasNotifiedAboutJsonError = false
            hasNotifiedAboutValidationError = false
            
            return config
        } catch let error as DecodingError {
            // Provide specific JSON decoding error details
            let errorDetails = Self.decodingErrorMessage(error)
            logError("Configuration JSON parsing failed: \(errorDetails)")
            
            showJsonErrorNotification(decodingPath: Self.decodingErrorPath(error))
            return nil
        } catch {
            // Other file system errors (permissions, etc.)
            logError("Failed to read configuration file: \(error.localizedDescription)")
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

    private static func validationIssues(for config: AppConfiguration) -> [ConfigValidationIssue] {
        var issues: [ConfigValidationIssue] = []

        if let version = config.configVersion, version < 1 || version > AppConfiguration.currentConfigVersion {
            let message = version < 1
                ? "configuration version must be at least 1"
                : "configuration version \(version) is newer than supported version \(AppConfiguration.currentConfigVersion)"
            issues.append(ConfigValidationIssue(
                path: "configVersion",
                message: message,
                kind: .semantic,
                rawValue: String(version)
            ))
        }

        if let duplicateNames = findDuplicateActionNamesAcrossTypes(in: config), !duplicateNames.isEmpty {
            for name in duplicateNames.sorted() {
                issues.append(
                    ConfigValidationIssue(
                        path: "actions.\(name)",
                        message: "duplicate action name exists across multiple action types ('\(name)')",
                        kind: .duplicateName,
                        rawValue: name
                    )
                )
            }
        }

        // Build unique action name set.
        var actionNames: Set<String> = []
        actionNames.formUnion(config.inserts.keys)
        actionNames.formUnion(config.urls.keys)
        actionNames.formUnion(config.shortcuts.keys)
        actionNames.formUnion(config.scriptsShell.keys)
        actionNames.formUnion(config.scriptsAS.keys)

        let activeAction = config.defaults.activeAction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaultsNextAction = config.defaults.nextAction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !activeAction.isEmpty && !actionNames.contains(activeAction) {
            issues.append(
                ConfigValidationIssue(
                    path: "defaults.activeAction",
                    message: "referenced action does not exist ('\(activeAction)')",
                    kind: .semantic,
                    rawValue: activeAction
                )
            )
        }
        if !defaultsNextAction.isEmpty && !actionNames.contains(defaultsNextAction) {
            issues.append(
                ConfigValidationIssue(
                    path: "defaults.nextAction",
                    message: "referenced action does not exist ('\(defaultsNextAction)')",
                    kind: .semantic,
                    rawValue: defaultsNextAction
                )
            )
        }
        if !activeAction.isEmpty && !defaultsNextAction.isEmpty && activeAction == defaultsNextAction {
            issues.append(
                ConfigValidationIssue(
                    path: "defaults.activeAction",
                    message: "defaults.activeAction and defaults.nextAction cannot be the same ('\(activeAction)')",
                    kind: .semantic,
                    rawValue: activeAction
                )
            )
        }

        struct NextActionSetting {
            let isExplicitlySet: Bool
            let value: String
        }

        var nextActionMap: [String: String] = [:]
        var nextActionSettings: [String: NextActionSetting] = [:]
        func appendNextAction(_ actionName: String, _ rawNextAction: String?, _ actionType: ActionType) {
            guard let rawNextAction else {
                nextActionSettings[actionName] = NextActionSetting(isExplicitlySet: false, value: "")
                return
            }
            let next = rawNextAction.trimmingCharacters(in: .whitespacesAndNewlines)
            nextActionSettings[actionName] = NextActionSetting(isExplicitlySet: true, value: next)
            guard !next.isEmpty else { return }
            if !actionNames.contains(next) {
                issues.append(
                    ConfigValidationIssue(
                        path: "\(actionSectionPath(for: actionType)).\(actionName).nextAction",
                        message: "referenced action does not exist ('\(next)')",
                        kind: .semantic,
                        rawValue: next
                    )
                )
                return
            }
            nextActionMap[actionName] = next
        }

        for (name, insert) in config.inserts { appendNextAction(name, insert.nextAction, .insert) }
        for (name, url) in config.urls { appendNextAction(name, url.nextAction, .url) }
        for (name, shortcut) in config.shortcuts { appendNextAction(name, shortcut.nextAction, .shortcut) }
        for (name, shell) in config.scriptsShell { appendNextAction(name, shell.nextAction, .shell) }
        for (name, script) in config.scriptsAS { appendNextAction(name, script.nextAction, .appleScript) }

        for (name, insert) in config.inserts {
            issues.append(contentsOf: validateTriggerLogic(
                insert.triggerLogic,
                actionPathPrefix: "inserts.\(name)"
            ))
            issues.append(contentsOf: validateInputCondition(
                insert.inputCondition,
                actionType: .insert,
                actionPathPrefix: "inserts.\(name)"
            ))
        }
        for (name, url) in config.urls {
            issues.append(contentsOf: validateTriggerLogic(
                url.triggerLogic,
                actionPathPrefix: "urls.\(name)"
            ))
            issues.append(contentsOf: validateInputCondition(
                url.inputCondition,
                actionType: .url,
                actionPathPrefix: "urls.\(name)"
            ))
        }
        for (name, shortcut) in config.shortcuts {
            issues.append(contentsOf: validateTriggerLogic(
                shortcut.triggerLogic,
                actionPathPrefix: "shortcuts.\(name)"
            ))
            issues.append(contentsOf: validateInputCondition(
                shortcut.inputCondition,
                actionType: .shortcut,
                actionPathPrefix: "shortcuts.\(name)"
            ))
        }
        for (name, shell) in config.scriptsShell {
            issues.append(contentsOf: validateTriggerLogic(
                shell.triggerLogic,
                actionPathPrefix: "scriptsShell.\(name)"
            ))
            issues.append(contentsOf: validateInputCondition(
                shell.inputCondition,
                actionType: .shell,
                actionPathPrefix: "scriptsShell.\(name)"
            ))
        }
        for (name, script) in config.scriptsAS {
            issues.append(contentsOf: validateTriggerLogic(
                script.triggerLogic,
                actionPathPrefix: "scriptsAS.\(name)"
            ))
            issues.append(contentsOf: validateInputCondition(
                script.inputCondition,
                actionType: .appleScript,
                actionPathPrefix: "scriptsAS.\(name)"
            ))
        }

        if config.defaults.icon == ".none" {
            issues.append(
                ConfigValidationIssue(
                    path: "defaults.icon",
                    message: "'.none' is not allowed in configVersion \(AppConfiguration.currentConfigVersion); use empty string for explicit no icon or null to inherit",
                    kind: .semantic,
                    rawValue: ".none"
                )
            )
        }
        if config.defaults.moveTo == ".none" {
            issues.append(
                ConfigValidationIssue(
                    path: "defaults.moveTo",
                    message: "'.none' is not allowed in configVersion \(AppConfiguration.currentConfigVersion); use empty string for explicit no move or null to inherit",
                    kind: .semantic,
                    rawValue: ".none"
                )
            )
        }

        for (name, insert) in config.inserts {
            if insert.icon == ".none" {
                issues.append(
                    ConfigValidationIssue(
                        path: "inserts.\(name).icon",
                        message: "'.none' is not allowed in configVersion \(AppConfiguration.currentConfigVersion)",
                        kind: .semantic,
                        rawValue: ".none"
                    )
                )
            }
            if insert.moveTo == ".none" {
                issues.append(
                    ConfigValidationIssue(
                        path: "inserts.\(name).moveTo",
                        message: "'.none' is not allowed in configVersion \(AppConfiguration.currentConfigVersion)",
                        kind: .semantic,
                        rawValue: ".none"
                    )
                )
            }
        }
        for (name, url) in config.urls {
            if url.icon == ".none" {
                issues.append(
                    ConfigValidationIssue(
                        path: "urls.\(name).icon",
                        message: "'.none' is not allowed in configVersion \(AppConfiguration.currentConfigVersion)",
                        kind: .semantic,
                        rawValue: ".none"
                    )
                )
            }
            if url.moveTo == ".none" {
                issues.append(
                    ConfigValidationIssue(
                        path: "urls.\(name).moveTo",
                        message: "'.none' is not allowed in configVersion \(AppConfiguration.currentConfigVersion)",
                        kind: .semantic,
                        rawValue: ".none"
                    )
                )
            }
        }
        for (name, shortcut) in config.shortcuts {
            if shortcut.icon == ".none" {
                issues.append(
                    ConfigValidationIssue(
                        path: "shortcuts.\(name).icon",
                        message: "'.none' is not allowed in configVersion \(AppConfiguration.currentConfigVersion)",
                        kind: .semantic,
                        rawValue: ".none"
                    )
                )
            }
            if shortcut.moveTo == ".none" {
                issues.append(
                    ConfigValidationIssue(
                        path: "shortcuts.\(name).moveTo",
                        message: "'.none' is not allowed in configVersion \(AppConfiguration.currentConfigVersion)",
                        kind: .semantic,
                        rawValue: ".none"
                    )
                )
            }
        }
        for (name, shell) in config.scriptsShell {
            if shell.icon == ".none" {
                issues.append(
                    ConfigValidationIssue(
                        path: "scriptsShell.\(name).icon",
                        message: "'.none' is not allowed in configVersion \(AppConfiguration.currentConfigVersion)",
                        kind: .semantic,
                        rawValue: ".none"
                    )
                )
            }
            if shell.moveTo == ".none" {
                issues.append(
                    ConfigValidationIssue(
                        path: "scriptsShell.\(name).moveTo",
                        message: "'.none' is not allowed in configVersion \(AppConfiguration.currentConfigVersion)",
                        kind: .semantic,
                        rawValue: ".none"
                    )
                )
            }
        }
        for (name, ascript) in config.scriptsAS {
            if ascript.icon == ".none" {
                issues.append(
                    ConfigValidationIssue(
                        path: "scriptsAS.\(name).icon",
                        message: "'.none' is not allowed in configVersion \(AppConfiguration.currentConfigVersion)",
                        kind: .semantic,
                        rawValue: ".none"
                    )
                )
            }
            if ascript.moveTo == ".none" {
                issues.append(
                    ConfigValidationIssue(
                        path: "scriptsAS.\(name).moveTo",
                        message: "'.none' is not allowed in configVersion \(AppConfiguration.currentConfigVersion)",
                        kind: .semantic,
                        rawValue: ".none"
                    )
                )
            }
        }

        // Cycle detection for action-level chains
        enum NodeState { case visiting, visited }
        var nodeStates: [String: NodeState] = [:]

        func dfs(_ node: String) {
            if let state = nodeStates[node] {
                if state == .visiting {
                    issues.append(
                        ConfigValidationIssue(
                            path: "actions.\(node).nextAction",
                            message: "action chain cycle detected involving '\(node)'",
                            kind: .semantic,
                            rawValue: node
                        )
                    )
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

        return Array(Set(issues))
    }

    private static func validateTriggerLogic(
        _ rawValue: String?,
        actionPathPrefix: String
    ) -> [ConfigValidationIssue] {
        guard let rawValue else { return [] }
        let normalized = rawValue.lowercased()
        guard normalized == "and" || normalized == "or" else {
            return [
                ConfigValidationIssue(
                    path: "\(actionPathPrefix).triggerLogic",
                    message: "invalid triggerLogic '\(rawValue)': expected 'and' or 'or'",
                    kind: .semantic,
                    rawValue: rawValue
                )
            ]
        }
        return []
    }

    private static func validateInputCondition(
        _ rawValue: String?,
        actionType: ActionType,
        actionPathPrefix: String
    ) -> [ConfigValidationIssue] {
        let normalized = rawValue ?? ""
        if normalized.isEmpty {
            return []
        }

        if normalized.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return [
                ConfigValidationIssue(
                    path: "\(actionPathPrefix).inputCondition",
                    message: "invalid inputCondition '\(normalized)': whitespace is not allowed",
                    kind: .semantic,
                    rawValue: normalized
                )
            ]
        }

        let allowedTokens: Set<String>
        switch actionType {
        case .insert:
            allowedTokens = [
                "restoreClipboard",
                "restoreClipboardDelay",
                "simEsc",
                "simReturn",
                "nextAction",
                "moveTo",
                "action",
                "actionDelay"
            ]
        case .url:
            allowedTokens = [
                "restoreClipboard",
                "restoreClipboardDelay",
                "simEsc",
                "nextAction",
                "moveTo",
                "action",
                "actionDelay"
            ]
        case .shell, .appleScript:
            allowedTokens = [
                "restoreClipboard",
                "restoreClipboardDelay",
                "simEsc",
                "nextAction",
                "moveTo",
                "action",
                "actionDelay",
                "scriptAsync",
                "scriptWaitTimeout"
            ]
        case .shortcut:
            allowedTokens = [
                "restoreClipboard",
                "restoreClipboardDelay",
                "simEsc",
                "nextAction",
                "moveTo",
                "action",
                "actionDelay",
                "scriptAsync",
                "scriptWaitTimeout"
            ]
        }

        var issues: [ConfigValidationIssue] = []
        let parts = normalized.components(separatedBy: "|")
        for rawToken in parts {
            if rawToken.isEmpty {
                issues.append(
                    ConfigValidationIssue(
                        path: "\(actionPathPrefix).inputCondition",
                        message: "invalid inputCondition '\(normalized)': empty token is not allowed",
                        kind: .semantic,
                        rawValue: normalized
                    )
                )
                continue
            }

            let token = rawToken.hasPrefix("!") ? String(rawToken.dropFirst()) : rawToken
            if token.isEmpty {
                issues.append(
                    ConfigValidationIssue(
                        path: "\(actionPathPrefix).inputCondition",
                        message: "invalid inputCondition '\(normalized)': '!' must be followed by a valid token",
                        kind: .semantic,
                        rawValue: normalized
                    )
                )
                continue
            }

            if !allowedTokens.contains(token) {
                issues.append(
                    ConfigValidationIssue(
                        path: "\(actionPathPrefix).inputCondition",
                        message: "invalid inputCondition token '\(rawToken)'",
                        kind: .semantic,
                        rawValue: rawToken
                    )
                )
            }
        }

        return issues
    }

    private static func actionSectionPath(for type: ActionType) -> String {
        switch type {
        case .insert: return "inserts"
        case .url: return "urls"
        case .shortcut: return "shortcuts"
        case .shell: return "scriptsShell"
        case .appleScript: return "scriptsAS"
        }
    }

    private static func sortedIssues(_ issues: [ConfigValidationIssue]) -> [ConfigValidationIssue] {
        issues.sorted {
            if $0.path != $1.path {
                return $0.path < $1.path
            }
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.message < $1.message
        }
    }

    private static func codingPathString(_ codingPath: [CodingKey]) -> String {
        let components = codingPath
            .map(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return components.isEmpty ? "root" : components.joined(separator: ".")
    }

    private static func decodingErrorPath(_ error: DecodingError) -> String? {
        switch error {
        case .typeMismatch(_, let context):
            return codingPathString(context.codingPath)
        case .valueNotFound(_, let context):
            return codingPathString(context.codingPath)
        case .keyNotFound(let key, let context):
            var path = context.codingPath
            path.append(key)
            return codingPathString(path)
        case .dataCorrupted(let context):
            return codingPathString(context.codingPath)
        @unknown default:
            return nil
        }
    }

    private static func decodingErrorMessage(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(let type, let context):
            return "type mismatch for \(type) at \(codingPathString(context.codingPath))"
        case .valueNotFound(let type, let context):
            return "missing required value of type \(type) at \(codingPathString(context.codingPath))"
        case .keyNotFound(let key, let context):
            var path = context.codingPath
            path.append(key)
            return "missing required key '\(key.stringValue)' at \(codingPathString(path))"
        case .dataCorrupted(let context):
            return "data corrupted at \(codingPathString(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return "unknown decoding error: \(error.localizedDescription)"
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
    
    /// Shows user-friendly notification for JSON configuration errors with compact hints.
    private func showJsonErrorNotification(decodingPath: String?) {
        // Only show notification if we haven't already notified
        if !hasNotifiedAboutJsonError {
            hasNotifiedAboutJsonError = true
            
            let path = (decodingPath ?? "root").trimmingCharacters(in: .whitespacesAndNewlines)
            let message = compactValidationNotificationMessage(
                prefix: "Config parse error at \(path.isEmpty ? "root" : path).",
                maxLength: 160
            )

            notify(title: "MacroWhisper - Configuration Error", message: message)
            
            logWarning("Configuration file at \(configPath) contains invalid JSON. Application will continue with default settings.")
            logWarning("To inspect issues quickly, run: macrowhisper --validate-config")
            
            // Reset the file watcher to recover from JSON error
            self.resetFileWatcher()
        }
    }

    private func showConfigValidationErrorNotification(_ report: ConfigValidationReport) {
        if !hasNotifiedAboutValidationError {
            hasNotifiedAboutValidationError = true
            notify(
                title: "MacroWhisper - Configuration Error",
                message: compactValidationNotificationMessage(
                    for: report,
                    maxLength: 160
                )
            )
        }
        let details = report.issues
            .map { "[\($0.kind.rawValue)] \($0.path): \($0.message)" }
            .joined(separator: "\n")
        logWarning("Configuration validation errors in \(configPath): \(details)")
        self.resetFileWatcher()
    }

    private func compactValidationNotificationMessage(for report: ConfigValidationReport, maxLength: Int) -> String {
        let paths = Array(Set(report.issues.map(\.path))).sorted()
        let pathPreview = paths.prefix(2).joined(separator: ", ")
        let prefix: String
        if pathPreview.isEmpty {
            prefix = "\(report.issues.count) config errors."
        } else {
            prefix = "\(report.issues.count) config errors: \(pathPreview)."
        }
        return compactValidationNotificationMessage(prefix: prefix, maxLength: maxLength)
    }

    private func compactValidationNotificationMessage(prefix: String, maxLength: Int) -> String {
        let suffix = "Run --validate-config"
        let singleLinePrefix = prefix.replacingOccurrences(of: "\n", with: " ")
        let fullMessage = "\(singleLinePrefix) \(suffix)"
        if fullMessage.count <= maxLength {
            return fullMessage
        }

        let maxPrefixLength = maxLength - suffix.count - 1
        if maxPrefixLength <= 0 {
            return String(suffix.prefix(maxLength))
        }

        var trimmedPrefix = String(singleLinePrefix.prefix(maxPrefixLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmedPrefix.last, [",", ".", ":", ";"].contains(last) {
            trimmedPrefix.removeLast()
        }
        if trimmedPrefix.isEmpty {
            return suffix
        }
        return "\(trimmedPrefix) \(suffix)"
    }
    
    func saveConfig() throws {
        var originalDiskConfig: AppConfiguration?
        if fileManager.fileExists(atPath: configPath) {
            let diskPath = Self.resolveSymlink(configPath)
            guard let rawData = try? Data(contentsOf: URL(fileURLWithPath: diskPath), options: .uncached),
                  let root = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any],
                  let diskConfig = try? JSONDecoder().decode(AppConfiguration.self, from: rawData) else {
                throw ConfigurationError.invalidJSON("Existing configuration is not readable JSON")
            }
            let rawVersion = diskConfig.configVersion ?? 1
            guard rawVersion == AppConfiguration.currentConfigVersion,
                  !Self.containsLegacyKeys(in: root),
                  Self.unknownPaths(in: root).isEmpty else {
                throw ConfigurationError.invalidJSON("Migrate legacy configuration explicitly before saving changes")
            }
            guard Self.validationIssues(for: diskConfig).isEmpty else {
                throw ConfigurationError.invalidJSON("Existing configuration is invalid or uses a future version")
            }
            originalDiskConfig = diskConfig
        }

        // Don't overwrite an existing file that failed to load (has invalid JSON)
        if fileManager.fileExists(atPath: configPath) &&
            self.loadConfig() == nil {
            logWarning("Not saving configuration because the existing file has invalid JSON that needs to be fixed manually")
            // Don't show another notification here - we've already notified in loadConfig()
            return
        }

        var candidate = _config
        for name in candidate.inserts.keys {
            guard var insert = candidate.inserts[name] else { continue }
            if originalDiskConfig == nil || insert.action != originalDiskConfig?.inserts[name]?.action {
                insert.action = canonicalizeMacrowhisperInsertAction(insert.action)
                candidate.inserts[name] = insert
            }
        }
        _ = Self.canonicalizeNonInsertReplacements(
            &candidate,
            legacy: false,
            changedFrom: originalDiskConfig
        )
        _config = candidate
        
        // Set suppression flag before writing config to prevent reload loop
        suppressNextConfigReload = true
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .useDefaultKeys
        do {
            let data = try encoder.encode(_config)
            if let jsonString = String(data: data, encoding: .utf8) {
                var formattedJson = jsonString.replacingOccurrences(of: "\\/", with: "/")
                
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
                        logInfo("\(schemaAction) schema reference for IDE validation: \(schemaRef)")
                    }
                }
                
                // Write the formatted JSON back to data with atomic write and error recovery
                if let formattedData = formattedJson.data(using: .utf8) {
                    let writePath = Self.resolveSymlink(configPath)
                    let configDir = (writePath as NSString).deletingLastPathComponent

                    // Ensure parent directory exists with proper error handling
                    do {
                        if !fileManager.fileExists(atPath: configDir) {
                            try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
                            logDebug("Created configuration directory: \(configDir)")
                        }

                        // Perform atomic write to prevent corruption
                        let tempPath = writePath + ".tmp"
                        try formattedData.write(to: URL(fileURLWithPath: tempPath))

                        // Verify the written file can be parsed before replacing original
                        if let _ = Self.loadConfig(from: tempPath) {
                            if fileManager.fileExists(atPath: writePath) {
                                // Atomic move (replace original with verified temp file)
                                _ = try fileManager.replaceItem(at: URL(fileURLWithPath: writePath),
                                                           withItemAt: URL(fileURLWithPath: tempPath),
                                                           backupItemName: nil,
                                                           options: [],
                                                           resultingItemURL: nil)
                            } else {
                                try fileManager.moveItem(atPath: tempPath, toPath: writePath)
                                // Target was just created in a potentially different directory than the
                                // symlink — reset the watcher so it follows the resolved path.
                                // Also clear suppressNextConfigReload: the old directory-mode watcher
                                // never saw the write event, so the flag was never consumed.
                                DispatchQueue.main.async {
                                    self.suppressNextConfigReload = false
                                    self.setupFileWatcher()
                                }
                            }
                            logDebug("Configuration saved atomically to \(writePath)")
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
        // Reset notification flags when config is successfully reloaded
        hasNotifiedAboutJsonError = false
        hasNotifiedAboutValidationError = false
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
    
    // MARK: - Configuration Migration
    private static let supportedRootKeys: Set<String> = [
        "$schema", "configVersion", "defaults", "inserts", "urls", "shortcuts", "scriptsShell", "scriptsAS"
    ]
    private static let actionSections: Set<String> = ["inserts", "urls", "shortcuts", "scriptsShell", "scriptsAS"]
    private static let legacyFieldKeys: Set<String> = ["noUpdates", "noNoti", "noEsc", "pressReturn"]
    private static let supportedDefaultsKeys: Set<String> = [
        "watch", "disableUpdateCheck", "muteNotifications", "activeAction", "icon", "moveTo", "simEsc",
        "simKeypress", "smartCasing", "smartPunctuation", "smartSpacing", "actionDelay", "history",
        "simReturn", "returnDelay", "restoreClipboard", "restoreClipboardDelay", "scheduledActionTimeout",
        "scriptAsync", "scriptWaitTimeout", "clipboardStacking", "clipboardAttachments", "clipboardBuffer",
        "clipboardIgnore", "bypassModes", "muteTriggers", "autoUpdateConfig", "redactedLogs", "nextAction",
        "noUpdates", "noNoti", "noEsc", "pressReturn"
    ]
    private static let insertKeys: Set<String> = [
        "action", "icon", "moveTo", "simEsc", "simKeypress", "smartCasing", "smartPunctuation", "smartSpacing",
        "actionDelay", "simReturn", "restoreClipboard", "restoreClipboardDelay", "clipboardStacking",
        "clipboardAttachments", "inputCondition", "nextAction", "triggerVoice", "triggerApps", "triggerModes",
        "triggerUrls", "triggerLogic", "noEsc", "pressReturn"
    ]
    private static let urlKeys: Set<String> = [
        "action", "icon", "moveTo", "simEsc", "actionDelay", "restoreClipboard", "restoreClipboardDelay",
        "clipboardStacking", "clipboardAttachments", "inputCondition", "nextAction", "triggerVoice", "triggerApps",
        "triggerModes", "triggerUrls", "triggerLogic", "openWith", "openBackground", "noEsc", "pressReturn"
    ]
    private static let scriptLikeKeys: Set<String> = [
        "action", "icon", "moveTo", "simEsc", "actionDelay", "restoreClipboard", "restoreClipboardDelay",
        "clipboardStacking", "clipboardAttachments", "scriptAsync", "scriptWaitTimeout", "inputCondition", "nextAction",
        "triggerVoice", "triggerApps", "triggerModes", "triggerUrls", "triggerLogic", "noEsc", "pressReturn"
    ]

    private static func allowedActionKeys(for section: String) -> Set<String> {
        switch section {
        case "inserts": return insertKeys
        case "urls": return urlKeys
        case "shortcuts", "scriptsShell", "scriptsAS": return scriptLikeKeys
        default: return []
        }
    }

    private static func unknownPaths(in root: [String: Any]) -> [[String]] {
        var paths = root.keys.filter { !supportedRootKeys.contains($0) }.sorted().map { [$0] }
        if let defaults = root["defaults"] as? [String: Any] {
            paths += defaults.keys.filter { !supportedDefaultsKeys.contains($0) }.sorted().map { ["defaults", $0] }
        }
        for section in actionSections.sorted() {
            guard let actions = root[section] as? [String: Any] else { continue }
            let allowed = allowedActionKeys(for: section)
            for actionName in actions.keys.sorted() {
                guard let action = actions[actionName] as? [String: Any] else { continue }
                paths += action.keys.filter { !allowed.contains($0) }.sorted().map { [section, actionName, $0] }
            }
        }
        return paths
    }

    private static func containsLegacyKeys(in root: [String: Any]) -> Bool {
        if let defaults = root["defaults"] as? [String: Any],
           defaults.keys.contains(where: legacyFieldKeys.contains) { return true }
        for section in actionSections {
            guard let actions = root[section] as? [String: Any] else { continue }
            for value in actions.values {
                if let action = value as? [String: Any], action.keys.contains(where: { ["noEsc", "pressReturn"].contains($0) }) {
                    return true
                }
            }
        }
        return false
    }

    /// Migrates a legacy configuration through each supported version step.
    /// Current-version files are read-only here and remain byte-for-byte unchanged.
    func migrateConfigurationIfNeeded() -> ConfigurationMigrationResult {
        syncQueue.sync {
            let requestedPath = configPath
            let targetPath = Self.resolveSymlink(requestedPath)
            guard let originalData = try? Data(contentsOf: URL(fileURLWithPath: targetPath), options: .uncached),
                  !originalData.isEmpty,
                  let root = (try? JSONSerialization.jsonObject(with: originalData)) as? [String: Any],
                  let source = try? JSONDecoder().decode(AppConfiguration.self, from: originalData) else {
                logError("Configuration migration requires a readable, non-empty JSON object")
                return .failed
            }

            let rawVersion = source.configVersion ?? 1
            guard rawVersion <= AppConfiguration.currentConfigVersion else {
                logError("Configuration uses a future configVersion and was left unchanged")
                return .failed
            }

            let legacyAliases = Self.containsLegacyKeys(in: root)
            let isLegacy = rawVersion < AppConfiguration.currentConfigVersion || legacyAliases
            var candidate = source
            Self.normalizeConfigurationForRuntime(&candidate)
            let runtimeIssues = Self.sortedIssues(Self.validationIssues(for: candidate))
            guard runtimeIssues.isEmpty else {
                logError("Configuration migration rejected invalid values: \(runtimeIssues.map { $0.path }.joined(separator: ", "))")
                return .failed
            }
            let unknownPaths = Self.unknownPaths(in: root)
            guard unknownPaths.isEmpty else {
                logError("Configuration migration refused to discard unknown fields: \(unknownPaths.map { $0.joined(separator: ".") }.joined(separator: ", "))")
                return .failed
            }
            guard isLegacy else { return .alreadyCurrent }

            // Build each schema step in memory first. Backups capture the
            // exact bytes at the boundary before each version transition.
            var versionedCandidate = source
            var backupSnapshots: [(path: String, data: Data)] = []
            var dataAtCurrentStep = originalData
            var version = rawVersion
            if version < 2 {
                _ = Self.applyV2Normalization(&versionedCandidate)
                _ = Self.normalizeEscInputConditionTokens(&versionedCandidate)
                versionedCandidate.configVersion = 2
                backupSnapshots.append((targetPath + ".backup.pre-v2", dataAtCurrentStep))
                guard let version2Data = try? Self.encodedConfigurationData(versionedCandidate) else { return .failed }
                dataAtCurrentStep = version2Data
                version = 2
            }
            if version < 3 {
                _ = migrateConfigurationToV3(&versionedCandidate)
                versionedCandidate.configVersion = 3
                backupSnapshots.append((targetPath + ".backup.pre-v3", dataAtCurrentStep))
                version = 3
            } else if legacyAliases {
                // A current-version file carrying decoded legacy aliases still
                // needs one canonical rewrite to avoid dropping them later.
                backupSnapshots.append((targetPath + ".backup.pre-v3", originalData))
            }

            _ = Self.normalizeEscInputConditionTokens(&versionedCandidate)
            _ = versionedCandidate.defaults.canonicalizeRootDefaultsForPersistence()
            versionedCandidate.configVersion = AppConfiguration.currentConfigVersion
            if let schemaReference = SchemaManager.getSchemaReference() {
                versionedCandidate.schema = schemaReference
            }
            let candidateIssues = Self.sortedIssues(Self.validationIssues(for: versionedCandidate))
            guard candidateIssues.isEmpty else {
                logError("Migrated configuration failed validation: \(candidateIssues.map { $0.path }.joined(separator: ", "))")
                return .failed
            }

            do {
                let candidateData = try Self.encodedConfigurationData(versionedCandidate)
                for backup in backupSnapshots {
                    try createImmutableBackup(at: backup.path, data: backup.data)
                }

#if CONFIGURATION_V3_TESTING
                Self.migrationAfterBackupHook?()
#endif

                // Recheck after backup and immediately before replacement.
                // This detects changes during preparation; an external write in
                // the final replace window remains a filesystem race.
                guard Self.resolveSymlink(requestedPath) == targetPath,
                      (try? Data(contentsOf: URL(fileURLWithPath: targetPath), options: .uncached)) == originalData else {
                    logError("Configuration changed while migration was being prepared; leaving it untouched")
                    return .failed
                }

                let temporaryPath = targetPath + ".tmp.\(UUID().uuidString)"
                defer { try? fileManager.removeItem(atPath: temporaryPath) }
                // Copy first to retain target metadata, then replace only its
                // contents before the final compare-and-replace checks.
                try fileManager.copyItem(atPath: targetPath, toPath: temporaryPath)
                try candidateData.write(to: URL(fileURLWithPath: temporaryPath))

                guard let verifiedRoot = (try? JSONSerialization.jsonObject(with: candidateData)) as? [String: Any],
                      Self.unknownPaths(in: verifiedRoot).isEmpty,
                      let verified = try? JSONDecoder().decode(AppConfiguration.self, from: candidateData),
                      verified.configVersion == AppConfiguration.currentConfigVersion,
                      Self.validationIssues(for: verified).isEmpty else {
                    throw ConfigurationError.corruptedWrite("Generated configuration failed validation")
                }

                guard Self.resolveSymlink(requestedPath) == targetPath,
                      (try? Data(contentsOf: URL(fileURLWithPath: targetPath), options: .uncached)) == originalData else {
                    logError("Configuration changed immediately before migration replacement; leaving it untouched")
                    return .failed
                }
                _ = try fileManager.replaceItem(
                    at: URL(fileURLWithPath: targetPath),
                    withItemAt: URL(fileURLWithPath: temporaryPath),
                    backupItemName: nil,
                    options: [],
                    resultingItemURL: nil
                )

                _config = verified
                hasLegacyConfigOnDisk = false
                hasNotifiedAboutJsonError = false
                hasNotifiedAboutValidationError = false
                suppressNextConfigReload = true
                logInfo("Migrated configuration to configVersion \(AppConfiguration.currentConfigVersion)")
                return .migrated
            } catch {
                logError("Configuration migration failed: \(error.localizedDescription)")
                return .failed
            }
        }
    }

    /// Compatibility wrapper for existing CLI/path-switch callers.
    func updateConfiguration() -> Bool {
        switch migrateConfigurationIfNeeded() {
        case .migrated, .alreadyCurrent: return true
        case .failed: return false
        }
    }

    private func createImmutableBackup(at backupPath: String, data: Data) throws {
        if fileManager.fileExists(atPath: backupPath) {
            let attributes = try fileManager.attributesOfItem(atPath: backupPath)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                  let existing = try? Data(contentsOf: URL(fileURLWithPath: backupPath), options: .uncached),
                  existing == data else {
                throw CocoaError(.fileWriteFileExists)
            }
            return
        }

        if (try? fileManager.destinationOfSymbolicLink(atPath: backupPath)) != nil {
            throw CocoaError(.fileWriteFileExists)
        }

        let temporaryBackup = backupPath + ".tmp.\(UUID().uuidString)"
        defer { try? fileManager.removeItem(atPath: temporaryBackup) }
        try data.write(to: URL(fileURLWithPath: temporaryBackup), options: [.atomic])
        guard (try? Data(contentsOf: URL(fileURLWithPath: temporaryBackup), options: .uncached)) == data else {
            throw ConfigurationError.corruptedWrite("Pre-migration backup did not preserve the original bytes")
        }
        // moveItem fails if another process creates the versioned backup first.
        do {
            try fileManager.moveItem(atPath: temporaryBackup, toPath: backupPath)
        } catch {
            if (try? fileManager.destinationOfSymbolicLink(atPath: backupPath)) == nil,
               let existing = try? Data(contentsOf: URL(fileURLWithPath: backupPath), options: .uncached), existing == data {
                return
            }
            throw error
        }
    }

    private static func encodedConfigurationData(_ config: AppConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(config)
        let json = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        guard let data = json.data(using: .utf8) else { throw ConfigurationError.corruptedWrite("Could not encode JSON as UTF-8") }
        return data
    }

    private func migrateConfigurationToV3(_ config: inout AppConfiguration) -> Bool {
        var changed = false
        for name in config.inserts.keys {
            guard var insert = config.inserts[name] else { continue }
            let canonical = canonicalizeLegacyMacrowhisperInsertAction(insert.action)
            if canonical != insert.action {
                insert.action = canonical
                config.inserts[name] = insert
                changed = true
            }
        }
        changed = Self.canonicalizeNonInsertReplacements(&config, legacy: true) || changed
        return changed
    }

    private static func canonicalizeNonInsertReplacements(
        _ config: inout AppConfiguration,
        legacy: Bool,
        changedFrom original: AppConfiguration? = nil
    ) -> Bool {
        var changed = false
        for name in config.urls.keys {
            guard var item = config.urls[name] else { continue }
            if let original, item.action == original.urls[name]?.action { continue }
            let value = canonicalizePlaceholderReplacementNewlines(item.action, legacy: legacy)
            if value != item.action { item.action = value; config.urls[name] = item; changed = true }
        }
        for name in config.shortcuts.keys {
            guard var item = config.shortcuts[name] else { continue }
            if let original, item.action == original.shortcuts[name]?.action { continue }
            let value = canonicalizePlaceholderReplacementNewlines(item.action, legacy: legacy)
            if value != item.action { item.action = value; config.shortcuts[name] = item; changed = true }
        }
        for name in config.scriptsShell.keys {
            guard var item = config.scriptsShell[name] else { continue }
            if let original, item.action == original.scriptsShell[name]?.action { continue }
            let value = canonicalizePlaceholderReplacementNewlines(item.action, legacy: legacy)
            if value != item.action { item.action = value; config.scriptsShell[name] = item; changed = true }
        }
        for name in config.scriptsAS.keys {
            guard var item = config.scriptsAS[name] else { continue }
            if let original, item.action == original.scriptsAS[name]?.action { continue }
            let value = canonicalizePlaceholderReplacementNewlines(item.action, legacy: legacy)
            if value != item.action { item.action = value; config.scriptsAS[name] = item; changed = true }
        }
        return changed
    }

    private static func migrateLegacyInsertActionsForRuntime(_ config: inout AppConfiguration) -> Bool {
        var changed = false
        for name in config.inserts.keys {
            guard var insert = config.inserts[name] else { continue }
            let canonical = canonicalizeLegacyMacrowhisperInsertAction(insert.action)
            if canonical != insert.action { insert.action = canonical; config.inserts[name] = insert; changed = true }
        }
        return changed
    }

    private static func normalizeConfigurationForRuntime(_ config: inout AppConfiguration) {
        _ = normalizeEscInputConditionTokens(&config)
        var version = config.configVersion ?? 1
        guard version >= 1, version <= AppConfiguration.currentConfigVersion else { return }
        if version < 2 {
            _ = applyV2Normalization(&config)
            version = 2
        }
        if version < 3 {
            _ = migrateLegacyInsertActionsForRuntime(&config)
            _ = canonicalizeNonInsertReplacements(&config, legacy: true)
            version = 3
        }
        if (config.configVersion ?? 1) < AppConfiguration.currentConfigVersion {
            config.configVersion = AppConfiguration.currentConfigVersion
        }
    }

    private static func applyV2Normalization(_ config: inout AppConfiguration) -> Bool {
        var changed = false

        func normalize(_ value: inout String?) {
            guard let raw = value else { return }
            if raw == ".none" {
                value = ""
                changed = true
                return
            }
            if raw.isEmpty {
                value = nil
                changed = true
            }
        }

        func normalizeInputLike(_ value: inout String?) {
            if value?.isEmpty == true {
                value = nil
                changed = true
            }
        }

        normalize(&config.defaults.icon)
        normalize(&config.defaults.moveTo)
        normalizeInputLike(&config.defaults.nextAction)
        normalizeInputLike(&config.defaults.clipboardIgnore)
        normalizeInputLike(&config.defaults.bypassModes)

        for name in config.inserts.keys {
            guard var insert = config.inserts[name] else { continue }
            normalize(&insert.icon)
            normalize(&insert.moveTo)
            normalizeInputLike(&insert.nextAction)
            normalizeInputLike(&insert.inputCondition)
            normalizeInputLike(&insert.triggerVoice)
            normalizeInputLike(&insert.triggerApps)
            normalizeInputLike(&insert.triggerModes)
            normalizeInputLike(&insert.triggerUrls)
            config.inserts[name] = insert
        }

        for name in config.urls.keys {
            guard var url = config.urls[name] else { continue }
            normalize(&url.icon)
            normalize(&url.moveTo)
            normalizeInputLike(&url.nextAction)
            normalizeInputLike(&url.inputCondition)
            normalizeInputLike(&url.triggerVoice)
            normalizeInputLike(&url.triggerApps)
            normalizeInputLike(&url.triggerModes)
            normalizeInputLike(&url.triggerUrls)
            normalizeInputLike(&url.openWith)
            config.urls[name] = url
        }

        for name in config.shortcuts.keys {
            guard var shortcut = config.shortcuts[name] else { continue }
            normalize(&shortcut.icon)
            normalize(&shortcut.moveTo)
            normalizeInputLike(&shortcut.nextAction)
            normalizeInputLike(&shortcut.inputCondition)
            normalizeInputLike(&shortcut.triggerVoice)
            normalizeInputLike(&shortcut.triggerApps)
            normalizeInputLike(&shortcut.triggerModes)
            normalizeInputLike(&shortcut.triggerUrls)
            config.shortcuts[name] = shortcut
        }

        for name in config.scriptsShell.keys {
            guard var shell = config.scriptsShell[name] else { continue }
            normalize(&shell.icon)
            normalize(&shell.moveTo)
            normalizeInputLike(&shell.nextAction)
            normalizeInputLike(&shell.inputCondition)
            normalizeInputLike(&shell.triggerVoice)
            normalizeInputLike(&shell.triggerApps)
            normalizeInputLike(&shell.triggerModes)
            normalizeInputLike(&shell.triggerUrls)
            config.scriptsShell[name] = shell
        }

        for name in config.scriptsAS.keys {
            guard var ascript = config.scriptsAS[name] else { continue }
            normalize(&ascript.icon)
            normalize(&ascript.moveTo)
            normalizeInputLike(&ascript.nextAction)
            normalizeInputLike(&ascript.inputCondition)
            normalizeInputLike(&ascript.triggerVoice)
            normalizeInputLike(&ascript.triggerApps)
            normalizeInputLike(&ascript.triggerModes)
            normalizeInputLike(&ascript.triggerUrls)
            config.scriptsAS[name] = ascript
        }

        return changed
    }

    private static func normalizeEscInputConditionTokens(_ config: inout AppConfiguration) -> Bool {
        var changed = false

        func normalizeEscToken(_ value: inout String?) {
            guard let raw = value, !raw.isEmpty else { return }

            let transformedTokens = raw.split(separator: "|", omittingEmptySubsequences: false).map { token -> String in
                let tokenString = String(token)
                switch tokenString {
                case "noEsc":
                    return "simEsc"
                case "!noEsc":
                    return "!simEsc"
                default:
                    return tokenString
                }
            }
            let transformed = transformedTokens.joined(separator: "|")
            if transformed != raw {
                value = transformed
                changed = true
            }
        }

        for name in config.inserts.keys {
            guard var insert = config.inserts[name] else { continue }
            normalizeEscToken(&insert.inputCondition)
            config.inserts[name] = insert
        }

        for name in config.urls.keys {
            guard var url = config.urls[name] else { continue }
            normalizeEscToken(&url.inputCondition)
            config.urls[name] = url
        }

        for name in config.shortcuts.keys {
            guard var shortcut = config.shortcuts[name] else { continue }
            normalizeEscToken(&shortcut.inputCondition)
            config.shortcuts[name] = shortcut
        }

        for name in config.scriptsShell.keys {
            guard var shell = config.scriptsShell[name] else { continue }
            normalizeEscToken(&shell.inputCondition)
            config.scriptsShell[name] = shell
        }

        for name in config.scriptsAS.keys {
            guard var ascript = config.scriptsAS[name] else { continue }
            normalizeEscToken(&ascript.inputCondition)
            config.scriptsAS[name] = ascript
        }

        return changed
    }

}
