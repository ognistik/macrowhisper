import Foundation

/// Decodes the v3 Insert action escape syntax at runtime.
///
/// A single (odd) backslash before `n` is Macrowhisper's newline token.  An
/// even run preserves its paired backslashes, so `\\n` in the decoded action
/// remains a literal backslash followed by `n`.  Keeping this parser outside
/// of JSON decoding is important: JSON escaping and Macrowhisper escaping are
/// two separate layers.
func decodeMacrowhisperInsertEscapes(_ value: String) -> String {
    let characters = Array(value)
    var result = String()
    result.reserveCapacity(value.count)

    var index = 0
    while index < characters.count {
        guard characters[index] == "\\" else {
            result.append(characters[index])
            index += 1
            continue
        }

        var slashCount = 0
        while index < characters.count, characters[index] == "\\" {
            slashCount += 1
            index += 1
        }

        guard index < characters.count, characters[index] == "n" else {
            result.append(String(repeating: "\\", count: slashCount))
            continue
        }

        result.append(String(repeating: "\\", count: slashCount / 2))
        if slashCount.isMultiple(of: 2) {
            result.append("n")
        } else {
            result.append("\n")
        }
        index += 1
    }

    return result
}

/// Converts raw control newlines in an Insert action to the canonical v3
/// token.  Existing backslash runs are deliberately left untouched; this is
/// a persistence-layer operation, not runtime escape decoding.
func canonicalizeMacrowhisperInsertAction(_ value: String) -> String {
    var result = String()
    result.reserveCapacity(value.count)

    let characters = Array(value)
    var index = 0
    while index < characters.count {
        if characters[index] == "\r" {
            if index + 1 < characters.count, characters[index + 1] == "\n" {
                index += 1
            }
            result += "\\n"
        } else if characters[index] == "\n" {
            result += "\\n"
        } else {
            result.append(characters[index])
        }
        index += 1
    }
    return result
}

/// Converts a legacy v1/v2 action to the v3 representation while preserving
/// the historical runtime behavior.  Legacy runtime code replaced every
/// `\\n` token with a line feed, including the final token in an even run.
/// Expanding each legacy run to the equivalent odd v3 run keeps that behavior
/// for configurations that opt out of automatic on-disk migration.
func canonicalizeLegacyMacrowhisperInsertAction(_ value: String) -> String {
    let characters = Array(value)
    var result = String()
    result.reserveCapacity(value.count)

    var index = 0
    while index < characters.count {
        if characters[index] == "\r" {
            if index + 1 < characters.count, characters[index + 1] == "\n" {
                index += 1
            }
            result += "\\n"
            index += 1
            continue
        }
        if characters[index] == "\n" {
            result += "\\n"
            index += 1
            continue
        }
        guard characters[index] == "\\" else {
            result.append(characters[index])
            index += 1
            continue
        }

        var slashCount = 0
        while index < characters.count, characters[index] == "\\" {
            slashCount += 1
            index += 1
        }
        guard index < characters.count, characters[index] == "n" else {
            result.append(String(repeating: "\\", count: slashCount))
            continue
        }

        // The old replacement removed one slash for every `\\n` token.  A
        // v3 run of 2n-1 slashes produces n-1 literal slashes plus a line
        // feed under odd/even decoding.
        result.append(String(repeating: "\\", count: max(1, slashCount * 2 - 1)))
        result.append("n")
        index += 1
    }

    return result
}

protocol ClipboardStackingConfigurable {
    var clipboardStacking: Bool? { get }
}

func effectiveClipboardStacking(for action: Any?, defaultValue: Bool) -> Bool {
    (action as? any ClipboardStackingConfigurable)?.clipboardStacking ?? defaultValue
}

protocol ClipboardAttachmentsConfigurable {
    var clipboardAttachments: Bool? { get }
}

func effectiveClipboardAttachments(for action: Any?, defaultValue: Bool) -> Bool {
    (action as? any ClipboardAttachmentsConfigurable)?.clipboardAttachments ?? defaultValue
}

protocol MoveToConfigurable {
    var moveTo: String? { get }
}

func effectiveMoveTo(for action: Any?, defaultValue: String?) -> String? {
    (action as? any MoveToConfigurable)?.moveTo ?? defaultValue
}

// MARK: - Configuration Manager

struct AppConfiguration: Codable {
    // Schema reference for IDE validation - maps to $schema in JSON
    var schema: String?
    // Configuration semantics version
    // v1: legacy empty-string fallback behavior for some action-level string fields
    // v2: explicit empty-string semantics (null=inherits, ""=explicit empty)
    // v3: Insert action newline escape semantics.
    // An odd run before the letter n is an LF token; an even run leaves a
    // literal backslash followed by n.
    var configVersion: Int?
    static let currentConfigVersion = 3

    /// Whether continuous clipboard monitoring needs to retain binary payloads
    /// for at least one potentially selected root action.
    var canCaptureClipboardAttachments: Bool {
        defaults.clipboardAttachments
            || inserts.contains { $0.value.clipboardAttachments == true }
            || urls.contains { $0.value.clipboardAttachments == true }
            || shortcuts.contains { $0.value.clipboardAttachments == true }
            || scriptsShell.contains { $0.value.clipboardAttachments == true }
            || scriptsAS.contains { $0.value.clipboardAttachments == true }
    }

