#!/usr/bin/env swift

import Foundation
import Swifter
import Dispatch
import Darwin
import UserNotifications
import ApplicationServices
import Cocoa
import Carbon.HIToolbox

let APP_VERSION = "1.0.0"
private let UNIX_PATH_MAX = 104

// MARK: - Global instances
// Global variables
var disableUpdates: Bool = false
var disableNotifications: Bool = false
var globalConfigManager: ConfigurationManager?
var autoReturnEnabled = false
var actionDelayValue: Double? = nil
var socketHealthTimer: Timer?
var historyManager: HistoryManager?
var configManager: ConfigurationManager!
var recordingsWatcher: RecordingsFolderWatcher?
var lastDetectedFrontApp: NSRunningApplication?

// Create default paths for logs
let logDirectory = ("~/Library/Logs/Macrowhisper" as NSString).expandingTildeInPath

// Initialize logger and notification manager
let logger = Logger(logDirectory: logDirectory)
let notificationManager = NotificationManager()

let lockPath = "/tmp/macrowhisper.lock"

// Initialize socket communication
let configDir = ("~/.config/macrowhisper" as NSString).expandingTildeInPath
// Place the socket in /tmp with the user's UID to avoid issues with custom config locations
let uid = getuid()
let socketPath = "/tmp/macrowhisper-\(uid).sock"

let socketCommunication = SocketCommunication(socketPath: socketPath)

// MARK: - Helper functions for logging and notifications
// Utility function to expand tilde in paths
func expandTilde(_ path: String) -> String {
    return (path as NSString).expandingTildeInPath
}

func checkWatcherAvailability() -> Bool {
    let watchPath = expandTilde(configManager.config.defaults.watch)
    let exists = FileManager.default.fileExists(atPath: watchPath)
    
    if !exists {
        logWarning("Superwhisper folder not found at: \(watchPath)")
        notify(title: "Macrowhisper", message: "Superwhisper folder not found. Please check the path.")
        return false
    }
    
    return exists
}

func initializeWatcher(_ path: String) {
    let expandedPath = expandTilde(path)
    let recordingsPath = "\(expandedPath)/recordings"
    
    if !FileManager.default.fileExists(atPath: recordingsPath) {
        logWarning("Recordings folder not found at \(recordingsPath)")
        notify(title: "Macrowhisper", message: "Recordings folder not found. Please check the path.")
        
        // Update config to disable watcher
        configManager.updateFromCommandLine(watcher: false)
        return
    }
    
    guard let historyManager = historyManager else {
        logError("History manager not initialized. Exiting.")
        exit(1)
    }
    
    recordingsWatcher = RecordingsFolderWatcher(basePath: expandedPath, configManager: configManager, historyManager: historyManager, socketCommunication: socketCommunication)
    if recordingsWatcher == nil {
        logWarning("Failed to initialize recordings folder watcher")
        notify(title: "Macrowhisper", message: "Failed to initialize watcher")
        
        // Update config to disable watcher
        configManager.updateFromCommandLine(watcher: false)
    } else {
        logDebug("Watching recordings folder at \(recordingsPath)")
        recordingsWatcher?.start()
    }
}

func acquireSingleInstanceLock(lockFilePath: String) -> Bool {
    // Try to create and lock the file
    let fd = open(lockFilePath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    if fd == -1 {
        logWarning("Could not open lock file: \(lockFilePath)")
        notify(title: "Macrowhisper", message: "Could not open lock file.")
        return false
    }

    // Try to acquire exclusive lock, non-blocking
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        close(fd)
        // Another instance is running
        print("Another instance of macrowhisper is already running.")
        print("Use 'macrowhisper --status' to check the running instance.")
        return false
    }

    // Keep fd open for the lifetime of the process to hold the lock
    return true
}

func checkSocketHealth() -> Bool {
    // Try to send a simple status command to yourself
    return socketCommunication.sendCommand(.status) != nil
}

func recoverSocket() {
    logDebug("Attempting to recover socket connection...")
    
    // Cancel and close existing socket
    socketCommunication.stopServer()
    
    // Remove socket file
    if FileManager.default.fileExists(atPath: socketPath) {
        do {
            try FileManager.default.removeItem(atPath: socketPath)
            logDebug("Removed existing socket file during recovery")
        } catch {
            logError("Failed to remove socket file during recovery: \(error)")
        }
    }
    
    // Brief delay to ensure socket cleanup
    Thread.sleep(forTimeInterval: 0.5)
    
    // Restart the server on the EXISTING global socket instance
    if let configManager = globalConfigManager {
        socketCommunication.startServer(configManager: configManager)
        logDebug("Socket server restarted after recovery attempt")
        
        // Verify recovery was successful
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if checkSocketHealth() {
                logInfo("Socket recovery successful")
            } else {
                logError("Socket recovery failed - health check still failing")
            }
        }
    } else {
        logError("Failed to restart socket server: globalConfigManager is nil")
        
        // Try to create a new configuration manager as fallback
        let fallbackConfigManager = ConfigurationManager(configPath: nil)
        socketCommunication.startServer(configManager: fallbackConfigManager)
        globalConfigManager = fallbackConfigManager
        logDebug("Socket server restarted with fallback configuration manager")
        
        // Verify fallback recovery was successful
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if checkSocketHealth() {
                logInfo("Socket recovery with fallback configuration successful")
            } else {
                logError("Socket recovery with fallback configuration failed")
            }
        }
    }
}

