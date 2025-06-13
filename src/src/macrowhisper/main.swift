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

// MARK: - Global instances
// Global variables
var disableUpdates: Bool = false
var disableNotifications: Bool = false
var globalConfigManager: ConfigurationManager?
var autoReturnEnabled = false
var actionDelayValue: Double? = nil
var socketHealthTimer: Timer?

// Create default paths for logs
let logDirectory = ("~/Library/Logs/Macrowhisper" as NSString).expandingTildeInPath

// Initialize logger and notification manager
let logger = Logger(logDirectory: logDirectory)
let notificationManager = NotificationManager()
let socketCommunication = SocketCommunication(socketPath: "/tmp/macrowhisper.sock")

// --- Ensure watcher is global and not redeclared locally ---
var recordingsWatcher: RecordingsFolderWatcher? = nil

// MARK: - Helper functions for logging and notifications

func checkWatcherAvailability() -> Bool {
    // TODO: Implementation needed
    return true
}

func initializeWatcher(_ path: String) {
    // TODO: Implementation needed
}

func registerForSleepWakeNotifications() {
    // TODO: Implementation needed
}

func startSocketHealthMonitor() {
    // TODO: Implementation needed
}

// MARK: - Argument Parsing and Startup

let defaultSuperwhisperPath = ("~/Documents/superwhisper" as NSString).expandingTildeInPath
let defaultRecordingsPath = "\(defaultSuperwhisperPath)/recordings"

func printHelp() {
    print("""
    Usage: macrowhisper [OPTIONS]

    Automation tools for Superwhisper.

    OPTIONS:
      <no argument>                 Reloads configuration file on running instance
      -c, --config <path>           Path to config file (default: ~/.config/macrowhisper/macrowhisper.json)
      -w, --watch <path>            Path to superwhisper folder
          --no-updates true/false   Enable or disable automatic update checking
          --no-noti true/false      Enable or disable all notifications
          --no-esc true/false       Disable all ESC key simulations when set to true
          --action-delay <seconds>  Set delay in seconds before actions are executed
          --insert <name>           Set the active insert (use empty string to disable)
          --history <days>          Set number of days to keep recordings (0 to keep most recent recording)
                                    Use 'null' or no value to disable history management
          --sim-keypress true/false Simulate key presses for text input
                                    (note: linebreaks are treated as return presses)
          --press-return true/false Simulate return key press after every insert execution
                                    (persistent setting, unlike --auto-return which is one-time)
          --icon <icon>             Set the default icon to use when no insert icon is available
                                    Use '.none' to explicitly use no icon
          --move-to <path>          Set the default path to move folder to after processing
                                    Use '.delete' to delete folder, '.none' to not move
      -s, --status                  Get the status of the background process
      -h, --help                    Show this help message
      -v, --version                 Show version information

    INSERTS COMMANDS:
      --list-inserts                List all configured inserts
      --add-insert <name> <action>  Add or update an insert
      --remove-insert <name>        Remove an insert
      --exec-insert <name>          Execute an insert action using the last valid result
      --auto-return true/false      Insert result and simulate return for one interaction
      --get-icon                    Get the icon of the active insert

    Examples:
      macrowhisper
        # Uses defaults from config file/Reloads config file

      macrowhisper --config ~/custom-config.json

      macrowhisper --watch ~/otherfolder/superwhisper --watcher true --no-updates false

      macrowhisper --insert pasteResult
        # Sets the active insert to pasteResult

    """)
}

// Argument parsing
var configPath: String? = nil
var watchPath: String? = nil
var watcherFlag: Bool? = nil
var insertName: String? = nil
var iconValue: String? = nil
var moveToPath: String? = nil
var noEscFlag: Bool? = nil
var simKeypressFlag: Bool? = nil
var pressReturnFlag: Bool? = nil
var historyValue: Int? = nil

