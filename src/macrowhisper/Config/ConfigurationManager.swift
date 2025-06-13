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
    
    init(configPath: String?) {
        let defaultConfigPath = ("~/.config/macrowhisper/macrowhisper.json" as NSString).expandingTildeInPath
        self.configPath = configPath ?? defaultConfigPath
        
        if let loadedConfig = Self.loadConfig(from: self.configPath) {
            self._config = loadedConfig
            logInfo("Configuration loaded from \(self.configPath)")
        } else {
            self._config = AppConfiguration()
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
        return Self.loadConfig(from: self.configPath)
    }
    
    func saveConfig() {
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
                    logInfo("Configuration saved to \(configPath)")
                }
            }
        } catch {
            logError("Failed to save configuration: \(error.localizedDescription)")
            notify(title: "Macrowhisper", message: "Failed to save configuration: \(error.localizedDescription)")
        }
    }
    
    func updateFromCommandLine(watchPath: String? = nil, watcher: Bool? = nil, noUpdates: Bool? = nil, noNoti: Bool? = nil, activeInsert: String? = nil, icon: String? = nil, moveTo: String? = nil, noEsc: Bool? = nil, simKeypress: Bool? = nil, history: Int?? = nil, pressReturn: Bool? = nil, actionDelay: Double? = nil) {
        
        var shouldSave = false
        
        if let watchPath = watchPath { _config.defaults.watch = watchPath; shouldSave = true }
        if let noUpdates = noUpdates { _config.defaults.noUpdates = noUpdates; shouldSave = true }
        if let noNoti = noNoti { _config.defaults.noNoti = noNoti; shouldSave = true }
        if let activeInsert = activeInsert { _config.defaults.activeInsert = activeInsert.isEmpty ? nil : activeInsert; shouldSave = true }
        if let icon = icon { _config.defaults.icon = icon.isEmpty ? nil : icon; shouldSave = true }
        if let moveTo = moveTo { _config.defaults.moveTo = moveTo; shouldSave = true }
        if let noEsc = noEsc { _config.defaults.noEsc = noEsc; shouldSave = true }
        if let simKeypress = simKeypress { _config.defaults.simKeypress = simKeypress; shouldSave = true }
        if let pressReturn = pressReturn { _config.defaults.pressReturn = pressReturn; shouldSave = true }
        if let actionDelay = actionDelay { _config.defaults.actionDelay = actionDelay; shouldSave = true }

        if let history = history {
            _config.defaults.history = history
            shouldSave = true
        }

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
                pressReturn: arguments["pressReturn"].flatMap { Bool($0) }
            )
            
            DispatchQueue.main.async {
                completion?()
                self.onConfigChanged?("commandLineUpdate")
            }
        }
    }
    
    private func setupFileWatcher() {
        fileWatcher?.stop()
        
        logInfo("Setting up file watcher for configuration at: \(configPath)")
        
        fileWatcher = ConfigChangeWatcher(filePath: configPath, onChanged: { [weak self] in
            logInfo("Configuration file change detected. Reloading.")
            self?.syncQueue.async {
                if let newConfig = self?.loadConfig() {
                    self?._config = newConfig
                    DispatchQueue.main.async {
                        self?.onConfigChanged?("configFileChanged")
                    }
                }
            }
        })
        
        fileWatcher?.start()
    }

    func resetFileWatcher() {
        logInfo("Resetting file watcher due to configuration change.")
        setupFileWatcher()
    }

    func configurationSuccessfullyLoaded() {
        // Placeholder for future use
    }
    
    func getHistoryRetentionDays() -> Int? {
        return syncQueue.sync {
            _config.defaults.history
        }
    }
} 
