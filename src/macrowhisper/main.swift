#!/usr/bin/env swift

import Foundation
import Swifter
import Dispatch
import Darwin
import UserNotifications
import ApplicationServices
import Cocoa
import Carbon.HIToolbox

let APP_VERSION = "1.3.3"
private let UNIX_PATH_MAX = 104

// Dependency version check - Swifter 1.5.0+ required
// If you encounter socket issues, verify Swifter version compatibility

// Global variable suppressConsoleLogging is imported from Logger.swift

// MARK: - Global instances and Thread-Safe State Management

/// Thread-safe state manager for global application state
/// Prevents race conditions on shared state accessed from multiple threads
class GlobalStateManager {
    private let queue = DispatchQueue(label: "com.macrowhisper.globalstate", attributes: .concurrent)
    
    // Private backing storage for thread-safe properties
    private var _disableUpdates: Bool = false
    private var _disableNotifications: Bool = false
    private var _autoReturnEnabled: Bool = false
    private var _scheduledActionName: String? = nil
    private var _autoReturnTimeoutTimer: Timer? = nil
    private var _scheduledActionTimeoutTimer: Timer? = nil
    private var _actionDelayValue: Double? = nil
    private var _socketHealthTimer: Timer? = nil
    private var _lastDetectedFrontApp: NSRunningApplication? = nil
    
    // Thread-safe property accessors using concurrent queue with barriers for writes
    var disableUpdates: Bool {
        get { queue.sync { _disableUpdates } }
        set { queue.async(flags: .barrier) { self._disableUpdates = newValue } }
    }
    
    var disableNotifications: Bool {
        get { queue.sync { _disableNotifications } }
        set { queue.async(flags: .barrier) { self._disableNotifications = newValue } }
    }
    
    var autoReturnEnabled: Bool {
        get { queue.sync { _autoReturnEnabled } }
        set { queue.async(flags: .barrier) { self._autoReturnEnabled = newValue } }
    }
    
    var scheduledActionName: String? {
        get { queue.sync { _scheduledActionName } }
        set { queue.async(flags: .barrier) { self._scheduledActionName = newValue } }
    }
    
    var autoReturnTimeoutTimer: Timer? {
        get { queue.sync { _autoReturnTimeoutTimer } }
        set { 
            queue.async(flags: .barrier) { 
                // Invalidate previous timer before setting new one
                self._autoReturnTimeoutTimer?.invalidate()
                self._autoReturnTimeoutTimer = newValue 
            } 
        }
    }
    
    var scheduledActionTimeoutTimer: Timer? {
        get { queue.sync { _scheduledActionTimeoutTimer } }
        set { 
            queue.async(flags: .barrier) { 
                // Invalidate previous timer before setting new one
                self._scheduledActionTimeoutTimer?.invalidate()
                self._scheduledActionTimeoutTimer = newValue 
            } 
        }
    }
    
    var actionDelayValue: Double? {
        get { queue.sync { _actionDelayValue } }
        set { queue.async(flags: .barrier) { self._actionDelayValue = newValue } }
    }
    
    var socketHealthTimer: Timer? {
        get { queue.sync { _socketHealthTimer } }
        set { 
            queue.async(flags: .barrier) { 
                // Invalidate previous timer before setting new one
                self._socketHealthTimer?.invalidate()
                self._socketHealthTimer = newValue 
            } 
        }
    }
    
    var lastDetectedFrontApp: NSRunningApplication? {
        get { queue.sync { _lastDetectedFrontApp } }
        set { queue.async(flags: .barrier) { self._lastDetectedFrontApp = newValue } }
    }
    
    /// Thread-safe method to atomically check and update autoReturn state
    func cancelAutoReturnIfEnabled(reason: String) -> Bool {
        return queue.sync(flags: .barrier) {
            if _autoReturnEnabled {
                _autoReturnEnabled = false
                _autoReturnTimeoutTimer?.invalidate()
                _autoReturnTimeoutTimer = nil
                logInfo("Auto-return cancelled due to: \(reason)")
                return true
            }
            return false
        }
    }
    
    /// Thread-safe method to atomically check and update scheduled action state
    func cancelScheduledActionIfSet(reason: String) -> String? {
        return queue.sync(flags: .barrier) {
            if let actionName = _scheduledActionName {
                _scheduledActionName = nil
                _scheduledActionTimeoutTimer?.invalidate()
                _scheduledActionTimeoutTimer = nil
                logInfo("Scheduled action '\(actionName)' cancelled due to: \(reason)")
                return actionName
            }
            return nil
        }
    }
    
