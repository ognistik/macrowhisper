import Foundation

// MARK: - Configuration Manager

struct AppConfiguration: Codable {
    struct Defaults: Codable {
        var watch: String
        var noUpdates: Bool
        var noNoti: Bool
        var activeInsert: String?
        var icon: String?
        var moveTo: String?
        var noEsc: Bool
        var simKeypress: Bool
        var actionDelay: Double
        var history: Int?
        var pressReturn: Bool
        var returnDelay: Double
        var restoreClipboard: Bool
        
        // Add these coding keys and custom encoding
        enum CodingKeys: String, CodingKey {
            case watch, noUpdates, noNoti, activeInsert, icon, moveTo, noEsc, simKeypress, actionDelay, history, pressReturn, returnDelay, restoreClipboard
        }
        
        // Custom encoding to preserve null values
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(watch, forKey: .watch)
            try container.encode(noUpdates, forKey: .noUpdates)
            try container.encode(noNoti, forKey: .noNoti)
            try container.encode(activeInsert, forKey: .activeInsert)
            try container.encode(icon, forKey: .icon)
            try container.encode(moveTo, forKey: .moveTo)
            try container.encode(noEsc, forKey: .noEsc)
            try container.encode(simKeypress, forKey: .simKeypress)
            try container.encode(actionDelay, forKey: .actionDelay)
            try container.encode(history, forKey: .history)
            try container.encode(pressReturn, forKey: .pressReturn)
            try container.encode(returnDelay, forKey: .returnDelay)
            try container.encode(restoreClipboard, forKey: .restoreClipboard)
        }
        
