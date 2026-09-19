import Foundation

enum ConfigValidationIssueKind: String, Codable {
    case semantic
    case duplicateName
    case decoding
    case io
}

struct ConfigValidationIssue: Hashable, Codable {
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

class ConfigurationManager {
#if CONFIGURATION_TRANSACTION_TESTING
    // Deterministic fault/race seams used only by the standalone transaction
    // runner. They are compiled out of the application target so a test can
    // exercise failure before publication and the symlink replacement window
    // without changing normal filesystem behavior.
    static var transactionBeforeTemporaryWriteHook: ((String, Data) throws -> Void)?
    static var transactionBeforeReplaceHook: (() -> Void)?
    static var transactionAfterReplaceHook: ((String) -> Void)?
#endif

    private var _config: AppConfiguration
    /// The accepted runtime configuration.  Mutations must go through one of
    /// the transaction methods below so the in-memory state cannot get ahead
    /// of the file on disk.
    var config: AppConfiguration {
        syncQueue.sync { _config }
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
    /// A marker for the exact internal replacement that the file watcher may
    /// report. A boolean is unsafe: an unrelated edit arriving before the
    /// watcher event could consume the flag and disappear from runtime state.
    private var pendingInternalWrite: PendingInternalWrite?
    private var acceptedRevision = ConfigurationRevision(
        generation: UUID().uuidString,
        version: 0,
        fingerprint: "missing"
    )
    private var acceptedDiskIsValid = true
    private(set) var hasLegacyConfigOnDisk = false
    private var acceptedDiskIssues: [ConfigValidationIssue] = []

    private struct PendingInternalWrite {
        let resolvedPath: String
        let fingerprint: String
    }

    /// A side-effect-free read of the selected file.  `AppConfiguration` is
    /// intentionally permissive for runtime compatibility, so this carries
    /// the additional editor checks separately instead of making ordinary
    /// hand-edited configurations fail to load.
    private struct DiskState {
        let requestedPath: String
        let resolvedPath: String
        let fingerprint: String
        let data: Data?
        let config: AppConfiguration?
        let syntaxIsValid: Bool
        let semanticIssues: [ConfigValidationIssue]
        let unknownPaths: [[String]]
        let isMissing: Bool
        let isLegacy: Bool
        let isFuture: Bool

        var isRuntimeUsable: Bool {
            config != nil && syntaxIsValid && semanticIssues.isEmpty && !isFuture
        }

        var isEditorWritable: Bool {
            isRuntimeUsable && unknownPaths.isEmpty && !isLegacy
        }

        var isDiskValid: Bool {
            syntaxIsValid && semanticIssues.isEmpty && unknownPaths.isEmpty && !isFuture
        }
    }

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
        
        // Establish the initial accepted state synchronously.  This avoids a
        // window in which an editor can read the in-memory defaults while the
        // first file write is still queued, and it gives the first snapshot a
        // real disk fingerprint.
        let initialState = inspectDisk(at: self.configPath)
        if initialState.isMissing {
            logInfo("No configuration file found at \(self.configPath). Creating a new one with default settings.")
            let initialConfig = self._config
            do {
                let written = try writeConfigurationLocked(
                    initialConfig,
                    to: self.configPath,
                    expectedFingerprint: initialState.fingerprint,
                    preserveBackup: false
                )
                self._config = written.config
                self.acceptedRevision = ConfigurationRevision(
                    generation: self.acceptedRevision.generation,
                    version: 1,
                    fingerprint: written.fingerprint
                )
                self.acceptedDiskIsValid = true
                self.acceptedDiskIssues = []
                logDebug("Configuration file successfully created")
            } catch {
                self.acceptedDiskIsValid = false
                self.acceptedDiskIssues = [ConfigValidationIssue(
                    path: "root",
                    message: "failed to create configuration file: \(error.localizedDescription)",
                    kind: .io,
                    rawValue: nil
                )]
                logError("Failed to create configuration file at \(self.configPath): \(error.localizedDescription)")
            }
        } else {
            applyInitialDiskState(initialState)
            if !initialState.syntaxIsValid {
                showJsonErrorNotification(decodingPath: initialState.semanticIssues.first?.path)
            } else if !initialState.semanticIssues.isEmpty {
                showConfigValidationErrorNotification(
                    ConfigValidationReport(
                        isValid: false,
                        issues: initialState.semanticIssues,
                        configPath: self.configPath,
                        summary: "Configuration is invalid"
                    )
                )
            }
        }

        // Always set up file watcher - it handles both existing and non-existing files.
        self.setupFileWatcherLocked()
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
        // URL resolution follows symlinked parent directories as well as a
        // symlinked configuration file.  For a dangling link Foundation may
        // still return a useful standardized destination; retain the small
        // manual fallback for paths that cannot be resolved by URL.
        let resolvedByURL = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        if resolvedByURL != path || FileManager.default.fileExists(atPath: resolvedByURL) {
            return resolvedByURL
        }

        var current = (path as NSString).standardizingPath
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
        syncQueue.sync { configPath }
    }

    /// Returns the accepted configuration and the revision that identifies the
    /// selected path, daemon generation, and current disk bytes.  A snapshot
    /// performs a cheap fingerprint/read check first, so an external editor
    /// that wins the race with the file watcher is visible immediately.
    func configurationSnapshot() -> ConfigurationSnapshot {
        syncQueue.sync {
            _ = refreshDiskStateLocked(notifyExternalChange: true)
            return makeSnapshotLocked()
        }
    }

    /// Short alias used by callers that already refer to the result as a
    /// snapshot.
    func snapshot() -> ConfigurationSnapshot {
        configurationSnapshot()
    }

    /// Returns the latest accepted revision without requiring callers to copy
    /// the full configuration object.
    func currentConfigurationRevision() -> ConfigurationRevision {
        syncQueue.sync {
            _ = refreshDiskStateLocked(notifyExternalChange: true)
            return acceptedRevision
        }
    }

    /// Switches this running manager to a new config path and reloads live.
    /// Returns true when the path is active and configuration is loaded.
    func switchConfigPath(to newPath: String) -> Bool {
        syncQueue.sync {
            switchConfigPathLocked(to: newPath)
        }
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
        let state = syncQueue.sync { () -> DiskState in
            let state = inspectDisk(at: configPath)
            hasLegacyConfigOnDisk = state.isLegacy
            if state.isRuntimeUsable && state.semanticIssues.isEmpty && !state.isFuture {
                configurationSuccessfullyLoadedLocked()
            }
            return state
        }
        let loadedPath = state.requestedPath

        guard !state.isMissing else {
            logDebug("Configuration file does not exist at \(loadedPath)")
            return nil
        }

        guard state.syntaxIsValid else {
            logError("Configuration JSON parsing failed at \(loadedPath)")
            showJsonErrorNotification(decodingPath: state.semanticIssues.first?.path)
            return nil
        }

        guard let config = state.config else {
            logError("Configuration at \(loadedPath) could not be decoded")
            return nil
        }

        if !state.semanticIssues.isEmpty {
            let report = ConfigValidationReport(
                isValid: false,
                issues: state.semanticIssues,
                configPath: loadedPath,
                summary: "Configuration is invalid"
            )
            showConfigValidationErrorNotification(report)
            return nil
        }

        if state.isFuture {
            logWarning("Configuration at \(configPath) uses a future configVersion and will remain unchanged")
            return nil
        }

        return config
    }

    // MARK: - Serialized configuration transactions

    private static let supportedRootKeys: Set<String> = [
        "$schema", "configVersion", "defaults", "inserts", "urls",
        "shortcuts", "scriptsShell", "scriptsAS"
    ]

    private static let supportedDefaultsKeys: Set<String> = [
        "watch", "disableUpdateCheck", "muteNotifications", "activeAction",
        "icon", "moveTo", "simEsc", "simKeypress", "smartCasing",
        "smartPunctuation", "smartSpacing", "actionDelay", "history",
        "simReturn", "returnDelay", "restoreClipboard", "restoreClipboardDelay",
        "scheduledActionTimeout", "scriptAsync", "scriptWaitTimeout",
        "clipboardStacking", "clipboardAttachments", "clipboardBuffer",
        "clipboardIgnore", "bypassModes", "muteTriggers", "autoUpdateConfig",
        "redactedLogs", "nextAction", "noUpdates", "noNoti", "noEsc", "pressReturn"
    ]

    private static let insertActionKeys: Set<String> = [
        "action", "icon", "moveTo", "simEsc", "simKeypress", "smartCasing",
        "smartPunctuation", "smartSpacing", "actionDelay", "simReturn",
        "restoreClipboard", "restoreClipboardDelay", "clipboardStacking",
        "clipboardAttachments", "inputCondition", "nextAction", "triggerVoice",
        "triggerApps", "triggerModes", "triggerUrls", "triggerLogic", "noEsc", "pressReturn"
    ]

    private static let urlActionKeys: Set<String> = [
        "action", "icon", "moveTo", "simEsc", "actionDelay", "restoreClipboard",
        "restoreClipboardDelay", "clipboardStacking", "clipboardAttachments",
        "inputCondition", "nextAction", "triggerVoice", "triggerApps", "triggerModes",
        "triggerUrls", "triggerLogic", "openWith", "openBackground", "noEsc", "pressReturn"
    ]

