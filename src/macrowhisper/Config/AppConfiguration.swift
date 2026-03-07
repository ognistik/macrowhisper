import Foundation

// MARK: - Configuration Manager

struct AppConfiguration: Codable {
    // Schema reference for IDE validation - maps to $schema in JSON
    var schema: String?
    // Configuration semantics version
    // v1: legacy empty-string fallback behavior for some action-level string fields
    // v2: explicit empty-string semantics (null=inherits, ""=explicit empty)
    var configVersion: Int?
    static let currentConfigVersion = 2
    
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
            case watch, disableUpdateCheck, muteNotifications, activeAction, icon, moveTo, simEsc, simKeypress, smartCasing, smartPunctuation, smartSpacing, actionDelay, history, simReturn, returnDelay, restoreClipboard, restoreClipboardDelay, scheduledActionTimeout, scriptAsync, scriptWaitTimeout, clipboardStacking, clipboardBuffer, clipboardIgnore, bypassModes, muteTriggers, autoUpdateConfig, redactedLogs, nextAction
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
            clipboardBuffer = try container.decodeIfPresent(Double.self, forKey: .clipboardBuffer) ?? 5.0
            clipboardIgnore = try container.decodeIfPresent(String.self, forKey: .clipboardIgnore)
            bypassModes = try container.decodeIfPresent(String.self, forKey: .bypassModes)
            muteTriggers = try container.decodeIfPresent(Bool.self, forKey: .muteTriggers) ?? false
            autoUpdateConfig = try container.decodeIfPresent(Bool.self, forKey: .autoUpdateConfig) ?? true
            redactedLogs = try container.decodeIfPresent(Bool.self, forKey: .redactedLogs) ?? true
            nextAction = try container.decodeIfPresent(String.self, forKey: .nextAction)
        }
        
        // Memberwise initializer (needed since we added custom init(from decoder:))
        init(watch: String, disableUpdateCheck: Bool, muteNotifications: Bool, activeAction: String?, icon: String?, moveTo: String?, simEsc: Bool, simKeypress: Bool, smartCasing: Bool, smartPunctuation: Bool, smartSpacing: Bool, actionDelay: Double, history: Int?, simReturn: Bool, returnDelay: Double, restoreClipboard: Bool, restoreClipboardDelay: Double?, scheduledActionTimeout: Double, scriptAsync: Bool?, scriptWaitTimeout: Double?, clipboardStacking: Bool, clipboardBuffer: Double, clipboardIgnore: String?, bypassModes: String?, muteTriggers: Bool, autoUpdateConfig: Bool, redactedLogs: Bool, nextAction: String?) {
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
    
    struct Insert: Codable {
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
        var inputCondition: String?
        var nextAction: String?
        // --- Trigger fields for future extensibility ---
        /// Voice trigger regex (matches start of phrase)
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
            case action, icon, moveTo, simEsc, simKeypress, smartCasing, smartPunctuation, smartSpacing, actionDelay, simReturn, restoreClipboard, restoreClipboardDelay, inputCondition, nextAction
            case triggerVoice, triggerApps, triggerModes, triggerUrls, triggerLogic
        }
        
        // Custom encoding to preserve null values and ensure trigger fields are always present
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(action, forKey: .action)
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
            inputCondition = try container.decodeIfPresent(String.self, forKey: .inputCondition)
            nextAction = try container.decodeIfPresent(String.self, forKey: .nextAction)
            triggerVoice = try container.decodeIfPresent(String.self, forKey: .triggerVoice)
            triggerApps = try container.decodeIfPresent(String.self, forKey: .triggerApps)
            triggerModes = try container.decodeIfPresent(String.self, forKey: .triggerModes)
            triggerUrls = try container.decodeIfPresent(String.self, forKey: .triggerUrls)
            triggerLogic = try container.decodeIfPresent(String.self, forKey: .triggerLogic) ?? "or"
        }
        // Default initializer for new inserts
        init(action: String, icon: String? = nil, moveTo: String? = nil, simEsc: Bool? = nil, simKeypress: Bool? = nil, smartCasing: Bool? = nil, smartPunctuation: Bool? = nil, smartSpacing: Bool? = nil, actionDelay: Double? = nil, simReturn: Bool? = nil, restoreClipboard: Bool? = nil, restoreClipboardDelay: Double? = nil, inputCondition: String? = nil, nextAction: String? = nil, triggerVoice: String? = nil, triggerApps: String? = nil, triggerModes: String? = nil, triggerUrls: String? = nil, triggerLogic: String? = "or") {
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
            self.inputCondition = inputCondition
            self.nextAction = nextAction
            self.triggerVoice = triggerVoice
            self.triggerApps = triggerApps
            self.triggerModes = triggerModes
            self.triggerUrls = triggerUrls
            self.triggerLogic = triggerLogic ?? "or"
        }
    }
    
    struct Url: Codable {
        var action: String
        var icon: String?
        var moveTo: String?
        var simEsc: Bool?
        var actionDelay: Double?
        var restoreClipboard: Bool?  // Action-level override for clipboard restoration
        var restoreClipboardDelay: Double?
        var inputCondition: String?
        var nextAction: String?
        // --- Trigger fields for future extensibility ---
        /// Voice trigger regex (matches start of phrase)
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
            case action, icon, moveTo, simEsc, actionDelay, restoreClipboard, restoreClipboardDelay, inputCondition, nextAction
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
        init(action: String, icon: String? = nil, moveTo: String? = nil, simEsc: Bool? = nil, actionDelay: Double? = nil, restoreClipboard: Bool? = nil, restoreClipboardDelay: Double? = nil, inputCondition: String? = nil, nextAction: String? = nil, triggerVoice: String? = nil, triggerApps: String? = nil, triggerModes: String? = nil, triggerUrls: String? = nil, triggerLogic: String? = "or", openWith: String? = nil, openBackground: Bool? = nil) {
            self.action = action
            self.icon = icon
            self.moveTo = moveTo
            self.simEsc = simEsc
            self.actionDelay = actionDelay
            self.restoreClipboard = restoreClipboard
            self.restoreClipboardDelay = restoreClipboardDelay
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
    
    struct Shortcut: Codable {
        var action: String
        var icon: String?
        var moveTo: String?
        var simEsc: Bool?
        var actionDelay: Double?
        var restoreClipboard: Bool?  // Action-level override for clipboard restoration
        var restoreClipboardDelay: Double?
        var scriptAsync: Bool?
        var scriptWaitTimeout: Double?
        var inputCondition: String?
        var nextAction: String?
        // --- Trigger fields for future extensibility ---
        /// Voice trigger regex (matches start of phrase)
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
            case action, icon, moveTo, simEsc, actionDelay, restoreClipboard, restoreClipboardDelay, scriptAsync, scriptWaitTimeout, inputCondition, nextAction
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
        init(action: String, icon: String? = nil, moveTo: String? = nil, simEsc: Bool? = nil, actionDelay: Double? = nil, restoreClipboard: Bool? = nil, restoreClipboardDelay: Double? = nil, scriptAsync: Bool? = nil, scriptWaitTimeout: Double? = nil, inputCondition: String? = nil, nextAction: String? = nil, triggerVoice: String? = nil, triggerApps: String? = nil, triggerModes: String? = nil, triggerUrls: String? = nil, triggerLogic: String? = "or") {
            self.action = action
            self.icon = icon
            self.moveTo = moveTo
            self.simEsc = simEsc
            self.actionDelay = actionDelay
            self.restoreClipboard = restoreClipboard
            self.restoreClipboardDelay = restoreClipboardDelay
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
    
    struct ScriptShell: Codable {
        var action: String
        var icon: String?
        var moveTo: String?
        var simEsc: Bool?
        var actionDelay: Double?
        var restoreClipboard: Bool?  // Action-level override for clipboard restoration
        var restoreClipboardDelay: Double?
        var scriptAsync: Bool?
        var scriptWaitTimeout: Double?
        var inputCondition: String?
        var nextAction: String?
        // --- Trigger fields for future extensibility ---
        /// Voice trigger regex (matches start of phrase)
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
            case action, icon, moveTo, simEsc, actionDelay, restoreClipboard, restoreClipboardDelay, scriptAsync, scriptWaitTimeout, inputCondition, nextAction
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
        init(action: String, icon: String? = nil, moveTo: String? = nil, simEsc: Bool? = nil, actionDelay: Double? = nil, restoreClipboard: Bool? = nil, restoreClipboardDelay: Double? = nil, scriptAsync: Bool? = nil, scriptWaitTimeout: Double? = nil, inputCondition: String? = nil, nextAction: String? = nil, triggerVoice: String? = nil, triggerApps: String? = nil, triggerModes: String? = nil, triggerUrls: String? = nil, triggerLogic: String? = "or") {
            self.action = action
            self.icon = icon
            self.moveTo = moveTo
            self.simEsc = simEsc
            self.actionDelay = actionDelay
            self.restoreClipboard = restoreClipboard
            self.restoreClipboardDelay = restoreClipboardDelay
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
    
    struct ScriptAppleScript: Codable {
        var action: String
        var icon: String?
        var moveTo: String?
        var simEsc: Bool?
        var actionDelay: Double?
        var restoreClipboard: Bool?  // Action-level override for clipboard restoration
        var restoreClipboardDelay: Double?
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
            case action, icon, moveTo, simEsc, actionDelay, restoreClipboard, restoreClipboardDelay, scriptAsync, scriptWaitTimeout, inputCondition, nextAction, triggerVoice, triggerApps, triggerModes, triggerUrls, triggerLogic
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

        init(action: String, icon: String? = nil, moveTo: String? = nil, simEsc: Bool? = nil, actionDelay: Double? = nil, restoreClipboard: Bool? = nil, restoreClipboardDelay: Double? = nil, scriptAsync: Bool? = nil, scriptWaitTimeout: Double? = nil, inputCondition: String? = nil, nextAction: String? = nil, triggerVoice: String? = nil, triggerApps: String? = nil, triggerModes: String? = nil, triggerUrls: String? = nil, triggerLogic: String? = "or") {
            self.action = action
            self.icon = icon
            self.moveTo = moveTo
            self.simEsc = simEsc
            self.actionDelay = actionDelay
            self.restoreClipboard = restoreClipboard
            self.restoreClipboardDelay = restoreClipboardDelay
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
