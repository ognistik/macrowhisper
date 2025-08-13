import ApplicationServices
import Cocoa

// Thread-local cache for input field detection results
private var inputFieldDetectionCache: [String: (result: Bool, timestamp: Date)] = [:]
private let cacheValidityDuration: TimeInterval = 0.5 // Cache result for 500ms
private let cacheQueue = DispatchQueue(label: "inputFieldDetectionCache", attributes: .concurrent)

func requestAccessibilityPermission() -> Bool {
    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
    return AXIsProcessTrustedWithOptions(options)
}

/// Checks if accessibility permissions are already granted (without showing prompt)
func checkAccessibilityPermission() -> Bool {
    return AXIsProcessTrusted()
}

/// Proactively requests accessibility permissions during app startup
/// This provides better UX by requesting permissions upfront rather than during first use
func requestAccessibilityPermissionOnStartup() {
    // First check if permissions are already granted
    if AXIsProcessTrusted() {
        logDebug("Accessibility permissions already granted")
    } else {
        // If not granted, show the permission dialog
        logInfo("Requesting accessibility permissions during startup for key simulation and input field detection...")
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
        let granted = AXIsProcessTrustedWithOptions(options)
        
        if granted {
            logInfo("Accessibility permissions granted")
            // No notification needed when permissions are granted successfully
        } else {
            logWarning("Accessibility permissions were not granted - some features may be limited")
            if !disableNotifications {
                notify(title: "Macrowhisper", message: "Accessibility permissions are needed for key simulation and input field detection.")
            }
        }
    }
    
    // Also request System Events control permission for simKeypress functionality
    requestSystemEventsPermissionOnStartup()
}

/// Checks if System Events control permission is granted (needed for simKeypress functionality)
func checkSystemEventsPermission() -> Bool {
    let script = "tell application \"System Events\" to get name"
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", script]
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    } catch {
        return false
    }
}

/// Proactively requests System Events control permission during app startup
/// This is needed for the simKeypress functionality which uses AppleScript to control System Events
func requestSystemEventsPermissionOnStartup() {
    // Check if System Events permission is already granted
    if checkSystemEventsPermission() {
        logDebug("System Events control permission already granted")
        return
    }
    
    // If not granted, attempt to trigger the permission dialog by running a simple System Events command
    logInfo("Requesting System Events control permission for simKeypress functionality...")
    let script = "tell application \"System Events\" to get name"
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", script]
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    
    do {
        try task.run()
        task.waitUntilExit()
        
        if task.terminationStatus == 0 {
            logInfo("System Events control permission granted")
        } else {
            logWarning("System Events control permission was not granted - simKeypress functionality may not work")
            if !disableNotifications {
                notify(title: "Macrowhisper", message: "System Events control permission is needed for simKeypress functionality. You may be prompted again when using this feature.")
            }
        }
    } catch {
        logError("Failed to request System Events permission: \(error)")
    }
}