    /// Thread-safe method to invalidate all timers during cleanup
    func invalidateAllTimers() {
        queue.async(flags: .barrier) {
            self._autoReturnTimeoutTimer?.invalidate()
            self._autoReturnTimeoutTimer = nil
            self._scheduledActionTimeoutTimer?.invalidate()
            self._scheduledActionTimeoutTimer = nil
            self._socketHealthTimer?.invalidate()
            self._socketHealthTimer = nil
        }
    }
}

// Global thread-safe state manager instance
let globalState = GlobalStateManager()

// Legacy global variables (non-thread-critical, kept for compatibility)
var globalConfigManager: ConfigurationManager?
var historyManager: HistoryManager?
var configManager: ConfigurationManager!
var recordingsWatcher: RecordingsFolderWatcher?
var superwhisperFolderWatcher: SuperwhisperFolderWatcher?

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

// MARK: - AutoReturn Management (Thread-Safe)
/// Cancels auto-return if currently enabled using thread-safe atomic operations
func cancelAutoReturn(reason: String) {
    _ = globalState.cancelAutoReturnIfEnabled(reason: reason)
}

// MARK: - Scheduled Action Management (Thread-Safe)
/// Cancels scheduled action if currently set using thread-safe atomic operations
func cancelScheduledAction(reason: String) {
    _ = globalState.cancelScheduledActionIfSet(reason: reason)
}

// MARK: - Timeout Management (Thread-Safe)
/// Starts auto-return timeout with thread-safe timer management
func startAutoReturnTimeout() {
    // Get timeout value from configuration
    let timeoutValue = globalConfigManager?.config.defaults.scheduledActionTimeout ?? 5.0
    
    // If timeout is 0, don't start timeout (no timeout)
    if timeoutValue == 0 {
        logDebug("Auto-return timeout disabled (scheduledActionTimeout = 0)")
        return
    }
    
    // Check if there are any active recording sessions - if so, don't start timeout
    if let watcher = recordingsWatcher, !watcher.hasActiveRecordingSessions() {
        // Start configurable timeout on main thread with thread-safe timer management
        DispatchQueue.main.async {
            let timer = Timer.scheduledTimer(withTimeInterval: timeoutValue, repeats: false) { [weak globalState] _ in
                // Use thread-safe atomic operation to check and cancel auto-return
                _ = globalState?.cancelAutoReturnIfEnabled(reason: "timed out after \(timeoutValue) seconds - no valid recording session detected")
            }
            
            // Thread-safe assignment of timer (automatically invalidates any previous timer)
            globalState.autoReturnTimeoutTimer = timer
            
            // Ensure timer is added to the main run loop
            RunLoop.main.add(timer, forMode: .common)
            logDebug("Auto-return timeout timer started (\(timeoutValue) seconds)")
        }
    } else {
        logDebug("Auto-return timeout not started - recording session already in progress")
    }
}

/// Starts scheduled action timeout with thread-safe timer management
func startScheduledActionTimeout() {
    // Get timeout value from configuration
    let timeoutValue = globalConfigManager?.config.defaults.scheduledActionTimeout ?? 5.0
    
    // If timeout is 0, don't start timeout (no timeout)
    if timeoutValue == 0 {
        logDebug("Scheduled action timeout disabled (scheduledActionTimeout = 0)")
        return
    }
    
    // Check if there are any active recording sessions - if so, don't start timeout
    if let watcher = recordingsWatcher, !watcher.hasActiveRecordingSessions() {
        // Start configurable timeout on main thread with thread-safe timer management
        DispatchQueue.main.async {
            let timer = Timer.scheduledTimer(withTimeInterval: timeoutValue, repeats: false) { [weak globalState] _ in
                // Use thread-safe atomic operation to check and cancel scheduled action
                _ = globalState?.cancelScheduledActionIfSet(reason: "timed out after \(timeoutValue) seconds - no valid recording session detected")
            }
            
            // Thread-safe assignment of timer (automatically invalidates any previous timer)
            globalState.scheduledActionTimeoutTimer = timer
            
            // Ensure timer is added to the main run loop
            RunLoop.main.add(timer, forMode: .common)
            logDebug("Scheduled action timeout timer started (\(timeoutValue) seconds)")
        }
    } else {
        logDebug("Scheduled action timeout not started - recording session already in progress")
    }
}