func registerForSleepWakeNotifications() {
    logDebug("Registering for sleep/wake notifications")
    
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil,
        queue: .main
    ) { _ in
        logDebug("System woke from sleep, restarting socket health monitor")
        startSocketHealthMonitor()
    }

    center.addObserver(
        forName: NSWorkspace.willSleepNotification,
        object: nil,
        queue: .main
    ) { _ in
        logDebug("System going to sleep, stopping socket health monitor")
        stopSocketHealthMonitor()
    }
}

func startSocketHealthMonitor() {
    // Invalidate previous timer if any
    socketHealthTimer?.invalidate()
    socketHealthTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { _ in
        logDebug("Performing periodic socket health check")
        if !checkSocketHealth() {
            logWarning("Socket appears to be unhealthy, attempting recovery")
            recoverSocket()
        }
    }
    socketHealthTimer?.tolerance = 10.0
    RunLoop.main.add(socketHealthTimer!, forMode: .common)
    logDebug("Socket health monitor started")
}

func stopSocketHealthMonitor() {
    socketHealthTimer?.invalidate()
    socketHealthTimer = nil
    logDebug("Socket health monitor stopped")
}

// ---- QUICK COMMANDS: These should never start the daemon ----
let args = CommandLine.arguments

// Handle verbose logging for quick commands too
if args.contains("--verbose") {
    logger.setConsoleLogLevel(.debug)
}

// Always available commands (work without daemon)
if args.contains("-h") || args.contains("--help") {
    printHelp()
    exit(0)
}
if args.contains("-v") || args.contains("--version") {
    print("macrowhisper version \(APP_VERSION)")
    exit(0)
}

// Config management commands (work without daemon)
if args.contains("--reveal-config") {
    // Determine the config file path using the same logic as ConfigurationManager
    let configArgIndex = args.firstIndex(where: { $0 == "--config" })
    var configPath: String
    
    if let index = configArgIndex, index + 1 < args.count {
        // Use explicit --config path
        configPath = ConfigurationManager.normalizeConfigPath(args[index + 1])
    } else {
        // Use the effective config path (saved preference or default)
        configPath = ConfigurationManager.getEffectiveConfigPath()
    }
    
    let expandedPath = configPath
    
    // Check if config file exists, if not create it with defaults
    if !FileManager.default.fileExists(atPath: expandedPath) {
        print("Configuration file not found. Creating default configuration at: \(expandedPath)")
        let configDir = (expandedPath as NSString).deletingLastPathComponent
        do {
            if !FileManager.default.fileExists(atPath: configDir) {
                try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true, attributes: nil)
            }
            let defaultConfig = AppConfiguration.defaultConfig()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(defaultConfig)
            if let jsonString = String(data: data, encoding: .utf8) {
                let formattedJson = jsonString.replacingOccurrences(of: "\\/", with: "/")
                if let formattedData = formattedJson.data(using: .utf8) {
                    try formattedData.write(to: URL(fileURLWithPath: expandedPath))
                    print("Default configuration created successfully.")
                }
            }
        } catch {
            print("Failed to create default configuration: \(error)")
            exit(1)
        }
    }
    
    // Use AppleScript to reveal the file in Finder
    let script = """
    tell application "Finder"
        reveal POSIX file "\(expandedPath)" as alias
        activate
    end tell
    """
    
    if let appleScript = NSAppleScript(source: script) {
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        
        if let error = error {
            print("Failed to reveal config file in Finder: \(error)")
            exit(1)
        } else {
            print("Configuration file revealed in Finder: \(expandedPath)")
            exit(0)
        }
    } else {
        print("Failed to create AppleScript to reveal config file")
        exit(1)
    }
}

if args.contains("--set-config") {
    let setConfigIndex = args.firstIndex(where: { $0 == "--set-config" })
    if let index = setConfigIndex, index + 1 < args.count {
        let newPath = args[index + 1]
        if ConfigurationManager.setDefaultConfigPath(newPath) {
            let normalizedPath = ConfigurationManager.normalizeConfigPath(newPath)
            print("Config path set to: \(normalizedPath)")
            print("This path will be used for future runs of macrowhisper")
        } else {
            print("Error: Cannot access or create directory for config path: \(newPath)")
            exit(1)
        }
    } else {
        print("Missing path after --set-config")
        exit(1)
    }
    exit(0)
}

if args.contains("--reset-config") {
    ConfigurationManager.resetToDefaultConfigPath()
    let defaultPath = ("~/.config/macrowhisper/macrowhisper.json" as NSString).expandingTildeInPath
    print("Config path reset to default: \(defaultPath)")
    exit(0)
}