let args = CommandLine.arguments
var i = 1
while i < args.count {
    switch args[i] {
    case "-c", "--config":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            notify(title: "Macrowhisper", message: "Missing value after \(args[i])")
            exit(1)
        }
        configPath = args[i + 1]
        i += 2
    case "-w", "--watch":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            notify(title: "Macrowhisper", message: "Missing value after \(args[i])")
            exit(1)
        }
        watchPath = args[i + 1]
        i += 2
    case "--no-updates":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            exit(1)
        }
        let value = args[i + 1].lowercased()
        disableUpdates = value == "true" || value == "yes" || value == "1"
        i += 2
    case "--no-noti":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            exit(1)
        }
        let value = args[i + 1].lowercased()
        disableNotifications = value == "true" || value == "yes" || value == "1"
        i += 2
    case "--no-esc":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            exit(1)
        }
        let value = args[i + 1].lowercased()
        noEscFlag = value == "true" || value == "yes" || value == "1"
        i += 2
    case "--sim-keypress":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            exit(1)
        }
        let value = args[i + 1].lowercased()
        simKeypressFlag = value == "true" || value == "yes" || value == "1"
        i += 2
    case "--action-delay":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            exit(1)
        }
        if let delayValue = Double(args[i + 1]) {
            // Store the delay value in our top-level variable
            actionDelayValue = delayValue
        } else {
            logError("Invalid delay value: \(args[i + 1]). Must be a number in seconds.")
            exit(1)
        }
        i += 2
    case "-h", "--help":
        printHelp()
        exit(0)
    case "--history":
        if i + 1 < args.count && !args[i + 1].starts(with: "--") {
            // A value was provided
            let historyArg = args[i + 1]
            if historyArg.lowercased() == "null" {
                historyValue = nil  // This will be handled specially
                i += 2
            } else if let historyVal = Int(historyArg) {
                historyValue = historyVal
                i += 2
            } else {
                logError("Invalid history value: \(historyArg). Must be a number (days) or 'null'.")
                exit(1)
            }
        } else {
            // No value provided, set to null
            historyValue = nil  // This will be handled specially
            i += 1
        }
    case "-v", "--version":
        print("Macrowhisper version \(APP_VERSION)")
        exit(0)
    case "--insert":
        if i + 1 < args.count && !args[i + 1].starts(with: "--") {
            // A value was provided
            insertName = args[i + 1]
            i += 2
        } else {
            // No value provided, set empty string to clear the active insert
            insertName = ""
            i += 1
        }
    case "--icon":
        if i + 1 < args.count && !args[i + 1].starts(with: "--") {
            // A value was provided
            iconValue = args[i + 1]
            i += 2
        } else {
            // No value provided, set empty string to clear the default icon
            iconValue = ""
            i += 1
        }
    case "--move-to":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            notify(title: "Macrowhisper", message: "Missing value after \(args[i])")
            exit(1)
        }
        moveToPath = args[i + 1]
        i += 2
    case "--list-inserts":
        if let response = socketCommunication.sendCommand(.listInserts) {
            print(response)
        } else {
            print("Failed to list inserts")
        }
        exit(0)
    case "--exec-insert":
        guard i + 1 < args.count else {
            logError("Missing insert name after \(args[i])")
            exit(1)
        }
        let insertName = args[i + 1]
        
        let arguments: [String: String] = [
            "name": insertName
        ]
        
        if let response = socketCommunication.sendCommand(.execInsert, arguments: arguments) {
            print(response)
        } else {
            print("Failed to execute insert")
        }
        exit(0)
    case "--add-insert":
        guard i + 1 < args.count else {
            logError("Missing insert name after \(args[i])")
            exit(1)
        }
        let insertName = args[i + 1]
        
        let arguments: [String: String] = [
            "name": insertName
        ]
        
        if let response = socketCommunication.sendCommand(.addInsert, arguments: arguments) {
            print(response)
        } else {
            print("Failed to add insert")
        }
        exit(0)

    case "--remove-insert":
        guard i + 1 < args.count else {
            logError("Missing insert name after \(args[i])")
            exit(1)
        }
        let insertName = args[i + 1]
        
        let arguments: [String: String] = [
            "name": insertName
        ]
        
        if let response = socketCommunication.sendCommand(.removeInsert, arguments: arguments) {
            print(response)
        } else {
            print("Failed to remove insert")
        }
        exit(0)
    case "--press-return":
        guard i + 1 < args.count else {
            logError("Missing value after \(args[i])")
            exit(1)
        }
        let value = args[i + 1].lowercased()
        pressReturnFlag = value == "true" || value == "yes" || value == "1"
        i += 2
    case "--add-shortcut":
        guard i + 1 < args.count else {
            logError("Missing name after \(args[i])")
            exit(1)
        }
        let shortcutName = args[i + 1]
        if let response = socketCommunication.sendCommand(.addShortcut, arguments: ["name": shortcutName]) {
            print(response)
        } else {
            print("Failed to add shortcut")
        }
        exit(0)
    case "--add-shell":
        guard i + 1 < args.count else {
            logError("Missing name after \(args[i])")
            exit(1)
        }
        let shellName = args[i + 1]
        if let response = socketCommunication.sendCommand(.addShell, arguments: ["name": shellName]) {
            print(response)
        } else {
            print("Failed to add shell script")
        }
        exit(0)
    default:
        if args[i].starts(with: "-") {
            logError("Unknown argument: \(args[i])")
            notify(title: "Macrowhisper", message: "Unknown argument: \(args[i])")
            exit(1)
        }
        // This case handles the scenario where `macrowhisper` is run with no arguments
        // We'll proceed with normal execution, which will either start the daemon or reload the config
        i += 1
    }
}

