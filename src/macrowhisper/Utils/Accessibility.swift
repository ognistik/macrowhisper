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
    
    // Second try: AXSelectedTextRangeAttribute to get selection range
    var selectedRangeValue: CFTypeRef?
    let selectedRangeError = AXUIElementCopyAttributeValue(axElement, "AXSelectedTextRange" as CFString, &selectedRangeValue)
    
    if selectedRangeError == .success, let _ = selectedRangeValue {
        // If we have a selected range, try to get the text content
        var textValue: CFTypeRef?
        let textError = AXUIElementCopyAttributeValue(axElement, "AXValue" as CFString, &textValue)
        
        if textError == .success, let textValue = textValue, let fullText = textValue as? String {
            // For now, we'll return the full text if we can't get the specific range
            // This is a simplified approach - in a more complex implementation, we'd parse the range
            logDebug("[SelectedText] Found text content but could not extract specific selection")
            return fullText
        }
    }
    
    // Third try: Try to get text from common text field attributes
    let textAttributes = ["AXValue", "AXTitle", "AXDescription"]
    for attribute in textAttributes {
        var textValue: CFTypeRef?
        let textError = AXUIElementCopyAttributeValue(axElement, attribute as CFString, &textValue)
        
        if textError == .success, let textValue = textValue, let text = textValue as? String, !text.isEmpty {
            logDebug("[SelectedText] Found text content via \(attribute): '\(text)'")
            return text
        }
    }
    
    logDebug("[SelectedText] No selected text found in \(frontApp.localizedName ?? "unknown app")")
    return ""
}

/// Gets all the text content from the frontmost application window using accessibility APIs
/// Returns the text content if any, or empty string if no content found or accessibility fails
func getWindowContent() -> String {
    // Check if we have accessibility permissions
    guard AXIsProcessTrusted() else {
        logDebug("[WindowContent] No accessibility permissions, cannot get window content")
        return ""
    }
    
    // Get the frontmost application
    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
        logDebug("[WindowContent] No frontmost application found")
        return ""
    }
    
    // Create accessibility element for the application
    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
    
    // Get the focused window
    var focusedWindow: CFTypeRef?
    let focusedWindowError = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
    
    guard focusedWindowError == .success, let focusedWindow = focusedWindow else {
        logDebug("[WindowContent] Could not get focused window for \(frontApp.localizedName ?? "unknown app")")
        return ""
    }
    
    let windowElement = focusedWindow as! AXUIElement
    
    // Recursively collect all text content from the window
    let allText = collectTextFromElement(windowElement)
    
    if !allText.isEmpty {
        logDebug("[WindowContent] Found window content.")
        return allText
    } else {
        logDebug("[WindowContent] No text content found in window for \(frontApp.localizedName ?? "unknown app")")
        return ""
    }
}

/// Recursively collects text content from an accessibility element and its children
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