func isInInputField() -> Bool {
    let currentThread = Thread.current
    let threadId = String(describing: Unmanaged.passUnretained(currentThread).toOpaque())
    
    // Check if we have a recent cached result for this thread
    var cachedResult: (result: Bool, timestamp: Date)?
    cacheQueue.sync {
        cachedResult = inputFieldDetectionCache[threadId]
    }
    
    if let cached = cachedResult,
       Date().timeIntervalSince(cached.timestamp) < cacheValidityDuration {
        logDebug("[InputField] Using cached input field detection result: \(cached.result)")
        return cached.result
    }
    
    logDebug("[InputField] Starting input field detection")
    
    // Small delay to ensure UI has settled after transcription
    Thread.sleep(forTimeInterval: 0.05)
    
    // Check accessibility permissions first
    if !AXIsProcessTrusted() {
        logDebug("[InputField] ❌ Accessibility permissions not granted")
        let result = false
        cacheResult(threadId: threadId, result: result)
        return result
    }
    
    // Get the frontmost application - handle main thread case properly
    var frontApp: NSRunningApplication?
    
    if Thread.isMainThread {
        // We're already on the main thread, get the app directly
        frontApp = NSWorkspace.shared.frontmostApplication
        logDebug("[InputField] Getting frontmost app directly (main thread)")
    } else {
        // We're on a background thread, use semaphore
        logDebug("[InputField] Getting frontmost app via dispatch (background thread)")
        let semaphore = DispatchSemaphore(value: 0)
        
        DispatchQueue.main.async {
            frontApp = NSWorkspace.shared.frontmostApplication
            semaphore.signal()
        }
        
        // Wait for the main thread to get the frontmost app
        _ = semaphore.wait(timeout: .now() + 0.1)
    }
    
    guard let app = frontApp else {
        logDebug("[InputField] No frontmost app detected")
        lastDetectedFrontApp = nil
        let result = false
        cacheResult(threadId: threadId, result: result)
        return result
    }
    
    // Log the detected app
    logDebug("[InputField] Detected app: \(app.localizedName ?? "Unknown") (PID: \(app.processIdentifier))")
    
    // Store reference to current app
    lastDetectedFrontApp = app
    
    // Get the application's process ID and create accessibility element
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    
    // Get the focused UI element in the application
    var focusedElement: AnyObject?
    let focusedError = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    
    if focusedError != .success {
        logDebug("[InputField] Failed to get focused element, error: \(focusedError.rawValue)")
        let result = false
        cacheResult(threadId: threadId, result: result)
        return result
    }
    
    if focusedElement == nil {
        logDebug("[InputField] No focused element found")
        let result = false
        cacheResult(threadId: threadId, result: result)
        return result
    }
    
    let axElement = focusedElement as! AXUIElement
    logDebug("[InputField] Found focused element, checking attributes...")
    
    // Check role (fastest check)
    var roleValue: AnyObject?
    if AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue) == .success,
       let role = roleValue as? String {
        
        logDebug("[InputField] Element role: \(role)")
        
        // Definitive input field roles - quick return
        let definiteInputRoles = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
        if definiteInputRoles.contains(role) {
            logDebug("[InputField] ✅ Input field detected by role: \(role)")
            let result = true
            cacheResult(threadId: threadId, result: result)
            return result
        }
    } else {
        logDebug("[InputField] Could not get role attribute")
    }
    
    // Check subrole
    var subroleValue: AnyObject?
    if AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subroleValue) == .success,
       let subrole = subroleValue as? String {
        
        logDebug("[InputField] Element subrole: \(subrole)")
        
        let definiteInputSubroles = ["AXSearchField", "AXSecureTextField", "AXTextInput"]
        if definiteInputSubroles.contains(subrole) {
            logDebug("[InputField] ✅ Input field detected by subrole: \(subrole)")
            let result = true
            cacheResult(threadId: threadId, result: result)
            return result
        }
    } else {
        logDebug("[InputField] No subrole attribute found")
    }
    
    // Check editable attribute
    var editableValue: AnyObject?
    if AXUIElementCopyAttributeValue(axElement, "AXEditable" as CFString, &editableValue) == .success,
       let isEditable = editableValue as? Bool {
        
        logDebug("[InputField] Element editable: \(isEditable)")
        if isEditable {
            logDebug("[InputField] ✅ Input field detected by editable attribute")
            let result = true
            cacheResult(threadId: threadId, result: result)
            return result
        }
    } else {
        logDebug("[InputField] No editable attribute found")
    }
    
    // Only check actions if we haven't determined it's an input field yet
    var actionsRef: CFArray?
    if AXUIElementCopyActionNames(axElement, &actionsRef) == .success,
       let actions = actionsRef as? [String] {
        
        logDebug("[InputField] Element actions: \(actions)")
        
        let inputActions = ["AXInsertText", "AXDelete"]
        let foundInputActions = actions.filter { inputActions.contains($0) }
        if !foundInputActions.isEmpty {
            logDebug("[InputField] ✅ Input field detected by actions: \(foundInputActions)")
            let result = true
            cacheResult(threadId: threadId, result: result)
            return result
        }
    } else {
        logInfo("[InputField] Could not get actions")
    }
    
    logInfo("[InputField] ❌ No input field detected")
    let result = false
    cacheResult(threadId: threadId, result: result)
    return result
}