if args.contains("--get-config") {
    let effectivePath = ConfigurationManager.getEffectiveConfigPath()
    if let savedPath = ConfigurationManager.getSavedConfigPath() {
        print("Saved config path: \(savedPath)")
    } else {
        print("Using default config path: \(effectivePath)")
    }
    exit(0)
}

// Service management commands (work without daemon)
if args.contains("--install-service") {
    suppressConsoleLogging = true
    let serviceManager = ServiceManager()
    let result = serviceManager.installService()
    if result.success {
        print(result.message)
    } else {
        print(result.message)
        exit(1)
    }
    exit(0)
}

if args.contains("--start-service") {
    suppressConsoleLogging = true
    let serviceManager = ServiceManager()
    
    // Check if there's a running daemon instance and stop it first
    let daemonResult = serviceManager.stopRunningDaemon()
    if daemonResult.success && daemonResult.message != "No running daemon instance found" {
        print("Stopped existing daemon instance: \(daemonResult.message)")
        // Brief delay to ensure clean shutdown
        Thread.sleep(forTimeInterval: 1.0)
    }
    
    let result = serviceManager.startService()
    if result.success {
        print(result.message)
    } else {
        print(result.message)
        exit(1)
    }
    exit(0)
}

if args.contains("--stop-service") {
    suppressConsoleLogging = true
    let serviceManager = ServiceManager()
    
    // Try to stop the service first
    let serviceResult = serviceManager.stopService()
    var stoppedService = false
    
    if serviceResult.success && serviceResult.message != "Service is not running" {
        print("Service stopped: \(serviceResult.message)")
        stoppedService = true
    }
    
    // Also try to stop any running daemon instance
    let daemonResult = serviceManager.stopRunningDaemon()
    if daemonResult.success && daemonResult.message != "No running daemon instance found" {
        print("Daemon stopped: \(daemonResult.message)")
        stoppedService = true
    }
    
    if !stoppedService {
        if serviceResult.success {
            print("Service is not running")
        } else {
            print(serviceResult.message)
            exit(1)
        }
    }
    exit(0)
}

if args.contains("--restart-service") {
    suppressConsoleLogging = true
    let serviceManager = ServiceManager()
    let result = serviceManager.restartService()
    if result.success {
        print(result.message)
    } else {
        print(result.message)
        exit(1)
    }
    exit(0)
}

if args.contains("--uninstall-service") {
    suppressConsoleLogging = true
    let serviceManager = ServiceManager()
    let result = serviceManager.uninstallService()
    if result.success {
        print(result.message)
    } else {
        print(result.message)
        exit(1)
    }
    exit(0)
}

if args.contains("--service-status") {
    let serviceManager = ServiceManager()
    print(serviceManager.getServiceStatus())
    exit(0)
}

// Commands that require a running daemon
let requireDaemonCommands = [
    "-s", "--status", "--get-icon", "--get-insert", "--list-inserts", 
    "--check-updates", "--exec-insert", "--auto-return", "--add-url", 
    "--add-shortcut", "--add-shell", "--add-as", "--add-insert", 
    "--remove-url", "--remove-shortcut", "--remove-shell", "--remove-as", 
    "--remove-insert", "--quit", "--stop", "--watch", "--no-updates", 
    "--no-noti", "--insert", "--icon", "--move-to", "--no-esc", 
    "--sim-keypress", "--action-delay", "--return-delay", "--history", 
    "--press-return", "--restore-clipboard"
]

// Check if any of the commands that require a daemon are present
let hasDaemonCommand = requireDaemonCommands.contains { args.contains($0) }