    /// Resolves the Superwhisper folder to persist in a newly created configuration.
    /// Existing configuration values are never passed through this resolver.
    static func resolvedWatchPathForNewConfiguration() -> String {
        let configuredParentDirectory = UserDefaults(suiteName: "com.superduper.superwhisper")?
            .string(forKey: "appFolderDirectory")

        return resolveWatchPathForNewConfiguration(
            homeDirectory: NSHomeDirectory(),
            configuredParentDirectory: configuredParentDirectory,
            pathExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    /// Finds a valid replacement for a configured watch path that no longer
    /// contains a recordings folder. Healthy explicit paths are never changed.
    static func resolvedWatchPathForRecovery(configuredWatchPath: String) -> String? {
        let configuredParentDirectory = UserDefaults(suiteName: "com.superduper.superwhisper")?
            .string(forKey: "appFolderDirectory")

        return resolveWatchPathForRecovery(
            configuredWatchPath: configuredWatchPath,
            homeDirectory: NSHomeDirectory(),
            configuredParentDirectory: configuredParentDirectory,
            pathIsDirectory: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
        )
    }

    /// Injectable form used by regression tests.
    static func resolveWatchPathForNewConfiguration(
        homeDirectory: String,
        configuredParentDirectory: String?,
        pathExists: (String) -> Bool
    ) -> String {
        let standardizedHome = (homeDirectory as NSString).standardizingPath
        let currentDefault = (standardizedHome as NSString).appendingPathComponent("superwhisper")
        let legacyDefault = (standardizedHome as NSString).appendingPathComponent("Documents/superwhisper")

        func pathForPersistence(_ path: String) -> String {
            let standardizedPath = (path as NSString).standardizingPath
            if standardizedPath == standardizedHome {
                return "~"
            }
            let homePrefix = standardizedHome + "/"
            if standardizedPath.hasPrefix(homePrefix) {
                return "~/" + String(standardizedPath.dropFirst(homePrefix.count))
            }
            return standardizedPath
        }

        // Superwhisper stores the parent of its app folder. This is the strongest
        // signal and also supports custom locations outside the two defaults.
        if let configuredParentDirectory = configuredParentDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredParentDirectory.isEmpty {
            let expandedParent: String
            if configuredParentDirectory == "~" {
                expandedParent = standardizedHome
            } else if configuredParentDirectory.hasPrefix("~/") {
                expandedParent = (standardizedHome as NSString).appendingPathComponent(
                    String(configuredParentDirectory.dropFirst(2))
                )
            } else {
                expandedParent = configuredParentDirectory
            }
            let standardizedParent = (expandedParent as NSString).standardizingPath
            let configuredFolder = (standardizedParent as NSString).appendingPathComponent("superwhisper")
            return pathForPersistence(configuredFolder)
        }

        let currentRecordings = (currentDefault as NSString).appendingPathComponent("recordings")
        let legacyRecordings = (legacyDefault as NSString).appendingPathComponent("recordings")

        if pathExists(currentRecordings) { return pathForPersistence(currentDefault) }
        if pathExists(legacyRecordings) { return pathForPersistence(legacyDefault) }
        if pathExists(currentDefault) { return pathForPersistence(currentDefault) }
        if pathExists(legacyDefault) { return pathForPersistence(legacyDefault) }

        // Match Superwhisper 2.16.4+ for installations that have not created
        // their folder yet.
        return pathForPersistence(currentDefault)
    }

    /// Injectable recovery resolver used by runtime code and regression tests.
    /// Preference-derived locations may repair any broken path. The filesystem
    /// fallback to ~/superwhisper is intentionally limited to the known legacy
    /// ~/Documents/superwhisper migration.
    static func resolveWatchPathForRecovery(
        configuredWatchPath: String,
        homeDirectory: String,
        configuredParentDirectory: String?,
        pathIsDirectory: (String) -> Bool
    ) -> String? {
        let standardizedHome = (homeDirectory as NSString).standardizingPath

        func expandedAndStandardized(_ path: String) -> String {
            let expandedPath: String
            if path == "~" {
                expandedPath = standardizedHome
            } else if path.hasPrefix("~/") {
                expandedPath = (standardizedHome as NSString).appendingPathComponent(
                    String(path.dropFirst(2))
                )
            } else {
                expandedPath = path
            }
            return (expandedPath as NSString).standardizingPath
        }

        func pathForPersistence(_ path: String) -> String {
            let standardizedPath = (path as NSString).standardizingPath
            if standardizedPath == standardizedHome {
                return "~"
            }
            let homePrefix = standardizedHome + "/"
            if standardizedPath.hasPrefix(homePrefix) {
                return "~/" + String(standardizedPath.dropFirst(homePrefix.count))
            }
            return standardizedPath
        }

        func hasRecordingsFolder(_ watchPath: String) -> Bool {
            let recordingsPath = (watchPath as NSString).appendingPathComponent("recordings")
            return pathIsDirectory(recordingsPath)
        }

        let configuredPath = expandedAndStandardized(configuredWatchPath)
        guard !hasRecordingsFolder(configuredPath) else {
            return nil
        }

        // Superwhisper's own configured parent is the strongest recovery signal,
        // including when it points to a custom location.
        if let configuredParentDirectory = configuredParentDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredParentDirectory.isEmpty {
            let preferredParent = expandedAndStandardized(configuredParentDirectory)
            let preferredFolder = (preferredParent as NSString).appendingPathComponent("superwhisper")
            if preferredFolder != configuredPath, hasRecordingsFolder(preferredFolder) {
                return pathForPersistence(preferredFolder)
            }
        }

        // A stale Superwhisper preference is expected during a manual move. Only
        // infer the new default directly for the unambiguous legacy -> current move.
        let legacyDefault = (standardizedHome as NSString).appendingPathComponent("Documents/superwhisper")
        let currentDefault = (standardizedHome as NSString).appendingPathComponent("superwhisper")
        if configuredPath == legacyDefault, hasRecordingsFolder(currentDefault) {
            return pathForPersistence(currentDefault)
        }

        return nil
    }
    
    struct Defaults: Codable {
        var watch: String
        var disableUpdateCheck: Bool
        var muteNotifications: Bool
        var activeAction: String?
        var icon: String?
        var moveTo: String?
        var simEsc: Bool
        var simKeypress: Bool
        var smartCasing: Bool
        var smartPunctuation: Bool
        var smartSpacing: Bool
        var actionDelay: Double
        var history: Int?
        var simReturn: Bool
        var returnDelay: Double
        var restoreClipboard: Bool
        var restoreClipboardDelay: Double?
        var scheduledActionTimeout: Double
        var scriptAsync: Bool?
        var scriptWaitTimeout: Double?
        var clipboardStacking: Bool
        var clipboardAttachments: Bool
        var clipboardBuffer: Double
        var clipboardIgnore: String?
        var bypassModes: String?
        var muteTriggers: Bool
        var autoUpdateConfig: Bool
        var redactedLogs: Bool
        var nextAction: String?

        @discardableResult
        mutating func canonicalizeRootDefaultsForPersistence() -> Bool {
            let defaults = Defaults.defaultValues()
            var changed = false

            func replaceIfNil<T>(_ value: inout T?, with replacement: T) {
                guard value == nil else { return }
                value = replacement
                changed = true
            }

            replaceIfNil(&icon, with: defaults.icon ?? "")
            replaceIfNil(&moveTo, with: defaults.moveTo ?? "")
            replaceIfNil(&restoreClipboardDelay, with: defaults.restoreClipboardDelay ?? 0.3)
            replaceIfNil(&scriptAsync, with: defaults.scriptAsync ?? true)
            replaceIfNil(&scriptWaitTimeout, with: defaults.scriptWaitTimeout ?? 3)
            replaceIfNil(&clipboardIgnore, with: defaults.clipboardIgnore ?? "")
            replaceIfNil(&bypassModes, with: defaults.bypassModes ?? "")
            replaceIfNil(&nextAction, with: defaults.nextAction ?? "")

            return changed
        }
        
        // Add these coding keys and custom encoding
        enum CodingKeys: String, CodingKey {
            case watch, disableUpdateCheck, muteNotifications, activeAction, icon, moveTo, simEsc, simKeypress, smartCasing, smartPunctuation, smartSpacing, actionDelay, history, simReturn, returnDelay, restoreClipboard, restoreClipboardDelay, scheduledActionTimeout, scriptAsync, scriptWaitTimeout, clipboardStacking, clipboardAttachments, clipboardBuffer, clipboardIgnore, bypassModes, muteTriggers, autoUpdateConfig, redactedLogs, nextAction
        }
        
        // Custom encoding to preserve null values
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(watch, forKey: .watch)
            try container.encode(disableUpdateCheck, forKey: .disableUpdateCheck)
            try container.encode(muteNotifications, forKey: .muteNotifications)
            try container.encode(activeAction, forKey: .activeAction)
            try container.encode(icon, forKey: .icon)
            try container.encode(moveTo, forKey: .moveTo)
            try container.encode(simEsc, forKey: .simEsc)
            try container.encode(simKeypress, forKey: .simKeypress)
            try container.encode(smartCasing, forKey: .smartCasing)
            try container.encode(smartPunctuation, forKey: .smartPunctuation)
            try container.encode(smartSpacing, forKey: .smartSpacing)
            try container.encode(actionDelay, forKey: .actionDelay)
            try container.encode(history, forKey: .history)
            try container.encode(simReturn, forKey: .simReturn)
            try container.encode(returnDelay, forKey: .returnDelay)
            try container.encode(restoreClipboard, forKey: .restoreClipboard)
            try container.encode(restoreClipboardDelay, forKey: .restoreClipboardDelay)
            try container.encode(scheduledActionTimeout, forKey: .scheduledActionTimeout)
            try container.encode(scriptAsync, forKey: .scriptAsync)
            try container.encode(scriptWaitTimeout, forKey: .scriptWaitTimeout)
            try container.encode(clipboardStacking, forKey: .clipboardStacking)
            try container.encode(clipboardAttachments, forKey: .clipboardAttachments)
            try container.encode(clipboardBuffer, forKey: .clipboardBuffer)
            try container.encode(clipboardIgnore, forKey: .clipboardIgnore)
            try container.encode(bypassModes, forKey: .bypassModes)
            try container.encode(muteTriggers, forKey: .muteTriggers)
            try container.encode(autoUpdateConfig, forKey: .autoUpdateConfig)
            try container.encode(redactedLogs, forKey: .redactedLogs)
            try container.encode(nextAction, forKey: .nextAction)
        }
        
        // Custom decoding with legacy key fallbacks
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Runtime always expects a concrete watch path, but hand-edited configs
            // may omit or null this field to fall back to the built-in default.
            watch = try container.decodeIfPresent(String.self, forKey: .watch) ?? Defaults.defaultValues().watch
            actionDelay = try container.decodeIfPresent(Double.self, forKey: .actionDelay) ?? 0

            // Optional fields with sensible fallbacks (aligned with defaultValues())
            if let newDisableUpdateCheck = try container.decodeIfPresent(Bool.self, forKey: .disableUpdateCheck) {
                disableUpdateCheck = newDisableUpdateCheck
            } else {
                let legacyContainer = try decoder.container(keyedBy: AnyCodingKey.self)
                let legacyNoUpdatesKey = AnyCodingKey(stringValue: "noUpdates")
                disableUpdateCheck = try legacyContainer.decodeIfPresent(Bool.self, forKey: legacyNoUpdatesKey) ?? false
            }

            if let newMuteNotifications = try container.decodeIfPresent(Bool.self, forKey: .muteNotifications) {
                muteNotifications = newMuteNotifications
            } else {
                let legacyContainer = try decoder.container(keyedBy: AnyCodingKey.self)
                let legacyNoNotiKey = AnyCodingKey(stringValue: "noNoti")
                muteNotifications = try legacyContainer.decodeIfPresent(Bool.self, forKey: legacyNoNotiKey) ?? false
            }

            activeAction = try container.decodeIfPresent(String.self, forKey: .activeAction)
            
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)
            if container.contains(.simEsc) {
                simEsc = try container.decodeIfPresent(Bool.self, forKey: .simEsc) ?? true
            } else {
                let legacyContainer = try decoder.container(keyedBy: AnyCodingKey.self)
                let legacyNoEscKey = AnyCodingKey(stringValue: "noEsc")
                if let legacyNoEsc = try legacyContainer.decodeIfPresent(Bool.self, forKey: legacyNoEscKey) {
                    simEsc = !legacyNoEsc
                } else {
                    simEsc = true
                }
            }
            simKeypress = try container.decodeIfPresent(Bool.self, forKey: .simKeypress) ?? false
            smartCasing = try container.decodeIfPresent(Bool.self, forKey: .smartCasing) ?? true
            smartPunctuation = try container.decodeIfPresent(Bool.self, forKey: .smartPunctuation) ?? true
            smartSpacing = try container.decodeIfPresent(Bool.self, forKey: .smartSpacing) ?? true
            // Handle both Int and Float values for history (some configs may have Float)
            if let intHistory = try? container.decodeIfPresent(Int.self, forKey: .history) {
                history = intHistory
            } else if let floatHistory = try? container.decodeIfPresent(Double.self, forKey: .history) {
                history = Int(floatHistory)
            } else {
                history = nil
            }
            if container.contains(.simReturn) {
                simReturn = try container.decodeIfPresent(Bool.self, forKey: .simReturn) ?? false
            } else {
                let legacyContainer = try decoder.container(keyedBy: AnyCodingKey.self)
                let legacyPressReturnKey = AnyCodingKey(stringValue: "pressReturn")
                simReturn = try legacyContainer.decodeIfPresent(Bool.self, forKey: legacyPressReturnKey) ?? false
            }
            returnDelay = try container.decodeIfPresent(Double.self, forKey: .returnDelay) ?? Defaults.defaultValues().returnDelay
            restoreClipboard = try container.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? true
            restoreClipboardDelay = try container.decodeIfPresent(Double.self, forKey: .restoreClipboardDelay)
            scheduledActionTimeout = try container.decodeIfPresent(Double.self, forKey: .scheduledActionTimeout) ?? 5
            scriptAsync = try container.decodeIfPresent(Bool.self, forKey: .scriptAsync)
            scriptWaitTimeout = try container.decodeIfPresent(Double.self, forKey: .scriptWaitTimeout)
            clipboardStacking = try container.decodeIfPresent(Bool.self, forKey: .clipboardStacking) ?? false
            clipboardAttachments = try container.decodeIfPresent(Bool.self, forKey: .clipboardAttachments) ?? false
            clipboardBuffer = try container.decodeIfPresent(Double.self, forKey: .clipboardBuffer) ?? 5.0
            clipboardIgnore = try container.decodeIfPresent(String.self, forKey: .clipboardIgnore)
            bypassModes = try container.decodeIfPresent(String.self, forKey: .bypassModes)
            muteTriggers = try container.decodeIfPresent(Bool.self, forKey: .muteTriggers) ?? false
            autoUpdateConfig = try container.decodeIfPresent(Bool.self, forKey: .autoUpdateConfig) ?? true
            redactedLogs = try container.decodeIfPresent(Bool.self, forKey: .redactedLogs) ?? true
            nextAction = try container.decodeIfPresent(String.self, forKey: .nextAction)
        }
        