/// Cache the input field detection result for the current thread
private func cacheResult(threadId: String, result: Bool) {
    cacheQueue.async(flags: .barrier) {
        inputFieldDetectionCache[threadId] = (result: result, timestamp: Date())
        
        // Clean up old cache entries to prevent memory leaks
        let now = Date()
        inputFieldDetectionCache = inputFieldDetectionCache.filter { 
            now.timeIntervalSince($0.value.timestamp) < cacheValidityDuration 
        }
    }
}

func simulateEscKeyPress(activeInsert: AppConfiguration.Insert?) {
    // First check if there's an insert-specific noEsc setting
    if let insert = activeInsert, let insertNoEsc = insert.noEsc {
        // Use the insert-specific setting if available
        if insertNoEsc {
            logDebug("ESC key simulation disabled by insert-specific noEsc setting")
            return
        }
    }
    // Otherwise fall back to the global setting
    else if let noEsc = globalConfigManager?.config.defaults.noEsc, noEsc == true {
        logDebug("ESC key simulation disabled by global noEsc setting")
        return
    }
    
    // Simulate ESC key press
    simulateKeyDown(key: 53)
}

/// Enhanced key simulation with proper modifier handling
func simulateKeyDown(key: Int, flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .hidSystemState)
    let keyCode = CGKeyCode(key)
    
    let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    keyDownEvent?.flags = flags

    let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    keyUpEvent?.flags = flags

    keyDownEvent?.post(tap: .cghidEventTap)
    keyUpEvent?.post(tap: .cghidEventTap)
}

// MARK: - Simple Text Typing (Complete Solution)

/// Main function to type any text
func typeText(_ text: String) {
    // Check if we have permission
    guard AXIsProcessTrusted() else {
        print("Need accessibility permission")
        return
    }
    
    // Small delay before starting
    Thread.sleep(forTimeInterval: 0.1)
    
    // Type each character
    for character in text {
        typeUnicodeCharacter(character)
        Thread.sleep(forTimeInterval: 0.01) // Small delay between characters
    }
}

/// Type any Unicode character (works for all languages and symbols)
private func typeUnicodeCharacter(_ character: Character) {
    let source = CGEventSource(stateID: .hidSystemState)
    let characterString = String(character)
    
    // Convert to UTF-16 (this handles all Unicode correctly)
    let utf16Array = Array(characterString.utf16)
    var mutableArray = utf16Array
    
    // Create key down event
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
    keyDown?.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: &mutableArray)
    keyDown?.post(tap: .cghidEventTap)
    
    // Create key up event
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
    keyUp?.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: &mutableArray)
    keyUp?.post(tap: .cghidEventTap)
}

/// Simple key press function
private func pressKey(_ keyCode: Int) {
    let source = CGEventSource(stateID: .hidSystemState)
    
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
    
    keyDown?.post(tap: .cghidEventTap)
    keyUp?.post(tap: .cghidEventTap)
}

// MARK: - Selected Text Retrieval