if hasDaemonCommand {
    let socketCommunication = SocketCommunication(socketPath: socketPath)
    
    // Check for status command first (has different error message)
    if args.contains("-s") || args.contains("--status") {
        if let response = socketCommunication.sendCommand(.status) {
            print(response)
        } else {
            print("macrowhisper is not running.")
        }
        exit(0)
    }
    
    // For all other commands, check if daemon is running first
    if socketCommunication.sendCommand(.status) == nil {
        print("macrowhisper is not running. Start it first.")
        exit(1)
    }
    
    // Handle daemon-required commands
    if args.contains("--get-icon") {
        if let response = socketCommunication.sendCommand(.getIcon) {
            print(response)
        } else {
            print("Failed to get icon.")
        }
        exit(0)
    }
    
    if args.contains("--get-insert") {
        let getInsertIndex = args.firstIndex(where: { $0 == "--get-insert" })
        var arguments: [String: String]? = nil
        if let index = getInsertIndex, index + 1 < args.count, !args[index + 1].starts(with: "--") {
            arguments = ["name": args[index + 1]]
        }
        if let response = socketCommunication.sendCommand(.getInsert, arguments: arguments) {
            print(response)
        } else {
            print("Failed to get insert.")
        }
        exit(0)
    }
    
    if args.contains("--list-inserts") {
        if let response = socketCommunication.sendCommand(.listInserts) {
            print(response)
        } else {
            print("Failed to list inserts.")
        }
        exit(0)
    }
    
    if args.contains("--check-updates") {
        if let response = socketCommunication.sendCommand(.forceUpdateCheck) {
            print(response)
        } else {
            print("Failed to check for updates.")
        }
        exit(0)
    }
    
    if args.contains("--exec-insert") {
        let execInsertIndex = args.firstIndex(where: { $0 == "--exec-insert" })
        if let index = execInsertIndex, index + 1 < args.count {
            let insertName = args[index + 1]
            let arguments: [String: String] = ["name": insertName]
            if let response = socketCommunication.sendCommand(.execInsert, arguments: arguments) {
                print(response)
            } else {
                print("Failed to execute insert.")
            }
        } else {
            print("Missing insert name after --exec-insert")
        }
        exit(0)
    }
    
    if args.contains("--auto-return") {
        let autoReturnIndex = args.firstIndex(where: { $0 == "--auto-return" })
        var arguments: [String: String] = [:]
        if let index = autoReturnIndex, index + 1 < args.count && !args[index + 1].starts(with: "--") {
            arguments["enable"] = args[index + 1]
        } else {
            arguments["enable"] = "true"
        }
        if let response = socketCommunication.sendCommand(.autoReturn, arguments: arguments) {
            print(response)
        } else {
            print("Failed to set auto-return.")
        }
        exit(0)
    }
    
    // Add commands
    if args.contains("--add-url") {
        let addUrlIndex = args.firstIndex(where: { $0 == "--add-url" })
        if let index = addUrlIndex, index + 1 < args.count {
            let urlName = args[index + 1]
            let arguments: [String: String] = ["name": urlName]
            if let response = socketCommunication.sendCommand(.addUrl, arguments: arguments) {
                print(response)
            } else {
                print("Failed to add URL action.")
            }
        } else {
            print("Missing name after --add-url")
        }
        exit(0)
    }
    
    if args.contains("--add-shortcut") {
        let addShortcutIndex = args.firstIndex(where: { $0 == "--add-shortcut" })
        if let index = addShortcutIndex, index + 1 < args.count {
            let shortcutName = args[index + 1]
            let arguments: [String: String] = ["name": shortcutName]
            if let response = socketCommunication.sendCommand(.addShortcut, arguments: arguments) {
                print(response)
            } else {
                print("Failed to add shortcut action.")
            }
        } else {
            print("Missing name after --add-shortcut")
        }
        exit(0)
    }
    
    if args.contains("--add-shell") {
        let addShellIndex = args.firstIndex(where: { $0 == "--add-shell" })
        if let index = addShellIndex, index + 1 < args.count {
            let shellName = args[index + 1]
            let arguments: [String: String] = ["name": shellName]
            if let response = socketCommunication.sendCommand(.addShell, arguments: arguments) {
                print(response)
            } else {
                print("Failed to add shell script action.")
            }
        } else {
            print("Missing name after --add-shell")
        }
        exit(0)
    }
    
    if args.contains("--add-as") {
        let addASIndex = args.firstIndex(where: { $0 == "--add-as" })
        if let index = addASIndex, index + 1 < args.count {
            let asName = args[index + 1]
            let arguments: [String: String] = ["name": asName]
            if let response = socketCommunication.sendCommand(.addAppleScript, arguments: arguments) {
                print(response)
            } else {
                print("Failed to add AppleScript action.")
            }
        } else {
            print("Missing name after --add-as")
        }
        exit(0)
    }
    
    if args.contains("--add-insert") {
        let addInsertIndex = args.firstIndex(where: { $0 == "--add-insert" })
        if let index = addInsertIndex, index + 1 < args.count {
            let insertName = args[index + 1]
            let arguments: [String: String] = ["name": insertName]
            if let response = socketCommunication.sendCommand(.addInsert, arguments: arguments) {
                print(response)
            } else {
                print("Failed to add insert.")
            }
        } else {
            print("Missing name after --add-insert")
        }
        exit(0)
    }
    
    // Remove commands
    if args.contains("--remove-url") {
        let removeUrlIndex = args.firstIndex(where: { $0 == "--remove-url" })
        if let index = removeUrlIndex, index + 1 < args.count {
            let urlName = args[index + 1]
            let arguments: [String: String] = ["name": urlName]
            if let response = socketCommunication.sendCommand(.removeUrl, arguments: arguments) {
                print(response)
            } else {
                print("Failed to remove URL action.")
            }
        } else {
            print("Missing name after --remove-url")
        }
        exit(0)
    }
    
    if args.contains("--remove-shortcut") {
        let removeShortcutIndex = args.firstIndex(where: { $0 == "--remove-shortcut" })
        if let index = removeShortcutIndex, index + 1 < args.count {
            let shortcutName = args[index + 1]
            let arguments: [String: String] = ["name": shortcutName]
            if let response = socketCommunication.sendCommand(.removeShortcut, arguments: arguments) {
                print(response)
            } else {
                print("Failed to remove shortcut action.")
            }
        } else {
            print("Missing name after --remove-shortcut")
        }
        exit(0)
    }
    
    if args.contains("--remove-shell") {
        let removeShellIndex = args.firstIndex(where: { $0 == "--remove-shell" })
        if let index = removeShellIndex, index + 1 < args.count {
            let shellName = args[index + 1]
            let arguments: [String: String] = ["name": shellName]
            if let response = socketCommunication.sendCommand(.removeShell, arguments: arguments) {
                print(response)
            } else {
                print("Failed to remove shell script action.")
            }
        } else {
            print("Missing name after --remove-shell")
        }
        exit(0)
    }
    
    if args.contains("--remove-as") {
        let removeASIndex = args.firstIndex(where: { $0 == "--remove-as" })
        if let index = removeASIndex, index + 1 < args.count {
            let asName = args[index + 1]
            let arguments: [String: String] = ["name": asName]
            if let response = socketCommunication.sendCommand(.removeAppleScript, arguments: arguments) {
                print(response)
            } else {
                print("Failed to remove AppleScript action.")
            }
        } else {
            print("Missing name after --remove-as")
        }
        exit(0)
    }
    
    if args.contains("--remove-insert") {
        let removeInsertIndex = args.firstIndex(where: { $0 == "--remove-insert" })
        if let index = removeInsertIndex, index + 1 < args.count {
            let insertName = args[index + 1]
            let arguments: [String: String] = ["name": insertName]
            if let response = socketCommunication.sendCommand(.removeInsert, arguments: arguments) {
                print(response)
            } else {
                print("Failed to remove insert.")
            }
        } else {
            print("Missing name after --remove-insert")
        }
        exit(0)
    }
    
    if args.contains("--quit") || args.contains("--stop") {
        if let response = socketCommunication.sendCommand(.quit) {
            print(response)
        } else {
            print("No running instance to quit.")
        }
        exit(0)
    }
    
    // Handle configuration update commands (require daemon)
    var arguments: [String: String] = [:]
    
    if let watchIndex = args.firstIndex(where: { $0 == "--watch" }),
       watchIndex + 1 < args.count {
        arguments["watchPath"] = args[watchIndex + 1]
    }
    
    if args.contains("--no-updates") {
        let noUpdatesIndex = args.firstIndex(where: { $0 == "--no-updates" })
        if let index = noUpdatesIndex, index + 1 < args.count {
            arguments["noUpdates"] = args[index + 1]
        } else {
            arguments["noUpdates"] = "true"
        }
    }
    
    if args.contains("--no-noti") {
        let noNotiIndex = args.firstIndex(where: { $0 == "--no-noti" })
        if let index = noNotiIndex, index + 1 < args.count {
            arguments["noNoti"] = args[index + 1]
        } else {
            arguments["noNoti"] = "true"
        }
    }
    
    if args.contains("--insert") {
        let insertIndex = args.firstIndex(where: { $0 == "--insert" })
        if let index = insertIndex, index + 1 < args.count && !args[index + 1].starts(with: "--") {
            arguments["activeInsert"] = args[index + 1]
        } else {
            arguments["activeInsert"] = ""
        }
    }
    
    if args.contains("--no-esc") {
        let noEscIndex = args.firstIndex(where: { $0 == "--no-esc" })
        if let index = noEscIndex, index + 1 < args.count {
            arguments["noEsc"] = args[index + 1]
        } else {
            arguments["noEsc"] = "true"
        }
    }
    
    if args.contains("--sim-keypress") {
        let simKeyPressIndex = args.firstIndex(where: { $0 == "--sim-keypress" })
        if let index = simKeyPressIndex, index + 1 < args.count {
            arguments["simKeypress"] = args[index + 1]
        } else {
            arguments["simKeypress"] = "true"
        }
    }
    
    if args.contains("--press-return") {
        let pressReturnIndex = args.firstIndex(where: { $0 == "--press-return" })
        if let index = pressReturnIndex, index + 1 < args.count {
            arguments["pressReturn"] = args[index + 1]
        } else {
            arguments["pressReturn"] = "true"
        }
    }
    
    if args.contains("--icon") {
        let iconIndex = args.firstIndex(where: { $0 == "--icon" })
        if let index = iconIndex, index + 1 < args.count && !args[index + 1].starts(with: "--") {
            arguments["icon"] = args[index + 1]
        } else {
            arguments["icon"] = ""
        }
    }
    
    if args.contains("--action-delay") {
        let actionDelayIndex = args.firstIndex(where: { $0 == "--action-delay" })
        if let index = actionDelayIndex, index + 1 < args.count {
            arguments["actionDelay"] = args[index + 1]
        }
    }
    
    if args.contains("--return-delay") {
        let returnDelayIndex = args.firstIndex(where: { $0 == "--return-delay" })
        if let index = returnDelayIndex, index + 1 < args.count {
            arguments["returnDelay"] = args[index + 1]
        }
    }
    
    if args.contains("--history") {
        let historyIndex = args.firstIndex(where: { $0 == "--history" })
        if let index = historyIndex, index + 1 < args.count && !args[index + 1].starts(with: "--") {
            let historyArg = args[index + 1]
            if historyArg.lowercased() == "null" {
                arguments["history"] = "null"
            } else {
                arguments["history"] = historyArg
            }
        } else {
            arguments["history"] = "null"
        }
    }
    
    if args.contains("--move-to") {
        let moveToIndex = args.firstIndex(where: { $0 == "--move-to" })
        if let index = moveToIndex, index + 1 < args.count && !args[index + 1].starts(with: "--") {
            arguments["moveTo"] = args[index + 1]
        } else {
            arguments["moveTo"] = ""
        }
    }
    
    if args.contains("--restore-clipboard") {
        let restoreClipboardIndex = args.firstIndex(where: { $0 == "--restore-clipboard" })
        if let index = restoreClipboardIndex, index + 1 < args.count {
            arguments["restoreClipboard"] = args[index + 1]
        } else {
            arguments["restoreClipboard"] = "true"
        }
    }
    
    // If we have config update arguments, send updateConfig
    if !arguments.isEmpty {
        if let response = socketCommunication.sendCommand(.updateConfig, arguments: arguments) {
            print("Response from running instance: \(response)")
        } else {
            print("Failed to communicate with running instance.")
        }
        exit(0)
    }
}