        // Custom decoding to ensure activeInsert defaults to empty string instead of null
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            watch = try container.decode(String.self, forKey: .watch)
            noUpdates = try container.decode(Bool.self, forKey: .noUpdates)
            noNoti = try container.decode(Bool.self, forKey: .noNoti)
            // Ensure activeInsert is always empty string instead of null for consistency
            activeInsert = try container.decodeIfPresent(String.self, forKey: .activeInsert) ?? ""
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)
            noEsc = try container.decode(Bool.self, forKey: .noEsc)
            simKeypress = try container.decode(Bool.self, forKey: .simKeypress)
            actionDelay = try container.decode(Double.self, forKey: .actionDelay)
            history = try container.decodeIfPresent(Int.self, forKey: .history)
            pressReturn = try container.decode(Bool.self, forKey: .pressReturn)
            returnDelay = try container.decodeIfPresent(Double.self, forKey: .returnDelay) ?? 0.1
            restoreClipboard = try container.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? true
        }
        
        // Memberwise initializer (needed since we added custom init(from decoder:))
        init(watch: String, noUpdates: Bool, noNoti: Bool, activeInsert: String?, icon: String?, moveTo: String?, noEsc: Bool, simKeypress: Bool, actionDelay: Double, history: Int?, pressReturn: Bool, returnDelay: Double, restoreClipboard: Bool) {
            self.watch = watch
            self.noUpdates = noUpdates
            self.noNoti = noNoti
            self.activeInsert = activeInsert
            self.icon = icon
            self.moveTo = moveTo
            self.noEsc = noEsc
            self.simKeypress = simKeypress
            self.actionDelay = actionDelay
            self.history = history
            self.pressReturn = pressReturn
            self.returnDelay = returnDelay
            self.restoreClipboard = restoreClipboard
        }
        
        static func defaultValues() -> Defaults {
            return Defaults(
                watch: ("~/Documents/superwhisper" as NSString).expandingTildeInPath,
                noUpdates: false,
                noNoti: false,
                activeInsert: "",
                icon: "",
                moveTo: "",
                noEsc: false,
                simKeypress: false,
                actionDelay: 0.0,
                history: nil,
                pressReturn: false,
                returnDelay: 0.1,
                restoreClipboard: true
            )
        }
    }
    
    struct Insert: Codable {
        var action: String
        var icon: String? = ""  // Default to empty string
        var moveTo: String? = ""  // Default to empty string
        var noEsc: Bool?
        var simKeypress: Bool?
        var actionDelay: Double?
        var pressReturn: Bool?
        // --- Trigger fields for future extensibility ---
        /// Voice trigger regex (matches start of phrase)
        var triggerVoice: String? = ""
        /// App trigger regex (matches app name or bundle ID)
        var triggerApps: String? = ""
        /// Mode trigger regex (matches modeName)
        var triggerModes: String? = ""
        /// Logic for combining triggers ("and"/"or")
        var triggerLogic: String? = "or"
        // ---------------------------------------------
        
        enum CodingKeys: String, CodingKey {
            case action, icon, moveTo, noEsc, simKeypress, actionDelay, pressReturn
            case triggerVoice, triggerApps, triggerModes, triggerLogic
        }
        
        // Custom encoding to preserve null values and ensure trigger fields are always present
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(action, forKey: .action)
            try container.encode(icon, forKey: .icon)
            try container.encode(moveTo, forKey: .moveTo)
            try container.encode(noEsc, forKey: .noEsc)
            try container.encode(simKeypress, forKey: .simKeypress)
            try container.encode(actionDelay, forKey: .actionDelay)
            try container.encode(pressReturn, forKey: .pressReturn)
            // Always encode trigger fields, defaulting to "" if nil
            try container.encode(triggerVoice ?? "", forKey: .triggerVoice)
            try container.encode(triggerApps ?? "", forKey: .triggerApps)
            try container.encode(triggerModes ?? "", forKey: .triggerModes)
            try container.encode(triggerLogic ?? "or", forKey: .triggerLogic)
        }
        // Custom decoding to ensure trigger fields are always present
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            action = try container.decode(String.self, forKey: .action)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)
            noEsc = try container.decodeIfPresent(Bool.self, forKey: .noEsc)
            simKeypress = try container.decodeIfPresent(Bool.self, forKey: .simKeypress)
            actionDelay = try container.decodeIfPresent(Double.self, forKey: .actionDelay)
            pressReturn = try container.decodeIfPresent(Bool.self, forKey: .pressReturn)
            triggerVoice = try container.decodeIfPresent(String.self, forKey: .triggerVoice) ?? ""
            triggerApps = try container.decodeIfPresent(String.self, forKey: .triggerApps) ?? ""
            triggerModes = try container.decodeIfPresent(String.self, forKey: .triggerModes) ?? ""
            triggerLogic = try container.decodeIfPresent(String.self, forKey: .triggerLogic) ?? "or"
        }
        // Default initializer for new inserts
        init(action: String, icon: String? = "", moveTo: String? = "", noEsc: Bool? = nil, simKeypress: Bool? = nil, actionDelay: Double? = nil, pressReturn: Bool? = nil, triggerVoice: String? = "", triggerApps: String? = "", triggerModes: String? = "", triggerLogic: String? = "or") {
            self.action = action
            self.icon = icon
            self.moveTo = moveTo
            self.noEsc = noEsc
            self.simKeypress = simKeypress
            self.actionDelay = actionDelay
            self.pressReturn = pressReturn
            self.triggerVoice = triggerVoice ?? ""
            self.triggerApps = triggerApps ?? ""
            self.triggerModes = triggerModes ?? ""
            self.triggerLogic = triggerLogic ?? "or"
        }
    }
    
    struct Url: Codable {
        var action: String
        var moveTo: String? = ""  // Default to empty string
        var noEsc: Bool?
        var actionDelay: Double?
        // --- Trigger fields for future extensibility ---
        /// Voice trigger regex (matches start of phrase)
        var triggerVoice: String? = ""
        /// App trigger regex (matches app name or bundle ID)
        var triggerApps: String? = ""
        /// Mode trigger regex (matches modeName)
        var triggerModes: String? = ""
        /// Logic for combining triggers ("and"/"or")
        var triggerLogic: String? = "or"
        // ---------------------------------------------
        var openWith: String? = ""
        
        enum CodingKeys: String, CodingKey {
            case action, moveTo, noEsc, actionDelay
            case triggerVoice, triggerApps, triggerModes, triggerLogic
            case openWith
        }
        
        // Custom encoding to preserve null values and ensure trigger fields are always present
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(action, forKey: .action)
            try container.encode(moveTo, forKey: .moveTo)
            try container.encode(noEsc, forKey: .noEsc)
            try container.encode(actionDelay, forKey: .actionDelay)
            // Always encode trigger fields, defaulting to "" if nil
            try container.encode(triggerVoice ?? "", forKey: .triggerVoice)
            try container.encode(triggerApps ?? "", forKey: .triggerApps)
            try container.encode(triggerModes ?? "", forKey: .triggerModes)
            try container.encode(triggerLogic ?? "or", forKey: .triggerLogic)
            try container.encode(openWith ?? "", forKey: .openWith)
        }
        // Custom decoding to ensure trigger fields are always present
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            action = try container.decode(String.self, forKey: .action)
            moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)
            noEsc = try container.decodeIfPresent(Bool.self, forKey: .noEsc)
            actionDelay = try container.decodeIfPresent(Double.self, forKey: .actionDelay)
            triggerVoice = try container.decodeIfPresent(String.self, forKey: .triggerVoice) ?? ""
            triggerApps = try container.decodeIfPresent(String.self, forKey: .triggerApps) ?? ""
            triggerModes = try container.decodeIfPresent(String.self, forKey: .triggerModes) ?? ""
            triggerLogic = try container.decodeIfPresent(String.self, forKey: .triggerLogic) ?? "or"
            openWith = try container.decodeIfPresent(String.self, forKey: .openWith) ?? ""
        }
        // Default initializer for new URLs
        init(action: String, moveTo: String? = "", noEsc: Bool? = nil, actionDelay: Double? = nil, triggerVoice: String? = "", triggerApps: String? = "", triggerModes: String? = "", triggerLogic: String? = "or", openWith: String? = "") {
            self.action = action
            self.moveTo = moveTo
            self.noEsc = noEsc
            self.actionDelay = actionDelay
            self.triggerVoice = triggerVoice ?? ""
            self.triggerApps = triggerApps ?? ""
            self.triggerModes = triggerModes ?? ""
            self.triggerLogic = triggerLogic ?? "or"
            self.openWith = openWith ?? ""
        }
    }
    
    struct Shortcut: Codable {
        var action: String
        var moveTo: String? = ""  // Default to empty string
        var noEsc: Bool?
        var actionDelay: Double?
        // --- Trigger fields for future extensibility ---
        /// Voice trigger regex (matches start of phrase)
        var triggerVoice: String? = ""
        /// App trigger regex (matches app name or bundle ID)
        var triggerApps: String? = ""
        /// Mode trigger regex (matches modeName)
        var triggerModes: String? = ""
        /// Logic for combining triggers ("and"/"or")
        var triggerLogic: String? = "or"
        
        enum CodingKeys: String, CodingKey {
            case action, moveTo, noEsc, actionDelay
            case triggerVoice, triggerApps, triggerModes, triggerLogic
        }
        
        // Custom encoding to preserve null values and ensure trigger fields are always present
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(action, forKey: .action)
            try container.encode(moveTo, forKey: .moveTo)
            try container.encode(noEsc, forKey: .noEsc)
            try container.encode(actionDelay, forKey: .actionDelay)
            // Always encode trigger fields, defaulting to "" if nil
            try container.encode(triggerVoice ?? "", forKey: .triggerVoice)
            try container.encode(triggerApps ?? "", forKey: .triggerApps)
            try container.encode(triggerModes ?? "", forKey: .triggerModes)
            try container.encode(triggerLogic ?? "or", forKey: .triggerLogic)
        }
        
        // Custom decoding to ensure trigger fields are always present
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            action = try container.decode(String.self, forKey: .action)
            moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)
            noEsc = try container.decodeIfPresent(Bool.self, forKey: .noEsc)
            actionDelay = try container.decodeIfPresent(Double.self, forKey: .actionDelay)
            triggerVoice = try container.decodeIfPresent(String.self, forKey: .triggerVoice) ?? ""
            triggerApps = try container.decodeIfPresent(String.self, forKey: .triggerApps) ?? ""
            triggerModes = try container.decodeIfPresent(String.self, forKey: .triggerModes) ?? ""
            triggerLogic = try container.decodeIfPresent(String.self, forKey: .triggerLogic) ?? "or"
        }
        
        // Default initializer for new shortcuts
        init(action: String, moveTo: String? = "", noEsc: Bool? = nil, actionDelay: Double? = nil, triggerVoice: String? = "", triggerApps: String? = "", triggerModes: String? = "", triggerLogic: String? = "or") {
            self.action = action
            self.moveTo = moveTo
            self.noEsc = noEsc
            self.actionDelay = actionDelay
            self.triggerVoice = triggerVoice ?? ""
            self.triggerApps = triggerApps ?? ""
            self.triggerModes = triggerModes ?? ""
            self.triggerLogic = triggerLogic ?? "or"
        }
    }
    
    struct ScriptShell: Codable {
        var action: String
        var moveTo: String? = ""  // Default to empty string
        var noEsc: Bool?
        var actionDelay: Double?
        // --- Trigger fields for future extensibility ---
        /// Voice trigger regex (matches start of phrase)
        var triggerVoice: String? = ""
        /// App trigger regex (matches app name or bundle ID)
        var triggerApps: String? = ""
        /// Mode trigger regex (matches modeName)
        var triggerModes: String? = ""
        /// Logic for combining triggers ("and"/"or")
        var triggerLogic: String? = "or"
        
        enum CodingKeys: String, CodingKey {
            case action, moveTo, noEsc, actionDelay
            case triggerVoice, triggerApps, triggerModes, triggerLogic
        }
        
        // Custom encoding to preserve null values and ensure trigger fields are always present
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(action, forKey: .action)
            try container.encode(moveTo, forKey: .moveTo)
            try container.encode(noEsc, forKey: .noEsc)
            try container.encode(actionDelay, forKey: .actionDelay)
            // Always encode trigger fields, defaulting to "" if nil
            try container.encode(triggerVoice ?? "", forKey: .triggerVoice)
            try container.encode(triggerApps ?? "", forKey: .triggerApps)
            try container.encode(triggerModes ?? "", forKey: .triggerModes)
            try container.encode(triggerLogic ?? "or", forKey: .triggerLogic)
        }
        
        // Custom decoding to ensure trigger fields are always present
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            action = try container.decode(String.self, forKey: .action)
            moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)
            noEsc = try container.decodeIfPresent(Bool.self, forKey: .noEsc)
            actionDelay = try container.decodeIfPresent(Double.self, forKey: .actionDelay)
            triggerVoice = try container.decodeIfPresent(String.self, forKey: .triggerVoice) ?? ""
            triggerApps = try container.decodeIfPresent(String.self, forKey: .triggerApps) ?? ""
            triggerModes = try container.decodeIfPresent(String.self, forKey: .triggerModes) ?? ""
            triggerLogic = try container.decodeIfPresent(String.self, forKey: .triggerLogic) ?? "or"
        }
        
        // Default initializer for new shell scripts
        init(action: String, moveTo: String? = "", noEsc: Bool? = nil, actionDelay: Double? = nil, triggerVoice: String? = "", triggerApps: String? = "", triggerModes: String? = "", triggerLogic: String? = "or") {
            self.action = action
            self.moveTo = moveTo
            self.noEsc = noEsc
            self.actionDelay = actionDelay
            self.triggerVoice = triggerVoice ?? ""
            self.triggerApps = triggerApps ?? ""
            self.triggerModes = triggerModes ?? ""
            self.triggerLogic = triggerLogic ?? "or"
        }
    }
    
    struct ScriptAppleScript: Codable {
        var action: String
        var moveTo: String? = ""
        var noEsc: Bool?
        var actionDelay: Double?
        var triggerVoice: String? = ""
        var triggerApps: String? = ""
        var triggerModes: String? = ""
        var triggerLogic: String? = "or"

        enum CodingKeys: String, CodingKey {
            case action, moveTo, noEsc, actionDelay, triggerVoice, triggerApps, triggerModes, triggerLogic
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(action, forKey: .action)
            try container.encode(moveTo, forKey: .moveTo)
            try container.encode(noEsc, forKey: .noEsc)
            try container.encode(actionDelay, forKey: .actionDelay)
            try container.encode(triggerVoice ?? "", forKey: .triggerVoice)
            try container.encode(triggerApps ?? "", forKey: .triggerApps)
            try container.encode(triggerModes ?? "", forKey: .triggerModes)
            try container.encode(triggerLogic ?? "or", forKey: .triggerLogic)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            action = try container.decode(String.self, forKey: .action)
            moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)
            noEsc = try container.decodeIfPresent(Bool.self, forKey: .noEsc)
            actionDelay = try container.decodeIfPresent(Double.self, forKey: .actionDelay)
            triggerVoice = try container.decodeIfPresent(String.self, forKey: .triggerVoice) ?? ""
            triggerApps = try container.decodeIfPresent(String.self, forKey: .triggerApps) ?? ""
            triggerModes = try container.decodeIfPresent(String.self, forKey: .triggerModes) ?? ""
            triggerLogic = try container.decodeIfPresent(String.self, forKey: .triggerLogic) ?? "or"
        }

        init(action: String, moveTo: String? = "", noEsc: Bool? = nil, actionDelay: Double? = nil, triggerVoice: String? = "", triggerApps: String? = "", triggerModes: String? = "", triggerLogic: String? = "or") {
            self.action = action
            self.moveTo = moveTo
            self.noEsc = noEsc
            self.actionDelay = actionDelay
            self.triggerVoice = triggerVoice ?? ""
            self.triggerApps = triggerApps ?? ""
            self.triggerModes = triggerModes ?? ""
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
        case defaults, inserts, urls, shortcuts, scriptsShell, scriptsAS
    }
    
    // Custom encoding
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
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
        defaults = try container.decodeIfPresent(Defaults.self, forKey: .defaults) ?? .defaultValues()
        inserts = try container.decodeIfPresent([String: Insert].self, forKey: .inserts) ?? [:]
        urls = try container.decodeIfPresent([String: Url].self, forKey: .urls) ?? [:]
        shortcuts = try container.decodeIfPresent([String: Shortcut].self, forKey: .shortcuts) ?? [:]
        scriptsShell = try container.decodeIfPresent([String: ScriptShell].self, forKey: .scriptsShell) ?? [:]
        scriptsAS = try container.decodeIfPresent([String: ScriptAppleScript].self, forKey: .scriptsAS) ?? [:]
    }
    
    // Default initializer for creating a new configuration from scratch
    init(
        defaults: Defaults = .defaultValues(),
        inserts: [String: Insert] = [:],
        urls: [String: Url] = [:],
        shortcuts: [String: Shortcut] = [:],
        scriptsShell: [String: ScriptShell] = [:],
        scriptsAS: [String: ScriptAppleScript] = [:]
    ) {
        self.defaults = defaults
        self.inserts = inserts
        self.urls = urls
        self.shortcuts = shortcuts
        self.scriptsShell = scriptsShell
        self.scriptsAS = scriptsAS
    }

    static func defaultConfig() -> AppConfiguration {
        return AppConfiguration()
    }
} 