/// Gets the currently selected text from the frontmost application using accessibility APIs
/// Returns the selected text if any, or empty string if no text is selected or accessibility fails
func getSelectedText() -> String {
    // Check if we have accessibility permissions
    guard AXIsProcessTrusted() else {
        logDebug("[SelectedText] No accessibility permissions, cannot get selected text")
        return ""
    }
    
    // Get the frontmost application
    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
        logDebug("[SelectedText] No frontmost application found")
        return ""
    }
    
    // Create accessibility element for the application
    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
    
    // Get the focused UI element
    var focusedElement: CFTypeRef?
    let focusedError = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    
    guard focusedError == .success, let focusedElement = focusedElement else {
        logDebug("[SelectedText] Could not get focused element for \(frontApp.localizedName ?? "unknown app")")
        return ""
    }
    
    let axElement = focusedElement as! AXUIElement
    
    // Try to get the selected text using various accessibility attributes
    var selectedTextValue: CFTypeRef?
    
    // First try: AXSelectedTextAttribute (most common)
    let selectedTextError = AXUIElementCopyAttributeValue(axElement, "AXSelectedText" as CFString, &selectedTextValue)
    
    if selectedTextError == .success, let selectedTextValue = selectedTextValue {
        if let selectedText = selectedTextValue as? String, !selectedText.isEmpty {
            logDebug("[SelectedText] Found selected text.")
            return selectedText
        } else {
            logDebug("[SelectedText] No text selected or selected text is empty")
            return ""
        }
    }
    
    // Second try: AXSelectedTextRangeAttribute to get selection range and slice content
    var selectedRangeValue: CFTypeRef?
    let selectedRangeError = AXUIElementCopyAttributeValue(axElement, "AXSelectedTextRange" as CFString, &selectedRangeValue)
    
    if selectedRangeError == .success, let rangeValue = selectedRangeValue {
        // Extract CFRange from AXValue
        if CFGetTypeID(rangeValue) == AXValueGetTypeID(),
           AXValueGetType(rangeValue as! AXValue) == .cfRange {
            var cfRange = CFRange(location: 0, length: 0)
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange) {
                // Only proceed if there is an actual non-empty selection
                if cfRange.length > 0 {
                    // Get the full text to slice the selection from
                    var textValue: CFTypeRef?
                    let textError = AXUIElementCopyAttributeValue(axElement, "AXValue" as CFString, &textValue)
                    if textError == .success, let textValue = textValue, let fullText = textValue as? String {
                        // Slice using UTF-16 indices to map CFRange properly
                        let utf16 = fullText.utf16
                        guard 
                            cfRange.location >= 0,
                            cfRange.length >= 0,
                            Int(cfRange.location) <= utf16.count,
                            Int(cfRange.location + cfRange.length) <= utf16.count
                        else {
                            logDebug("[SelectedText] Selection range out of bounds for text content")
                            return ""
                        }
                        let start = utf16.index(utf16.startIndex, offsetBy: Int(cfRange.location))
                        let end = utf16.index(start, offsetBy: Int(cfRange.length))
                        if let s = String.Index(start, within: fullText), let e = String.Index(end, within: fullText) {
                            let selected = String(fullText[s..<e]).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !selected.isEmpty {
                                logDebug("[SelectedText] Extracted selected text via range.")
                                return selected
                            }
                        }
                    }
                    // Could not extract text for a non-empty range
                    logDebug("[SelectedText] Non-empty selection range present but failed to extract text")
                    return ""
                } else {
                    // Empty range indicates no selection
                    logDebug("[SelectedText] Selection range present but empty (no selection)")
                    return ""
                }
            }
        }
    }
    
    // No reliable selection found
    logDebug("[SelectedText] No selected text found in \(frontApp.localizedName ?? "unknown app")")
    return ""
}

/// Gets structured app context information from the frontmost application
/// Returns formatted context with app name, window title, names, URL, and input field content
func getAppContext() -> String {
    // Check if we have accessibility permissions
    guard AXIsProcessTrusted() else {
        logDebug("[AppContext] No accessibility permissions, cannot get app context")
        return ""
    }
    
    // Get the frontmost application
    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
        logDebug("[AppContext] No frontmost application found")
        return ""
    }
    
    // Start building the context
    var contextParts: [String] = []
    
    // Active App (always included)
    let appName = (frontApp.localizedName ?? "Unknown").trimmingCharacters(in: .whitespacesAndNewlines)
    contextParts.append("ACTIVE APP: \(appName)")
    
    // Create accessibility element for the application
    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
    
    // Active Window (always included)
    var windowTitle = "Unknown"
    var focusedWindow: CFTypeRef?
    let focusedWindowError = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
    
    if focusedWindowError == .success, let focusedWindow = focusedWindow {
        let windowElement = focusedWindow as! AXUIElement
        var windowTitleValue: CFTypeRef?
        let titleError = AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &windowTitleValue)
        
        if titleError == .success, let titleValue = windowTitleValue, let title = titleValue as? String, !title.isEmpty {
            windowTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    contextParts.append("ACTIVE WINDOW: \(windowTitle)")
    
    // Names and usernames removed for performance optimization
    
    // Active URL (optional - only for browsers)
    if let url = getBrowserURL(appElement: appElement, frontApp: frontApp) {
        contextParts.append("ACTIVE URL: \(url)")
    }
    
    // Active Element Content (optional - only if in input field)
    if let inputContent = getInputFieldContent(appElement: appElement) {
        contextParts.append("ACTIVE ELEMENT CONTENT:\n\(inputContent)")
    }
    
    let result = contextParts.joined(separator: "\n")
    logDebug("[AppContext] Generated app context with \(contextParts.count) sections")
    return result
}

