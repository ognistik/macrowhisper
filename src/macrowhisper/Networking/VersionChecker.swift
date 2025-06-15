import Foundation
import Cocoa

class VersionChecker {
    private var lastFailedCheckDate: Date?
    private let failedCheckBackoffInterval: TimeInterval = 3600 // 1 hour
    private var updateCheckInProgress = false
    private let currentCLIVersion = APP_VERSION
    private let versionsURL = "https://raw.githubusercontent.com/ognistik/macrowhisper-cli/main/versions.json"
    private var lastCheckDate: Date?
    private let checkInterval: TimeInterval = 24 * 60 * 60 // 24 hours
    private let reminderInterval: TimeInterval = 4 * 24 * 60 * 60 // 4 days
    private var lastReminderDate: Date?
    
    func shouldCheckForUpdates() -> Bool {
        guard let lastCheck = lastCheckDate else { return true }
        return Date().timeIntervalSince(lastCheck) >= checkInterval
    }
    
    func resetLastCheckDate() {
        // Reset the last check date to trigger a check after the next interaction
        lastCheckDate = nil
        logDebug("Version checker state reset - will check after next interaction")
    }
    
    func checkForUpdates() {
        // Don't run if updates are disabled
        guard !disableUpdates else { return }
        
        // Don't run if we've checked recently (within 24 hours)
        guard shouldCheckForUpdates() else { return }
        
        // Don't run if we're already checking
        guard !updateCheckInProgress else { return }
        
        // Don't run if we've had a recent failure and are backing off
        if let lastFailed = lastFailedCheckDate,
           Date().timeIntervalSince(lastFailed) < failedCheckBackoffInterval {
            return
        }
        
        logDebug("Checking for updates...")
        updateCheckInProgress = true
        
        // Create request with timeout
        guard let url = URL(string: versionsURL) else {
            logError("Invalid versions URL")
            updateCheckInProgress = false
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0 // 10 second timeout
        
        // Use background queue for network request
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.performVersionCheck(request: request)
        }
    }
    
    private func performVersionCheck(request: URLRequest) {
            defer {
                // Always reset the in-progress flag when done
                updateCheckInProgress = false
            }
            
            let semaphore = DispatchSemaphore(value: 0)
            var resultData: Data?
            var resultError: Error?
            
            let session = URLSession(configuration: .default)
            session.dataTask(with: request) { data, response, error in
                resultData = data
                resultError = error
                semaphore.signal()
            }.resume()
            
            // Wait with timeout
            let result = semaphore.wait(timeout: .now() + 15.0)
            
            if result == .timedOut {
                logDebug("Version check timed out - continuing offline")
                lastFailedCheckDate = Date() // Track the failure
                return
            }
            
            if let error = resultError {
                logDebug("Version check failed: \(error.localizedDescription) - continuing offline")
                lastFailedCheckDate = Date() // Track the failure
                return
            }
            
            guard let data = resultData else {
                logDebug("No data received from version check - continuing offline")
                lastFailedCheckDate = Date() // Track the failure
                return
            }
            
            // Clear the failed check date since we succeeded
            lastFailedCheckDate = nil
            
            // Update last check date - this is critical
            lastCheckDate = Date()
            
            processVersionResponse(data)
        }
    
    private func processVersionResponse(_ data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logError("Invalid JSON in versions response")
                return
            }
            
            // Check CLI version
            var cliUpdateAvailable = false
            var kmUpdateAvailable = false
            var cliMessage = ""
            var kmMessage = ""
            
            if let cliInfo = json["cli"] as? [String: Any],
               let latestCLI = cliInfo["latest"] as? String {
                if isNewerVersion(latest: latestCLI, current: currentCLIVersion) {
                    cliUpdateAvailable = true
                    cliMessage = "CLI: \(currentCLIVersion) → \(latestCLI)"
                }
            }
            
            // Check Keyboard Maestro version
            if let kmInfo = json["km_macros"] as? [String: Any],
               let latestKM = kmInfo["latest"] as? String {
                let currentKMVersion = getCurrentKeyboardMaestroVersion()
                
                // Only check for updates if we have a valid current version (not empty, not "missing value")
                if !currentKMVersion.isEmpty &&
                   currentKMVersion != "missing value" &&
                   isNewerVersion(latest: latestKM, current: currentKMVersion) {
                    kmUpdateAvailable = true
                    kmMessage = "KM Macros: \(currentKMVersion) → \(latestKM)"
                } else if currentKMVersion.isEmpty || currentKMVersion == "missing value" {
                    logDebug("Skipping KM version check - macro not available or not installed")
                }
            }
            