    private static let scriptLikeActionKeys: Set<String> = [
        "action", "icon", "moveTo", "simEsc", "actionDelay", "restoreClipboard",
        "restoreClipboardDelay", "clipboardStacking", "clipboardAttachments", "scriptAsync",
        "scriptWaitTimeout", "inputCondition", "nextAction", "triggerVoice", "triggerApps",
        "triggerModes", "triggerUrls", "triggerLogic", "noEsc", "pressReturn"
    ]

    private static let actionSections: Set<String> = [
        "inserts", "urls", "shortcuts", "scriptsShell", "scriptsAS"
    ]

    /// These aliases are decoded for v1 compatibility, but they are not
    /// writable editor fields.  Keeping them in the disk allow-list lets a
    /// legacy file be reported as legacy instead of silently dropping the
    /// aliases during a typed re-encode.
    private static let legacyFieldKeys: Set<String> = [
        "noUpdates", "noNoti", "noEsc", "pressReturn"
    ]

    private static func supportedActionKeys(for section: String) -> Set<String> {
        switch section {
        case "inserts": return insertActionKeys
        case "urls": return urlActionKeys
        case "shortcuts", "scriptsShell", "scriptsAS": return scriptLikeActionKeys
        default: return []
        }
    }

    private static func editableActionKeys(for section: String) -> Set<String> {
        supportedActionKeys(for: section).subtracting(legacyFieldKeys)
    }

    private enum EditValueKind {
        case string(nullable: Bool)
        case boolean(nullable: Bool)
        case number(nullable: Bool)
        case integer(nullable: Bool)
    }

    private struct WrittenConfiguration {
        let config: AppConfiguration
        let fingerprint: String
        let resolvedPath: String
    }

    /// Reads and classifies a configuration without resetting, backing up, or
    /// writing anything.  The normal model decoder remains the source of
    /// runtime defaults and legacy compatibility; raw JSON inspection adds the
    /// loss-detection checks needed before typed re-encoding.
    private func inspectDisk(at path: String) -> DiskState {
        let requestedPath = (path as NSString).standardizingPath
        let resolvedPath = Self.resolveSymlink(requestedPath)
        let missingFingerprint = "missing:\(resolvedPath)"

        guard fileManager.fileExists(atPath: resolvedPath) else {
            return DiskState(
                requestedPath: requestedPath,
                resolvedPath: resolvedPath,
                fingerprint: missingFingerprint,
                data: nil,
                config: nil,
                syntaxIsValid: false,
                semanticIssues: [ConfigValidationIssue(
                    path: "root",
                    message: "configuration file does not exist",
                    kind: .io,
                    rawValue: nil
                )],
                unknownPaths: [],
                isMissing: true,
                isLegacy: false,
                isFuture: false
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath), options: .uncached)
        } catch {
            return DiskState(
                requestedPath: requestedPath,
                resolvedPath: resolvedPath,
                fingerprint: Self.diskFingerprint(at: resolvedPath),
                data: nil,
                config: nil,
                syntaxIsValid: false,
                semanticIssues: [ConfigValidationIssue(
                    path: "root",
                    message: "failed to read configuration: \(error.localizedDescription)",
                    kind: .io,
                    rawValue: nil
                )],
                unknownPaths: [],
                isMissing: false,
                isLegacy: false,
                isFuture: false
            )
        }

        let fingerprint = Self.diskFingerprint(at: resolvedPath, data: data)
        guard !data.isEmpty else {
            return DiskState(
                requestedPath: requestedPath,
                resolvedPath: resolvedPath,
                fingerprint: fingerprint,
                data: data,
                config: nil,
                syntaxIsValid: false,
                semanticIssues: [ConfigValidationIssue(
                    path: "root",
                    message: "configuration file is empty",
                    kind: .io,
                    rawValue: nil
                )],
                unknownPaths: [],
                isMissing: false,
                isLegacy: false,
                isFuture: false
            )
        }

        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let root = object as? [String: Any] else {
            return DiskState(
                requestedPath: requestedPath,
                resolvedPath: resolvedPath,
                fingerprint: fingerprint,
                data: data,
                config: nil,
                syntaxIsValid: false,
                semanticIssues: [ConfigValidationIssue(
                    path: "root",
                    message: "configuration JSON must contain an object at the root",
                    kind: .decoding,
                    rawValue: nil
                )],
                unknownPaths: [],
                isMissing: false,
                isLegacy: false,
                isFuture: false
            )
        }

        let unknownPaths = Self.unknownPaths(in: root)
        let legacyKeysPresent = Self.containsLegacyKeys(in: root)
        let decoded: AppConfiguration
        do {
            decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)
        } catch let error as DecodingError {
            return DiskState(
                requestedPath: requestedPath,
                resolvedPath: resolvedPath,
                fingerprint: fingerprint,
                data: data,
                config: nil,
                syntaxIsValid: false,
                semanticIssues: [ConfigValidationIssue(
                    path: Self.decodingErrorPath(error) ?? "root",
                    message: Self.decodingErrorMessage(error),
                    kind: .decoding,
                    rawValue: nil
                )],
                unknownPaths: unknownPaths,
                isMissing: false,
                isLegacy: legacyKeysPresent,
                isFuture: false
            )
        } catch {
            return DiskState(
                requestedPath: requestedPath,
                resolvedPath: resolvedPath,
                fingerprint: fingerprint,
                data: data,
                config: nil,
                syntaxIsValid: false,
                semanticIssues: [ConfigValidationIssue(
                    path: "root",
                    message: "configuration decoding failed: \(error.localizedDescription)",
                    kind: .decoding,
                    rawValue: nil
                )],
                unknownPaths: unknownPaths,
                isMissing: false,
                isLegacy: legacyKeysPresent,
                isFuture: false
            )
        }

        let rawVersion = decoded.configVersion
        var normalized = decoded
        Self.normalizeConfigurationForRuntime(&normalized)
        let issues = Self.sortedIssues(Self.validationIssues(for: normalized))
        let isLegacy = legacyKeysPresent || (rawVersion ?? 1) < AppConfiguration.currentConfigVersion
        let isFuture = (rawVersion ?? AppConfiguration.currentConfigVersion) > AppConfiguration.currentConfigVersion