/// Gets the current URL from browser applications
private func getBrowserURL(appElement: AXUIElement, frontApp: NSRunningApplication) -> String? {
    // Check if this is a known browser application
    let browserBundleIds = [
        "com.apple.Safari",
        "com.google.Chrome", 
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",  // Arc Browser
        "org.chromium.Chromium"
    ]
    
    let bundleId = frontApp.bundleIdentifier ?? "unknown"
    logDebug("[AppContext] Current app bundle ID: \(bundleId)")
    
    guard browserBundleIds.contains(bundleId) else {
        logDebug("[AppContext] App with bundle ID '\(bundleId)' is not a recognized browser")
        return nil
    }
    
    logDebug("[AppContext] Recognized browser: \(bundleId)")
    
    // Try to get URL from address bar using accessibility
    var focusedWindow: CFTypeRef?
    let windowError = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
    
    guard windowError == .success, let focusedWindow = focusedWindow else {
        logDebug("[AppContext] Failed to get focused window for URL extraction")
        return nil
    }
    
    let windowElement = focusedWindow as! AXUIElement
    
    // Special handling for Arc browser - prioritize AppleScript for full URL
    if bundleId == "company.thebrowser.Browser" {
        // Try AppleScript first to get the complete URL with path/parameters
        if let scriptUrl = getArcURLViaAppleScript() {
            logDebug("[AppContext] Successfully found full Arc URL via AppleScript: \(scriptUrl)")
            return scriptUrl
        } else {
            // Fallback to accessibility method for basic domain
            if let arcUrl = findArcBrowserURL(windowElement) {
                logDebug("[AppContext] AppleScript failed, using accessibility Arc URL: \(arcUrl)")
                return arcUrl
            }
        }
    }
    
    // Look for URL in address bar for other browsers
    let urlString = findAddressBarURL(windowElement)
    
    if let url = urlString, !url.isEmpty {
        logDebug("[AppContext] Successfully found URL: \(url)")
    } else {
        logDebug("[AppContext] No URL found in browser window")
    }
    
    return urlString?.isEmpty == false ? urlString : nil
}

/// Specifically searches for Arc browser URL using the commandBarPlaceholderTextField identifier
private func findArcBrowserURL(_ element: AXUIElement) -> String? {
    return findArcURLRecursively(element, depth: 0)
}

/// Recursively searches for Arc browser URL with the specific identifier
private func findArcURLRecursively(_ element: AXUIElement, depth: Int) -> String? {
    // Limit recursion depth for performance
    guard depth < 10 else { return nil }
    
    // Check if this element has the Arc URL identifier
    var identifier: CFTypeRef?
    let identifierError = AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &identifier)
    
    if identifierError == .success, let identifier = identifier, let identifierString = identifier as? String {
        if identifierString == "commandBarPlaceholderTextField" {
            // This is Arc's URL element - get its value
            var value: CFTypeRef?
            let valueError = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
            
            if valueError == .success, let value = value, let urlText = value as? String {
                let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != "Search…" { // Ignore placeholder text
                    // Arc stores URL without protocol most of the time, so add https:// if it looks like a domain
                    if trimmed.contains(".") && !trimmed.hasPrefix("http") {
                        logDebug("[ARC URL] Found Arc domain: \(trimmed), adding https://")
                        return "https://\(trimmed)"
                    } else if trimmed.hasPrefix("http") {
                        logDebug("[ARC URL] Found Arc URL with protocol: \(trimmed)")
                        return trimmed
                    }
                }
            }
        }
    }
    
    // Check children elements
    var children: CFTypeRef?
    let childrenError = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
    
    if childrenError == .success, let children = children, let childrenArray = children as? [AXUIElement] {
        for child in childrenArray {
            if let foundURL = findArcURLRecursively(child, depth: depth + 1) {
                return foundURL
            }
        }
    }
    
    return nil
}

