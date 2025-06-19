import Foundation
import Cocoa

class VersionChecker {
    private var lastFailedCheckDate: Date? {
        get {
            let timestamp = UserDefaults.standard.double(forKey: "macrowhisper.lastFailedCheckDate")
            return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        }
        set {
            if let date = newValue {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "macrowhisper.lastFailedCheckDate")
            } else {
                UserDefaults.standard.removeObject(forKey: "macrowhisper.lastFailedCheckDate")
            }
        }
    }
    
    private let failedCheckBackoffInterval: TimeInterval = 3600 // 1 hour
    private var updateCheckInProgress = false
    private let currentCLIVersion = APP_VERSION
    private let versionsURL = "https://raw.githubusercontent.com/ognistik/macrowhisper/main/versions.json"
    
    private var lastCheckDate: Date? {
        get {
            let timestamp = UserDefaults.standard.double(forKey: "macrowhisper.lastCheckDate")
            return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        }
        set {
            if let date = newValue {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "macrowhisper.lastCheckDate")
            } else {
                UserDefaults.standard.removeObject(forKey: "macrowhisper.lastCheckDate")
            }
        }
    }
    
    private let checkInterval: TimeInterval = 24 * 60 * 60 // 24 hours
    private let reminderInterval: TimeInterval = 4 * 24 * 60 * 60 // 4 days
    
    private var lastReminderDate: Date? {
        get {
            let timestamp = UserDefaults.standard.double(forKey: "macrowhisper.lastReminderDate")
            return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        }
        set {
            if let date = newValue {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "macrowhisper.lastReminderDate")
            } else {
                UserDefaults.standard.removeObject(forKey: "macrowhisper.lastReminderDate")
            }
        }
    }
    
    // Flag to track if this is a forced check that should bypass reminder limits
    private var isForcedCheck = false
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
            
            // Parse the new JSON format with "version" and "description" fields
            guard let latestVersion = json["version"] as? String else {
                logError("Missing 'version' field in versions JSON")
                return
            }
            
            let description = json["description"] as? String ?? ""
            
            // Check if update is available
            if isNewerVersion(latest: latestVersion, current: currentCLIVersion) {
                let versionMessage = "v\(currentCLIVersion) → v\(latestVersion)"
                showCLIUpdateDialog(versionMessage: versionMessage, description: description, bypassReminderCheck: isForcedCheck)
            } else {
                logDebug("CLI is up to date (\(currentCLIVersion))")
            }
            
        } catch {
            logError("Error parsing versions JSON: \(error)")
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
    
    private func showCLIUpdateDialog(versionMessage: String, description: String, bypassReminderCheck: Bool = false) {
        DispatchQueue.main.async {
            logDebug("showCLIUpdateDialog called with version: \(versionMessage), bypassReminderCheck: \(bypassReminderCheck)")
            
            // Re-read from UserDefaults to ensure we have the latest state
            let currentReminderTimestamp = UserDefaults.standard.double(forKey: "macrowhisper.lastReminderDate")
            let currentLastReminder = currentReminderTimestamp > 0 ? Date(timeIntervalSince1970: currentReminderTimestamp) : nil
            
            logDebug("Current reminder timestamp from UserDefaults: \(currentReminderTimestamp)")
            
            // Check if we should show reminder (not too frequent) - unless bypassed
            if !bypassReminderCheck {
                if let lastReminder = currentLastReminder {
                    let timeSinceReminder = Date().timeIntervalSince(lastReminder)
                    logDebug("Last reminder was \(Int(timeSinceReminder/3600))h ago, interval is \(Int(self.reminderInterval/3600))h")
                    if timeSinceReminder < self.reminderInterval {
                        logDebug("Skipping dialog - too recent reminder (within \(Int(self.reminderInterval/3600))h)")
                        return
                    }
                } else {
                    logDebug("No previous reminder found - will show dialog")
                }
            } else {
                logDebug("Bypassing reminder check for forced update")
            }
            
            logDebug("Showing update dialog now...")
            self.lastReminderDate = Date()
            
            let brewCommand = "macrowhisper --stop-service && brew update && brew upgrade macrowhisper"
            
            // Build the dialog message with version info, description, and update instructions
            var fullMessage = "Macrowhisper update available:\n\(versionMessage)"
            
            // Add description if available
            if !description.isEmpty {
                fullMessage += "\n\n\(description)"
            }
            
            // Add update instructions
            fullMessage += "\n\nTo update, run:\n\(brewCommand)"
            
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
                    self.copyCommandToClipboard(brewCommand)
                } else if output.contains("Open Release") {
                    // Open CLI release page
                    self.openCLIReleasePage()
                }
                // If "Remind Later" is pressed, do nothing
            } catch {
                logError("Failed to show CLI update dialog: \(error)")
            }
        }
    }
    
    private func copyCommandToClipboard(_ command: String) {
        let pbTask = Process()
        pbTask.launchPath = "/usr/bin/pbcopy"
        let inputPipe = Pipe()
        pbTask.standardInput = inputPipe
        pbTask.launch()
        inputPipe.fileHandleForWriting.write(command.data(using: .utf8)!)
        inputPipe.fileHandleForWriting.closeFile()
        logDebug("Copied brew command to clipboard")
    }
    
    private func openCLIReleasePage() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["https://github.com/ognistik/macrowhisper-cli/releases/latest"]
        try? task.run()
        logDebug("Opened CLI release page")
    }
    
    // MARK: - Test Methods (Development Only)
    /// Test method to show update dialog with custom version and description
    /// This is for development/testing purposes only
    func testUpdateDialog(versionMessage: String, description: String) {
        showCLIUpdateDialog(versionMessage: versionMessage, description: description, bypassReminderCheck: true)
    }
    
    /// Debug method to log current version checker state
    /// This is for development/testing purposes only
    func logCurrentState() {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        
        logDebug("=== Version Checker State ===")
        
        if let lastCheck = lastCheckDate {
            let timeSinceCheck = now.timeIntervalSince(lastCheck)
            let timeUntilNextCheck = checkInterval - timeSinceCheck
            logDebug("Last check: \(formatter.string(from: lastCheck)) (\(Int(timeSinceCheck/3600))h ago)")
            if timeUntilNextCheck > 0 {
                logDebug("Next check allowed in: \(Int(timeUntilNextCheck/3600))h \(Int((timeUntilNextCheck.truncatingRemainder(dividingBy: 3600))/60))m")
            } else {
                logDebug("Next check: NOW (overdue)")
            }
        } else {
            logDebug("Last check: Never - will check immediately")
        }
        
        if let lastFailed = lastFailedCheckDate {
            let timeSinceFailure = now.timeIntervalSince(lastFailed)
            let timeUntilRetry = failedCheckBackoffInterval - timeSinceFailure
            logDebug("Last failure: \(formatter.string(from: lastFailed)) (\(Int(timeSinceFailure/60))m ago)")
            if timeUntilRetry > 0 {
                logDebug("Failure backoff ends in: \(Int(timeUntilRetry/60))m")
            } else {
                logDebug("Failure backoff: Expired")
            }
        } else {
            logDebug("Last failure: Never")
        }
        
        if let lastReminder = lastReminderDate {
            let timeSinceReminder = now.timeIntervalSince(lastReminder)
            let timeUntilNextReminder = reminderInterval - timeSinceReminder
            logDebug("Last reminder: \(formatter.string(from: lastReminder)) (\(Int(timeSinceReminder/(24*3600)))d ago)")
            if timeUntilNextReminder > 0 {
                logDebug("Next reminder allowed in: \(Int(timeUntilNextReminder/(24*3600)))d \(Int((timeUntilNextReminder.truncatingRemainder(dividingBy: 24*3600))/3600))h")
            } else {
                logDebug("Next reminder: NOW (overdue)")
            }
        } else {
            logDebug("Last reminder: Never - will show immediately if update available")
        }
        
        logDebug("Updates disabled: \(disableUpdates)")
        logDebug("Check in progress: \(updateCheckInProgress)")
        logDebug("Current version: \(currentCLIVersion)")
        logDebug("==============================")
    }
    
    /// Get version checker state as a formatted string (for socket communication)
    func getStateString() -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        
        var lines: [String] = []
        lines.append("=== Version Checker State ===")
        
        if let lastCheck = lastCheckDate {
            let timeSinceCheck = now.timeIntervalSince(lastCheck)
            let timeUntilNextCheck = checkInterval - timeSinceCheck
            lines.append("Last check: \(formatter.string(from: lastCheck)) (\(Int(timeSinceCheck/3600))h ago)")
            if timeUntilNextCheck > 0 {
                lines.append("Next check allowed in: \(Int(timeUntilNextCheck/3600))h \(Int((timeUntilNextCheck.truncatingRemainder(dividingBy: 3600))/60))m")
            } else {
                lines.append("Next check: NOW (overdue)")
            }
        } else {
            lines.append("Last check: Never - will check immediately")
        }
        
        if let lastFailed = lastFailedCheckDate {
            let timeSinceFailure = now.timeIntervalSince(lastFailed)
            let timeUntilRetry = failedCheckBackoffInterval - timeSinceFailure
            lines.append("Last failure: \(formatter.string(from: lastFailed)) (\(Int(timeSinceFailure/60))m ago)")
            if timeUntilRetry > 0 {
                lines.append("Failure backoff ends in: \(Int(timeUntilRetry/60))m")
            } else {
                lines.append("Failure backoff: Expired")
            }
        } else {
            lines.append("Last failure: Never")
        }
        
        if let lastReminder = lastReminderDate {
            let timeSinceReminder = now.timeIntervalSince(lastReminder)
            let timeUntilNextReminder = reminderInterval - timeSinceReminder
            lines.append("Last reminder: \(formatter.string(from: lastReminder)) (\(Int(timeSinceReminder/(24*3600)))d ago)")
            if timeUntilNextReminder > 0 {
                lines.append("Next reminder allowed in: \(Int(timeUntilNextReminder/(24*3600)))d \(Int((timeUntilNextReminder.truncatingRemainder(dividingBy: 24*3600))/3600))h")
            } else {
                lines.append("Next reminder: NOW (overdue)")
            }
        } else {
            lines.append("Last reminder: Never - will show immediately if update available")
        }
        
        lines.append("Updates disabled: \(disableUpdates)")
        lines.append("Check in progress: \(updateCheckInProgress)")
        lines.append("Current version: \(currentCLIVersion)")
        
        // Add raw UserDefaults values for debugging
        lines.append("")
        lines.append("Raw UserDefaults values:")
        let lastCheckRaw = UserDefaults.standard.double(forKey: "macrowhisper.lastCheckDate")
        let lastFailedRaw = UserDefaults.standard.double(forKey: "macrowhisper.lastFailedCheckDate")
        let lastReminderRaw = UserDefaults.standard.double(forKey: "macrowhisper.lastReminderDate")
        lines.append("macrowhisper.lastCheckDate: \(lastCheckRaw == 0 ? "not set" : String(lastCheckRaw))")
        lines.append("macrowhisper.lastFailedCheckDate: \(lastFailedRaw == 0 ? "not set" : String(lastFailedRaw))")
        lines.append("macrowhisper.lastReminderDate: \(lastReminderRaw == 0 ? "not set" : String(lastReminderRaw))")
        
        lines.append("==============================")
        
        return lines.joined(separator: "\n")
    }
    
    /// Force an update check regardless of timing constraints and noUpdates setting
    func forceUpdateCheck() {
        logDebug("Forcing update check - resetting ALL timing constraints...")
        
        // Set the forced check flag
        isForcedCheck = true
        
        // Reset all timing constraints completely, including reminder date for force check
        lastCheckDate = nil
        lastFailedCheckDate = nil
        lastReminderDate = nil  // Also reset this for force check to ensure dialog shows
        
        logDebug("Performing forced update check...")
        
        // Perform the check synchronously for forced checks
        forceUpdateCheckSynchronous()
        
        // Reset the forced check flag after the check
        isForcedCheck = false
    }
    
    /// Synchronous version of update check for forced updates
    private func forceUpdateCheckSynchronous() {
        // Note: Forced checks ignore the noUpdates setting
        logDebug("Performing synchronous update check (ignoring noUpdates setting)...")
        updateCheckInProgress = true
        
        // Create request with timeout
        guard let url = URL(string: versionsURL) else {
            logError("Invalid versions URL")
            updateCheckInProgress = false
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0 // 10 second timeout
        
        // Perform synchronous request
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?
        
        let session = URLSession(configuration: .default)
        session.dataTask(with: request) { data, response, error in
            resultData = data
            resultError = error
            semaphore.signal()
        }.resume()
        
        // Wait for completion
        let result = semaphore.wait(timeout: .now() + 15.0)
        updateCheckInProgress = false
        
        if result == .timedOut {
            logDebug("Forced version check timed out")
            lastFailedCheckDate = Date()
            return
        }
        
        if let error = resultError {
            logDebug("Forced version check failed: \(error.localizedDescription)")
            lastFailedCheckDate = Date()
            return
        }
        
        guard let data = resultData else {
            logDebug("No data received from forced version check")
            lastFailedCheckDate = Date()
            return
        }
        
        // Clear the failed check date since we succeeded
        lastFailedCheckDate = nil
        
        // Update last check date
        lastCheckDate = Date()
        
        // Process the response
        processVersionResponse(data)
        
        logDebug("Forced update check completed")
    }
    
    /// Completely clear all UserDefaults for version checker (nuclear option for debugging)
    func clearAllUserDefaults() {
        UserDefaults.standard.removeObject(forKey: "macrowhisper.lastCheckDate")
        UserDefaults.standard.removeObject(forKey: "macrowhisper.lastFailedCheckDate")
        UserDefaults.standard.removeObject(forKey: "macrowhisper.lastReminderDate")
        logDebug("All version checker UserDefaults cleared")
    }
} 