        return DiskState(
            requestedPath: requestedPath,
            resolvedPath: resolvedPath,
            fingerprint: fingerprint,
            data: data,
            config: normalized,
            syntaxIsValid: true,
            semanticIssues: issues,
            unknownPaths: unknownPaths,
            isMissing: false,
            isLegacy: isLegacy,
            isFuture: isFuture
        )
    }

    private func applyInitialDiskState(_ state: DiskState) {
        hasLegacyConfigOnDisk = state.isLegacy
        acceptedDiskIsValid = state.isDiskValid
        acceptedDiskIssues = issuesForDiskState(state)
        acceptedRevision = ConfigurationRevision(
            generation: acceptedRevision.generation,
            version: 1,
            fingerprint: state.fingerprint
        )

        if state.isRuntimeUsable, let config = state.config {
            _config = config
            hasNotifiedAboutJsonError = false
            hasNotifiedAboutValidationError = false
            logDebug("Configuration loaded from \(configPath)")
        } else {
            _config = AppConfiguration.defaultConfig()
            logWarning("Failed to load configuration. Using defaults in memory only.")
        }
    }

    private func makeSnapshotLocked() -> ConfigurationSnapshot {
        ConfigurationSnapshot(
            config: _config,
            revision: acceptedRevision,
            configPath: configPath,
            diskIsValid: acceptedDiskIsValid,
            isLegacyOnDisk: hasLegacyConfigOnDisk,
            diskIssues: acceptedDiskIssues
        )
    }

    private func issuesForDiskState(_ state: DiskState) -> [ConfigValidationIssue] {
        var issues = state.semanticIssues
        for path in state.unknownPaths {
            issues.append(ConfigValidationIssue(
                path: path.map { $0 == "$schema" ? "$schema" : $0 }.joined(separator: "."),
                message: "unsupported configuration key '\(path.last ?? "")'",
                kind: .decoding,
                rawValue: path.last
            ))
        }
        if state.isFuture {
            issues.append(ConfigValidationIssue(
                path: "configVersion",
                message: "configuration version is newer than the supported version",
                kind: .decoding,
                rawValue: nil
            ))
        }
        return Self.sortedIssues(Array(Set(issues)))
    }

    /// Reconciles disk state before a transaction or snapshot.  An internal
    /// write is suppressed only when both its resolved target and resulting
    /// fingerprint match; an unrelated edit therefore cannot consume the
    /// suppression marker.
    @discardableResult
    private func refreshDiskStateLocked(notifyExternalChange: Bool) -> DiskState {
        let state = inspectDisk(at: configPath)
        if let pending = pendingInternalWrite,
           pending.resolvedPath == state.resolvedPath,
           pending.fingerprint == state.fingerprint {
            pendingInternalWrite = nil
            return state
        }

        guard state.fingerprint != acceptedRevision.fingerprint else {
            return state
        }

        let oldGeneration = acceptedRevision.generation
        let nextVersion = acceptedRevision.version == UInt64.max
            ? UInt64.max
            : acceptedRevision.version + 1
        acceptedRevision = ConfigurationRevision(
            generation: oldGeneration,
            version: nextVersion,
            fingerprint: state.fingerprint
        )
        acceptedDiskIsValid = state.isDiskValid
        acceptedDiskIssues = issuesForDiskState(state)
        hasLegacyConfigOnDisk = state.isLegacy
        pendingInternalWrite = nil

        if state.isRuntimeUsable, let config = state.config {
            _config = config
            configurationSuccessfullyLoadedLocked()
        } else {
            // Invalid external JSON is represented explicitly in the snapshot;
            // runtime keeps its established fallback behavior without writing
            // over the user's file.
            _config = AppConfiguration.defaultConfig()
        }

        guard notifyExternalChange else { return state }
        let reason = state.isRuntimeUsable && !state.isFuture
            ? "configFileChanged"
            : "configValidationFallback"
        DispatchQueue.main.async { [weak self] in
            self?.onConfigChanged?(reason)
        }
        return state
    }

    private func switchConfigPathLocked(to newPath: String) -> Bool {
        let normalizedPath = Self.normalizeConfigPath(newPath)
        let parentDir = (normalizedPath as NSString).deletingLastPathComponent

        do {
            if !fileManager.fileExists(atPath: parentDir) {
                try fileManager.createDirectory(
                    atPath: parentDir,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }
        } catch {
            logError("Failed to prepare config directory for path switch: \(error.localizedDescription)")
            return false
        }

        let state = inspectDisk(at: normalizedPath)
        var selectedConfig: AppConfiguration
        var selectedFingerprint: String
        var selectedIsLegacy: Bool
        var selectedDiskIsValid: Bool
        var selectedDiskIssues: [ConfigValidationIssue]
        var selectedPendingWrite: PendingInternalWrite?

        if state.isMissing {
            do {
                let defaultConfig = AppConfiguration.defaultConfig()
                let written = try writeConfigurationLocked(
                    defaultConfig,
                    to: normalizedPath,
                    expectedFingerprint: state.fingerprint,
                    preserveBackup: false
                )
                selectedConfig = written.config
                selectedFingerprint = written.fingerprint
                selectedIsLegacy = false
                selectedDiskIsValid = true
                selectedDiskIssues = []
                selectedPendingWrite = PendingInternalWrite(
                    resolvedPath: written.resolvedPath,
                    fingerprint: written.fingerprint
                )
            } catch {
                logError("Failed to create configuration for path switch: \(error.localizedDescription)")
                return false
            }
        } else {
            guard state.isRuntimeUsable, let loadedConfig = state.config else {
                logError("Failed to load configuration after switching to \(normalizedPath)")
                return false
            }
            if state.isFuture || !state.unknownPaths.isEmpty || !state.semanticIssues.isEmpty {
                logError("Cannot switch to unsupported configuration at \(normalizedPath)")
                return false
            }

            selectedConfig = loadedConfig
            selectedFingerprint = state.fingerprint
            selectedIsLegacy = state.isLegacy
            selectedDiskIsValid = state.isDiskValid
            selectedDiskIssues = issuesForDiskState(state)
            selectedPendingWrite = nil

            // Migrate before changing the active manager identity. If the
            // write fails, the old path, runtime configuration, and revision
            // remain active as one failed path-switch operation.
            if state.isLegacy && loadedConfig.defaults.autoUpdateConfig {
                let migrated = migrateConfigurationToCurrentVersionValue(loadedConfig)
                if !createPreMigrationBackupIfNeededLocked(at: normalizedPath) {
                    logWarning("Pre-migration backup could not be created; continuing migration")
                }
                do {
                    let written = try writeConfigurationLocked(
                        migrated,
                        to: normalizedPath,
                        expectedFingerprint: state.fingerprint,
                        preserveBackup: true
                    )
                    selectedConfig = written.config
                    selectedFingerprint = written.fingerprint
                    selectedIsLegacy = false
                    selectedDiskIsValid = true
                    selectedDiskIssues = []
                    selectedPendingWrite = PendingInternalWrite(
                        resolvedPath: written.resolvedPath,
                        fingerprint: written.fingerprint
                    )
                } catch {
                    logError("Config path switch migration failed: \(error.localizedDescription)")
                    return false
                }
            }
        }

        let oldPath = configPath
        configPath = normalizedPath
        _config = selectedConfig
        hasLegacyConfigOnDisk = selectedIsLegacy
        acceptedDiskIsValid = selectedDiskIsValid
        acceptedDiskIssues = selectedDiskIssues
        acceptedRevision = ConfigurationRevision(
            generation: UUID().uuidString,
            // A path selection starts a fresh generation. The selected disk
            // state is the first accepted revision in that generation even
            // when selecting a missing path required creating the file.
            version: 1,
            fingerprint: selectedFingerprint
        )
        pendingInternalWrite = selectedPendingWrite
        configurationSuccessfullyLoadedLocked()
        UserDefaultsManager.shared.setConfigPath(normalizedPath)
        setupFileWatcherLocked()

        DispatchQueue.main.async { [weak self] in
            self?.onConfigChanged?("configPathChanged")
        }
        logInfo("Switched active configuration path from \(oldPath) to: \(normalizedPath)")
        return true
    }

    /// Trusted in-process callers (CLI and watcher recovery) use the closure
    /// form.  Editor callers should provide an expected revision and use the
    /// structured edit form below.
    @discardableResult
    func mutateConfiguration(
        expectedRevision: ConfigurationRevision? = nil,
        reason: String? = nil,
        _ mutation: (inout AppConfiguration) throws -> Void
    ) throws -> ConfigurationSnapshot {
        try syncQueue.sync {
            let state = refreshDiskStateLocked(notifyExternalChange: true)

            guard !state.isMissing else {
                throw ConfigurationTransactionError(
                    code: .invalidDiskState,
                    message: "Cannot mutate a missing configuration file"
                )
            }
            guard state.syntaxIsValid, let currentConfig = state.config else {
                throw transactionError(for: state)
            }
            guard state.semanticIssues.isEmpty else {
                throw transactionError(for: state)
            }
            guard !state.isFuture else {
                throw ConfigurationTransactionError(
                    code: .unsupportedVersion,
                    path: ["configVersion"],
                    message: "Configuration version is newer than the supported version"
                )
            }
            guard state.unknownPaths.isEmpty else {
                let path = state.unknownPaths[0]
                throw ConfigurationTransactionError(
                    code: .unknownKey,
                    path: path,
                    message: "Unsupported configuration key '\(path.last ?? "")'"
                )
            }
            if expectedRevision != nil, state.isLegacy {
                throw ConfigurationTransactionError(
                    code: .legacyConfiguration,
                    message: "Editor writes are unavailable until this legacy configuration is migrated"
                )
            }
            if let expectedRevision, expectedRevision != acceptedRevision {
                throw ConfigurationTransactionError(
                    code: .staleRevision,
                    message: "Configuration changed since this edit was prepared"
                )
            }

            var candidate = currentConfig
            try mutation(&candidate)
            Self.normalizeConfigurationForRuntime(&candidate)
            try validateCandidateConfiguration(candidate)
            let written = try writeConfigurationLocked(
                candidate,
                to: configPath,
                expectedFingerprint: state.fingerprint,
                preserveBackup: true
            )
            return commitWrittenConfigurationLocked(written, reason: reason)
        }
    }

    /// Applies a bounded, typed set of structured edits against an exact
    /// revision.  The result is suitable for an editor/API response and never
    /// reports success until the replacement is on disk.
    @discardableResult
    func mutateConfiguration(
        expectedRevision: ConfigurationRevision,
        edits: [ConfigurationEdit],
        reason: String? = "editor"
    ) -> ConfigurationTransactionResult {
        do {
            let snapshot = try syncQueue.sync {
                try applyStructuredEditsLocked(
                    edits,
                    expectedRevision: expectedRevision,
                    reason: reason
                )
            }
            return .committed(snapshot)
        } catch {
            return .rejected(transactionError(from: error))
        }
    }

    @discardableResult
    func applyConfigurationEdits(
        _ edits: [ConfigurationEdit],
        expectedRevision: ConfigurationRevision,
        reason: String? = "editor"
    ) -> ConfigurationTransactionResult {
        mutateConfiguration(expectedRevision: expectedRevision, edits: edits, reason: reason)
    }

    @discardableResult
    func applyConfigurationEdits(
        edits: [ConfigurationEdit],
        expectedRevision: ConfigurationRevision,
        reason: String? = "editor"
    ) -> ConfigurationTransactionResult {
        applyConfigurationEdits(edits, expectedRevision: expectedRevision, reason: reason)
    }

    @discardableResult
    func performConfigurationTransaction(
        expectedRevision: ConfigurationRevision,
        edits: [ConfigurationEdit],
        reason: String? = "editor"
    ) -> ConfigurationTransactionResult {
        mutateConfiguration(expectedRevision: expectedRevision, edits: edits, reason: reason)
    }

    /// Explicit reload used by the CLI.  It shares the same disk inspection
    /// and publication boundary as editor transactions and never repairs an
    /// invalid file as a side effect.
    func reloadConfiguration() -> Bool {
        let state = syncQueue.sync { () -> DiskState in
            // An explicit reload is a lifecycle operation even when the file
            // fingerprint is unchanged: clear stale notification state, re-arm
            // the watcher, and publish one runtime callback.  External-change
            // callbacks are disabled here so the reload cannot publish twice.
            let state = refreshDiskStateLocked(notifyExternalChange: false)
            let runtimeUsable = state.isRuntimeUsable && !state.isFuture
            if runtimeUsable {
                configurationSuccessfullyLoadedLocked()
                setupFileWatcherLocked()
            }

            let reason = runtimeUsable ? "configFileChanged" : "configValidationFallback"
            DispatchQueue.main.async { [weak self] in
                self?.onConfigChanged?(reason)
            }
            return state
        }

        let runtimeUsable = state.isRuntimeUsable && !state.isFuture
        if runtimeUsable {
            // Unknown fields remain visible through the snapshot and keep
            // editor writes blocked, but the typed runtime can still reload
            // them using the established compatibility decoder.
            return true
        }

        // Keep the existing user-facing recovery behavior for an external
        // malformed or semantically invalid file. This helper must run outside
        // syncQueue because it updates notification state through the same
        // queue.
        handleInvalidDiskStateOutsideSync(state)
        return false
    }

    private func handleInvalidDiskStateOutsideSync(_ state: DiskState) {
        guard !state.isRuntimeUsable || state.isFuture else { return }
        if state.isMissing {
            logWarning("Configuration file at \(state.requestedPath) is missing; keeping in-memory defaults")
            resetFileWatcher()
        } else if !state.syntaxIsValid {
            showJsonErrorNotification(decodingPath: state.semanticIssues.first?.path)
        } else if !state.semanticIssues.isEmpty {
            showConfigValidationErrorNotification(
                ConfigValidationReport(
                    isValid: false,
                    issues: state.semanticIssues,
                    configPath: state.requestedPath,
                    summary: "Configuration is invalid"
                )
            )
        } else if state.isFuture {
            logWarning("Configuration at \(state.requestedPath) uses a future configVersion and will remain unchanged")
            resetFileWatcher()
        }
    }

    private func applyStructuredEditsLocked(
        _ edits: [ConfigurationEdit],
        expectedRevision: ConfigurationRevision,
        reason: String?
    ) throws -> ConfigurationSnapshot {
        guard !edits.isEmpty else {
            throw ConfigurationTransactionError(
                code: .malformedEdit,
                message: "At least one configuration edit is required"
            )
        }

        let state = refreshDiskStateLocked(notifyExternalChange: true)
        guard !state.isMissing else {
            throw ConfigurationTransactionError(
                code: .invalidDiskState,
                message: "Cannot edit a missing configuration file"
            )
        }
        guard state.syntaxIsValid, state.config != nil else {
            throw transactionError(for: state)
        }
        guard state.semanticIssues.isEmpty else {
            throw transactionError(for: state)
        }
        guard !state.isFuture else {
            throw ConfigurationTransactionError(
                code: .unsupportedVersion,
                path: ["configVersion"],
                message: "Configuration version is newer than the supported version"
            )
        }
        guard state.unknownPaths.isEmpty else {
            let path = state.unknownPaths[0]
            throw ConfigurationTransactionError(
                code: .unknownKey,
                path: path,
                message: "Unsupported configuration key '\(path.last ?? "")'"
            )
        }
        guard !state.isLegacy else {
            throw ConfigurationTransactionError(
                code: .legacyConfiguration,
                message: "Editor writes are unavailable until this legacy configuration is migrated"
            )
        }
        guard expectedRevision == acceptedRevision else {
            throw ConfigurationTransactionError(
                code: .staleRevision,
                message: "Configuration changed since this edit was prepared"
            )
        }

        guard let originalData = state.data,
              var root = try JSONSerialization.jsonObject(with: originalData, options: []) as? [String: Any] else {
            throw ConfigurationTransactionError(
                code: .invalidDiskState,
                message: "Configuration JSON could not be read as an object"
            )
        }

        for edit in edits {
            try validateEdit(edit)
            try apply(edit, to: &root)
        }

        let candidateData: Data
        do {
            candidateData = try JSONSerialization.data(withJSONObject: root, options: [])
        } catch {
            throw ConfigurationTransactionError(
                code: .encodingFailed,
                message: "Failed to encode structured configuration edits: \(error.localizedDescription)"
            )
        }
        var candidate: AppConfiguration
        do {
            candidate = try JSONDecoder().decode(AppConfiguration.self, from: candidateData)
        } catch let error as DecodingError {
            throw ConfigurationTransactionError(
                code: .typeMismatch,
                message: Self.decodingErrorMessage(error)
            )
        } catch {
            throw ConfigurationTransactionError(
                code: .typeMismatch,
                message: "Edited configuration could not be decoded: \(error.localizedDescription)"
            )
        }
        Self.normalizeConfigurationForRuntime(&candidate)
        guard candidate.configVersion == AppConfiguration.currentConfigVersion else {
            throw ConfigurationTransactionError(
                code: .unsupportedVersion,
                path: ["configVersion"],
                message: "Edited configuration must use configVersion \(AppConfiguration.currentConfigVersion)"
            )
        }
        try validateCandidateConfiguration(candidate)
        let written = try writeConfigurationLocked(
            candidate,
            to: configPath,
            expectedFingerprint: state.fingerprint,
            preserveBackup: true
        )
        return commitWrittenConfigurationLocked(written, reason: reason)
    }

    private func validateCandidateConfiguration(_ candidate: AppConfiguration) throws {
        guard candidate.configVersion == AppConfiguration.currentConfigVersion else {
            throw ConfigurationTransactionError(
                code: .unsupportedVersion,
                path: ["configVersion"],
                message: "Configuration must use configVersion \(AppConfiguration.currentConfigVersion)"
            )
        }
        let issues = Self.sortedIssues(Self.validationIssues(for: candidate))
        guard issues.isEmpty else {
            throw ConfigurationTransactionError(
                code: .validationFailed,
                path: Self.pathSegments(for: issues[0], in: candidate),
                message: "Configuration validation failed: \(issues[0].message)",
                issues: issues
            )
        }
    }

    private func transactionError(for state: DiskState) -> ConfigurationTransactionError {
        if state.isFuture {
            return ConfigurationTransactionError(
                code: .unsupportedVersion,
                path: ["configVersion"],
                message: "Configuration version is newer than the supported version",
                issues: issuesForDiskState(state)
            )
        }
        if let path = state.unknownPaths.first {
            return ConfigurationTransactionError(
                code: .unknownKey,
                path: path,
                message: "Unsupported configuration key '\(path.last ?? "")'",
                issues: issuesForDiskState(state)
            )
        }
        let issues = issuesForDiskState(state)
        return ConfigurationTransactionError(
            code: !state.syntaxIsValid || state.semanticIssues.isEmpty
                ? .invalidDiskState
                : .validationFailed,
            path: issues.first.map { Self.pathSegments(for: $0, in: state.config) } ?? [],
            message: issues.first?.message ?? "Configuration file is invalid",
            issues: issues
        )
    }

    private func transactionError(from error: Error) -> ConfigurationTransactionError {
        if let error = error as? ConfigurationTransactionError { return error }
        if let error = error as? ConfigurationError {
            return ConfigurationTransactionError(
                code: .validationFailed,
                message: error.localizedDescription
            )
        }
        if let error = error as? DecodingError {
            return ConfigurationTransactionError(
                code: .malformedEdit,
                message: Self.decodingErrorMessage(error)
            )
        }
        return ConfigurationTransactionError(
            code: .persistenceFailed,
            message: error.localizedDescription
        )
    }

    /// Converts known validator paths back into structured segments without
    /// splitting action names on punctuation.  Unknown paths are retained as
    /// one opaque segment rather than pretending a dotted action name is a
    /// hierarchy.
    private static func pathSegments(
        for issue: ConfigValidationIssue,
        in config: AppConfiguration?
    ) -> [String] {
        let raw = issue.path
        if raw == "root" { return [] }
        if raw == "configVersion" { return ["configVersion"] }
        if raw.hasPrefix("defaults.") {
            return ["defaults", String(raw.dropFirst("defaults.".count))]
        }
        for section in actionSections.sorted() {
            let prefix = section + "."
            guard raw.hasPrefix(prefix) else { continue }
            let body = String(raw.dropFirst(prefix.count))
            let fields = supportedActionKeys(for: section).sorted { $0.count > $1.count }
            for field in fields {
                let suffix = "." + field
                guard body.hasSuffix(suffix) else { continue }
                let name = String(body.dropLast(suffix.count))
                if !name.isEmpty { return [section, name, field] }
            }
        }
        if raw.hasPrefix("actions.") {
            let body = String(raw.dropFirst("actions.".count))
            let nextActionSuffix = ".nextAction"
            let isNextActionIssue = body.hasSuffix(nextActionSuffix)
            let bodyName = isNextActionIssue
                ? String(body.dropLast(nextActionSuffix.count))
                : body
            let actionName = issue.rawValue?.isEmpty == false
                ? issue.rawValue!
                : bodyName
            if !actionName.isEmpty,
               let section = actionSection(containing: actionName, in: config) {
                return isNextActionIssue
                    ? [section, actionName, "nextAction"]
                    : [section, actionName]
            }
            // Preserve the action as one opaque segment when the validator
            // did not retain enough model information to identify its map.
            return isNextActionIssue
                ? ["actions", actionName, "nextAction"]
                : ["actions", actionName]
        }
        return [raw]
    }

    private static func actionSection(containing name: String, in config: AppConfiguration?) -> String? {
        guard let config else { return nil }
        for section in actionSections.sorted() {
            switch section {
            case "inserts":
                if config.inserts[name] != nil { return section }
            case "urls":
                if config.urls[name] != nil { return section }
            case "shortcuts":
                if config.shortcuts[name] != nil { return section }
            case "scriptsShell":
                if config.scriptsShell[name] != nil { return section }
            case "scriptsAS":
                if config.scriptsAS[name] != nil { return section }
            default:
                break
            }
        }
        return nil
    }

    private func commitWrittenConfigurationLocked(
        _ written: WrittenConfiguration,
        reason: String?
    ) -> ConfigurationSnapshot {
        _config = written.config
        hasLegacyConfigOnDisk = false
        acceptedDiskIsValid = true
        acceptedDiskIssues = []
        let nextVersion = acceptedRevision.version == UInt64.max
            ? UInt64.max
            : acceptedRevision.version + 1
        acceptedRevision = ConfigurationRevision(
            generation: acceptedRevision.generation,
            version: nextVersion,
            fingerprint: written.fingerprint
        )
        pendingInternalWrite = PendingInternalWrite(
            resolvedPath: written.resolvedPath,
            fingerprint: written.fingerprint
        )
        configurationSuccessfullyLoadedLocked()
        // Re-arm after a replacement so a symlink or a previously missing
        // target is followed by the watcher.  The identity marker above keeps
        // the resulting event from causing a duplicate runtime reload.
        setupFileWatcherLocked()
        let snapshot = makeSnapshotLocked()
        DispatchQueue.main.async { [weak self] in
            self?.onConfigChanged?(reason)
        }
        return snapshot
    }

    private func writeConfigurationLocked(
        _ candidate: AppConfiguration,
        to requestedPath: String,
        expectedFingerprint: String,
        preserveBackup: Bool
    ) throws -> WrittenConfiguration {
        var configuration = candidate
        if let schemaReference = SchemaManager.getSchemaReference(), configuration.schema != schemaReference {
            configuration.schema = schemaReference
        }

        // v3 stores Insert newline tokens as the two-character sequence
        // backslash+n.  Canonicalize raw control newlines at the persistence
        // boundary so editor, CLI, and watcher writes all produce identical
        // JSON regardless of which caller supplied the candidate model.
        for name in configuration.inserts.keys {
            guard var insert = configuration.inserts[name] else { continue }
            insert.action = canonicalizeMacrowhisperInsertAction(insert.action)
            configuration.inserts[name] = insert
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .useDefaultKeys
        let encoded: Data
        do {
            encoded = try encoder.encode(configuration)
        } catch {
            throw ConfigurationTransactionError(
                code: .encodingFailed,
                message: "Failed to encode configuration: \(error.localizedDescription)"
            )
        }

        let jsonString = String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
        // JSONEncoder has already serialized numeric values structurally. Do
        // not run a regular expression over this text: action payloads are
        // strings and decimal-looking text inside them must remain byte-for-
        // byte unchanged.
        guard let data = jsonString.data(using: .utf8) else {
            throw ConfigurationTransactionError(
                code: .encodingFailed,
                message: "Failed to encode configuration as UTF-8"
            )
        }

        let targetPath = Self.resolveSymlink(requestedPath)
        let targetDirectory = (targetPath as NSString).deletingLastPathComponent
        do {
            if !fileManager.fileExists(atPath: targetDirectory) {
                try fileManager.createDirectory(
                    atPath: targetDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }
        } catch {
            throw ConfigurationTransactionError(
                code: .persistenceFailed,
                message: "Failed to prepare configuration directory: \(error.localizedDescription)"
            )
        }

        guard Self.diskFingerprint(at: targetPath) == expectedFingerprint else {
            throw ConfigurationTransactionError(
                code: .resourceMismatch,
                message: "Configuration changed before it could be written"
            )
        }

        let temporaryPath = (targetDirectory as NSString).appendingPathComponent(
            ".\((targetPath as NSString).lastPathComponent).tmp.\(UUID().uuidString)"
        )
        let existingAttributes = try? fileManager.attributesOfItem(atPath: targetPath)
        let permissions = existingAttributes?[.posixPermissions] ?? NSNumber(value: Int(0o600))
        var temporaryCreated = false
        var backupTemporaryCreated = false
        var backupTemporaryPath: String?
        defer {
            if temporaryCreated, fileManager.fileExists(atPath: temporaryPath) {
                try? fileManager.removeItem(atPath: temporaryPath)
            }
            if backupTemporaryCreated, let backupTemporaryPath,
               fileManager.fileExists(atPath: backupTemporaryPath) {
                try? fileManager.removeItem(atPath: backupTemporaryPath)
            }
        }

        guard fileManager.createFile(
            atPath: temporaryPath,
            contents: nil,
            attributes: [.posixPermissions: permissions]
        ) else {
            throw ConfigurationTransactionError(
                code: .persistenceFailed,
                message: "Failed to create unique temporary configuration file"
            )
        }
        temporaryCreated = true
        do {
#if CONFIGURATION_TRANSACTION_TESTING
            try Self.transactionBeforeTemporaryWriteHook?(temporaryPath, data)
#endif
            try data.write(to: URL(fileURLWithPath: temporaryPath))
            try fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: temporaryPath
            )
        } catch {
            throw ConfigurationTransactionError(
                code: .persistenceFailed,
                message: "Failed to write temporary configuration file: \(error.localizedDescription)"
            )
        }

        let temporaryState = inspectDisk(at: temporaryPath)
        guard temporaryState.isRuntimeUsable,
              temporaryState.unknownPaths.isEmpty,
              !temporaryState.isLegacy,
              !temporaryState.isFuture,
              let verifiedConfig = temporaryState.config else {
            throw ConfigurationTransactionError(
                code: .encodingFailed,
                path: issuesForDiskState(temporaryState).first.map { Self.pathSegments(for: $0, in: temporaryState.config) } ?? [],
                message: "Generated configuration failed side-effect-free validation",
                issues: issuesForDiskState(temporaryState)
            )
        }

#if CONFIGURATION_TRANSACTION_TESTING
        Self.transactionBeforeReplaceHook?()
#endif

        // Resolve the requested path again immediately before replacement. A
        // symlink target can change while the candidate is being prepared; in
        // that case the temporary file belongs to the old target directory and
        // must never be installed at the newly selected target.
        let replacementTargetPath = Self.resolveSymlink(requestedPath)
        guard replacementTargetPath == targetPath else {
            throw ConfigurationTransactionError(
                code: .resourceMismatch,
                message: "Configuration symlink target changed while the transaction was being prepared"
            )
        }

        // This check is deliberately immediately before the replacement.  It
        // detects ordinary external edits; the remaining replace window is a
        // filesystem limitation and is not represented as a false guarantee.
        guard Self.diskFingerprint(at: replacementTargetPath) == expectedFingerprint else {
            throw ConfigurationTransactionError(
                code: .resourceMismatch,
                message: "Configuration changed while the transaction was being prepared"
            )
        }

        let targetExistsAtReplacement = fileManager.fileExists(atPath: replacementTargetPath)
        if targetExistsAtReplacement && preserveBackup {
            // Keep one manager-owned latest snapshot. The explicit suffix
            // avoids broad cleanup of user files and makes recovery predictable
            // across repeated field saves.
            let backupPath = replacementTargetPath + ".macrowhisper-backup"
            let newBackupPath = backupPath + ".tmp.\(UUID().uuidString)"
            backupTemporaryPath = newBackupPath
            backupTemporaryCreated = true
            do {
                try fileManager.copyItem(atPath: replacementTargetPath, toPath: newBackupPath)
                if fileManager.fileExists(atPath: backupPath) {
                    _ = try fileManager.replaceItem(
                        at: URL(fileURLWithPath: backupPath),
                        withItemAt: URL(fileURLWithPath: newBackupPath),
                        backupItemName: nil,
                        options: [],
                        resultingItemURL: nil
                    )
                } else {
                    try fileManager.moveItem(atPath: newBackupPath, toPath: backupPath)
                }
                backupTemporaryCreated = false
            } catch {
                throw ConfigurationTransactionError(
                    code: .persistenceFailed,
                    message: "Failed to preserve the previous configuration: \(error.localizedDescription)"
                )
            }
            guard Self.diskFingerprint(at: replacementTargetPath) == expectedFingerprint else {
                throw ConfigurationTransactionError(
                    code: .resourceMismatch,
                    message: "Configuration changed while preserving its backup"
                )
            }
        }

        do {
            // Re-resolve one more time while still before the replacement.
            // This closes the common symlink-switch window without making a
            // fallible read or decode necessary after the atomic operation.
            guard Self.resolveSymlink(requestedPath) == replacementTargetPath else {
                throw ConfigurationTransactionError(
                    code: .resourceMismatch,
                    message: "Configuration symlink target changed before replacement"
                )
            }
            if targetExistsAtReplacement {
                _ = try fileManager.replaceItem(
                    at: URL(fileURLWithPath: replacementTargetPath),
                    withItemAt: URL(fileURLWithPath: temporaryPath),
                    backupItemName: nil,
                    options: [],
                    resultingItemURL: nil
                )
            } else {
                guard Self.diskFingerprint(at: replacementTargetPath) == expectedFingerprint else {
                    throw ConfigurationTransactionError(
                        code: .resourceMismatch,
                        message: "Configuration appeared while the transaction was being prepared"
                    )
                }
                try fileManager.moveItem(atPath: temporaryPath, toPath: replacementTargetPath)
            }
            temporaryCreated = false
        } catch let error as ConfigurationTransactionError {
            throw error
        } catch {
            throw ConfigurationTransactionError(
                code: .persistenceFailed,
                message: "Failed to atomically replace configuration: \(error.localizedDescription)"
            )
        }

#if CONFIGURATION_TRANSACTION_TESTING
        // This callback deliberately cannot throw. It models an external
        // writer winning immediately after replacement; the returned marker
        // must still be based on the verified candidate bytes so the next
        // snapshot observes that external write.
        Self.transactionAfterReplaceHook?(replacementTargetPath)
#endif

        // Everything that can throw has completed before replacement. The
        // candidate was decoded and semantically validated from the temporary
        // sibling above, so publish that verified value instead of performing a
        // fallible post-replace read that could report failure after the user's
        // file has already changed.
        // Hash the bytes that were verified before replacement while taking
        // the installed file identity from the target.  Reading the target
        // after replacement could accidentally capture an unrelated external
        // edit that raced us and then mark that edit as our own.
        let finalFingerprint = Self.diskFingerprint(at: replacementTargetPath, data: data)
        return WrittenConfiguration(
            config: verifiedConfig,
            fingerprint: finalFingerprint,
            resolvedPath: replacementTargetPath
        )
    }

    private func migrateConfigurationToCurrentVersionValue(_ source: AppConfiguration) -> AppConfiguration {
        var migrated = source
        _ = migrateConfigurationToCurrentVersion(&migrated)
        _ = Self.normalizeEscInputConditionTokens(&migrated)
        _ = migrated.defaults.canonicalizeRootDefaultsForPersistence()
        return migrated
    }

    private static func diskFingerprint(at path: String, data: Data? = nil) -> String {
        let resolvedPath = resolveSymlink(path)
        let bytes: Data?
        if let data {
            bytes = data
        } else {
            bytes = try? Data(contentsOf: URL(fileURLWithPath: resolvedPath), options: .uncached)
        }
        guard let bytes else {
            return "missing:\(resolvedPath)"
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath)
        let inode = String(describing: attributes?[.systemFileNumber] ?? "")
        let device = String(describing: attributes?[.systemNumber] ?? "")
        let size = String(describing: attributes?[.size] ?? bytes.count)

        // A stable, dependency-free digest is enough for an in-process
        // compare-and-recheck.  Include file identity so replacing a file with
        // identical bytes still advances the revision.
        var first: UInt64 = 14695981039346656037
        var second: UInt64 = 1099511628211
        for byte in bytes {
            first ^= UInt64(byte)
            first = first &* 1099511628211
            second ^= UInt64(byte) &+ 0x9e3779b97f4a7c15
            second = second &* 14029467366897019727
        }
        return "file:\(resolvedPath)|\(device)|\(inode)|\(size)|\(String(first, radix: 16)):\(String(second, radix: 16))"
    }

    private static func unknownPaths(in root: [String: Any]) -> [[String]] {
        var paths: [[String]] = []
        for key in root.keys.sorted() where !supportedRootKeys.contains(key) {
            paths.append([key])
        }

        if let defaults = root["defaults"] as? [String: Any] {
            for key in defaults.keys.sorted() where !supportedDefaultsKeys.contains(key) {
                paths.append(["defaults", key])
            }
        }

        for section in actionSections.sorted() {
            guard let actions = root[section] as? [String: Any] else { continue }
            for name in actions.keys.sorted() {
                guard let action = actions[name] as? [String: Any] else { continue }
                let allowedKeys = supportedActionKeys(for: section)
                for key in action.keys.sorted() where !allowedKeys.contains(key) {
                    paths.append([section, name, key])
                }
            }
        }
        return paths
    }

    private static func containsLegacyKeys(in root: [String: Any]) -> Bool {
        if let defaults = root["defaults"] as? [String: Any],
           defaults.keys.contains(where: { ["noUpdates", "noNoti", "noEsc", "pressReturn"].contains($0) }) {
            return true
        }
        for section in actionSections {
            guard let actions = root[section] as? [String: Any] else { continue }
            for value in actions.values {
                if let action = value as? [String: Any],
                   action.keys.contains(where: { ["noEsc", "pressReturn"].contains($0) }) {
                    return true
                }
            }
        }
        return false
    }

    private func validateEdit(_ edit: ConfigurationEdit) throws {
        guard !edit.path.isEmpty,
              edit.path.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ConfigurationTransactionError(
                code: .invalidPath,
                path: edit.path,
                message: "Configuration edit paths must contain non-empty segments"
            )
        }

        switch edit.operation {
        case .set:
            guard let value = edit.value else {
                throw ConfigurationTransactionError(
                    code: .malformedEdit,
                    path: edit.path,
                    message: "A set edit must include a value; use null explicitly when needed"
                )
            }
            try validateSetValue(value, at: edit.path)
        case .remove:
            guard edit.value == nil else {
                throw ConfigurationTransactionError(
                    code: .malformedEdit,
                    path: edit.path,
                    message: "A remove edit must omit value"
                )
            }
            try validateRemovePath(edit.path)
        }
    }

    private func validateSetValue(_ value: ConfigurationJSONValue, at path: [String]) throws {
        guard let kind = editValueKind(for: path) else {
            // A two-segment action path addresses an action object and is
            // validated separately below.
            if path.count == 2, Self.actionSections.contains(path[0]), path[1].isEmpty == false {
                guard case .object(let object) = value else {
                    throw ConfigurationTransactionError(
                        code: .typeMismatch,
                        path: path,
                        message: "An action definition must be a JSON object"
                    )
                }
                try validateActionObject(object, section: path[0], path: path)
                return
            }
            throw ConfigurationTransactionError(
                code: .invalidPath,
                path: path,
                message: "Unsupported configuration field path"
            )
        }

        guard path.count == 2 || path.count == 3 else {
            throw ConfigurationTransactionError(
                code: .invalidPath,
                path: path,
                message: "Configuration edits must address one field or one action"
            )
        }
        try validate(value, against: kind, path: path)
    }

    private func validateRemovePath(_ path: [String]) throws {
        guard editValueKind(for: path) != nil ||
                (path.count == 2 && Self.actionSections.contains(path[0])) else {
            throw ConfigurationTransactionError(
                code: .invalidPath,
                path: path,
                message: "Unsupported configuration field path"
            )
        }
        if path.count == 3, editValueKind(for: path) == nil {
            throw ConfigurationTransactionError(
                code: .invalidPath,
                path: path,
                message: "Unsupported action field path"
            )
        }
        if path.count == 3, path[2] == "action" {
            throw ConfigurationTransactionError(
                code: .invalidPath,
                path: path,
                message: "The required action payload cannot be removed"
            )
        }
    }

    private func validateActionObject(
        _ object: [String: ConfigurationJSONValue],
        section: String,
        path: [String]
    ) throws {
        let allowedKeys = Self.editableActionKeys(for: section)
        guard object.keys.allSatisfy(allowedKeys.contains) else {
            let key = object.keys.sorted().first { !allowedKeys.contains($0) } ?? ""
            throw ConfigurationTransactionError(
                code: .unknownKey,
                path: path + [key],
                message: "Unsupported action key '\(key)'"
            )
        }
        guard let action = object["action"] else {
            throw ConfigurationTransactionError(
                code: .typeMismatch,
                path: path + ["action"],
                message: "An action definition requires an action payload"
            )
        }
        guard case .string = action else {
            throw ConfigurationTransactionError(
                code: .typeMismatch,
                path: path + ["action"],
                message: "The action payload must be a string"
            )
        }
        for key in object.keys.sorted() where key != "action" {
            guard let kind = editValueKind(for: [section, path[1], key]) else {
                throw ConfigurationTransactionError(
                    code: .invalidPath,
                    path: path + [key],
                    message: "Unsupported action field path"
                )
            }
            try validate(object[key]!, against: kind, path: path + [key])
        }
    }

    private func validate(
        _ value: ConfigurationJSONValue,
        against kind: EditValueKind,
        path: [String]
    ) throws {
        switch value {
        case .null:
            let nullable: Bool
            switch kind {
            case .string(let allows), .boolean(let allows), .number(let allows), .integer(let allows):
                nullable = allows
            }
            guard nullable else {
                throw ConfigurationTransactionError(
                    code: .typeMismatch,
                    path: path,
                    message: "This field does not accept null"
                )
            }
        case .string:
            guard case .string = kind else {
                throw ConfigurationTransactionError(code: .typeMismatch, path: path, message: "Expected a numeric or boolean value")
            }
        case .boolean:
            guard case .boolean = kind else {
                throw ConfigurationTransactionError(code: .typeMismatch, path: path, message: "Expected a string or numeric value")
            }
        case .integer(let number):
            switch kind {
            case .integer:
                guard number >= 0 || path.last != "history" else {
                    throw ConfigurationTransactionError(code: .outOfRange, path: path, message: "Value must be at least 0")
                }
            case .number:
                guard number >= 0 || !isRangeCheckedNumericField(path) else {
                    throw ConfigurationTransactionError(code: .outOfRange, path: path, message: "Value must be at least 0")
                }
            default:
                throw ConfigurationTransactionError(code: .typeMismatch, path: path, message: "Expected a string or boolean value")
            }
        case .number(let number):
            switch kind {
            case .number:
                guard number.isFinite else {
                    throw ConfigurationTransactionError(code: .typeMismatch, path: path, message: "Value must be finite")
                }
                guard number >= 0 || !isRangeCheckedNumericField(path) else {
                    throw ConfigurationTransactionError(code: .outOfRange, path: path, message: "Value must be at least 0")
                }
            default:
                throw ConfigurationTransactionError(code: .typeMismatch, path: path, message: "Expected an integer, string, or boolean value")
            }
        case .array, .object:
            throw ConfigurationTransactionError(code: .typeMismatch, path: path, message: "Expected a scalar value")
        }
    }

    private func isRangeCheckedNumericField(_ path: [String]) -> Bool {
        guard let field = path.last else { return false }
        return [
            "actionDelay", "history", "returnDelay", "restoreClipboardDelay",
            "scheduledActionTimeout", "scriptWaitTimeout", "clipboardBuffer"
        ].contains(field)
    }

    private func editValueKind(for path: [String]) -> EditValueKind? {
        let section: String
        let field: String
        switch path.count {
        case 2 where path[0] == "defaults":
            section = "defaults"
            field = path[1]
        case 3 where Self.actionSections.contains(path[0]):
            section = path[0]
            field = path[2]
        default:
            return nil
        }

        guard Self.isEditableField(section: section, field: field) else {
            return nil
        }

        let strings: Set<String> = [
            "watch", "activeAction", "icon", "moveTo", "clipboardIgnore", "bypassModes", "nextAction",
            "action", "inputCondition", "triggerVoice", "triggerApps", "triggerModes", "triggerUrls",
            "triggerLogic", "openWith"
        ]
        let booleans: Set<String> = [
            "disableUpdateCheck", "muteNotifications", "simEsc", "simKeypress", "smartCasing",
            "smartPunctuation", "smartSpacing", "simReturn", "restoreClipboard", "scriptAsync",
            "clipboardStacking", "clipboardAttachments", "muteTriggers", "autoUpdateConfig",
            "redactedLogs", "openBackground"
        ]
        let numbers: Set<String> = [
            "actionDelay", "returnDelay", "restoreClipboardDelay", "scheduledActionTimeout",
            "scriptWaitTimeout", "clipboardBuffer"
        ]
        if strings.contains(field) {
            // `action` is required and accepts no null.  Every other string in
            // the schema has explicit nullable/inheritance semantics.
            return .string(nullable: field != "action")
        }
        if booleans.contains(field) { return .boolean(nullable: true) }
        if numbers.contains(field) { return .number(nullable: true) }
        if field == "history" { return .integer(nullable: true) }
        return nil
    }

    private static func isEditableField(section: String, field: String) -> Bool {
        if section == "defaults" {
            return supportedDefaultsKeys.contains(field) && !legacyFieldKeys.contains(field)
        }
        guard actionSections.contains(section) else { return false }
        return editableActionKeys(for: section).contains(field)
    }

    private func apply(_ edit: ConfigurationEdit, to root: inout [String: Any]) throws {
        guard let value = edit.value else {
            if edit.operation == .set {
                throw ConfigurationTransactionError(code: .malformedEdit, path: edit.path, message: "Set edit is missing value")
            }
            try remove(edit.path, from: &root)
            return
        }
        guard edit.operation == .set else {
            throw ConfigurationTransactionError(code: .malformedEdit, path: edit.path, message: "Remove edit must omit value")
        }
        let foundationValue = try foundationValue(value)
        switch edit.path.count {
        case 2 where edit.path[0] == "defaults":
            var defaults = root["defaults"] as? [String: Any] ?? [:]
            defaults[edit.path[1]] = foundationValue
            root["defaults"] = defaults
        case 2 where Self.actionSections.contains(edit.path[0]):
            guard case let actionObject as [String: Any] = foundationValue else {
                throw ConfigurationTransactionError(code: .typeMismatch, path: edit.path, message: "An action definition must be an object")
            }
            var actions = root[edit.path[0]] as? [String: Any] ?? [:]
            actions[edit.path[1]] = actionObject
            root[edit.path[0]] = actions
        case 3 where Self.actionSections.contains(edit.path[0]):
            guard var actions = root[edit.path[0]] as? [String: Any],
                  var action = actions[edit.path[1]] as? [String: Any] else {
                throw ConfigurationTransactionError(code: .invalidPath, path: edit.path, message: "Referenced action does not exist")
            }
            action[edit.path[2]] = foundationValue
            actions[edit.path[1]] = action
            root[edit.path[0]] = actions
        default:
            throw ConfigurationTransactionError(code: .invalidPath, path: edit.path, message: "Unsupported configuration field path")
        }
    }

    private func remove(_ path: [String], from root: inout [String: Any]) throws {
        switch path.count {
        case 2 where path[0] == "defaults":
            var defaults = root["defaults"] as? [String: Any] ?? [:]
            defaults.removeValue(forKey: path[1])
            root["defaults"] = defaults
        case 2 where Self.actionSections.contains(path[0]):
            var actions = root[path[0]] as? [String: Any] ?? [:]
            actions.removeValue(forKey: path[1])
            root[path[0]] = actions
        case 3 where Self.actionSections.contains(path[0]):
            guard var actions = root[path[0]] as? [String: Any],
                  var action = actions[path[1]] as? [String: Any] else {
                throw ConfigurationTransactionError(code: .invalidPath, path: path, message: "Referenced action does not exist")
            }
            action.removeValue(forKey: path[2])
            actions[path[1]] = action
            root[path[0]] = actions
        default:
            throw ConfigurationTransactionError(code: .invalidPath, path: path, message: "Unsupported configuration field path")
        }
    }

    private func foundationValue(_ value: ConfigurationJSONValue) throws -> Any {
        switch value {
        case .null: return NSNull()
        case .boolean(let value): return value
        case .integer(let value): return value
        case .number(let value):
            guard value.isFinite else {
                throw ConfigurationTransactionError(code: .typeMismatch, message: "Non-finite numbers are not valid JSON")
            }
            return value
        case .string(let value): return value
        case .array(let values): return try values.map { try foundationValue($0) }
        case .object(let values):
            var object: [String: Any] = [:]
            for key in values.keys { object[key] = try foundationValue(values[key]!) }
            return object
        }
    }

    /// Returns duplicate action names when the same name is defined in more than one action type map.
    private static func actionNameExists(_ name: String, in config: AppConfiguration) -> Bool {
        config.inserts[name] != nil ||
            config.urls[name] != nil ||
            config.shortcuts[name] != nil ||
            config.scriptsShell[name] != nil ||
            config.scriptsAS[name] != nil
    }

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

        // Walk roots in a stable order so a cycle diagnostic points to the
        // same real action across runs and can be addressed by an editor.
        for name in nextActionMap.keys.sorted() {
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
    
    /// Shows user-friendly notification for JSON configuration errors with compact hints.
    private func showJsonErrorNotification(decodingPath: String?) {
        let shouldNotify = syncQueue.sync { () -> Bool in
            guard !hasNotifiedAboutJsonError else { return false }
            hasNotifiedAboutJsonError = true
            return true
        }
        guard shouldNotify else { return }

        let path = (decodingPath ?? "root").trimmingCharacters(in: .whitespacesAndNewlines)
        let message = compactValidationNotificationMessage(
            prefix: "Config parse error at \(path.isEmpty ? "root" : path).",
            maxLength: 160
        )

        notify(title: "MacroWhisper - Configuration Error", message: message)

        let currentPath = getCurrentConfigPath()
        logWarning("Configuration file at \(currentPath) contains invalid JSON. Application will continue with default settings.")
        logWarning("To inspect issues quickly, run: macrowhisper --validate-config")

        // Reset the file watcher to recover from JSON error
        self.resetFileWatcher()
    }

    private func showConfigValidationErrorNotification(_ report: ConfigValidationReport) {
        let shouldNotify = syncQueue.sync { () -> Bool in
            guard !hasNotifiedAboutValidationError else { return false }
            hasNotifiedAboutValidationError = true
            return true
        }
        if shouldNotify {
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
        logWarning("Configuration validation errors in \(getCurrentConfigPath()): \(details)")
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
    
    /// Persists the currently accepted runtime configuration through the same
    /// serialized transaction boundary as editor and CLI edits.  This legacy
    /// entry point intentionally does not repair an invalid file or publish
    /// in-memory state before the atomic replacement succeeds.
    func saveConfig() throws {
        try syncQueue.sync {
            let state = refreshDiskStateLocked(notifyExternalChange: true)
            guard state.isRuntimeUsable, state.semanticIssues.isEmpty,
                  state.unknownPaths.isEmpty, !state.isFuture, !state.isLegacy else {
                throw transactionError(for: state)
            }
            try validateCandidateConfiguration(_config)
            let written = try writeConfigurationLocked(
                _config,
                to: configPath,
                expectedFingerprint: state.fingerprint,
                preserveBackup: true
            )
            _ = commitWrittenConfigurationLocked(written, reason: "saveConfig")
        }
    }
    
    /// Configuration-specific errors for better error handling
    enum ConfigurationError: Error, LocalizedError {
        case corruptedWrite(String)
        case invalidJSON(String)
        case permissionDenied(String)
        
        var errorDescription: String? {
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
        // `watcher` is retained for source compatibility with the existing
        // startup recovery callers; the persisted setting is the configured
        // watch path and there is no independent boolean field to write.
        _ = watcher
        guard let activeAction else { return }

        do {
            try mutateConfiguration(reason: "commandLineUpdate") { candidate in
                let normalized = activeAction.isEmpty ? "" : activeAction
                if !normalized.isEmpty && !Self.actionNameExists(normalized, in: candidate) {
                    throw ConfigurationError.invalidJSON("Action '\(normalized)' does not exist")
                }
                candidate.defaults.activeAction = normalized
            }
        } catch {
            logError("Failed to save configuration from command line update: \(error.localizedDescription)")
        }
    }

    func updateFromCommandLineAsync(arguments: [String: String], completion: (() -> Void)?) {
        commandQueue.async { [weak self] in
            guard let self else { return }
            self.updateFromCommandLine(
                watcher: arguments["watcher"].flatMap { Bool($0) },
                activeAction: arguments["activeAction"]
            )
            DispatchQueue.main.async { completion?() }
        }
    }

    /// Must be called on `syncQueue` (or during initialization before the
    /// manager is published). The watcher callback itself immediately returns
    /// to that queue so all accepted state and identity checks are serialized.
    private func setupFileWatcherLocked() {
        fileWatcher?.stop()
        
        logDebug("Setting up file watcher for configuration at: \(configPath)")
        
        fileWatcher = ConfigChangeWatcher(filePath: configPath, onChanged: { [weak self] in
            logDebug("Configuration file change detected. Reloading.")
            guard let self = self else { return }

            self.syncQueue.async {
                let state = self.refreshDiskStateLocked(notifyExternalChange: true)
                if state.isRuntimeUsable {
                    logDebug("Configuration automatically reloaded after file change")
                } else {
                    logError("Failed to reload configuration after file change")
                    logWarning("Applied in-memory default configuration due to invalid configuration file")
                    // `refreshDiskStateLocked` must remain side-effect-free
                    // with respect to user notifications while it is on the
                    // serialized queue. Defer the established notification
                    // and watcher reset until the queue work has returned.
                    DispatchQueue.main.async { [weak self] in
                        self?.handleInvalidDiskStateOutsideSync(state)
                    }
                }
            }
        })
        
        fileWatcher?.start()
    }

    func resetFileWatcher() {
        logDebug("Resetting file watcher due to previous JSON error...")

        // Stop and restart through the same serialization boundary used by
        // path switches and commits. The delay lets an atomic replacement
        // event settle without touching manager state from the main queue.
        syncQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.setupFileWatcherLocked()
            logDebug("File watcher has been reset and reinitialized")
        }
    }

    private func configurationSuccessfullyLoadedLocked() {
        // Reset notification flags when config is successfully reloaded
        hasNotifiedAboutJsonError = false
        hasNotifiedAboutValidationError = false
    }

    func configurationSuccessfullyLoaded() {
        syncQueue.sync { configurationSuccessfullyLoadedLocked() }
    }
    
    func getHistoryRetentionDays() -> Int? {
        return syncQueue.sync {
            _config.defaults.history
        }
    }
    
    // MARK: - Configuration Update
    /// Updates the configuration file by reloading from disk and re-saving
    /// This ensures the configuration is updated with any new schema changes or defaults
    /// while preserving user data
    func updateConfiguration() -> Bool {
        logInfo("Updating configuration file...")

        return syncQueue.sync {
            let state = refreshDiskStateLocked(notifyExternalChange: true)
            guard !state.isMissing, state.syntaxIsValid, let currentConfig = state.config else {
                logError("Failed to load current configuration for update")
                return false
            }
            guard state.semanticIssues.isEmpty, state.unknownPaths.isEmpty, !state.isFuture else {
                logError("Configuration update rejected: \(transactionError(for: state).localizedDescription)")
                return false
            }

            var updatedConfig = currentConfig
            if state.isLegacy || (currentConfig.configVersion ?? 1) < AppConfiguration.currentConfigVersion {
                let createdBackup = createPreMigrationBackupIfNeededLocked()
                if !createdBackup {
                    logWarning("Pre-migration backup could not be created; continuing migration")
                }
                let didMigrate = migrateConfigurationToCurrentVersion(&updatedConfig)
                if didMigrate {
                    logInfo("Migrated configuration semantics to configVersion \(AppConfiguration.currentConfigVersion)")
                } else {
                    updatedConfig.configVersion = AppConfiguration.currentConfigVersion
                    logInfo("Marked configuration as configVersion \(AppConfiguration.currentConfigVersion)")
                }
            }
            _ = Self.normalizeEscInputConditionTokens(&updatedConfig)
            _ = updatedConfig.defaults.canonicalizeRootDefaultsForPersistence()

            do {
                try validateCandidateConfiguration(updatedConfig)
                let written = try writeConfigurationLocked(
                    updatedConfig,
                    to: configPath,
                    expectedFingerprint: state.fingerprint,
                    preserveBackup: true
                )
                _ = commitWrittenConfigurationLocked(written, reason: "configUpdate")
                logInfo("Configuration file updated successfully")
                return true
            } catch {
                logError("Failed to save updated configuration: \(error.localizedDescription)")
                return false
            }
        }
    }

    private func createPreMigrationBackupIfNeededLocked(at requestedPath: String? = nil) -> Bool {
        let targetPath = Self.resolveSymlink(requestedPath ?? configPath)
        let backupPath = targetPath + ".backup.pre-v\(AppConfiguration.currentConfigVersion)"
        if fileManager.fileExists(atPath: backupPath) {
            return true
        }
        do {
            try fileManager.copyItem(atPath: targetPath, toPath: backupPath)
            logInfo("Created pre-migration backup at: \(backupPath)")
            return true
        } catch {
            logError("Failed to create pre-migration backup: \(error)")
            return false
        }
    }

    private func migrateConfigurationToCurrentVersion(_ config: inout AppConfiguration) -> Bool {
        var changed = false

        if (config.configVersion ?? 1) < 2 {
            changed = migrateConfigurationToV2(&config) || changed
            config.configVersion = 2
            changed = true
        }

        if (config.configVersion ?? 1) < 3 {
            changed = migrateConfigurationToV3(&config) || changed
            config.configVersion = 3
            changed = true
        }

        if config.configVersion != AppConfiguration.currentConfigVersion {
            config.configVersion = AppConfiguration.currentConfigVersion
            changed = true
        }

        return changed
    }

    private func migrateConfigurationToV2(_ config: inout AppConfiguration) -> Bool {
        return Self.applyV2Normalization(&config)
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
        return changed
    }

    private static func normalizeConfigurationForRuntime(_ config: inout AppConfiguration) {
        _ = normalizeEscInputConditionTokens(&config)
        var version = config.configVersion ?? 1
        if version < 2 {
            _ = applyV2Normalization(&config)
            version = 2
        }
        if version < 3 {
            _ = migrateLegacyInsertActionsForRuntime(&config)
            version = 3
        }
        if (config.configVersion ?? 1) < AppConfiguration.currentConfigVersion {
            config.configVersion = AppConfiguration.currentConfigVersion
        }
    }

    /// Legacy files remain executable when automatic disk migration is
    /// disabled.  Normalize their Insert payloads in memory using the same
    /// sequential v1/v2 -> v3 conversion as an explicit update, without
    /// changing the bytes on disk.
    private static func migrateLegacyInsertActionsForRuntime(_ config: inout AppConfiguration) -> Bool {
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
        return changed
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