// Hidden test commands (development only) - can work without daemon
if args.contains("--test-update-dialog") {
    let versionChecker = VersionChecker()
    
    var testVersion = "1.2.0"
    var testDescription = "This is a test update with new features:\n• Fixed clipboard handling\n• Improved performance\n• Added new automation triggers"
    
    if let versionIndex = args.firstIndex(where: { $0 == "--test-version" }),
       versionIndex + 1 < args.count {
        testVersion = args[versionIndex + 1]
    }
    
    if let descIndex = args.firstIndex(where: { $0 == "--test-description" }),
       descIndex + 1 < args.count {
        testDescription = args[descIndex + 1]
    }
    
    print("Testing update dialog with version: \(APP_VERSION) → \(testVersion)")
    print("Description: \(testDescription)")
    print("Dialog will appear shortly...")
    
    let versionMessage = "CLI: \(APP_VERSION) → \(testVersion)"
    versionChecker.testUpdateDialog(versionMessage: versionMessage, description: testDescription)
    
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        print("Test dialog displayed. Check for dialog window.")
    }
    
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 10))
    exit(0)
}

// Hidden commands to show/clear version checker state (require daemon)
if args.contains("--version-state") || args.contains("--version-clear") {
    let socketCommunication = SocketCommunication(socketPath: socketPath)
    if socketCommunication.sendCommand(.status) == nil {
        print("macrowhisper is not running. Start it first.")
        exit(1)
    }
    
    if args.contains("--version-state") {
        if let response = socketCommunication.sendCommand(.versionState) {
            print(response)
        } else {
            print("Failed to get version state.")
        }
        exit(0)
    }
    
    if args.contains("--version-clear") {
        if let response = socketCommunication.sendCommand(.versionClear) {
            print(response)
        } else {
            print("Failed to clear version state.")
        }
        exit(0)
    }
}

