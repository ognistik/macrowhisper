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
        
        // Add these coding keys and custom encoding
        enum CodingKeys: String, CodingKey {
            case watch, noUpdates, noNoti, activeInsert, icon, moveTo, noEsc, simKeypress, actionDelay, history, pressReturn
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
                pressReturn: false
            )
        }
    }
    
    struct Insert: Codable {
        var name: String
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
            case name, action, icon, moveTo, noEsc, simKeypress, actionDelay, pressReturn
            case triggerVoice, triggerApps, triggerModes, triggerLogic
        }
        
        // Custom encoding to preserve null values and ensure trigger fields are always present
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
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
            name = try container.decode(String.self, forKey: .name)
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
        init(name: String, action: String, icon: String? = "", moveTo: String? = "", noEsc: Bool? = nil, simKeypress: Bool? = nil, actionDelay: Double? = nil, pressReturn: Bool? = nil, triggerVoice: String? = "", triggerApps: String? = "", triggerModes: String? = "", triggerLogic: String? = "or") {
            self.name = name
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
        var name: String
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
            case name, action, moveTo, noEsc, actionDelay
            case triggerVoice, triggerApps, triggerModes, triggerLogic
            case openWith
        }
        
        // Custom encoding to preserve null values and ensure trigger fields are always present
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
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
            name = try container.decode(String.self, forKey: .name)
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
        init(name: String, action: String, moveTo: String? = "", noEsc: Bool? = nil, actionDelay: Double? = nil, triggerVoice: String? = "", triggerApps: String? = "", triggerModes: String? = "", triggerLogic: String? = "or", openWith: String? = "") {
            self.name = name
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
        var name: String
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
            case name, action, moveTo, noEsc, actionDelay
            case triggerVoice, triggerApps, triggerModes, triggerLogic
        }
        
        // Custom encoding to preserve null values and ensure trigger fields are always present
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
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
            name = try container.decode(String.self, forKey: .name)
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
        init(name: String, action: String, moveTo: String? = "", noEsc: Bool? = nil, actionDelay: Double? = nil, triggerVoice: String? = "", triggerApps: String? = "", triggerModes: String? = "", triggerLogic: String? = "or") {
            self.name = name
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
        var name: String
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
            case name, action, moveTo, noEsc, actionDelay
            case triggerVoice, triggerApps, triggerModes, triggerLogic
        }
        
        // Custom encoding to preserve null values and ensure trigger fields are always present
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
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
            name = try container.decode(String.self, forKey: .name)
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
        init(name: String, action: String, moveTo: String? = "", noEsc: Bool? = nil, actionDelay: Double? = nil, triggerVoice: String? = "", triggerApps: String? = "", triggerModes: String? = "", triggerLogic: String? = "or") {
            self.name = name
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
        var name: String
        var action: String
        var moveTo: String? = ""
        var noEsc: Bool?
        var actionDelay: Double?
        var triggerVoice: String? = ""
        var triggerApps: String? = ""
        var triggerModes: String? = ""
        var triggerLogic: String? = "or"

        enum CodingKeys: String, CodingKey {
            case name, action, moveTo, noEsc, actionDelay, triggerVoice, triggerApps, triggerModes, triggerLogic
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
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
            name = try container.decode(String.self, forKey: .name)
            action = try container.decode(String.self, forKey: .action)
            moveTo = try container.decodeIfPresent(String.self, forKey: .moveTo)
            noEsc = try container.decodeIfPresent(Bool.self, forKey: .noEsc)
            actionDelay = try container.decodeIfPresent(Double.self, forKey: .actionDelay)
            triggerVoice = try container.decodeIfPresent(String.self, forKey: .triggerVoice) ?? ""
            triggerApps = try container.decodeIfPresent(String.self, forKey: .triggerApps) ?? ""
            triggerModes = try container.decodeIfPresent(String.self, forKey: .triggerModes) ?? ""
            triggerLogic = try container.decodeIfPresent(String.self, forKey: .triggerLogic) ?? "or"
        }

        init(name: String, action: String, moveTo: String? = "", noEsc: Bool? = nil, actionDelay: Double? = nil, triggerVoice: String? = "", triggerApps: String? = "", triggerModes: String? = "", triggerLogic: String? = "or") {
            self.name = name
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
    var inserts: [Insert]
    var urls: [Url]
    var shortcuts: [Shortcut]
    var scriptsShell: [ScriptShell]
    var scriptsAS: [ScriptAppleScript]
    
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
        inserts = try container.decodeIfPresent([Insert].self, forKey: .inserts) ?? []
        urls = try container.decodeIfPresent([Url].self, forKey: .urls) ?? []
        shortcuts = try container.decodeIfPresent([Shortcut].self, forKey: .shortcuts) ?? []
        scriptsShell = try container.decodeIfPresent([ScriptShell].self, forKey: .scriptsShell) ?? []
        scriptsAS = try container.decodeIfPresent([ScriptAppleScript].self, forKey: .scriptsAS) ?? []
    }
    
    // Default initializer for creating a new configuration from scratch
    init(
        defaults: Defaults = .defaultValues(),
        inserts: [Insert] = [],
        urls: [Url] = [],
        shortcuts: [Shortcut] = [],
        scriptsShell: [ScriptShell] = [],
        scriptsAS: [ScriptAppleScript] = []
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