/// Gets the current URL from Arc browser using AppleScript as a fallback
/// This provides the full URL including path, query parameters, etc.
private func getArcURLViaAppleScript() -> String? {
    // Try multiple AppleScript approaches for Arc
    let scripts = [
        // Standard approach
        """
        tell application "Arc"
            try
                set currentURL to URL of active tab of front window
                return currentURL
            on error
                return ""
            end try
        end tell
        """,
        // Alternative approach using document
        """
        tell application "Arc"
            try
                set currentURL to URL of active tab of document 1
                return currentURL
            on error
                return ""
            end try
        end tell
        """,
        // Direct window approach
        """
        tell application "Arc"
            try
                tell front window
                    set currentURL to URL of active tab
                    return currentURL
                end tell
            on error
                return ""
            end try
        end tell
        """
    ]
    
    for (index, script) in scripts.enumerated() {
        logDebug("[ARC APPLESCRIPT] Trying approach \(index + 1)")
        
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && trimmed != "" && isValidURL(trimmed) {
                        logDebug("[ARC APPLESCRIPT] Successfully retrieved full URL (approach \(index + 1)): \(trimmed)")
                        return trimmed
                    } else {
                        logDebug("[ARC APPLESCRIPT] Approach \(index + 1) returned empty/invalid: '\(trimmed)'")
                    }
                }
            } else {
                logDebug("[ARC APPLESCRIPT] Approach \(index + 1) failed with exit code: \(task.terminationStatus)")
            }
        } catch {
            logDebug("[ARC APPLESCRIPT] Approach \(index + 1) error: \(error)")
        }
    }
    
    logDebug("[ARC APPLESCRIPT] All approaches failed")
    return nil
}

/// Specifically searches for address bar URLs in browser windows
private func findAddressBarURL(_ element: AXUIElement) -> String? {
    // Look for address bar by checking for text fields with URL-like content
    return findAddressBarRecursively(element, depth: 0)
}