// Initialize configuration manager with the specified path
let configManager = ConfigurationManager(configPath: configPath)
globalConfigManager = configManager

// Now initialize HistoryManager with the valid configManager
let historyManager = HistoryManager(configManager: configManager)

// Apply any stored action delay value if it was set in command line arguments
if let delayValue = actionDelayValue {
    configManager.updateFromCommandLine(actionDelay: delayValue)
}

// Read values from config first
var config = configManager.config
disableUpdates = config.defaults.noUpdates
disableNotifications = config.defaults.noNoti

// Only update config with command line arguments if they were specified
configManager.updateFromCommandLine(
    watchPath: watchPath,
    watcher: watcherFlag,
    noUpdates: args.contains("--no-updates") ? (args.firstIndex(where: { $0 == "--no-updates" }).flatMap { idx in
        idx + 1 < args.count ? (args[idx + 1].lowercased() == "true") : true
    }) : nil,
    noNoti: args.contains("--no-noti") ? (args.firstIndex(where: { $0 == "--no-noti" }).flatMap { idx in
        idx + 1 < args.count ? (args[idx + 1].lowercased() == "true") : true
    }) : nil,
    activeInsert: insertName,
    icon: iconValue,
    moveTo: moveToPath,
    noEsc: noEscFlag,
    simKeypress: simKeypressFlag,
    history: args.contains("--history") ? historyValue : nil,
    pressReturn: pressReturnFlag
)

// Update global variables again after possible configuration changes
config = configManager.config // a new config could have been loaded
disableUpdates = config.defaults.noUpdates
disableNotifications = config.defaults.noNoti

// Get the final watch path after possible updates
let watchFolderPath = config.defaults.watch

// Check feature availability
let runWatcher = checkWatcherAvailability()

// ---
// At this point, continue with initializing server and/or watcher as usual...
if runWatcher { logInfo("Watcher: \(watchFolderPath)/recordings") }

// Server setup - only if jsonPath is provided
// MARK: - Server and Watcher Setup

// Initialize the recordings folder watcher if enabled
if runWatcher {
    // Validate the watch folder exists
    let recordingsPath = "\(watchFolderPath)/recordings"
    if !FileManager.default.fileExists(atPath: recordingsPath) {
        logError("Error: Recordings folder not found at \(recordingsPath)")
        notify(title: "Macrowhisper", message: "Error: Recordings folder not found at \(recordingsPath)")
        exit(1)
    }
    
    recordingsWatcher = RecordingsFolderWatcher(basePath: watchFolderPath, configManager: configManager, historyManager: historyManager)
    if recordingsWatcher == nil {
        logWarning("Warning: Failed to initialize recordings folder watcher")
        notify(title: "Macrowhisper", message: "Warning: Failed to initialize recordings folder watcher")
    } else {
        logInfo("Watching recordings folder at \(recordingsPath)")
        recordingsWatcher?.start()
    }
}

var configChangeWatcher: ConfigChangeWatcher?
if let path = configManager.configPath {
    configChangeWatcher = ConfigChangeWatcher(filePath: path) {
        logInfo("Configuration file change detected. Reloading...")
        configManager.loadConfig()
        // Notify other components if necessary
        // For example, if the watch path changes, the watcher needs to be restarted.
        if let onConfigChanged = configManager.onConfigChanged {
            // You might want to pass a reason for the change
            onConfigChanged("fileChanged")
        }
    }
    configChangeWatcher?.start()
}


// Initialize version checker
let versionChecker = VersionChecker()

registerForSleepWakeNotifications()
startSocketHealthMonitor()
// Log that we're ready
logInfo("Macrowhisper initialized and ready")

// Keep the main thread running
RunLoop.main.run() 