// ---- END QUICK COMMANDS ----

if !acquireSingleInstanceLock(lockFilePath: lockPath) {
    logError("Failed to acquire single instance lock. Exiting.")
    exit(1)
}

// Check if a service is running and provide appropriate feedback
// Only do this check if we're NOT being started by launchd (i.e., started manually)
let parentPID = getppid()
let env = ProcessInfo.processInfo.environment
let isStartedByLaunchd = env["LAUNCHED_BY_LAUNCHD"] == "1" || 
                         env["XPC_SERVICE_NAME"] != nil ||
                         parentPID == 1  // Parent process ID is 1 (launchd)

// Debug logging to understand the startup context
logDebug("Startup context - Parent PID: \(parentPID), LAUNCHED_BY_LAUNCHD: \(env["LAUNCHED_BY_LAUNCHD"] ?? "nil"), XPC_SERVICE_NAME: \(env["XPC_SERVICE_NAME"] ?? "nil"), isStartedByLaunchd: \(isStartedByLaunchd)")

if !isStartedByLaunchd {
    let serviceManager = ServiceManager()
    if serviceManager.isServiceRunning() {
        logInfo("Service is already running. Configuration has been reloaded.")
        print("✅ macrowhisper service is already running. Configuration has been reloaded.")
        exit(0)
    }
} else {
    logDebug("Started by launchd - proceeding with daemon initialization")
}

// MARK: - Argument Parsing and Startup

let defaultSuperwhisperPath = ("~/Documents/superwhisper" as NSString).expandingTildeInPath
let defaultRecordingsPath = "\(defaultSuperwhisperPath)/recordings"

