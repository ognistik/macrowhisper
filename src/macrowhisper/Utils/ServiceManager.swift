import Foundation
import Darwin

/// Manages macOS launchd service operations for macrowhisper
class ServiceManager {
    private let serviceName = "com.aft.macrowhisper"
    private let serviceFileName = "com.aft.macrowhisper.plist"
    private var launchAgentsPath: String {
        return ("~/Library/LaunchAgents" as NSString).expandingTildeInPath
    }
    private var servicePlistPath: String {
        return "\(launchAgentsPath)/\(serviceFileName)"
    }
    
    init() {
        // No logger parameter needed - uses global logging functions
    }
    
    /// Check if the service is installed (plist file exists)
    func isServiceInstalled() -> Bool {
        return FileManager.default.fileExists(atPath: servicePlistPath)
    }
    
    /// Check if the service is currently running
    func isServiceRunning() -> Bool {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["list", serviceName]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            logError("Failed to check service status: \(error)")
            return false
        }
    }
    
    /// Get the current binary path (always return absolute path)
    private func getCurrentBinaryPath() -> String {
        let originalPath = CommandLine.arguments[0]
        
        // Strategy 1: If it's already an absolute path, clean it up and return
        if originalPath.hasPrefix("/") {
            return URL(fileURLWithPath: originalPath).standardized.path
        }
        
        // Strategy 2: Try to find the binary in PATH (for Homebrew and other installations)
        if let pathFromWhich = findBinaryInPath(originalPath) {
            return pathFromWhich
        }
        
        // Strategy 3: Resolve relative path against current directory
        let currentDir = FileManager.default.currentDirectoryPath
        let resolvedPath = URL(fileURLWithPath: currentDir)
            .appendingPathComponent(originalPath)
            .standardized
            .path
        
        // Verify the resolved path actually exists
        if FileManager.default.fileExists(atPath: resolvedPath) {
            return resolvedPath
        }
        
        // Strategy 4: Try to resolve symlinks if it exists
        if let realPath = try? FileManager.default.destinationOfSymbolicLink(atPath: resolvedPath) {
            return URL(fileURLWithPath: realPath).standardized.path
        }
        
        // Fallback: return the resolved path even if we can't verify it exists
        return resolvedPath
    }
    
    /// Find binary in PATH environment variable (useful for Homebrew installations)
    private func findBinaryInPath(_ binaryName: String) -> String? {
        // Get the binary name without any path components
        let executableName = URL(fileURLWithPath: binaryName).lastPathComponent
        
        // Get PATH environment variable
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else {
            return nil
        }
        
        // Search each directory in PATH
        for pathDir in pathEnv.components(separatedBy: ":") {
            let candidatePath = URL(fileURLWithPath: pathDir)
                .appendingPathComponent(executableName)
                .standardized
                .path
            
            // Check if file exists and is executable
            if FileManager.default.fileExists(atPath: candidatePath) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidatePath, isDirectory: &isDirectory),
                   !isDirectory.boolValue,
                   FileManager.default.isExecutableFile(atPath: candidatePath) {
                    return candidatePath
                }
            }
        }
        
        return nil
    }
    
    /// Get the effective config path for the service
    private func getEffectiveConfigPath() -> String? {
        return ConfigurationManager.getSavedConfigPath() ?? ConfigurationManager.getEffectiveConfigPath()
    }
    
    /// Create the launchd plist content
    private func createPlistContent() -> String {
        let binaryPath = getCurrentBinaryPath()
        let logPath = ("~/Library/Logs/Macrowhisper/service.log" as NSString).expandingTildeInPath
        
        var arguments = [binaryPath]
        
        // Add config path if one is saved
        if let configPath = ConfigurationManager.getSavedConfigPath() {
            arguments.append("--config")
            arguments.append(configPath)
        }
        
        // Convert arguments array to plist format
        let argumentsXML = arguments.map { "\t\t<string>\($0)</string>" }.joined(separator: "\n")
        
        return """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>\(serviceName)</string>
    <key>ProgramArguments</key>
    <array>
\(argumentsXML)
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>LANG</key>
        <string>en_US.UTF-8</string>
        <key>LC_ALL</key>
        <string>en_US.UTF-8</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>\(logPath)</string>
    <key>StandardErrorPath</key>
    <string>\(logPath)</string>
    <key>WorkingDirectory</key>
    <string>\((binaryPath as NSString).deletingLastPathComponent)</string>
</dict>
</plist>
"""
    }
    
    /// Install the service
    func installService() -> (success: Bool, message: String) {
        // Ensure LaunchAgents directory exists
        do {
            if !FileManager.default.fileExists(atPath: launchAgentsPath) {
                try FileManager.default.createDirectory(atPath: launchAgentsPath, withIntermediateDirectories: true, attributes: nil)
            }
        } catch {
            let message = "Failed to create LaunchAgents directory: \(error)"
            logError(message)
            return (false, message)
        }
        
        // Ensure log directory exists
        let logDir = ("~/Library/Logs/Macrowhisper" as NSString).expandingTildeInPath
        do {
            if !FileManager.default.fileExists(atPath: logDir) {
                try FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true, attributes: nil)
            }
        } catch {
            let message = "Failed to create log directory: \(error)"
            logError(message)
            return (false, message)
        }
        
        // Check if service already exists and validate binary path
        if isServiceInstalled() {
            if let (needsUpdate, currentPath) = checkServiceNeedsUpdate() {
                if needsUpdate {
                    let currentBinaryPath = getCurrentBinaryPath()
                    logInfo("Service binary path changed from '\(currentPath)' to '\(currentBinaryPath)'. Updating service.")
                    
                    // Stop the service first if it's running
                    if isServiceRunning() {
                        let stopResult = stopService()
                        if !stopResult.success {
                            return (false, "Failed to stop existing service for update: \(stopResult.message)")
                        }
                    }
                    
                    // Update the plist file
                    let plistContent = createPlistContent()
                    do {
                        try plistContent.write(toFile: servicePlistPath, atomically: true, encoding: .utf8)
                        logInfo("Service plist updated successfully")
                        return (true, "Service updated successfully (binary path changed)")
                    } catch {
                        let message = "Failed to update service plist: \(error)"
                        logError(message)
                        return (false, message)
                    }
                } else {
                    return (true, "Service already installed and up to date")
                }
            }
        }
        
        // Create and write the plist file
        let plistContent = createPlistContent()
        do {
            try plistContent.write(toFile: servicePlistPath, atomically: true, encoding: .utf8)
            logInfo("Service installed successfully at \(servicePlistPath)")
            return (true, "Service installed successfully")
        } catch {
            let message = "Failed to write service plist: \(error)"
            logError(message)
            return (false, message)
        }
    }
    
    /// Check if the service needs to be updated (binary path or environment changed)
    private func checkServiceNeedsUpdate() -> (needsUpdate: Bool, currentPath: String)? {
        guard let plistData = try? Data(contentsOf: URL(fileURLWithPath: servicePlistPath)),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let programArguments = plist["ProgramArguments"] as? [String],
              let currentBinaryPath = programArguments.first else {
            logWarning("Could not read existing service plist")
            return nil
        }

        let newBinaryPath = getCurrentBinaryPath()
        let binaryPathChanged = currentBinaryPath != newBinaryPath

        // Check if EnvironmentVariables section exists with proper UTF-8 locale
        var envVarsNeedUpdate = false
        if let envVars = plist["EnvironmentVariables"] as? [String: String],
           let lang = envVars["LANG"],
           let lcAll = envVars["LC_ALL"],
           lang.contains("UTF-8") && lcAll.contains("UTF-8") {
            // Environment variables are properly set
            envVarsNeedUpdate = false
        } else {
            // Missing or incorrect environment variables
            envVarsNeedUpdate = true
            logInfo("Service plist needs update: missing or incorrect UTF-8 environment variables")
        }

        return (binaryPathChanged || envVarsNeedUpdate, currentBinaryPath)
    }
    
    /// Start the service
    func startService() -> (success: Bool, message: String) {
        // Install service if it doesn't exist
        if !isServiceInstalled() {
            let installResult = installService()
            if !installResult.success {
                return installResult
            }
        } else {
            // Check if service needs update
            if let (needsUpdate, _) = checkServiceNeedsUpdate(), needsUpdate {
                let updateResult = installService()
                if !updateResult.success {
                    return updateResult
                }
            }
        }
        
        // Check if already running
        if isServiceRunning() {
            return (true, "Service is already running")
        }
        
        // Bootstrap the service
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["bootstrap", "gui/\(getuid())", servicePlistPath]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                logInfo("Service started successfully")
                return (true, "Service started successfully")
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? "Unknown error"
                let message = "Failed to start service: \(output)"
                logError(message)
                return (false, message)
            }
        } catch {
            let message = "Failed to execute launchctl bootstrap: \(error)"
            logError(message)
            return (false, message)
        }
    }
    
    /// Stop the service
    func stopService() -> (success: Bool, message: String) {
        if !isServiceRunning() {
            return (true, "Service is not running")
        }
        
        // Bootout the service
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["bootout", "gui/\(getuid())/\(serviceName)"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                logInfo("Service stopped successfully")
                return (true, "Service stopped successfully")
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? "Unknown error"
                let message = "Failed to stop service: \(output)"
                logError(message)
                return (false, message)
            }
        } catch {
            let message = "Failed to execute launchctl bootout: \(error)"
            logError(message)
            return (false, message)
        }
    }
    
    /// Restart the service
    func restartService() -> (success: Bool, message: String) {
        // Stop the service first
        let stopResult = stopService()
        if !stopResult.success && stopResult.message != "Service is not running" {
            return stopResult
        }
        
        // Brief delay to ensure clean shutdown
        Thread.sleep(forTimeInterval: 1.0)
        
        // Start the service
        return startService()
    }
    
    /// Uninstall the service
    func uninstallService() -> (success: Bool, message: String) {
        // Stop the service first if it's running
        if isServiceRunning() {
            let stopResult = stopService()
            if !stopResult.success {
                return (false, "Failed to stop service before uninstall: \(stopResult.message)")
            }
        }
        
        // Remove the plist file
        if isServiceInstalled() {
            do {
                try FileManager.default.removeItem(atPath: servicePlistPath)
                logInfo("Service uninstalled successfully")
                return (true, "Service uninstalled successfully")
            } catch {
                let message = "Failed to remove service plist: \(error)"
                logError(message)
                return (false, message)
            }
        } else {
            return (true, "Service is not installed")
        }
    }
    
    /// Get comprehensive service status
    func getServiceStatus() -> String {
        let installed = isServiceInstalled()
        let running = isServiceRunning()
        let binaryPath = getCurrentBinaryPath()
        let originalPath = CommandLine.arguments[0]
        
        var status = "Service Status:\n"
        status += "  Installed: \(installed ? "Yes" : "No")\n"
        status += "  Running: \(running ? "Yes" : "No")\n"
        status += "  Binary Path: \(binaryPath)\n"
        
        // Add debugging info about path resolution
        if originalPath != binaryPath {
            status += "  Original Path: \(originalPath)\n"
            
            // Show which strategy was used
            if originalPath.hasPrefix("/") {
                status += "  Resolution: Absolute path (cleaned)\n"
            } else if let pathFromWhich = findBinaryInPath(originalPath) {
                if pathFromWhich == binaryPath {
                    status += "  Resolution: Found in PATH\n"
                }
            } else {
                status += "  Resolution: Relative path (resolved)\n"
            }
        }
        
        if installed {
            status += "  Service File: \(servicePlistPath)\n"
            
            // Check if binary path matches
            if let (needsUpdate, currentPath) = checkServiceNeedsUpdate() {
                if needsUpdate {
                    status += "  Status: ⚠️  Service needs update (binary moved)\n"
                    status += "  Current Service Binary: \(currentPath)\n"
                } else {
                    status += "  Status: ✅ Service is up to date\n"
                }
            }
        }
        
        if let configPath = ConfigurationManager.getSavedConfigPath() {
            status += "  Config Path: \(configPath)\n"
        }
        
        return status
    }
    
    /// Stop any running daemon instance (for use when service management takes over)
    func stopRunningDaemon() -> (success: Bool, message: String) {
        let uid = getuid()
        let socketPath = "/tmp/macrowhisper-\(uid).sock"
        let socketCommunication = SocketCommunication(socketPath: socketPath)
        
        if let response = socketCommunication.sendCommand(.quit) {
            return (true, response)
        } else {
            return (true, "No running daemon instance found")
        }
    }
} 