/// Recursively searches for address bar URLs with depth limiting for performance
private func findAddressBarRecursively(_ element: AXUIElement, depth: Int) -> String? {
    // Limit recursion depth for performance
    guard depth < 10 else { return nil }
    
    // Check if this element is a text field (potential address bar)
    var role: CFTypeRef?
    let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    
    if roleError == .success, let role = role, let roleString = role as? String {
        if roleString == "AXTextField" || roleString == "AXComboBox" {
            // Check if it contains a URL
            var value: CFTypeRef?
            let valueError = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
            
            if valueError == .success, let value = value, let text = value as? String {
                // Use strict URL validation
                if isValidURL(text) {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            
            // Also check for placeholder or title attributes that might contain URL
            let urlAttributes = ["AXPlaceholderValue"]
            for attribute in urlAttributes {
                var attrValue: CFTypeRef?
                let attrError = AXUIElementCopyAttributeValue(element, attribute as CFString, &attrValue)
                
                if attrError == .success, let attrValue = attrValue, let text = attrValue as? String {
                    if isValidURL(text) {
                        return text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
    }
    
    // Check children elements (limit depth for performance)
    var children: CFTypeRef?
    let childrenError = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
    
    if childrenError == .success, let children = children, let childrenArray = children as? [AXUIElement] {
        // Prioritize likely address bar containers (toolbars, etc.)
        for child in childrenArray {
            if let foundURL = findAddressBarRecursively(child, depth: depth + 1) {
                return foundURL
            }
        }
    }
    
    return nil
}

/// Validates if a string is a proper URL
private func isValidURL(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Must not be empty and reasonable length
    guard !trimmed.isEmpty && trimmed.count < 2000 else { return false }
    
    // Must start with http(s):// or be a valid domain
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
        // Additional validation for HTTP URLs
        return URL(string: trimmed) != nil
    }
    
    // For non-HTTP URLs, check if it's a valid domain-like structure
    let domainPattern = "^[a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?\\.[a-zA-Z]{2,}(:[0-9]+)?(/.*)?$"
    do {
        let regex = try NSRegularExpression(pattern: domainPattern, options: [])
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        return regex.firstMatch(in: trimmed, options: [], range: range) != nil
    } catch {
        return false
    }
}

/// Gets the content of the currently focused input field
private func getInputFieldContent(appElement: AXUIElement) -> String? {
    // Get focused element
    var focusedElement: CFTypeRef?
    let focusedError = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    
    guard focusedError == .success, let focusedElement = focusedElement else {
        return nil
    }
    
    let element = focusedElement as! AXUIElement
    
    // Check if this is an input field
    var role: CFTypeRef?
    let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    
    guard roleError == .success, let role = role, let roleString = role as? String else {
        return nil
    }
    
    // Check for input field roles
    let inputRoles = ["AXTextField", "AXTextArea", "AXSearchField"]
    guard inputRoles.contains(roleString) else {
        return nil
    }
    
    // Get the value (content) of the input field
    var value: CFTypeRef?
    let valueError = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
    
    if valueError == .success, let value = value, let content = value as? String, !content.isEmpty {
        // Return content with trimmed leading/trailing whitespace but preserve internal formatting
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    return nil
}

/// Recursively collects text content from an accessibility element and its children (legacy function)
private func collectTextFromElement(_ element: AXUIElement) -> String {
    var collectedText: [String] = []
    
    // Try to get text content from various attributes
    let textAttributes = ["AXValue", "AXTitle", "AXDescription", "AXHelp", "AXPlaceholderValue"]
    
    for attribute in textAttributes {
        var textValue: CFTypeRef?
        let textError = AXUIElementCopyAttributeValue(element, attribute as CFString, &textValue)
        
        if textError == .success, let textValue = textValue, let text = textValue as? String, !text.isEmpty {
            // Skip very short text (like single characters or numbers) that might be UI elements
            if text.count > 2 {
                collectedText.append(text)
            }
        }
    }
    
    // Get children elements and recursively collect their text
    var children: CFTypeRef?
    let childrenError = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
    
    if childrenError == .success, let children = children, let childrenArray = children as? [AXUIElement] {
        for child in childrenArray {
            let childText = collectTextFromElement(child)
            if !childText.isEmpty {
                collectedText.append(childText)
            }
        }
    }
    
    // Join all collected text with spaces and remove excessive whitespace
    let combinedText = collectedText.joined(separator: " ")
    let cleanedText = combinedText.components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    
    return cleanedText
}

/// Comprehensive debugging function to log all accessibility elements with their attributes
/// Specifically designed to help debug Arc browser URL detection issues
private func debugLogAllElements(_ element: AXUIElement, depth: Int, maxDepth: Int, prefix: String) {
    // Limit recursion depth for performance
    guard depth <= maxDepth else { return }
    
    let indent = String(repeating: "  ", count: depth)
    
    // Get basic element info
    var role: CFTypeRef?
    var roleDescription: CFTypeRef?
    var title: CFTypeRef?
    var value: CFTypeRef?
    var description: CFTypeRef?
    var help: CFTypeRef?
    var placeholder: CFTypeRef?
    var identifier: CFTypeRef?
    var label: CFTypeRef?
    
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    AXUIElementCopyAttributeValue(element, kAXRoleDescriptionAttribute as CFString, &roleDescription)
    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
    AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
    AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &description)
    AXUIElementCopyAttributeValue(element, kAXHelpAttribute as CFString, &help)
    AXUIElementCopyAttributeValue(element, "AXPlaceholderValue" as CFString, &placeholder)
    AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &identifier)
    AXUIElementCopyAttributeValue(element, "AXLabel" as CFString, &label)
    
    let roleStr = (role as? String) ?? "nil"
    let roleDescStr = (roleDescription as? String) ?? "nil"
    let titleStr = (title as? String) ?? "nil"
    let valueStr = (value as? String) ?? "nil"
    let descStr = (description as? String) ?? "nil"
    let helpStr = (help as? String) ?? "nil"
    let placeholderStr = (placeholder as? String) ?? "nil"
    let identifierStr = (identifier as? String) ?? "nil"
    let labelStr = (label as? String) ?? "nil"
    
    // Create a comprehensive log entry for this element
    var elementInfo = "\(prefix) \(indent)ELEMENT[depth=\(depth)]:"
    elementInfo += "\n\(prefix) \(indent)  Role: \(roleStr)"
    elementInfo += "\n\(prefix) \(indent)  RoleDescription: \(roleDescStr)"
    elementInfo += "\n\(prefix) \(indent)  Title: \(titleStr)"
    elementInfo += "\n\(prefix) \(indent)  Value: \(valueStr)"
    elementInfo += "\n\(prefix) \(indent)  Description: \(descStr)"
    elementInfo += "\n\(prefix) \(indent)  Help: \(helpStr)"
    elementInfo += "\n\(prefix) \(indent)  Placeholder: \(placeholderStr)"
    elementInfo += "\n\(prefix) \(indent)  Identifier: \(identifierStr)"
    elementInfo += "\n\(prefix) \(indent)  Label: \(labelStr)"
    
    // Check if value looks like a URL
    if let valueString = value as? String, !valueString.isEmpty {
        if isValidURL(valueString) {
            elementInfo += "\n\(prefix) \(indent)  *** POTENTIAL URL FOUND *** Value: \(valueString)"
        } else if valueString.contains("http") || valueString.contains("www.") || valueString.contains(".com") {
            elementInfo += "\n\(prefix) \(indent)  *** URL-LIKE TEXT *** Value: \(valueString)"
        }
    }
    
    // Check placeholder for URLs too
    if let placeholderString = placeholder as? String, !placeholderString.isEmpty {
        if isValidURL(placeholderString) {
            elementInfo += "\n\(prefix) \(indent)  *** POTENTIAL URL IN PLACEHOLDER *** Placeholder: \(placeholderString)"
        } else if placeholderString.contains("http") || placeholderString.contains("www.") || placeholderString.contains(".com") {
            elementInfo += "\n\(prefix) \(indent)  *** URL-LIKE TEXT IN PLACEHOLDER *** Placeholder: \(placeholderString)"
        }
    }
    
    logInfo(elementInfo)
    
    // Get all available attributes for this element (additional debugging)
    var attributeNames: CFArray?
    let attributesError = AXUIElementCopyAttributeNames(element, &attributeNames)
    
    if attributesError == .success, let attributeNames = attributeNames, let attributeNamesArray = attributeNames as? [String] {
        if !attributeNamesArray.isEmpty {
            var allAttributes = "\(prefix) \(indent)  Available Attributes: \(attributeNamesArray.joined(separator: ", "))"
            
            // Check for any custom attributes that might contain URL
            for attribute in attributeNamesArray {
                if attribute.lowercased().contains("url") || attribute.lowercased().contains("address") || attribute.lowercased().contains("location") {
                    var customValue: CFTypeRef?
                    let customError = AXUIElementCopyAttributeValue(element, attribute as CFString, &customValue)
                    if customError == .success, let customValue = customValue, let customString = customValue as? String {
                        allAttributes += "\n\(prefix) \(indent)  *** CUSTOM URL ATTRIBUTE *** \(attribute): \(customString)"
                    }
                }
            }
            
            logInfo(allAttributes)
        }
    }
    
    // Process children elements
    var children: CFTypeRef?
    let childrenError = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
    
    if childrenError == .success, let children = children, let childrenArray = children as? [AXUIElement] {
        if !childrenArray.isEmpty {
            logInfo("\(prefix) \(indent)  Children count: \(childrenArray.count)")
            for (index, child) in childrenArray.enumerated() {
                if index < 50 { // Limit children to prevent too much output
                    debugLogAllElements(child, depth: depth + 1, maxDepth: maxDepth, prefix: prefix)
                } else {
                    logInfo("\(prefix) \(indent)  ... (truncated remaining \(childrenArray.count - 50) children)")
                    break
                }
            }
        }
    }
}