func printHelp() {
    print("""
    Usage: macrowhisper [OPTIONS]

    Automation tools for Superwhisper.

    DAEMON COMMANDS (start/manage the background service):
      (no arguments)                Start app with default configuration
      --config <path>               Start app with custom config file
      --verbose                     Enable verbose logging (debug messages)

    QUICK COMMANDS (work without running instance):
      -h, --help                    Show this help message
      -v, --version                 Show version information
      
    CONFIG MANAGEMENT (work without running instance):
      --set-config <path>           Set the default config path for future runs
      --reset-config                Reset config path to default location  
      --get-config                  Show the currently saved config path
      --reveal-config               Open the configuration file in Finder
                                    (creates default config if none exists)

    SERVICE MANAGEMENT (work without running instance):
      --install-service             Install macrowhisper as a system service
      --start-service               Start the service (installs if needed, stops existing daemon)
      --stop-service                Stop the service and any running daemon instances
      --restart-service             Restart the service
      --uninstall-service           Uninstall the service (stops it first)
      --service-status              Show detailed service status information

    RUNTIME COMMANDS (require running instance):
      -s, --status                  Get the status of the running instance
      --quit, --stop                Quit the running instance (legacy - use --stop-service instead)

    CONFIG EDITING (require running instance):
      --watch <path>                Set path to superwhisper folder
      --no-updates <true/false>     Enable or disable automatic update checking
      --no-noti <true/false>        Enable or disable all notifications
      --no-esc <true/false>         Disable all ESC key simulations when set to true
      --action-delay <seconds>      Set delay in seconds before actions are executed
      --return-delay <seconds>      Set delay in seconds before return key press
      --history <days>              Set number of days to keep recordings (0 to keep most recent)
                                    Use 'null' or no value to disable history management
      --sim-keypress <true/false>   Simulate key presses for text input
                                    (note: linebreaks are treated as return presses)
      --press-return <true/false>   Simulate return key press after every insert execution
                                    (persistent setting, unlike --auto-return which is one-time)
      --restore-clipboard <true/false> Enable or disable clipboard restoration
                                    after insert actions (default: true)
      --icon <icon>                 Set the default icon to use when no insert icon is available
                                    Use '.none' to explicitly use no icon
      --move-to <path>              Set the default path to move folder to after processing
                                    Use '.delete' to delete folder, '.none' to not move

    INSERT MANAGEMENT (require running instance):
      --list-inserts                List all configured inserts
      --add-insert <name>           Add or update an insert
      --remove-insert <name>        Remove an insert
      --exec-insert <name>          Execute an insert action using the last valid result
      --auto-return <true/false>    Simulate return for one interaction with insert actions
      --get-icon                    Get the icon of the active insert
      --get-insert [<name>]         Get name of active insert (if run without <name>)
                                    If a name is provided, returns the action content
      --insert [<name>]             Clears active insert (if run without <name>).
                                    If a name is provided, it sets it as active insert.

    ACTION MANAGEMENT (require running instance):
      --add-url <name>              Add or update a URL action
      --add-shortcut <name>         Add or update a Shortcuts action
      --add-shell <name>            Add or update a shell script action
      --add-as <name>               Add or update an AppleScript action
      --remove-url <name>           Remove a URL action
      --remove-shortcut <name>      Remove a Shortcuts action
      --remove-shell <name>         Remove a shell script action
      --remove-as <name>            Remove an AppleScript action

    OTHER (require running daemon):
      --check-updates               Force check for updates

    Examples:
      macrowhisper
        # Starts the daemon with default configuration

      macrowhisper --config ~/custom-config.json
        # Starts the daemon with a custom configuration file

      macrowhisper --insert pasteResult
        # Sets the active insert to 'pasteResult'

      macrowhisper --get-insert
        # Gets the name of the current active insert

      macrowhisper --get-insert pasteResult
        # Gets the processed action content for 'pasteResult'

      macrowhisper --reveal-config
        # Opens the configuration file in Finder (creates it if missing)

      macrowhisper --quit
        # Stops the running instance

      macrowhisper --set-config ~/my-configs/
        # Sets ~/my-configs/macrowhisper.json as the default config path

      macrowhisper --start-service
        # Install and start macrowhisper as a background service

      macrowhisper --service-status
        # Check if the service is installed and running

      macrowhisper --stop-service
        # Stop the background service

    Note: Most commands require a running daemon. Use --start-service for automatic startup,
    or start manually with 'macrowhisper'.
    """)
}

// Argument parsing
var configPath: String? = nil
var verboseLogging = false
var i = 1
while i < args.count {
    switch args[i] {
    case "--config":
        if i + 1 < args.count {
            configPath = args[i + 1]
            i += 2
        } else {
            logError("Missing value after \(args[i])")
            exit(1)
        }
    case "--verbose":
        verboseLogging = true
        i += 1
    default:
        // Ignore other arguments on the daemon side for now
        i += 1
    }
}

// Apply verbose logging setting if requested
if verboseLogging {
    logger.setConsoleLogLevel(.debug)
    logInfo("Verbose logging enabled - debug messages will be shown in console")
}

// Initialize configuration manager with the specified path
configManager = ConfigurationManager(configPath: configPath)
globalConfigManager = configManager

historyManager = HistoryManager(configManager: configManager)

// Read values from config first
let config = configManager.config
disableUpdates = config.defaults.noUpdates
disableNotifications = config.defaults.noNoti

// Get the final watch path after possible updates
let watchFolderPath = expandTilde(config.defaults.watch)

// Track the last used watch path for watcher reinitialization
var lastWatchPath: String? = watchFolderPath

// Check feature availability
let runWatcher = checkWatcherAvailability()

// ---
// At this point, continue with initializing server and/or watcher as usual...
if runWatcher { logDebug("Watcher: \(watchFolderPath)/recordings") }