        // Memberwise initializer (needed since we added custom init(from decoder:))
        init(watch: String, disableUpdateCheck: Bool, muteNotifications: Bool, activeAction: String?, icon: String?, moveTo: String?, simEsc: Bool, simKeypress: Bool, smartCasing: Bool, smartPunctuation: Bool, smartSpacing: Bool, actionDelay: Double, history: Int?, simReturn: Bool, returnDelay: Double, restoreClipboard: Bool, restoreClipboardDelay: Double?, scheduledActionTimeout: Double, scriptAsync: Bool?, scriptWaitTimeout: Double?, clipboardStacking: Bool, clipboardAttachments: Bool, clipboardBuffer: Double, clipboardIgnore: String?, bypassModes: String?, muteTriggers: Bool, autoUpdateConfig: Bool, redactedLogs: Bool, nextAction: String?) {
            self.watch = watch
            self.disableUpdateCheck = disableUpdateCheck
            self.muteNotifications = muteNotifications
            self.activeAction = activeAction
            self.icon = icon
            self.moveTo = moveTo
            self.simEsc = simEsc
            self.simKeypress = simKeypress
            self.smartCasing = smartCasing
            self.smartPunctuation = smartPunctuation
            self.smartSpacing = smartSpacing
            self.actionDelay = actionDelay
            self.history = history
            self.simReturn = simReturn
            self.returnDelay = returnDelay
            self.restoreClipboard = restoreClipboard
            self.restoreClipboardDelay = restoreClipboardDelay
            self.scheduledActionTimeout = scheduledActionTimeout
            self.scriptAsync = scriptAsync
            self.scriptWaitTimeout = scriptWaitTimeout
            self.clipboardStacking = clipboardStacking
            self.clipboardAttachments = clipboardAttachments
            self.clipboardBuffer = clipboardBuffer
            self.clipboardIgnore = clipboardIgnore
            self.bypassModes = bypassModes
            self.muteTriggers = muteTriggers
            self.autoUpdateConfig = autoUpdateConfig
            self.redactedLogs = redactedLogs
            self.nextAction = nextAction
        }
        