            // Now show the appropriate notification
            if cliUpdateAvailable && !kmUpdateAvailable {
                // CLI only: show terminal command
                showCLIUpdateDialog(message: cliMessage)
            } else if !cliUpdateAvailable && kmUpdateAvailable {
                // KM only: show open releases dialog
                showKMUpdateNotification(message: kmMessage)
            } else if cliUpdateAvailable && kmUpdateAvailable {
                // Both: show both messages, offer both instructions and button
                showBothUpdatesNotification(cliMessage: cliMessage, kmMessage: kmMessage)
            } else {
                // No update
                logDebug("All components are up to date")
            }
        } catch {
            logError("Error parsing versions JSON: \(error)")
        }
    }
    
    private func getCurrentKeyboardMaestroVersion() -> String {
        let script = """
        tell application "Keyboard Maestro Engine"
            try
                set result to do script "MW Mbar" with parameter "versionCheck"
                return result
            on error
                return ""
            end try
        end tell
        """
        
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice  // Redirect error output to prevent console errors
        
        do {
            try task.run()
            task.waitUntilExit()
            
            // Check exit status
            if task.terminationStatus != 0 {
                logDebug("Keyboard Maestro macro check failed - Keyboard Maestro might not be running")
                return ""
            }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            // If the macro doesn't exist or doesn't return a proper version, we'll get empty output
            if output.isEmpty || output == "missing value" {
                logDebug("Keyboard Maestro macro version check returned empty result - macro might not be installed")
            }
            
            return output
        } catch {
            logDebug("Failed to check Keyboard Maestro macro version: \(error.localizedDescription)")
            return ""
        }
    }
    
    private func isNewerVersion(latest: String, current: String) -> Bool {
        let latestComponents = latest.split(separator: ".").compactMap { Int($0) }
        let currentComponents = current.split(separator: ".").compactMap { Int($0) }
        
        let maxCount = max(latestComponents.count, currentComponents.count)
        
        for i in 0..<maxCount {
            let latestPart = i < latestComponents.count ? latestComponents[i] : 0
            let currentPart = i < currentComponents.count ? currentComponents[i] : 0
            
            if latestPart > currentPart {
                return true
            } else if latestPart < currentPart {
                return false
            }
        }
        
        return false
    }

    private func showKMUpdateNotification(message: String) {
        // Your current dialog logic with Open Release button
        showUpdateNotification(message: message)
    }

    private func showBothUpdatesNotification(cliMessage: String, kmMessage: String) {
        let brewCommand = "brew upgrade ognistik/tap/macrowhisper-cli"
        let fullMessage = "\(cliMessage)\n\(kmMessage)\n\nTo update CLI:\n\(brewCommand)\n\nWould you like to open the KM Macros release page?"
        // Show dialog with Open Release button and brew instructions
        showUpdateNotification(message: fullMessage)
    }
    
    private func showUpdateNotification(message: String) {
        DispatchQueue.main.async {
            // Check if we should show reminder (not too frequent)
            if let lastReminder = self.lastReminderDate,
               Date().timeIntervalSince(lastReminder) < self.reminderInterval {
                return
            }
            
            self.lastReminderDate = Date()
            
            let title = "Macrowhisper"
            let fullMessage = "Macrowhisper update available:\n\n\(message)"
            
            // Use AppleScript for interactive dialog
            let script = """
            display dialog "\(fullMessage.replacingOccurrences(of: "\"", with: "\\\""))" ¬
                with title "\(title)" ¬
                buttons {"Remind Later", "Open Release"} ¬
                default button "Open Release" ¬
            """
            
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            
            do {
                try task.run()
                task.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                if output.contains("Open Release") {
                    self.openDownloadPage()
                }
            } catch {
                // User cancelled or error occurred
                logDebug("Update dialog cancelled or failed")
            }
        }
    }
    
    private func openDownloadPage() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["https://github.com/ognistik/macrowhisper/releases/latest"]
        try? task.run()
    }
    
    private func showCLIUpdateDialog(message: String) {
        let brewCommand = "brew upgrade ognistik/tap/macrowhisper-cli"
        let fullMessage = """
        Macrowhisper update available:
        \(message)

        To update, run:
        \(brewCommand)
        """
        let script = """
        display dialog "\(fullMessage.replacingOccurrences(of: "\"", with: "\\\""))" ¬
            with title "Macrowhisper" ¬
            buttons {"Remind Later", "Copy Command", "Open Release"} ¬
            default button "Open Release" ¬
        """
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if output.contains("Copy Command") {
                // Copy command to clipboard
                let pbTask = Process()
                pbTask.launchPath = "/usr/bin/pbcopy"
                let inputPipe = Pipe()
                pbTask.standardInput = inputPipe
                pbTask.launch()
                inputPipe.fileHandleForWriting.write(brewCommand.data(using: .utf8)!)
                inputPipe.fileHandleForWriting.closeFile()
            } else if output.contains("Open Release") {
                // Open CLI release page
                openCLIReleasePage()
            }
            // If "Remind Later" is pressed, do nothing (optionally, implement snooze logic)
        } catch {
            logError("Failed to show CLI update dialog: \(error)")
        }
    }
    
    private func openCLIReleasePage() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["https://github.com/ognistik/macrowhisper-cli/releases/latest"]
        try? task.run()
    }
} 