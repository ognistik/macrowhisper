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

let socketCommunication = SocketCommunication(socketPath: socketPath, logger: logger)

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
        let args = CommandLine.arguments

        // Handle help command specifically
        if args.contains("-h") || args.contains("--help") {
            // Print help directly without trying to communicate with the running instance
            printHelp()
            exit(0)
        }

        // Handle version command specifically
        if args.contains("-v") || args.contains("--version") {
            if let response = socketCommunication.sendCommand(.version) {
                print(response)
            } else {
                print("macrowhisper version \(APP_VERSION)")
            }
            exit(0)
        }

        // Check for status command
        if args.contains("-s") || args.contains("--status") {
            if let response = socketCommunication.sendCommand(.status) {
                print(response)
            } else {
                print("Failed to get status")
            }
            exit(0)
        }

        if args.contains("--get-icon") {
            if let response = socketCommunication.sendCommand(.getIcon) {
                print(response)
            } else {
                print("Failed to get icon.")
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
                    print("Failed to execute insert")
                }
            } else {
                print("Missing insert name after --exec-insert")
            }
            exit(0)
        }

        if args.contains("--get-insert") {
            let getInsertIndex = args.firstIndex(where: { $0 == "--get-insert" })
            var arguments: [String: String]? = nil
            if let index = getInsertIndex, index + 1 < args.count, !args[index + 1].starts(with: "--") {
                // User provided a name after --get-insert
                arguments = ["name": args[index + 1]]
            }
            let socketCommunication = SocketCommunication(socketPath: socketPath, logger: logger)
            if let response = socketCommunication.sendCommand(.getInsert, arguments: arguments) {
                print(response)
            } else {
                print("Failed to get insert or macrowhisper is not running.")
            }
            exit(0)
        }

        if args.contains("--list-inserts") {
            if let response = socketCommunication.sendCommand(.listInserts) {
                print(response)
            } else {
                print("Failed to list inserts")
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
                print("Failed to set auto-return")
            }
            exit(0)
        }

        if args.contains("--add-url") {
            let addUrlIndex = args.firstIndex(where: { $0 == "--add-url" })
            if let index = addUrlIndex, index + 1 < args.count {
                let urlName = args[index + 1]
                let arguments: [String: String] = ["name": urlName]

                if let response = socketCommunication.sendCommand(.addUrl, arguments: arguments) {
                    print(response)
                } else {
                    print("Failed to add URL action")
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
                    print("Failed to add shortcut action")
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
                    print("Failed to add shell script action")
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
                    print("Failed to add AppleScript action")
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
                    print("Failed to add insert")
                }
            } else {
                print("Missing name after --add-insert")
            }
            exit(0)
        }

        // Handle reveal config command specifically
        if args.contains("--reveal-config") {
            // Determine the config file path (same logic as ConfigurationManager)
            let configArgIndex = args.firstIndex(where: { $0 == "-c" || $0 == "--config" })
            var configPath: String
            
            if let index = configArgIndex, index + 1 < args.count {
                configPath = args[index + 1]
            } else {
                configPath = ("~/.config/macrowhisper/macrowhisper.json" as NSString).expandingTildeInPath
            }
            
            // Expand tilde in path
            let expandedPath = (configPath as NSString).expandingTildeInPath
            
            // Check if config file exists
            if FileManager.default.fileExists(atPath: expandedPath) {
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
            } else {
                print("Configuration file not found at: \(expandedPath)")
                print("You can create it by running macrowhisper once, or manually create the directory:")
                print("mkdir -p ~/.config/macrowhisper")
                exit(1)
            }
        }

        // For reload configuration or no arguments, use socket communication
        if args.count == 1 ||
           args.contains("-w") || args.contains("--watch") ||
           args.contains("--no-updates") || args.contains("--no-noti") ||
           args.contains("--insert") || args.contains("--icon") ||
           args.contains("--move-to") || args.contains("--no-esc") ||
           args.contains("--sim-keypress") || args.contains("--action-delay") ||
           args.contains("--history") || args.contains("--press-return") {

            // Create command arguments if there are any
            var arguments: [String: String] = [:]

            // Extract arguments from command line
            if let watchIndex = args.firstIndex(where: { $0 == "-w" || $0 == "--watch" }),
               watchIndex + 1 < args.count {
                arguments["watch"] = args[watchIndex + 1]
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

            // If there are arguments, send updateConfig, otherwise send reloadConfig
            let command = arguments.isEmpty ? SocketCommunication.Command.reloadConfig : SocketCommunication.Command.updateConfig

            // Send the command to the running instance
            if let response = socketCommunication.sendCommand(command, arguments: arguments.isEmpty ? nil : arguments) {
                print("Response from running instance: \(response)")
            } else {
                print("Failed to communicate with running instance.")
            }

            exit(0)
        }

        // For any unrecognized command, provide helpful feedback
        print("Error: Unrecognized command or invalid arguments.")
        print("Use --help for available options.")
        exit(1)
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
    
    // Recreate socket
    let socketPath = "/tmp/macrowhisper-\(uid).sock"
    let socketCommunication = SocketCommunication(socketPath: socketPath, logger: logger)
    
    // Safely unwrap the globalConfigManager
    if let configManager = globalConfigManager {
        socketCommunication.startServer(configManager: configManager)
        logDebug("Socket server restarted after recovery attempt")
    } else {
        logError("Failed to restart socket server: globalConfigManager is nil")
        
        // Try to create a new configuration manager as fallback
        let fallbackConfigManager = ConfigurationManager(configPath: nil)
        socketCommunication.startServer(configManager: fallbackConfigManager)
        globalConfigManager = fallbackConfigManager
        logDebug("Socket server restarted with fallback configuration manager")
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

if args.contains("-h") || args.contains("--help") {
    printHelp()
    exit(0)
}
if args.contains("-v") || args.contains("--version") {
    print("macrowhisper version \(APP_VERSION)")
    exit(0)
}
if args.contains("-s") || args.contains("--status") {
    let socketCommunication = SocketCommunication(socketPath: socketPath, logger: logger)
    if let response = socketCommunication.sendCommand(.status) {
        print(response)
    } else {
        print("macrowhisper is not running.")
    }
    exit(0)
}
if args.contains("--get-icon") {
    let socketCommunication = SocketCommunication(socketPath: socketPath, logger: logger)
    if let response = socketCommunication.sendCommand(.getIcon) {
        print(response)
    } else {
        print("Failed to get icon or macrowhisper is not running.")
    }
    exit(0)
}
if args.contains("--get-insert") {
    let getInsertIndex = args.firstIndex(where: { $0 == "--get-insert" })
    var arguments: [String: String]? = nil
    if let index = getInsertIndex, index + 1 < args.count, !args[index + 1].starts(with: "--") {
        // User provided a name after --get-insert
        arguments = ["name": args[index + 1]]
    }
    let socketCommunication = SocketCommunication(socketPath: socketPath, logger: logger)
    if let response = socketCommunication.sendCommand(.getInsert, arguments: arguments) {
        print(response)
    } else {
        print("Failed to get insert or macrowhisper is not running.")
    }
    exit(0)
}
if args.contains("--list-inserts") {
    let socketCommunication = SocketCommunication(socketPath: socketPath, logger: logger)
    if let response = socketCommunication.sendCommand(.listInserts) {
        print(response)
    } else {
        print("Failed to list inserts or macrowhisper is not running.")
    }
    exit(0)
}
if args.contains("--exec-insert") {
    let execInsertIndex = args.firstIndex(where: { $0 == "--exec-insert" })
    if let index = execInsertIndex, index + 1 < args.count {
        let insertName = args[index + 1]
        let arguments: [String: String] = ["name": insertName]
        let socketCommunication = SocketCommunication(socketPath: socketPath, logger: logger)
        if let response = socketCommunication.sendCommand(.execInsert, arguments: arguments) {
            print(response)
        } else {
            print("Failed to execute insert or macrowhisper is not running.")
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
    let socketCommunication = SocketCommunication(socketPath: socketPath, logger: logger)
    if let response = socketCommunication.sendCommand(.autoReturn, arguments: arguments) {
        print(response)
    } else {
        print("Failed to set auto-return or macrowhisper is not running.")
    }
    exit(0)
}
if args.contains("--quit") || args.contains("--stop") {
    let socketCommunication = SocketCommunication(socketPath: socketPath, logger: logger)
    if let response = socketCommunication.sendCommand(.quit) {
        print(response)
    } else {
        print("No running instance to quit.")
    }
    exit(0)
}
// ---- END QUICK COMMANDS ----

if !acquireSingleInstanceLock(lockFilePath: lockPath) {
    logError("Failed to acquire single instance lock. Exiting.")
    exit(1)
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
          --return-delay <seconds>  Set delay in seconds before return key press (for --auto-return and pressReturn)
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
      --verbose                     Enable verbose logging (shows debug messages in console)
      --reveal-config               Reveal the configuration file in Finder
      --quit, --stop                Quit the running macrowhisper instance

    INSERTS COMMANDS:
      --list-inserts                List all configured inserts
      --add-insert <name>           Add or update an insert
      --remove-insert <name>        Remove an insert
      --exec-insert <name>          Execute an insert action using the last valid result
      --auto-return true/false      Insert result and simulate return for one interaction
      --get-icon                    Get the icon of the active insert
      --get-insert [<name>]         Get name of active insert (if run without <name>)
                                    If a name is provided, returns the action content

    OTHER ACTION COMMANDS:
      --add-url <name>              Add or update a URL action
      --add-shortcut <name>         Add or update a Shortcuts action
      --add-shell <name>            Add or update a shell script action
      --add-as <name>               Add or update an AppleScript action

    Examples:
      macrowhisper
        # Uses defaults from config file/Reloads config file

      macrowhisper --config ~/custom-config.json

      macrowhisper --watch ~/otherfolder/superwhisper --no-updates true

      macrowhisper --insert pasteResult
        # Sets the active insert to pasteResult

      macrowhisper --get-insert
        # Prints the name of the current active insert

      macrowhisper --get-insert pasteResult
        # Prints the processed action content for the 'pasteResult' insert using the last valid result

      macrowhisper --reveal-config
        # Opens the configuration file in Finder

      macrowhisper --quit
        # Quits the running macrowhisper instance
    """)
}

// Argument parsing
var configPath: String? = nil
var verboseLogging = false
var i = 1
while i < args.count {
    switch args[i] {
    case "-c", "--config":
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

registerForSleepWakeNotifications()
startSocketHealthMonitor()
// Log that we're ready
logInfo("Macrowhisper initialized and ready")

// Keep the main thread running
RunLoop.main.run()