/// Cancels auto-return timeout timer using thread-safe operations
func cancelAutoReturnTimeout() {
    if globalState.autoReturnTimeoutTimer != nil {
        logDebug("Cancelling auto-return timeout timer")
    }
    // Thread-safe timer cancellation (setting to nil automatically invalidates)
    globalState.autoReturnTimeoutTimer = nil
}

/// Cancels scheduled action timeout timer using thread-safe operations
func cancelScheduledActionTimeout() {
    if globalState.scheduledActionTimeoutTimer != nil {
        logDebug("Cancelling scheduled action timeout timer")
    }
    // Thread-safe timer cancellation (setting to nil automatically invalidates)
    globalState.scheduledActionTimeoutTimer = nil
}

// MARK: - Helper functions for logging and notifications
// Utility function to expand tilde in paths
func expandTilde(_ path: String) -> String {
    return (path as NSString).expandingTildeInPath
}

// SAFETY: Track the last notification time to prevent spam
private var lastMissingFolderNotification: Date = Date.distantPast
private let notificationCooldown: TimeInterval = 300.0 // 5 minutes

func checkWatcherAvailability() -> Bool {
    let watchPath = expandTilde(configManager.config.defaults.watch)
    let exists = FileManager.default.fileExists(atPath: watchPath)
    
    if !exists {
        logWarning("Superwhisper folder not found at: \(watchPath)")
        
        // SAFETY: Only notify if enough time has passed since last notification
        let now = Date()
        if now.timeIntervalSince(lastMissingFolderNotification) > notificationCooldown {
            notify(title: "Macrowhisper", message: "Superwhisper folder not found. Please check the path and restart service or reload config.")
            lastMissingFolderNotification = now
        }
        return false
    }
    
    return exists
}

func initializeWatcher(_ path: String, versionChecker: VersionChecker? = nil) {
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
        logError("History manager not initialized. Cannot initialize watcher.")
        return
    }
    
    recordingsWatcher = RecordingsFolderWatcher(basePath: expandedPath, configManager: configManager, historyManager: historyManager, socketCommunication: socketCommunication, versionChecker: versionChecker)
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
        print("Use 'macrowhisper --help' for info on usage.")
        return false
    }

    // Keep fd open for the lifetime of the process to hold the lock
    return true
}