        static func defaultValues() -> Defaults {
            return Defaults(
                watch: ("~/Documents/superwhisper" as NSString).expandingTildeInPath,
                disableUpdateCheck: false,
                muteNotifications: false,
                activeAction: "autoPaste",
                icon: "",
                moveTo: "",
                simEsc: true,
                simKeypress: false,
                smartCasing: true,
                smartPunctuation: true,
                smartSpacing: true,
                actionDelay: 0,
                history: nil,
                simReturn: false,
                returnDelay: 0.15,
                restoreClipboard: true,
                restoreClipboardDelay: 0.3,
                scheduledActionTimeout: 5,
                scriptAsync: true,
                scriptWaitTimeout: 3,
                clipboardStacking: false,
                clipboardAttachments: false,
                clipboardBuffer: 5.0,
                clipboardIgnore: "",
                bypassModes: "",
                muteTriggers: false,
                autoUpdateConfig: true,
                redactedLogs: true,
                nextAction: ""
            )
        }
    }
    
    struct Insert: Codable, MoveToConfigurable, ClipboardStackingConfigurable, ClipboardAttachmentsConfigurable {
        var action: String
        var icon: String?
        var moveTo: String?
        var simEsc: Bool?
        var simKeypress: Bool?
        var smartCasing: Bool?
        var smartPunctuation: Bool?
        var smartSpacing: Bool?
        var actionDelay: Double?
        var simReturn: Bool?
        var restoreClipboard: Bool?  // Action-level override for clipboard restoration
        var restoreClipboardDelay: Double?
        var clipboardStacking: Bool?
        var clipboardAttachments: Bool?
        var inputCondition: String?
        var nextAction: String?
        // --- Trigger fields for future extensibility ---
        /// Voice trigger phrases (plain = prefix, leading `*` = suffix, `==...==` = raw regex)
        var triggerVoice: String?
        /// App trigger regex (matches app name or bundle ID)
        var triggerApps: String?
        /// Mode trigger regex (matches modeName)
        var triggerModes: String?
        /// Active URL trigger patterns
        var triggerUrls: String?
        /// Logic for combining triggers ("and"/"or")
        var triggerLogic: String? = "or"
        // ---------------------------------------------
        
        enum CodingKeys: String, CodingKey {
            case action, icon, moveTo, simEsc, simKeypress, smartCasing, smartPunctuation, smartSpacing, actionDelay, simReturn, restoreClipboard, restoreClipboardDelay, clipboardStacking, clipboardAttachments, inputCondition, nextAction
            case triggerVoice, triggerApps, triggerModes, triggerUrls, triggerLogic
        }
        
        // Custom encoding to preserve null values and ensure trigger fields are always present
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            // Keep direct JSONEncoder callers on the same canonical wire
            // representation as ConfigurationManager persistence.
            try container.encode(canonicalizeMacrowhisperInsertAction(action), forKey: .action)
            try container.encode(icon, forKey: .icon)
            try container.encode(moveTo, forKey: .moveTo)
            try container.encode(simEsc, forKey: .simEsc)
            try container.encode(simKeypress, forKey: .simKeypress)
            try container.encode(smartCasing, forKey: .smartCasing)
            try container.encode(smartPunctuation, forKey: .smartPunctuation)
            try container.encode(smartSpacing, forKey: .smartSpacing)
            try container.encode(actionDelay, forKey: .actionDelay)
            try container.encode(simReturn, forKey: .simReturn)
            try container.encode(restoreClipboard, forKey: .restoreClipboard)
            try container.encode(restoreClipboardDelay, forKey: .restoreClipboardDelay)
            try container.encode(clipboardStacking, forKey: .clipboardStacking)
            try container.encode(clipboardAttachments, forKey: .clipboardAttachments)
            try container.encode(inputCondition, forKey: .inputCondition)
            try container.encode(nextAction, forKey: .nextAction)
            try container.encode(triggerVoice, forKey: .triggerVoice)
            try container.encode(triggerApps, forKey: .triggerApps)
            try container.encode(triggerModes, forKey: .triggerModes)
            try container.encode(triggerUrls, forKey: .triggerUrls)
            try container.encode(triggerLogic ?? "or", forKey: .triggerLogic)
        }
        // Custom decoding to ensure trigger fields are always present
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            action = try container.decode(String.self, forKey: .action)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)
            if container.contains(.simEsc) {
                simEsc = try container.decodeIfPresent(Bool.self, forKey: .simEsc)
            } else {
                let legacyContainer = try decoder.container(keyedBy: AnyCodingKey.self)
                let legacyNoEscKey = AnyCodingKey(stringValue: "noEsc")
                if let legacyNoEsc = try legacyContainer.decodeIfPresent(Bool.self, forKey: legacyNoEscKey) {
                    simEsc = !legacyNoEsc
                } else {
                    simEsc = nil
                }
            }
            simKeypress = try container.decodeIfPresent(Bool.self, forKey: .simKeypress)
            smartCasing = try container.decodeIfPresent(Bool.self, forKey: .smartCasing)
            smartPunctuation = try container.decodeIfPresent(Bool.self, forKey: .smartPunctuation)
            smartSpacing = try container.decodeIfPresent(Bool.self, forKey: .smartSpacing)
            actionDelay = try container.decodeIfPresent(Double.self, forKey: .actionDelay)
            if container.contains(.simReturn) {
                simReturn = try container.decodeIfPresent(Bool.self, forKey: .simReturn)
            } else {
                let legacyContainer = try decoder.container(keyedBy: AnyCodingKey.self)
                let legacyPressReturnKey = AnyCodingKey(stringValue: "pressReturn")
                simReturn = try legacyContainer.decodeIfPresent(Bool.self, forKey: legacyPressReturnKey)
            }
            restoreClipboard = try container.decodeIfPresent(Bool.self, forKey: .restoreClipboard)
            restoreClipboardDelay = try container.decodeIfPresent(Double.self, forKey: .restoreClipboardDelay)
            clipboardStacking = try container.decodeIfPresent(Bool.self, forKey: .clipboardStacking)
            clipboardAttachments = try container.decodeIfPresent(Bool.self, forKey: .clipboardAttachments)
            inputCondition = try container.decodeIfPresent(String.self, forKey: .inputCondition)
            nextAction = try container.decodeIfPresent(String.self, forKey: .nextAction)
            triggerVoice = try container.decodeIfPresent(String.self, forKey: .triggerVoice)
            triggerApps = try container.decodeIfPresent(String.self, forKey: .triggerApps)
            triggerModes = try container.decodeIfPresent(String.self, forKey: .triggerModes)
            triggerUrls = try container.decodeIfPresent(String.self, forKey: .triggerUrls)
            triggerLogic = try container.decodeIfPresent(String.self, forKey: .triggerLogic) ?? "or"
        }
        // Default initializer for new inserts
        init(action: String, icon: String? = nil, moveTo: String? = nil, simEsc: Bool? = nil, simKeypress: Bool? = nil, smartCasing: Bool? = nil, smartPunctuation: Bool? = nil, smartSpacing: Bool? = nil, actionDelay: Double? = nil, simReturn: Bool? = nil, restoreClipboard: Bool? = nil, restoreClipboardDelay: Double? = nil, clipboardStacking: Bool? = nil, clipboardAttachments: Bool? = nil, inputCondition: String? = nil, nextAction: String? = nil, triggerVoice: String? = nil, triggerApps: String? = nil, triggerModes: String? = nil, triggerUrls: String? = nil, triggerLogic: String? = "or") {
            self.action = action
            self.icon = icon
            self.moveTo = moveTo
            self.simEsc = simEsc
            self.simKeypress = simKeypress
            self.smartCasing = smartCasing
            self.smartPunctuation = smartPunctuation
            self.smartSpacing = smartSpacing
            self.actionDelay = actionDelay
            self.simReturn = simReturn
            self.restoreClipboard = restoreClipboard
            self.restoreClipboardDelay = restoreClipboardDelay
            self.clipboardStacking = clipboardStacking
            self.clipboardAttachments = clipboardAttachments
            self.inputCondition = inputCondition
            self.nextAction = nextAction
            self.triggerVoice = triggerVoice
            self.triggerApps = triggerApps
            self.triggerModes = triggerModes
            self.triggerUrls = triggerUrls
            self.triggerLogic = triggerLogic ?? "or"
        }
    }
    
    struct Url: Codable, MoveToConfigurable, ClipboardStackingConfigurable, ClipboardAttachmentsConfigurable {
        var action: String
        var icon: String?
        var moveTo: String?
        var simEsc: Bool?
        var actionDelay: Double?
        var restoreClipboard: Bool?  // Action-level override for clipboard restoration
        var restoreClipboardDelay: Double?
        var clipboardStacking: Bool?
        var clipboardAttachments: Bool?
        var inputCondition: String?
        var nextAction: String?
        // --- Trigger fields for future extensibility ---
        /// Voice trigger phrases (plain = prefix, leading `*` = suffix, `==...==` = raw regex)
        var triggerVoice: String?
        /// App trigger regex (matches app name or bundle ID)
        var triggerApps: String?
        /// Mode trigger regex (matches modeName)
        var triggerModes: String?
        /// Active URL trigger patterns
        var triggerUrls: String?
        /// Logic for combining triggers ("and"/"or")
        var triggerLogic: String? = "or"
        // ---------------------------------------------
        var openWith: String?
        var openBackground: Bool?  // nil/omitted means foreground behavior
        
        enum CodingKeys: String, CodingKey {
            case action, icon, moveTo, simEsc, actionDelay, restoreClipboard, restoreClipboardDelay, clipboardStacking, clipboardAttachments, inputCondition, nextAction
            case triggerVoice, triggerApps, triggerModes, triggerUrls, triggerLogic
            case openWith, openBackground
        }
        
        // Custom encoding to preserve null values and ensure trigger fields are always present
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(action, forKey: .action)
            try container.encode(icon, forKey: .icon)
            try container.encode(moveTo, forKey: .moveTo)
            try container.encode(simEsc, forKey: .simEsc)
            try container.encode(actionDelay, forKey: .actionDelay)
            try container.encode(restoreClipboard, forKey: .restoreClipboard)
            try container.encode(restoreClipboardDelay, forKey: .restoreClipboardDelay)
            try container.encode(clipboardStacking, forKey: .clipboardStacking)
            try container.encode(clipboardAttachments, forKey: .clipboardAttachments)
            try container.encode(inputCondition, forKey: .inputCondition)
            try container.encode(nextAction, forKey: .nextAction)
            try container.encode(triggerVoice, forKey: .triggerVoice)
            try container.encode(triggerApps, forKey: .triggerApps)
            try container.encode(triggerModes, forKey: .triggerModes)
            try container.encode(triggerUrls, forKey: .triggerUrls)
            try container.encode(triggerLogic ?? "or", forKey: .triggerLogic)
            try container.encode(openWith, forKey: .openWith)
            try container.encode(openBackground, forKey: .openBackground)
        }
        // Custom decoding to ensure trigger fields are always present
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            action = try container.decode(String.self, forKey: .action)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)
            if container.contains(.simEsc) {
                simEsc = try container.decodeIfPresent(Bool.self, forKey: .simEsc)
            } else {
                let legacyContainer = try decoder.container(keyedBy: AnyCodingKey.self)
                let legacyNoEscKey = AnyCodingKey(stringValue: "noEsc")
                if let legacyNoEsc = try legacyContainer.decodeIfPresent(Bool.self, forKey: legacyNoEscKey) {
                    simEsc = !legacyNoEsc
                } else {
                    simEsc = nil
                }
            }
            actionDelay = try container.decodeIfPresent(Double.self, forKey: .actionDelay)
            restoreClipboard = try container.decodeIfPresent(Bool.self, forKey: .restoreClipboard)
            restoreClipboardDelay = try container.decodeIfPresent(Double.self, forKey: .restoreClipboardDelay)
            clipboardStacking = try container.decodeIfPresent(Bool.self, forKey: .clipboardStacking)
            clipboardAttachments = try container.decodeIfPresent(Bool.self, forKey: .clipboardAttachments)
            inputCondition = try container.decodeIfPresent(String.self, forKey: .inputCondition)
            nextAction = try container.decodeIfPresent(String.self, forKey: .nextAction)
            triggerVoice = try container.decodeIfPresent(String.self, forKey: .triggerVoice)
            triggerApps = try container.decodeIfPresent(String.self, forKey: .triggerApps)
            triggerModes = try container.decodeIfPresent(String.self, forKey: .triggerModes)
            triggerUrls = try container.decodeIfPresent(String.self, forKey: .triggerUrls)
            triggerLogic = try container.decodeIfPresent(String.self, forKey: .triggerLogic) ?? "or"
            openWith = try container.decodeIfPresent(String.self, forKey: .openWith)
            openBackground = try container.decodeIfPresent(Bool.self, forKey: .openBackground)
        }
        // Default initializer for new URLs
        init(action: String, icon: String? = nil, moveTo: String? = nil, simEsc: Bool? = nil, actionDelay: Double? = nil, restoreClipboard: Bool? = nil, restoreClipboardDelay: Double? = nil, clipboardStacking: Bool? = nil, clipboardAttachments: Bool? = nil, inputCondition: String? = nil, nextAction: String? = nil, triggerVoice: String? = nil, triggerApps: String? = nil, triggerModes: String? = nil, triggerUrls: String? = nil, triggerLogic: String? = "or", openWith: String? = nil, openBackground: Bool? = nil) {
            self.action = action
            self.icon = icon
            self.moveTo = moveTo
            self.simEsc = simEsc
            self.actionDelay = actionDelay
            self.restoreClipboard = restoreClipboard
            self.restoreClipboardDelay = restoreClipboardDelay
            self.clipboardStacking = clipboardStacking
            self.clipboardAttachments = clipboardAttachments
            self.inputCondition = inputCondition
            self.nextAction = nextAction
            self.triggerVoice = triggerVoice
            self.triggerApps = triggerApps
            self.triggerModes = triggerModes
            self.triggerUrls = triggerUrls
            self.triggerLogic = triggerLogic ?? "or"
            self.openWith = openWith
            self.openBackground = openBackground
        }
    }
    
    struct Shortcut: Codable, MoveToConfigurable, ClipboardStackingConfigurable, ClipboardAttachmentsConfigurable {
        var action: String
        var icon: String?
        var moveTo: String?
        var simEsc: Bool?
        var actionDelay: Double?
        var restoreClipboard: Bool?  // Action-level override for clipboard restoration
        var restoreClipboardDelay: Double?
        var clipboardStacking: Bool?
        var clipboardAttachments: Bool?
        var scriptAsync: Bool?
        var scriptWaitTimeout: Double?
        var inputCondition: String?
        var nextAction: String?
        // --- Trigger fields for future extensibility ---
        /// Voice trigger phrases (plain = prefix, leading `*` = suffix, `==...==` = raw regex)
        var triggerVoice: String?
        /// App trigger regex (matches app name or bundle ID)
        var triggerApps: String?
        /// Mode trigger regex (matches modeName)
        var triggerModes: String?
        /// Active URL trigger patterns
        var triggerUrls: String?
        /// Logic for combining triggers ("and"/"or")
        var triggerLogic: String? = "or"
        
        enum CodingKeys: String, CodingKey {
            case action, icon, moveTo, simEsc, actionDelay, restoreClipboard, restoreClipboardDelay, clipboardStacking, clipboardAttachments, scriptAsync, scriptWaitTimeout, inputCondition, nextAction
            case triggerVoice, triggerApps, triggerModes, triggerUrls, triggerLogic
        }
        
        // Custom encoding to preserve null values and ensure trigger fields are always present
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(action, forKey: .action)
            try container.encode(icon, forKey: .icon)
            try container.encode(moveTo, forKey: .moveTo)
            try container.encode(simEsc, forKey: .simEsc)
            try container.encode(actionDelay, forKey: .actionDelay)
            try container.encode(restoreClipboard, forKey: .restoreClipboard)
            try container.encode(restoreClipboardDelay, forKey: .restoreClipboardDelay)
            try container.encode(clipboardStacking, forKey: .clipboardStacking)
            try container.encode(clipboardAttachments, forKey: .clipboardAttachments)
            try container.encode(scriptAsync, forKey: .scriptAsync)
            try container.encode(scriptWaitTimeout, forKey: .scriptWaitTimeout)
            try container.encode(inputCondition, forKey: .inputCondition)
            try container.encode(nextAction, forKey: .nextAction)
            try container.encode(triggerVoice, forKey: .triggerVoice)
            try container.encode(triggerApps, forKey: .triggerApps)
            try container.encode(triggerModes, forKey: .triggerModes)
            try container.encode(triggerUrls, forKey: .triggerUrls)
            try container.encode(triggerLogic ?? "or", forKey: .triggerLogic)
        }
        
        // Custom decoding to ensure trigger fields are always present
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            action = try container.decode(String.self, forKey: .action)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)
            if container.contains(.simEsc) {
                simEsc = try container.decodeIfPresent(Bool.self, forKey: .simEsc)
            } else {
                let legacyContainer = try decoder.container(keyedBy: AnyCodingKey.self)
                let legacyNoEscKey = AnyCodingKey(stringValue: "noEsc")
                if let legacyNoEsc = try legacyContainer.decodeIfPresent(Bool.self, forKey: legacyNoEscKey) {
                    simEsc = !legacyNoEsc
                } else {
                    simEsc = nil
                }
            }
            actionDelay = try container.decodeIfPresent(Double.self, forKey: .actionDelay)
            restoreClipboard = try container.decodeIfPresent(Bool.self, forKey: .restoreClipboard)
            restoreClipboardDelay = try container.decodeIfPresent(Double.self, forKey: .restoreClipboardDelay)
            clipboardStacking = try container.decodeIfPresent(Bool.self, forKey: .clipboardStacking)
            clipboardAttachments = try container.decodeIfPresent(Bool.self, forKey: .clipboardAttachments)
            scriptAsync = try container.decodeIfPresent(Bool.self, forKey: .scriptAsync)
            scriptWaitTimeout = try container.decodeIfPresent(Double.self, forKey: .scriptWaitTimeout)
            inputCondition = try container.decodeIfPresent(String.self, forKey: .inputCondition)
            nextAction = try container.decodeIfPresent(String.self, forKey: .nextAction)
            triggerVoice = try container.decodeIfPresent(String.self, forKey: .triggerVoice)
            triggerApps = try container.decodeIfPresent(String.self, forKey: .triggerApps)
            triggerModes = try container.decodeIfPresent(String.self, forKey: .triggerModes)
            triggerUrls = try container.decodeIfPresent(String.self, forKey: .triggerUrls)
            triggerLogic = try container.decodeIfPresent(String.self, forKey: .triggerLogic) ?? "or"
        }
        
        // Default initializer for new shortcuts
        init(action: String, icon: String? = nil, moveTo: String? = nil, simEsc: Bool? = nil, actionDelay: Double? = nil, restoreClipboard: Bool? = nil, restoreClipboardDelay: Double? = nil, clipboardStacking: Bool? = nil, clipboardAttachments: Bool? = nil, scriptAsync: Bool? = nil, scriptWaitTimeout: Double? = nil, inputCondition: String? = nil, nextAction: String? = nil, triggerVoice: String? = nil, triggerApps: String? = nil, triggerModes: String? = nil, triggerUrls: String? = nil, triggerLogic: String? = "or") {
            self.action = action
            self.icon = icon
            self.moveTo = moveTo
            self.simEsc = simEsc
            self.actionDelay = actionDelay
            self.restoreClipboard = restoreClipboard
            self.restoreClipboardDelay = restoreClipboardDelay
            self.clipboardStacking = clipboardStacking
            self.clipboardAttachments = clipboardAttachments
            self.scriptAsync = scriptAsync
            self.scriptWaitTimeout = scriptWaitTimeout
            self.inputCondition = inputCondition
            self.nextAction = nextAction
            self.triggerVoice = triggerVoice
            self.triggerApps = triggerApps
            self.triggerModes = triggerModes
            self.triggerUrls = triggerUrls
            self.triggerLogic = triggerLogic ?? "or"
        }
    }
    
    struct ScriptShell: Codable, MoveToConfigurable, ClipboardStackingConfigurable, ClipboardAttachmentsConfigurable {
        var action: String
        var icon: String?
        var moveTo: String?
        var simEsc: Bool?
        var actionDelay: Double?
        var restoreClipboard: Bool?  // Action-level override for clipboard restoration
        var restoreClipboardDelay: Double?
        var clipboardStacking: Bool?
        var clipboardAttachments: Bool?
        var scriptAsync: Bool?
        var scriptWaitTimeout: Double?
        var inputCondition: String?
        var nextAction: String?
        // --- Trigger fields for future extensibility ---
        /// Voice trigger phrases (plain = prefix, leading `*` = suffix, `==...==` = raw regex)
        var triggerVoice: String?
        /// App trigger regex (matches app name or bundle ID)
        var triggerApps: String?
        /// Mode trigger regex (matches modeName)
        var triggerModes: String?
        /// Active URL trigger patterns
        var triggerUrls: String?
        /// Logic for combining triggers ("and"/"or")
        var triggerLogic: String? = "or"
        
        enum CodingKeys: String, CodingKey {
            case action, icon, moveTo, simEsc, actionDelay, restoreClipboard, restoreClipboardDelay, clipboardStacking, clipboardAttachments, scriptAsync, scriptWaitTimeout, inputCondition, nextAction
            case triggerVoice, triggerApps, triggerModes, triggerUrls, triggerLogic
        }
        
        // Custom encoding to preserve null values and ensure trigger fields are always present
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(action, forKey: .action)
            try container.encode(icon, forKey: .icon)
            try container.encode(moveTo, forKey: .moveTo)
            try container.encode(simEsc, forKey: .simEsc)
            try container.encode(actionDelay, forKey: .actionDelay)
            try container.encode(restoreClipboard, forKey: .restoreClipboard)
            try container.encode(restoreClipboardDelay, forKey: .restoreClipboardDelay)
            try container.encode(clipboardStacking, forKey: .clipboardStacking)
            try container.encode(clipboardAttachments, forKey: .clipboardAttachments)
            try container.encode(scriptAsync, forKey: .scriptAsync)
            try container.encode(scriptWaitTimeout, forKey: .scriptWaitTimeout)
            try container.encode(inputCondition, forKey: .inputCondition)
            try container.encode(nextAction, forKey: .nextAction)
            try container.encode(triggerVoice, forKey: .triggerVoice)
            try container.encode(triggerApps, forKey: .triggerApps)
            try container.encode(triggerModes, forKey: .triggerModes)
            try container.encode(triggerUrls, forKey: .triggerUrls)
            try container.encode(triggerLogic ?? "or", forKey: .triggerLogic)
        }
        
        // Custom decoding to ensure trigger fields are always present
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            action = try container.decode(String.self, forKey: .action)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)
            if container.contains(.simEsc) {
                simEsc = try container.decodeIfPresent(Bool.self, forKey: .simEsc)
            } else {
                let legacyContainer = try decoder.container(keyedBy: AnyCodingKey.self)
                let legacyNoEscKey = AnyCodingKey(stringValue: "noEsc")
                if let legacyNoEsc = try legacyContainer.decodeIfPresent(Bool.self, forKey: legacyNoEscKey) {
                    simEsc = !legacyNoEsc
                } else {
                    simEsc = nil
                }
            }
            actionDelay = try container.decodeIfPresent(Double.self, forKey: .actionDelay)
            restoreClipboard = try container.decodeIfPresent(Bool.self, forKey: .restoreClipboard)
            restoreClipboardDelay = try container.decodeIfPresent(Double.self, forKey: .restoreClipboardDelay)
            clipboardStacking = try container.decodeIfPresent(Bool.self, forKey: .clipboardStacking)
            clipboardAttachments = try container.decodeIfPresent(Bool.self, forKey: .clipboardAttachments)
            scriptAsync = try container.decodeIfPresent(Bool.self, forKey: .scriptAsync)
            scriptWaitTimeout = try container.decodeIfPresent(Double.self, forKey: .scriptWaitTimeout)
            inputCondition = try container.decodeIfPresent(String.self, forKey: .inputCondition)
            nextAction = try container.decodeIfPresent(String.self, forKey: .nextAction)
            triggerVoice = try container.decodeIfPresent(String.self, forKey: .triggerVoice)
            triggerApps = try container.decodeIfPresent(String.self, forKey: .triggerApps)
            triggerModes = try container.decodeIfPresent(String.self, forKey: .triggerModes)
            triggerUrls = try container.decodeIfPresent(String.self, forKey: .triggerUrls)
            triggerLogic = try container.decodeIfPresent(String.self, forKey: .triggerLogic) ?? "or"
        }
        
        // Default initializer for new shell scripts
        init(action: String, icon: String? = nil, moveTo: String? = nil, simEsc: Bool? = nil, actionDelay: Double? = nil, restoreClipboard: Bool? = nil, restoreClipboardDelay: Double? = nil, clipboardStacking: Bool? = nil, clipboardAttachments: Bool? = nil, scriptAsync: Bool? = nil, scriptWaitTimeout: Double? = nil, inputCondition: String? = nil, nextAction: String? = nil, triggerVoice: String? = nil, triggerApps: String? = nil, triggerModes: String? = nil, triggerUrls: String? = nil, triggerLogic: String? = "or") {
            self.action = action
            self.icon = icon
            self.moveTo = moveTo
            self.simEsc = simEsc
            self.actionDelay = actionDelay
            self.restoreClipboard = restoreClipboard
            self.restoreClipboardDelay = restoreClipboardDelay
            self.clipboardStacking = clipboardStacking
            self.clipboardAttachments = clipboardAttachments
            self.scriptAsync = scriptAsync
            self.scriptWaitTimeout = scriptWaitTimeout
            self.inputCondition = inputCondition
            self.nextAction = nextAction
            self.triggerVoice = triggerVoice
            self.triggerApps = triggerApps
            self.triggerModes = triggerModes
            self.triggerUrls = triggerUrls
            self.triggerLogic = triggerLogic ?? "or"
        }
    }
    
    struct ScriptAppleScript: Codable, MoveToConfigurable, ClipboardStackingConfigurable, ClipboardAttachmentsConfigurable {
        var action: String
        var icon: String?
        var moveTo: String?
        var simEsc: Bool?
        var actionDelay: Double?
        var restoreClipboard: Bool?  // Action-level override for clipboard restoration
        var restoreClipboardDelay: Double?
        var clipboardStacking: Bool?
        var clipboardAttachments: Bool?
        var scriptAsync: Bool?
        var scriptWaitTimeout: Double?
        var inputCondition: String?
        var nextAction: String?
        var triggerVoice: String?
        var triggerApps: String?
        var triggerModes: String?
        var triggerUrls: String?
        var triggerLogic: String? = "or"

        enum CodingKeys: String, CodingKey {
            case action, icon, moveTo, simEsc, actionDelay, restoreClipboard, restoreClipboardDelay, clipboardStacking, clipboardAttachments, scriptAsync, scriptWaitTimeout, inputCondition, nextAction, triggerVoice, triggerApps, triggerModes, triggerUrls, triggerLogic
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(action, forKey: .action)
            try container.encode(icon, forKey: .icon)
            try container.encode(moveTo, forKey: .moveTo)
            try container.encode(simEsc, forKey: .simEsc)
            try container.encode(actionDelay, forKey: .actionDelay)
            try container.encode(restoreClipboard, forKey: .restoreClipboard)
            try container.encode(restoreClipboardDelay, forKey: .restoreClipboardDelay)
            try container.encode(clipboardStacking, forKey: .clipboardStacking)
            try container.encode(clipboardAttachments, forKey: .clipboardAttachments)
            try container.encode(scriptAsync, forKey: .scriptAsync)
            try container.encode(scriptWaitTimeout, forKey: .scriptWaitTimeout)
            try container.encode(inputCondition, forKey: .inputCondition)
            try container.encode(nextAction, forKey: .nextAction)
            try container.encode(triggerVoice, forKey: .triggerVoice)
            try container.encode(triggerApps, forKey: .triggerApps)
            try container.encode(triggerModes, forKey: .triggerModes)
            try container.encode(triggerUrls, forKey: .triggerUrls)
            try container.encode(triggerLogic ?? "or", forKey: .triggerLogic)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            action = try container.decode(String.self, forKey: .action)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)
            if container.contains(.simEsc) {
                simEsc = try container.decodeIfPresent(Bool.self, forKey: .simEsc)
            } else {
                let legacyContainer = try decoder.container(keyedBy: AnyCodingKey.self)
                let legacyNoEscKey = AnyCodingKey(stringValue: "noEsc")
                if let legacyNoEsc = try legacyContainer.decodeIfPresent(Bool.self, forKey: legacyNoEscKey) {
                    simEsc = !legacyNoEsc
                } else {
                    simEsc = nil
                }
            }
            actionDelay = try container.decodeIfPresent(Double.self, forKey: .actionDelay)
            restoreClipboard = try container.decodeIfPresent(Bool.self, forKey: .restoreClipboard)
            restoreClipboardDelay = try container.decodeIfPresent(Double.self, forKey: .restoreClipboardDelay)
            clipboardStacking = try container.decodeIfPresent(Bool.self, forKey: .clipboardStacking)
            clipboardAttachments = try container.decodeIfPresent(Bool.self, forKey: .clipboardAttachments)
            scriptAsync = try container.decodeIfPresent(Bool.self, forKey: .scriptAsync)
            scriptWaitTimeout = try container.decodeIfPresent(Double.self, forKey: .scriptWaitTimeout)
            inputCondition = try container.decodeIfPresent(String.self, forKey: .inputCondition)
            nextAction = try container.decodeIfPresent(String.self, forKey: .nextAction)
            triggerVoice = try container.decodeIfPresent(String.self, forKey: .triggerVoice)
            triggerApps = try container.decodeIfPresent(String.self, forKey: .triggerApps)
            triggerModes = try container.decodeIfPresent(String.self, forKey: .triggerModes)
            triggerUrls = try container.decodeIfPresent(String.self, forKey: .triggerUrls)
            triggerLogic = try container.decodeIfPresent(String.self, forKey: .triggerLogic) ?? "or"
        }

        init(action: String, icon: String? = nil, moveTo: String? = nil, simEsc: Bool? = nil, actionDelay: Double? = nil, restoreClipboard: Bool? = nil, restoreClipboardDelay: Double? = nil, clipboardStacking: Bool? = nil, clipboardAttachments: Bool? = nil, scriptAsync: Bool? = nil, scriptWaitTimeout: Double? = nil, inputCondition: String? = nil, nextAction: String? = nil, triggerVoice: String? = nil, triggerApps: String? = nil, triggerModes: String? = nil, triggerUrls: String? = nil, triggerLogic: String? = "or") {
            self.action = action
            self.icon = icon
            self.moveTo = moveTo
            self.simEsc = simEsc
            self.actionDelay = actionDelay
            self.restoreClipboard = restoreClipboard
            self.restoreClipboardDelay = restoreClipboardDelay
            self.clipboardStacking = clipboardStacking
            self.clipboardAttachments = clipboardAttachments
            self.scriptAsync = scriptAsync
            self.scriptWaitTimeout = scriptWaitTimeout
            self.inputCondition = inputCondition
            self.nextAction = nextAction
            self.triggerVoice = triggerVoice
            self.triggerApps = triggerApps
            self.triggerModes = triggerModes
            self.triggerUrls = triggerUrls
            self.triggerLogic = triggerLogic ?? "or"
        }
    }
    
    var defaults: Defaults
    var inserts: [String: Insert]
    var urls: [String: Url]
    var shortcuts: [String: Shortcut]
    var scriptsShell: [String: ScriptShell]
    var scriptsAS: [String: ScriptAppleScript]
    
    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case configVersion
        case defaults, inserts, urls, shortcuts, scriptsShell, scriptsAS
    }
    
    // Custom encoding
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(configVersion, forKey: .configVersion)
        try container.encode(defaults, forKey: .defaults)
        try container.encode(inserts, forKey: .inserts)
        try container.encode(urls, forKey: .urls)
        try container.encode(shortcuts, forKey: .shortcuts)
        try container.encode(scriptsShell, forKey: .scriptsShell)
        try container.encode(scriptsAS, forKey: .scriptsAS)
    }
    
    // Custom decoding
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema)
        configVersion = try container.decodeIfPresent(Int.self, forKey: .configVersion)
        defaults = try container.decodeIfPresent(Defaults.self, forKey: .defaults) ?? .defaultValues()
        inserts = try container.decodeIfPresent([String: Insert].self, forKey: .inserts) ?? [:]
        urls = try container.decodeIfPresent([String: Url].self, forKey: .urls) ?? [:]
        shortcuts = try container.decodeIfPresent([String: Shortcut].self, forKey: .shortcuts) ?? [:]
        scriptsShell = try container.decodeIfPresent([String: ScriptShell].self, forKey: .scriptsShell) ?? [:]
        scriptsAS = try container.decodeIfPresent([String: ScriptAppleScript].self, forKey: .scriptsAS) ?? [:]
    }
    
    // Default initializer for creating a new configuration from scratch
    init(
        schema: String? = nil,
        configVersion: Int? = AppConfiguration.currentConfigVersion,
        defaults: Defaults = .defaultValues(),
        inserts: [String: Insert] = [:],
        urls: [String: Url] = [:],
        shortcuts: [String: Shortcut] = [:],
        scriptsShell: [String: ScriptShell] = [:],
        scriptsAS: [String: ScriptAppleScript] = [:]
    ) {
        self.schema = schema
        self.configVersion = configVersion
        self.defaults = defaults
        self.inserts = inserts
        self.urls = urls
        self.shortcuts = shortcuts
        self.scriptsShell = scriptsShell
        self.scriptsAS = scriptsAS
    }

    static func defaultConfig() -> AppConfiguration {
        var resolvedDefaults = Defaults.defaultValues()
        resolvedDefaults.watch = resolvedWatchPathForNewConfiguration()

        // Create the autoPaste insert with all default fields
        let autoPasteInsert = Insert(
            action: ".autoPaste",
            icon: "•",
            moveTo: nil,
            simEsc: nil,
            simKeypress: nil,
            smartCasing: nil,
            smartPunctuation: nil,
            smartSpacing: nil,
            actionDelay: nil,
            simReturn: nil,
            restoreClipboard: nil,
            triggerVoice: nil,
            triggerApps: nil,
            triggerModes: nil,
            triggerUrls: nil,
            triggerLogic: "or"
        )
        
        return AppConfiguration(
            schema: nil,
            configVersion: AppConfiguration.currentConfigVersion,
            defaults: resolvedDefaults,
            inserts: ["autoPaste": autoPasteInsert]
        )
    }
}

struct CLIClipboardChainState {
    let initialClipboardContent: String?
    private(set) var didMutateClipboard: Bool = false
    private(set) var isFirstStep: Bool = true
    private(set) var isLastStep: Bool = false

    init(initialClipboardContent: String?) {
        self.initialClipboardContent = initialClipboardContent
    }

    mutating func beginStep(isLastStep: Bool) {
        self.isLastStep = isLastStep
    }

    mutating func noteClipboardMutation(_ didMutateClipboard: Bool) {
        if didMutateClipboard {
            self.didMutateClipboard = true
        }
    }

    mutating func advanceToNextStep() {
        isFirstStep = false
        isLastStep = false
    }

    func shouldRestoreClipboard(finalRestoreEnabled: Bool) -> Bool {
        finalRestoreEnabled && didMutateClipboard
    }
}

// Helper struct for dynamic coding keys in migration
private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    
    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }
    
    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
} 