// Server setup - only if jsonPath is provided
// MARK: - Server and Watcher Setup

// Start the socket server
logDebug("About to start socket server...")
socketCommunication.startServer(configManager: configManager)

// Add a deinit to stop the server when the app terminates
defer {
    socketCommunication.stopServer()
}

// Initialize the recordings folder watcher if enabled
if runWatcher {
    // Validate the watch folder exists
    let recordingsPath = "\(watchFolderPath)/recordings"
    if !FileManager.default.fileExists(atPath: recordingsPath) {
        logError("Error: Recordings folder not found at \(recordingsPath)")
        notify(title: "Macrowhisper", message: "Error: Recordings folder not found at \(recordingsPath)")
        exit(1)
    }
    
    guard let historyManager = historyManager else {
        logError("History manager not initialized. Exiting.")
        exit(1)
    }
    
    recordingsWatcher = RecordingsFolderWatcher(basePath: watchFolderPath, configManager: configManager, historyManager: historyManager, socketCommunication: socketCommunication)
    if recordingsWatcher == nil {
        logWarning("Warning: Failed to initialize recordings folder watcher")
        notify(title: "Macrowhisper", message: "Warning: Failed to initialize recordings folder watcher")
    } else {
        logDebug("Watching recordings folder at \(recordingsPath)")
        recordingsWatcher?.start()
    }
}

// Set up configuration change handler for live updates
configManager.onConfigChanged = { reason in
    // Store previous values to detect changes
    let previousDisableUpdates = disableUpdates
    // Update global variables
    disableUpdates = configManager.config.defaults.noUpdates
    disableNotifications = configManager.config.defaults.noNoti
    // If updates were disabled but are now enabled, reset the version checker state
    if previousDisableUpdates == true && disableUpdates == false {
        versionChecker.resetLastCheckDate()
    }
    
    // Handle watch path changes and validation
    let currentWatchPath = expandTilde(configManager.config.defaults.watch)
    let recordingsPath = "\(currentWatchPath)/recordings"
    let recordingsFolderExists = FileManager.default.fileExists(atPath: recordingsPath)
    
    // Only reinitialize watcher if the watch path actually changed
    if lastWatchPath != currentWatchPath {
        logDebug("Watch path changed from '\(lastWatchPath ?? "<none>")' to '\(currentWatchPath)'. Handling watcher reinitialization.")
        // Stop any existing watcher
        if recordingsWatcher != nil {
            recordingsWatcher?.stop()
            recordingsWatcher = nil
            logDebug("Stopped previous watcher for path: \(lastWatchPath ?? "<none>")")
        }
        // Update lastWatchPath
        lastWatchPath = currentWatchPath
        // If the new path is valid, start a new watcher
        if recordingsFolderExists {
            guard let historyManager = historyManager else {
                logError("History manager not initialized. Exiting.")
                return
            }
            recordingsWatcher = RecordingsFolderWatcher(basePath: currentWatchPath, configManager: configManager, historyManager: historyManager, socketCommunication: socketCommunication)
            if recordingsWatcher == nil {
                logWarning("Failed to initialize recordings folder watcher for new path: \(currentWatchPath)")
                notify(title: "Macrowhisper", message: "Failed to initialize watcher for new path.")
            } else {
                logDebug("Watching recordings folder at \(recordingsPath)")
                recordingsWatcher?.start()
            }
        } else {
            // If the new path is invalid, notify and wait for a valid path
            logWarning("Watch path invalid: Recordings folder not found at \(recordingsPath)")
            notify(title: "Macrowhisper", message: "Recordings folder not found at new path. Please check the path.")
        }
    } else if reason == "watchPathChanged" || recordingsWatcher == nil {
        // If the watcher is nil (e.g., app just started or was stopped due to invalid path), try to start it if the path is valid
        if recordingsWatcher == nil && recordingsFolderExists {
            guard let historyManager = historyManager else {
                logError("History manager not initialized. Exiting.")
                return
            }
            recordingsWatcher = RecordingsFolderWatcher(basePath: currentWatchPath, configManager: configManager, historyManager: historyManager, socketCommunication: socketCommunication)
            if recordingsWatcher == nil {
                logWarning("Failed to initialize recordings folder watcher for path: \(currentWatchPath)")
                notify(title: "Macrowhisper", message: "Failed to initialize watcher for path.")
            } else {
                logDebug("Watching recordings folder at \(recordingsPath)")
                recordingsWatcher?.start()
            }
        } else if !recordingsFolderExists {
            // If the path is still invalid, notify again
            logWarning("Watch path invalid: Recordings folder not found at \(recordingsPath)")
            notify(title: "Macrowhisper", message: "Recordings folder not found. Please check the path.")
        }
    }
}


// Initialize version checker
let versionChecker = VersionChecker()

// Check for updates on startup (respects noUpdates setting and timing constraints)
versionChecker.checkForUpdates()

registerForSleepWakeNotifications()
startSocketHealthMonitor()
// Log that we're ready
logInfo("Macrowhisper initialized and ready")

// Keep the main thread running
RunLoop.main.run()