func checkSocketHealth() -> Bool {
    // Ensure socket communication is properly initialized
    guard globalConfigManager != nil else {
        logDebug("Socket health check skipped - configuration manager not ready")
        return false
    }
    
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

/// Starts socket health monitoring with thread-safe timer management
func startSocketHealthMonitor() {
    let timer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { _ in
        logDebug("Performing periodic socket health check")
        if !checkSocketHealth() {
            logWarning("Socket appears to be unhealthy, attempting recovery")
            recoverSocket()
        }
    }
    timer.tolerance = 10.0
    
    // Thread-safe assignment of timer (automatically invalidates any previous timer)
    globalState.socketHealthTimer = timer
    RunLoop.main.add(timer, forMode: .common)
    logDebug("Socket health monitor started")
}

/// Stops socket health monitoring using thread-safe operations
func stopSocketHealthMonitor() {
    // Thread-safe timer cancellation (setting to nil automatically invalidates)
    globalState.socketHealthTimer = nil
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

if args.contains("--update-config") {
    let configPath = ConfigurationManager.getEffectiveConfigPath()
    
    // Check if config file exists
    if !FileManager.default.fileExists(atPath: configPath) {
        print("❌ Configuration file not found at: \(configPath)")
        print("Use --reveal-config to create a default configuration file first.")
        exit(1)
    }
    
    // Create a temporary configuration manager to perform the update
    let tempConfigManager = ConfigurationManager(configPath: configPath)
    
    if tempConfigManager.updateConfiguration() {
        print("✅ Configuration file updated successfully")
        print("Applied any new schema changes and fixed formatting issues")
        print("Your existing settings have been preserved")
        
        // Show the path that was updated
        print("Updated: \(configPath)")
    } else {
        print("❌ Failed to update configuration file")
        print("Please check that the file is valid JSON and try again")
        exit(1)
    }
    exit(0)
}



if args.contains("--schema-info") {
    let configPath = ConfigurationManager.getEffectiveConfigPath()
    let hasSchema = SchemaManager.hasSchemaReference(configPath: configPath)
    
    print("JSON Schema Information:")
    print("  Config file: \(configPath)")
    print("  Has schema reference: \(hasSchema ? "Yes" : "No")")
    print("")
    
    // Debug: Show the paths being checked
    print("Debug - Paths being checked:")
    SchemaManager.debugSchemaPaths()
    print("")
    
    if let localSchemaPath = SchemaManager.findSchemaPath() {
        print("  Local schema file: \(localSchemaPath)")
        print("  Status: ✅ Schema available for IDE integration")
        
        if let schemaReference = SchemaManager.getSchemaReference() {
            print("  Schema reference: \(schemaReference)")
        }
        
        if !hasSchema {
            print("")
            print("IDE validation will be enabled automatically when the service runs.")
        }
    } else {
        print("  Local schema file: ❌ Not found")
        print("  Status: Schema file missing - IDE integration not available")
        print("")
        print("To fix this:")
        print("  • If installed via Homebrew: brew reinstall macrowhisper")
        print("  • If installed manually: ensure macrowhisper-schema.json is alongside the binary")
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
    "--check-updates", "--exec-insert", "--auto-return", "--schedule-action", "--add-url", 
    "--add-shortcut", "--add-shell", "--add-as", "--add-insert", 
    "--remove-action", "--insert", 
    // New unified action commands
    "--list-actions", "--list-urls", "--list-shortcuts", "--list-shell", 
    "--list-as", "--exec-action", "--get-action", "--action"
]

// Check if any of the commands that require a daemon are present
let hasDaemonCommand = requireDaemonCommands.contains { args.contains($0) }

if hasDaemonCommand {
    // Suppress console logging for cleaner output unless verbose mode is enabled
    if !verboseLogging {
        suppressConsoleLogging = true
    }
    
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
    
    if args.contains("--schedule-action") {
        let scheduleActionIndex = args.firstIndex(where: { $0 == "--schedule-action" })
        var arguments: [String: String] = [:]
        if let index = scheduleActionIndex, index + 1 < args.count && !args[index + 1].starts(with: "--") {
            arguments["name"] = args[index + 1]
        } else {
            arguments["name"] = ""  // Empty name means cancel scheduled action
        }
        if let response = socketCommunication.sendCommand(.scheduleAction, arguments: arguments) {
            print(response)
        } else {
            print("Failed to schedule action.")
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
    
    if args.contains("--remove-action") {
        let removeActionIndex = args.firstIndex(where: { $0 == "--remove-action" })
        if let index = removeActionIndex, index + 1 < args.count {
            let actionName = args[index + 1]
            let arguments: [String: String] = ["name": actionName]
            if let response = socketCommunication.sendCommand(.removeAction, arguments: arguments) {
                print(response)
            } else {
                print("Failed to remove action.")
            }
        } else {
            print("Missing action name after --remove-action")
        }
        exit(0)
    }
    
    // New unified action commands
    if args.contains("--list-actions") {
        if let response = socketCommunication.sendCommand(.listActions) {
            print(response)
        } else {
            print("Failed to list actions.")
        }
        exit(0)
    }
    
    if args.contains("--list-urls") {
        if let response = socketCommunication.sendCommand(.listUrls) {
            print(response)
        } else {
            print("Failed to list URL actions.")
        }
        exit(0)
    }
    
    if args.contains("--list-shortcuts") {
        if let response = socketCommunication.sendCommand(.listShortcuts) {
            print(response)
        } else {
            print("Failed to list shortcut actions.")
        }
        exit(0)
    }
    
    if args.contains("--list-shell") {
        if let response = socketCommunication.sendCommand(.listShell) {
            print(response)
        } else {
            print("Failed to list shell script actions.")
        }
        exit(0)
    }
    
    if args.contains("--list-as") {
        if let response = socketCommunication.sendCommand(.listAppleScript) {
            print(response)
        } else {
            print("Failed to list AppleScript actions.")
        }
        exit(0)
    }
    
    if args.contains("--exec-action") {
        let execActionIndex = args.firstIndex(where: { $0 == "--exec-action" })
        if let index = execActionIndex, index + 1 < args.count {
            let actionName = args[index + 1]
            let arguments: [String: String] = ["name": actionName]
            if let response = socketCommunication.sendCommand(.execAction, arguments: arguments) {
                print(response)
            } else {
                print("Failed to execute action.")
            }
        } else {
            print("Missing action name after --exec-action")
        }
        exit(0)
    }
    
    if args.contains("--get-action") {
        let getActionIndex = args.firstIndex(where: { $0 == "--get-action" })
        var arguments: [String: String]? = nil
        if let index = getActionIndex, index + 1 < args.count, !args[index + 1].starts(with: "--") {
            arguments = ["name": args[index + 1]]
        }
        if let response = socketCommunication.sendCommand(.getAction, arguments: arguments) {
            print(response)
        } else {
            print("Failed to get action.")
        }
        exit(0)
    }

    
    // Handle configuration update commands (require daemon)
    var arguments: [String: String] = [:]
    
    if args.contains("--insert") {
        let insertIndex = args.firstIndex(where: { $0 == "--insert" })
        if let index = insertIndex, index + 1 < args.count && !args[index + 1].starts(with: "--") {
            arguments["activeInsert"] = args[index + 1]  // Backward compatibility
        } else {
            arguments["activeInsert"] = ""  // Backward compatibility
        }
    }
    
    if args.contains("--action") {
        let actionIndex = args.firstIndex(where: { $0 == "--action" })
        if let index = actionIndex, index + 1 < args.count && !args[index + 1].starts(with: "--") {
            arguments["activeAction"] = args[index + 1]
        } else {
            arguments["activeAction"] = ""
        }
    }
    
    // If we have config update arguments, send updateConfig
    if !arguments.isEmpty {
        if let response = socketCommunication.sendCommand(.updateConfig, arguments: arguments) {
            print(response)
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

// Validate arguments before starting daemon
// Only perform validation if there are arguments (allow no-args daemon startup)
if args.count > 1 {
    // Define all valid arguments
    let validDaemonArgs = ["--config", "--verbose"]
    let validQuickCommands = [
        "-h", "--help", "-v", "--version", "--reveal-config", "--set-config", 
        "--reset-config", "--get-config", "--update-config", "--schema-info",
        "--install-service", "--start-service", "--stop-service", "--restart-service", 
        "--uninstall-service", "--service-status", "--test-update-dialog", "--test-version", 
        "--test-description", "--version-state", "--version-clear"
    ]
    let allValidCommands = validDaemonArgs + validQuickCommands + requireDaemonCommands
    
    // Check for unrecognized arguments (skip the program name at index 0)
    var hasUnrecognizedArgs = false
    var unrecognizedArgs: [String] = []
    
    for i in 1..<args.count {
        let arg = args[i]
        
        // Skip arguments that are values for flags (like paths after --config)
        if i > 1 && (args[i-1] == "--config" || args[i-1] == "--set-config" || 
                     args[i-1] == "--exec-insert" || args[i-1] == "--get-insert" ||
                     args[i-1] == "--add-url" || args[i-1] == "--add-shortcut" ||
                     args[i-1] == "--add-shell" || args[i-1] == "--add-as" ||
                     args[i-1] == "--add-insert" || args[i-1] == "--remove-action" || 
                     args[i-1] == "--insert" || args[i-1] == "--auto-return" || 
                     args[i-1] == "--schedule-action" || args[i-1] == "--test-version" || args[i-1] == "--test-description" || 
                     args[i-1] == "--exec-action" || args[i-1] == "--get-action" || 
                     args[i-1] == "--action") {
            continue
        }
        
        // Check if this argument is recognized
        if !allValidCommands.contains(arg) {
            hasUnrecognizedArgs = true
            unrecognizedArgs.append(arg)
        }
    }
    
    // If there are unrecognized arguments, show error and exit
    if hasUnrecognizedArgs {
        print("Error: Unrecognized command(s): \(unrecognizedArgs.joined(separator: ", "))")
        print("Use 'macrowhisper --help' to see available commands.")
        exit(1)
    }
}

if !acquireSingleInstanceLock(lockFilePath: lockPath) {
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

    Automation helper for Superwhisper.

    DAEMON COMMANDS (start/manage the app - for debugging. Runs without service):
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
      --update-config               Update configuration file with new schema changes
                                    (preserves your settings, fixes formatting issues)
      --reveal-config               Open the configuration file in Finder
                                    (creates default config if none exists)
      
    IDE INTEGRATION (automatically handled):
      --schema-info                 Show JSON schema information and status

    SERVICE MANAGEMENT (allows users to run in bg - work without running instance):
      --install-service             Install macrowhisper as a system service
      --start-service               Start the service (installs if needed, stops existing daemon)
      --stop-service                Stop the service and any running daemon instances
      --restart-service             Restart the service
      --uninstall-service           Uninstall the service (stops it first)
      --service-status              Show detailed service status information

    RUNTIME COMMANDS (require running instance):
      -s, --status                  Get the status of the running instance

    ACTION MANAGEMENT (require running instance):
      --action [<name>]             Sets active action (if name provided) or clears it (if no name)
      --exec-action <name>          Execute any action using the last valid result
      --get-icon                    Get the icon of the active action
      --get-action [<name>]         Get name of active action (if run without <name>)
                                    If a name is provided, returns the action content
      --list-actions                List all configured actions (all types)
      --list-inserts                List all configured insert actions  
      --list-urls                   List all configured URL actions
      --list-shortcuts              List all configured shortcut actions
      --list-shell                  List all configured shell script actions
      --list-as                     List all configured AppleScript actions
      --add-insert <name>           Add an insert action
      --add-url <name>              Add a URL action
      --add-shortcut <name>         Add a Shortcuts action
      --add-shell <name>            Add a shell script action
      --add-as <name>               Add an AppleScript action
      --remove-action <name>        Remove any action by name (works for all action types)
      --auto-return <true/false>    Paste result and simulate return for one interaction
                                    (takes priority over active action and triggers)
      --schedule-action [<name>]    Schedule any action for next (or active) recording session
                                    (takes priority over active action and triggers)
                                    (no name = cancel scheduled action)

    OTHER (require running daemon):
      --check-updates               Force check for updates
      --version-clear               Clears all UserDefaults related
                                    to version checks. Only to be used for debugging
      --version-state               Checks the state of update checks
                                    (useful for debugging)
    
    DEPRECATED COMMANDS (temporarily maintained for backward compatibility):
      --exec-insert <name>          Use --exec-action instead
      --get-insert [<name>]         Use --get-action instead  
      --insert [<name>]             Use --action instead

    Examples:
      macrowhisper --action pasteResult
        # Sets the active action to 'pasteResult' (works for any action type)

      macrowhisper --get-action
        # Gets the name of the current active action

      macrowhisper --get-action pasteResult
        # Gets the processed action content for 'pasteResult'
        
      macrowhisper --exec-action myURLAction
        # Executes 'myURLAction' (works for any action type)
        
      macrowhisper --schedule-action myURLAction
        # Schedules 'myURLAction' for the next recording session
        
      macrowhisper --schedule-action
        # Cancels any scheduled action
        
      macrowhisper --list-actions
        # Lists all actions with their types (INSERT: name, URL: name, etc.)

      macrowhisper --reveal-config
        # Opens the configuration file in Finder (creates it if missing)

      macrowhisper --set-config ~/my-configs/
        # Sets ~/my-configs/macrowhisper.json as the default config path

      macrowhisper --start-service
        # Install and start macrowhisper as a background service

    Note: Most commands require a running daemon. Use --start-service for automatic startup.
    Once service has been installed, it will run on the background on startup.
    
    In-depth documentation and examples at:
    https://by.afadingthought.com/macrowhisper
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

// Automatically update configuration file on startup to apply any schema changes
// Respect user preference defaults.autoUpdateConfig (defaults to true)
let shouldAutoUpdateConfig = configManager.config.defaults.autoUpdateConfig
if shouldAutoUpdateConfig {
    logDebug("Performing automatic configuration update on startup...")
    if configManager.updateConfiguration() {
        logInfo("Configuration file automatically updated with latest schema and formatting")
    } else {
        logDebug("Configuration file update skipped - no changes needed or file had errors")
    }
} else {
    logDebug("Startup auto configuration update disabled by defaults.autoUpdateConfig = false")
}

historyManager = HistoryManager(configManager: configManager)

// Read values from config first and update thread-safe state
let config = configManager.config
globalState.disableUpdates = config.defaults.noUpdates
globalState.disableNotifications = config.defaults.noNoti

// Request accessibility permissions upfront for better user experience
// This ensures users grant permissions at startup rather than being surprised later
requestAccessibilityPermissionOnStartup()

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

// Add a deinit to stop the server and watchers when the app terminates
defer {
    socketCommunication.stopServer()
    recordingsWatcher?.stop()
    superwhisperFolderWatcher?.stop()
}

// Initialize the recordings folder watcher if enabled
if runWatcher {
    // Validate the watch folder exists
    let recordingsPath = "\(watchFolderPath)/recordings"
    if !FileManager.default.fileExists(atPath: recordingsPath) {
        logWarning("Recordings folder not found at \(recordingsPath). Starting folder watcher to wait for it to appear.")
        
        // Notify user that the folder is missing (with cooldown to prevent spam)
        let now = Date()
        if now.timeIntervalSince(lastMissingFolderNotification) > notificationCooldown {
            notify(title: "Macrowhisper", message: "Recordings folder not found. Waiting for Superwhisper setup.")
            lastMissingFolderNotification = now
        }
        
        // Start watching for the recordings folder to appear instead of exiting
        superwhisperFolderWatcher = SuperwhisperFolderWatcher(parentPath: watchFolderPath) {
            logInfo("Recordings folder appeared! Initializing recordings watcher...")
            
            // Now that the recordings folder exists, initialize the recordings watcher
            guard let historyManager = historyManager else {
                logError("History manager not initialized during late initialization.")
                return
            }
            
            recordingsWatcher = RecordingsFolderWatcher(basePath: watchFolderPath, configManager: configManager, historyManager: historyManager, socketCommunication: socketCommunication, versionChecker: versionChecker)
            if recordingsWatcher == nil {
                logWarning("Failed to initialize recordings folder watcher after folder appeared")
                notify(title: "Macrowhisper", message: "Failed to initialize recordings watcher")
            } else {
                logDebug("Successfully started watching recordings folder at \(recordingsPath)")
                recordingsWatcher?.start()
                // No notification here - folder appearing is the expected good outcome
            }
        }
        superwhisperFolderWatcher?.start()
    } else {
        // Recordings folder exists, initialize normally
        guard let historyManager = historyManager else {
            logError("History manager not initialized. Exiting.")
            exit(1)
        }
        
        recordingsWatcher = RecordingsFolderWatcher(basePath: watchFolderPath, configManager: configManager, historyManager: historyManager, socketCommunication: socketCommunication, versionChecker: versionChecker)
        if recordingsWatcher == nil {
            logWarning("Warning: Failed to initialize recordings folder watcher")
            notify(title: "Macrowhisper", message: "Warning: Failed to initialize recordings folder watcher")
        } else {
            logDebug("Watching recordings folder at \(recordingsPath)")
            recordingsWatcher?.start()
        }
    }
}

// Set up configuration change handler for live updates
configManager.onConfigChanged = { reason in
    // Store previous values to detect changes using thread-safe access
    let previousDisableUpdates = globalState.disableUpdates
    
    // Update global state variables using thread-safe operations
    globalState.disableUpdates = configManager.config.defaults.noUpdates
    globalState.disableNotifications = configManager.config.defaults.noNoti
    
    // Apply clipboard buffer changes live to the global ClipboardMonitor
    if let watcher = recordingsWatcher {
        let bufferSeconds = configManager.config.defaults.clipboardBuffer
        watcher.getClipboardMonitor().updateClipboardBuffer(seconds: bufferSeconds)
    }
    
    // If updates were disabled but are now enabled, reset the version checker state and perform immediate check
    if previousDisableUpdates == true && globalState.disableUpdates == false {
        versionChecker.resetLastCheckDate()
        // Perform an immediate version check when user enables updates
        // This ensures they get update notifications right away rather than waiting for the next recording
        versionChecker.checkForUpdates()
        logDebug("Performed immediate version check after enabling updates in configuration")
    }
    
    // Handle watch path changes and validation
    let currentWatchPath = expandTilde(configManager.config.defaults.watch)
    let recordingsPath = "\(currentWatchPath)/recordings"
    let recordingsFolderExists = FileManager.default.fileExists(atPath: recordingsPath)
    
    // Only reinitialize watcher if the watch path actually changed
    if lastWatchPath != currentWatchPath {
        logDebug("Watch path changed from '\(lastWatchPath ?? "<none>")' to '\(currentWatchPath)'. Handling watcher reinitialization.")
        // Stop any existing watchers
        if recordingsWatcher != nil {
            recordingsWatcher?.stop()
            recordingsWatcher = nil
            logDebug("Stopped previous recordings watcher for path: \(lastWatchPath ?? "<none>")")
        }
        if superwhisperFolderWatcher != nil {
            superwhisperFolderWatcher?.stop()
            superwhisperFolderWatcher = nil
            logDebug("Stopped previous superwhisper folder watcher for path: \(lastWatchPath ?? "<none>")")
        }
        // Update lastWatchPath
        lastWatchPath = currentWatchPath
        // If the new path is valid, start a new watcher
        if recordingsFolderExists {
            guard let historyManager = historyManager else {
                logError("History manager not initialized. Exiting.")
                return
            }
            recordingsWatcher = RecordingsFolderWatcher(basePath: currentWatchPath, configManager: configManager, historyManager: historyManager, socketCommunication: socketCommunication, versionChecker: versionChecker)
            if recordingsWatcher == nil {
                logWarning("Failed to initialize recordings folder watcher for new path: \(currentWatchPath)")
                notify(title: "Macrowhisper", message: "Failed to initialize watcher for new path.")
            } else {
                logDebug("Watching recordings folder at \(recordingsPath)")
                recordingsWatcher?.start()
            }
        } else {
            // If the new path is invalid, start folder watcher and wait for recordings folder to appear
            logWarning("Watch path invalid: Recordings folder not found at \(recordingsPath). Starting folder watcher.")
            let now = Date()
            if now.timeIntervalSince(lastMissingFolderNotification) > notificationCooldown {
                notify(title: "Macrowhisper", message: "Recordings folder not found at new path. Waiting for it to appear.")
                lastMissingFolderNotification = now
            }
            
            // Start watching for the recordings folder to appear
            superwhisperFolderWatcher = SuperwhisperFolderWatcher(parentPath: currentWatchPath) {
                logInfo("Recordings folder appeared at new path! Initializing recordings watcher...")
                
                guard let historyManager = historyManager else {
                    logError("History manager not initialized during late initialization.")
                    return
                }
                
                recordingsWatcher = RecordingsFolderWatcher(basePath: currentWatchPath, configManager: configManager, historyManager: historyManager, socketCommunication: socketCommunication, versionChecker: versionChecker)
                if recordingsWatcher == nil {
                    logWarning("Failed to initialize recordings folder watcher after folder appeared at new path")
                    notify(title: "Macrowhisper", message: "Failed to initialize recordings watcher for new path")
                } else {
                    logDebug("Successfully started watching recordings folder at \(recordingsPath)")
                    recordingsWatcher?.start()
                    // No notification here - folder appearing is the expected good outcome
                }
            }
            superwhisperFolderWatcher?.start()
        }
    } else if reason == "watchPathChanged" || recordingsWatcher == nil {
        // If the watcher is nil (e.g., app just started or was stopped due to invalid path), try to start it if the path is valid
        if recordingsWatcher == nil && recordingsFolderExists {
            guard let historyManager = historyManager else {
                logError("History manager not initialized. Exiting.")
                return
            }
            recordingsWatcher = RecordingsFolderWatcher(basePath: currentWatchPath, configManager: configManager, historyManager: historyManager, socketCommunication: socketCommunication, versionChecker: versionChecker)
            if recordingsWatcher == nil {
                logWarning("Failed to initialize recordings folder watcher for path: \(currentWatchPath)")
                notify(title: "Macrowhisper", message: "Failed to initialize watcher for path.")
            } else {
                logDebug("Watching recordings folder at \(recordingsPath)")
                recordingsWatcher?.start()
            }
        } else if !recordingsFolderExists && superwhisperFolderWatcher == nil {
            // If the recordings folder doesn't exist and we don't have a folder watcher yet, start one
            logWarning("Recordings folder still not found at \(recordingsPath). Starting folder watcher.")
            let now = Date()
            if now.timeIntervalSince(lastMissingFolderNotification) > notificationCooldown {
                notify(title: "Macrowhisper", message: "Recordings folder not found. Waiting for it to appear.")
                lastMissingFolderNotification = now
            }
            
            superwhisperFolderWatcher = SuperwhisperFolderWatcher(parentPath: currentWatchPath) {
                logInfo("Recordings folder appeared! Initializing recordings watcher...")
                
                guard let historyManager = historyManager else {
                    logError("History manager not initialized during late initialization.")
                    return
                }
                
                recordingsWatcher = RecordingsFolderWatcher(basePath: currentWatchPath, configManager: configManager, historyManager: historyManager, socketCommunication: socketCommunication, versionChecker: versionChecker)
                if recordingsWatcher == nil {
                    logWarning("Failed to initialize recordings folder watcher after folder appeared")
                    notify(title: "Macrowhisper", message: "Failed to initialize recordings watcher")
                } else {
                    logDebug("Successfully started watching recordings folder at \(recordingsPath)")
                    recordingsWatcher?.start()
                    // No notification here - folder appearing is the expected good outcome
                }
            }
            superwhisperFolderWatcher?.start()
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
