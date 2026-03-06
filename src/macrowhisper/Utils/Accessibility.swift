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
            if !globalState.disableNotifications {
                notify(title: "Macrowhisper", message: "Accessibility permissions are needed for key simulation and input field detection.")
            }
        }
    }
    
    // Also request System Events control permission for features that automate System Events
    requestSystemEventsPermissionOnStartup()
}

/// Checks if System Events control permission is granted (used by System Events automation features)
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

/// Proactively requests System Events control permission during app startup.
/// This supports features that rely on AppleScript/System Events automation.
func requestSystemEventsPermissionOnStartup() {
    // Check if System Events permission is already granted
    if checkSystemEventsPermission() {
        logDebug("System Events control permission already granted")
        return
    }
    
    // If not granted, attempt to trigger the permission dialog by running a simple System Events command
    logInfo("Requesting System Events control permission for automation features...")
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
            logWarning("System Events control permission was not granted - some automation features may not work")
            if !globalState.disableNotifications {
                notify(title: "Macrowhisper", message: "System Events control permission is needed for some automation features. You may be prompted again when using these features.")
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
        globalState.lastDetectedFrontApp = nil
        let result = false
        cacheResult(threadId: threadId, result: result)
        return result
    }
    
    // Log the detected app
    logDebug("[InputField] Detected app: \(app.localizedName ?? "Unknown") (PID: \(app.processIdentifier))")
    
    // Store reference to current app
    globalState.lastDetectedFrontApp = app
    
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
    // First check if there's an insert-specific simEsc setting
    if let insert = activeInsert, let insertSimEsc = insert.simEsc {
        // Use the insert-specific setting if available
        if !insertSimEsc {
            logDebug("ESC key simulation disabled by insert-specific simEsc setting")
            return
        }
    }
    // Otherwise fall back to the global setting
    else if let simEsc = globalConfigManager?.config.defaults.simEsc, simEsc == false {
        logDebug("ESC key simulation disabled by global simEsc setting")
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
    
    // Small delay before starting to avoid dropping first characters in some apps
    Thread.sleep(forTimeInterval: 0.03)
    
    // Type each character
    for character in text {
        typeUnicodeCharacter(character)
        Thread.sleep(forTimeInterval: 0.005) // Small delay between characters
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

// MARK: - Selected Text Retrieval

struct InputInsertionContext {
    let leftCharacter: Character?
    let leftNonWhitespaceCharacter: Character?
    let leftLinePrefix: String
    let rightCharacter: Character?
    let rightNonWhitespaceCharacter: Character?
    let rightHasLineBreakBeforeNextNonWhitespace: Bool
}

private let ignoredBoundaryScalarsForSmartInsert: Set<UnicodeScalar> = [
    "\u{FEFF}", // ZERO WIDTH NO-BREAK SPACE / BOM
    "\u{200B}", // ZERO WIDTH SPACE
    "\u{200C}", // ZERO WIDTH NON-JOINER
    "\u{200D}", // ZERO WIDTH JOINER
    "\u{2060}", // WORD JOINER
    "\u{FFFC}"  // OBJECT REPLACEMENT CHARACTER
]

private func isIgnorableBoundaryCharacterForSmartInsert(_ character: Character?) -> Bool {
    guard let character = character else { return false }
    return character.unicodeScalars.allSatisfy { scalar in
        ignoredBoundaryScalarsForSmartInsert.contains(scalar) || scalar.properties.isJoinControl
    }
}

private func getFrontmostApplicationForAccessibility(timeout: TimeInterval = 0.1) -> NSRunningApplication? {
    if Thread.isMainThread {
        return NSWorkspace.shared.frontmostApplication
    }

    var frontApp: NSRunningApplication?
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        frontApp = NSWorkspace.shared.frontmostApplication
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + timeout)
    return frontApp
}

private func isInputLikeElementForSmartInsert(_ element: AXUIElement, roleHint: String?) -> Bool {
    let inputRoles = Set(["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"])
    if let roleHint, inputRoles.contains(roleHint) {
        return true
    }

    var subroleValue: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue) == .success,
       let subrole = subroleValue as? String {
        let inputSubroles = Set(["AXSearchField", "AXSecureTextField", "AXTextInput"])
        if inputSubroles.contains(subrole) {
            return true
        }
    }

    var editableValue: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableValue) == .success,
       let isEditable = editableValue as? Bool,
       isEditable {
        return true
    }

    return false
}

/// Returns insertion boundary characters around the current cursor/selection in a focused input field.
/// The left character is immediately before selection start, and the right character is immediately after selection end.
/// Returns nil when context is unavailable or unreliable.
func getInputInsertionContext() -> InputInsertionContext? {
    guard AXIsProcessTrusted() else {
        logDebug("[SmartInsert] No accessibility permissions, cannot get insertion context")
        return nil
    }

    guard let frontApp = getFrontmostApplicationForAccessibility() else {
        logDebug("[SmartInsert] No frontmost application found")
        return nil
    }

    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

    var focusedElement: CFTypeRef?
    let focusedError = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    guard focusedError == .success, let focusedElement = focusedElement else {
        logDebug("[SmartInsert] Could not get focused element")
        return nil
    }

    let element = focusedElement as! AXUIElement

    var roleValue: CFTypeRef?
    let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
    guard roleError == .success, let roleValue = roleValue, let role = roleValue as? String else {
        logDebug("[SmartInsert] Could not get focused element role")
        return nil
    }

    guard isInputLikeElementForSmartInsert(element, roleHint: role) else {
        logDebug("[SmartInsert] Focused element role is not an input field: \(role)")
        return nil
    }

    var valueRef: CFTypeRef?
    let valueError = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
    guard valueError == .success, let valueRef = valueRef, let fullText = valueRef as? String else {
        logDebug("[SmartInsert] Could not get AXValue as String")
        return nil
    }

    var selectedRangeRef: CFTypeRef?
    let selectedRangeError = AXUIElementCopyAttributeValue(element, "AXSelectedTextRange" as CFString, &selectedRangeRef)
    guard selectedRangeError == .success, let selectedRangeRef = selectedRangeRef else {
        logDebug("[SmartInsert] Could not get AXSelectedTextRange")
        return nil
    }

    guard CFGetTypeID(selectedRangeRef) == AXValueGetTypeID(),
          AXValueGetType(selectedRangeRef as! AXValue) == .cfRange else {
        logDebug("[SmartInsert] AXSelectedTextRange has unexpected type")
        return nil
    }

    var selectedRange = CFRange(location: 0, length: 0)
    guard AXValueGetValue(selectedRangeRef as! AXValue, .cfRange, &selectedRange) else {
        logDebug("[SmartInsert] Failed to decode AXSelectedTextRange value")
        return nil
    }

    guard selectedRange.location >= 0, selectedRange.length >= 0 else {
        logDebug("[SmartInsert] AXSelectedTextRange has invalid negative values")
        return nil
    }

    let nsText = fullText as NSString
    let textLength = nsText.length
    let insertionStart = Int(selectedRange.location)
    let insertionEnd = insertionStart + Int(selectedRange.length)

    guard insertionStart <= textLength, insertionEnd <= textLength else {
        logDebug("[SmartInsert] AXSelectedTextRange is out of bounds for AXValue")
        return nil
    }

    var leftCharacter: Character?
    if insertionStart > 0 {
        let leftRange = nsText.rangeOfComposedCharacterSequence(at: insertionStart - 1)
        let leftString = nsText.substring(with: leftRange)
        leftCharacter = leftString.first
    }

    var leftNonWhitespaceCharacter: Character?
    if insertionStart > 0 {
        var cursor = insertionStart
        while cursor > 0 {
            let range = nsText.rangeOfComposedCharacterSequence(at: cursor - 1)
            let value = nsText.substring(with: range)
            if let character = value.first,
               !character.isWhitespace,
               !isIgnorableBoundaryCharacterForSmartInsert(character) {
                leftNonWhitespaceCharacter = character
                break
            }
            cursor = range.location
        }
    }

    var leftLinePrefix = ""
    do {
        let lineStart: Int
        if insertionStart == 0 {
            lineStart = 0
        } else {
            let searchRange = NSRange(location: 0, length: insertionStart)
            let newlineRange = nsText.range(
                of: "\n",
                options: .backwards,
                range: searchRange
            )
            lineStart = newlineRange.location == NSNotFound ? 0 : newlineRange.location + newlineRange.length
        }
        if lineStart <= insertionStart {
            leftLinePrefix = nsText.substring(with: NSRange(location: lineStart, length: insertionStart - lineStart))
        }
    }

    var rightCharacter: Character?
    if insertionEnd < textLength {
        let rightRange = nsText.rangeOfComposedCharacterSequence(at: insertionEnd)
        let rightString = nsText.substring(with: rightRange)
        rightCharacter = rightString.first
    }

    var rightNonWhitespaceCharacter: Character?
    var rightHasLineBreakBeforeNextNonWhitespace = false
    if insertionEnd < textLength {
        var cursor = insertionEnd
        while cursor < textLength {
            let range = nsText.rangeOfComposedCharacterSequence(at: cursor)
            let value = nsText.substring(with: range)
            if let character = value.first,
               !character.isWhitespace,
               !isIgnorableBoundaryCharacterForSmartInsert(character) {
                rightNonWhitespaceCharacter = character
                break
            }
            if value.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) {
                rightHasLineBreakBeforeNextNonWhitespace = true
            }
            cursor = range.location + range.length
        }
    }

    return InputInsertionContext(
        leftCharacter: leftCharacter,
        leftNonWhitespaceCharacter: leftNonWhitespaceCharacter,
        leftLinePrefix: leftLinePrefix,
        rightCharacter: rightCharacter,
        rightNonWhitespaceCharacter: rightNonWhitespaceCharacter,
        rightHasLineBreakBeforeNextNonWhitespace: rightHasLineBreakBeforeNextNonWhitespace
    )
}

/// Gets the currently selected text from the frontmost application using accessibility APIs
/// Returns the selected text if any, or empty string if no text is selected or accessibility fails
func getSelectedText() -> String {
    // Check if we have accessibility permissions
    guard AXIsProcessTrusted() else {
        logDebug("[SelectedText] No accessibility permissions, cannot get selected text")
        return ""
    }
    
    // Get the frontmost application using the same thread-safe path as other AX helpers.
    guard let frontApp = getFrontmostApplicationForAccessibility() else {
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
    if let selectedText = extractSelectedTextFromAXElement(axElement) {
        logDebug("[SelectedText] Found selected text from focused element.")
        return selectedText
    }

    let appBundleId = frontApp.bundleIdentifier ?? ""
    if appVocabularyBrowserBundleIds.contains(appBundleId) {
        var focusedWindow: CFTypeRef?
        let focusedWindowError = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        if focusedWindowError == .success,
           let focusedWindow = focusedWindow,
           CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() {
            let focusedWindowElement = unsafeBitCast(focusedWindow, to: AXUIElement.self)
            if let webArea = findBestWebArea(from: focusedWindowElement, maxDepth: 10, maxNodes: 2200),
               let selectedText = findSelectedTextInSubtree(from: webArea, maxDepth: 14, maxNodes: 2600) {
                logDebug("[SelectedText] Found selected text from browser web area subtree.")
                return selectedText
            }

            if let selectedText = findSelectedTextInSubtree(from: focusedWindowElement, maxDepth: 12, maxNodes: 3000) {
                logDebug("[SelectedText] Found selected text from focused browser window subtree.")
                return selectedText
            }
        }
    }

    // No reliable selection found
    logDebug("[SelectedText] No selected text found in \(frontApp.localizedName ?? "unknown app")")
    return ""
}

private func extractSelectedTextFromAXElement(_ element: AXUIElement) -> String? {
    var selectedTextValue: CFTypeRef?
    let selectedTextError = AXUIElementCopyAttributeValue(element, "AXSelectedText" as CFString, &selectedTextValue)
    if selectedTextError == .success, let selectedTextValue = selectedTextValue {
        if let selectedText = extractPlainTextFromAXValue(selectedTextValue) {
            let normalized = sanitizeContextPlaceholderValue(selectedText)
            if !normalized.isEmpty {
                return normalized
            }
        }
    }

    var selectedRangeValue: CFTypeRef?
    let selectedRangeError = AXUIElementCopyAttributeValue(element, "AXSelectedTextRange" as CFString, &selectedRangeValue)
    if selectedRangeError == .success,
       let selectedRangeValue = selectedRangeValue,
       CFGetTypeID(selectedRangeValue) == AXValueGetTypeID() {
        let selectedRangeAXValue = unsafeBitCast(selectedRangeValue, to: AXValue.self)
        if AXValueGetType(selectedRangeAXValue) == .cfRange {
            var selectedRange = CFRange(location: 0, length: 0)
            if AXValueGetValue(selectedRangeAXValue, .cfRange, &selectedRange), selectedRange.length > 0 {
                var stringForRangeValue: CFTypeRef?
                let stringForRangeError = AXUIElementCopyParameterizedAttributeValue(
                    element,
                    "AXStringForRange" as CFString,
                    selectedRangeAXValue,
                    &stringForRangeValue
                )
                if stringForRangeError == .success,
                   let stringForRangeValue = stringForRangeValue,
                   let stringForRange = extractPlainTextFromAXValue(stringForRangeValue) {
                    let normalized = sanitizeContextPlaceholderValue(stringForRange)
                    if !normalized.isEmpty {
                        return normalized
                    }
                }

                var fullTextValue: CFTypeRef?
                let fullTextError = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &fullTextValue)
                if fullTextError == .success,
                   let fullTextValue = fullTextValue,
                   let fullText = extractPlainTextFromAXValue(fullTextValue) {
                    let utf16 = fullText.utf16
                    if selectedRange.location >= 0,
                       selectedRange.length >= 0,
                       Int(selectedRange.location) <= utf16.count,
                       Int(selectedRange.location + selectedRange.length) <= utf16.count {
                        let start = utf16.index(utf16.startIndex, offsetBy: Int(selectedRange.location))
                        let end = utf16.index(start, offsetBy: Int(selectedRange.length))
                        if let s = String.Index(start, within: fullText), let e = String.Index(end, within: fullText) {
                            let selected = sanitizeContextPlaceholderValue(String(fullText[s..<e]))
                            if !selected.isEmpty {
                                return selected
                            }
                        }
                    }
                }
            }
        }
    }

    var selectedTextMarkerRangeValue: CFTypeRef?
    let selectedTextMarkerRangeError = AXUIElementCopyAttributeValue(
        element,
        "AXSelectedTextMarkerRange" as CFString,
        &selectedTextMarkerRangeValue
    )
    if selectedTextMarkerRangeError == .success, let selectedTextMarkerRangeValue = selectedTextMarkerRangeValue {
        var markerStringValue: CFTypeRef?
        let markerStringError = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXStringForTextMarkerRange" as CFString,
            selectedTextMarkerRangeValue,
            &markerStringValue
        )
        if markerStringError == .success,
           let markerStringValue = markerStringValue,
           let markerString = extractPlainTextFromAXValue(markerStringValue) {
            let normalized = sanitizeContextPlaceholderValue(markerString)
            if !normalized.isEmpty {
                return normalized
            }
        }
    }

    return nil
}

private func extractPlainTextFromAXValue(_ value: CFTypeRef) -> String? {
    if let text = value as? String {
        return text
    }

    if let attributedText = value as? NSAttributedString {
        return attributedText.string
    }

    return nil
}

private func findSelectedTextInSubtree(from root: AXUIElement, maxDepth: Int, maxNodes: Int) -> String? {
    var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
    var visited = 0
    var seen = Set<CFHashCode>()

    while !queue.isEmpty && visited < maxNodes {
        let current = queue.removeFirst()
        visited += 1

        let currentHash = CFHash(current.element)
        if !seen.insert(currentHash).inserted {
            continue
        }

        if let selected = extractSelectedTextFromAXElement(current.element) {
            return selected
        }

        guard current.depth < maxDepth else { continue }
        for child in getAXTraversalChildren(of: current.element) {
            queue.append((child, current.depth + 1))
        }
    }

    return nil
}

/// Gets structured app context information from a target app (or frontmost app when target is unavailable).
/// Returns formatted context with app name, window title, names, URL, and input field content
func getAppContext(targetPid: Int32? = nil, fallbackAppName: String? = nil) -> String {
    // Check if we have accessibility permissions
    guard AXIsProcessTrusted() else {
        logDebug("[AppContext] No accessibility permissions, cannot get app context")
        return ""
    }
    
    // Use frozen app when available, otherwise current frontmost app.
    guard let targetApp = resolveTargetApp(targetPid: targetPid) else {
        logDebug("[AppContext] No target application found")
        return ""
    }
    
    // Start building the context
    var contextParts: [String] = []
    
    // Active App (always included)
    let appName = (targetApp.localizedName ?? fallbackAppName ?? "Unknown").trimmingCharacters(in: .whitespacesAndNewlines)
    contextParts.append("ACTIVE APP:\n\(appName)")
    
    // Create accessibility element for the application
    let appElement = AXUIElementCreateApplication(targetApp.processIdentifier)
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
    contextParts.append("ACTIVE WINDOW:\n\(windowTitle)")
    
    // Names and usernames removed for performance optimization
    
    // Active URL (optional - only for browsers)
    if let url = getBrowserURL(appElement: appElement, frontApp: targetApp) {
        contextParts.append("ACTIVE URL:\n\(url)")
    }
    
    let inputContent = getInputFieldContent(appElement: appElement)

    // Active Element Info (optional - description/label of focused element)
    if let elementDescription = getFocusedElementDescription(appElement: appElement) {
        contextParts.append("ACTIVE ELEMENT INFO:\n\(elementDescription)")
    }

    // Active Element Content (optional - only if in input field)
    // Keep this section last because it is typically the largest payload.
    if let inputContent = inputContent {
        contextParts.append("ACTIVE ELEMENT CONTENT:\n\(inputContent)")
    }

    let result = contextParts.joined(separator: "\n\n")
    logDebug("[AppContext] Generated app context with \(contextParts.count) sections")
    return result
}

private func resolveTargetApp(targetPid: Int32?) -> NSRunningApplication? {
    if let targetPid {
        if let app = NSRunningApplication(processIdentifier: targetPid), !app.isTerminated {
            return app
        }
    }
    return NSWorkspace.shared.frontmostApplication
}

/// Gets active URL for the target app (or current frontmost app when pid is nil).
/// Returns nil when accessibility isn't available, app can't be resolved, or URL cannot be extracted.
func getActiveURL(targetPid: Int32? = nil, fallbackBundleId: String? = nil) -> String? {
    guard AXIsProcessTrusted() else {
        logDebug("[AppContext] No accessibility permissions, cannot get active URL")
        return nil
    }

    guard let targetApp = resolveTargetApp(targetPid: targetPid) else {
        logDebug("[AppContext] No target application found for active URL lookup")
        return nil
    }

    let appElement = AXUIElementCreateApplication(targetApp.processIdentifier)
    return getBrowserURL(appElement: appElement, frontApp: targetApp, fallbackBundleId: fallbackBundleId)
}

private let arcBrowserBundleId = "company.thebrowser.Browser"
private let arcURLWebAreaAttributes: [String] = [
    "AXURL",
    "AXDocument",
    kAXValueAttribute as String
]

private enum ArcURLSourceKind: String {
    case webArea
    case commandBar
}

private struct ArcURLSourceRef {
    let kind: ArcURLSourceKind
    let attribute: String
    let element: AXUIElement
}

/// Gets the current URL from browser applications
private func getBrowserURL(appElement: AXUIElement, frontApp: NSRunningApplication, fallbackBundleId: String? = nil) -> String? {
    // Check if this is a known browser application
    let browserBundleIds = [
        "com.apple.Safari",
        "com.google.Chrome", 
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.brave.Browser",
        "company.thebrowser.dia",
        "com.openai.atlas",
        "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS",
        "org.mozilla.librewolf",
        "ai.perplexity.comet",
        "org.torproject.torbrowser",
        "net.mullvad.mullvadbrowser",
        "net.waterfox.waterfox",
        "com.sigmaos.sigmaos.macos",
        "com.duckduckgo.macos.browser",
        "app.zen-browser.zen",
        "net.imput.helium",
        arcBrowserBundleId,  // Arc Browser
        "org.chromium.Chromium"
    ]
    
    let bundleId = frontApp.bundleIdentifier ?? fallbackBundleId ?? "unknown"
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

    if bundleId == arcBrowserBundleId {
        if let arcURL = getArcURLViaAccessibility(windowElement: windowElement, bundleId: bundleId) {
            logDebug("[AppContext] Found Arc URL via accessibility: \(redactForLogs(arcURL))")
            return arcURL
        }
        logDebug("[AppContext] Arc URL not found via accessibility")
        return nil
    }

    // Accessibility-only extraction for known non-Arc browsers.
    if let axURL = getBrowserURLViaAccessibility(windowElement: windowElement) {
        logDebug("[AppContext] Found browser URL via accessibility: \(redactForLogs(axURL))")
        return axURL
    }
    
    logDebug("[AppContext] No URL found in browser window")
    return nil
}

/// Browser-agnostic URL extraction using accessibility only.
/// Order matters: prioritize browser chrome (address bar), then web content attributes.
private func getBrowserURLViaAccessibility(windowElement: AXUIElement) -> String? {
    if let addressBarUrl = findAddressBarURL(windowElement) {
        return addressBarUrl
    }

    if let webAreaUrl = findWebAreaURL(windowElement) {
        return webAreaUrl
    }

    return nil
}

private func getArcURLViaAccessibility(windowElement: AXUIElement, bundleId: String) -> String? {
    let startedAt = CFAbsoluteTimeGetCurrent()

    guard let resolved = resolveArcURLSource(windowElement: windowElement) else {
        logArcURLResolution(
            bundleId: bundleId,
            sourceKind: nil,
            attribute: nil,
            cacheHit: false,
            url: nil,
            startedAt: startedAt
        )
        return nil
    }

    logArcURLResolution(
        bundleId: bundleId,
        sourceKind: resolved.source.kind,
        attribute: resolved.source.attribute,
        cacheHit: false,
        url: resolved.url,
        startedAt: startedAt
    )
    return resolved.url
}

private func resolveArcURLSource(windowElement: AXUIElement) -> (url: String, source: ArcURLSourceRef)? {
    if let webArea = findBestWebArea(from: windowElement, maxDepth: 10, maxNodes: 2200) {
        for attribute in arcURLWebAreaAttributes {
            let source = ArcURLSourceRef(kind: .webArea, attribute: attribute, element: webArea)
            if let url = readArcURLFromSource(source) {
                return (url, source)
            }
        }
    }

    if let commandBarElement = findElementByAXIdentifier(
        "commandBarPlaceholderTextField",
        from: windowElement,
        maxDepth: 10,
        maxNodes: 1800
    ) {
        let source = ArcURLSourceRef(kind: .commandBar, attribute: kAXValueAttribute as String, element: commandBarElement)
        if let url = readArcURLFromSource(source) {
            return (url, source)
        }
    }

    return nil
}

private func readArcURLFromSource(_ source: ArcURLSourceRef) -> String? {
    var valueRef: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(source.element, source.attribute as CFString, &valueRef)
    guard error == .success, let valueRef = valueRef else {
        return nil
    }

    switch source.kind {
    case .webArea:
        return normalizeBrowserURLCandidate(valueRef)
    case .commandBar:
        return normalizeArcCommandBarURLCandidate(valueRef)
    }
}

private func findElementByAXIdentifier(_ identifier: String, from root: AXUIElement, maxDepth: Int, maxNodes: Int) -> AXUIElement? {
    var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
    var visited = 0
    var seenHashes = Set<CFHashCode>()

    while !queue.isEmpty && visited < maxNodes {
        let current = queue.removeFirst()
        visited += 1

        let currentHash = CFHash(current.element)
        if !seenHashes.insert(currentHash).inserted {
            continue
        }

        var identifierRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(current.element, "AXIdentifier" as CFString, &identifierRef) == .success,
           let currentIdentifier = identifierRef as? String,
           currentIdentifier == identifier {
            return current.element
        }

        guard current.depth < maxDepth else { continue }
        for child in getAXTraversalChildren(of: current.element) {
            queue.append((child, current.depth + 1))
        }
    }

    return nil
}

private func shouldLogArcURLDiagnostics() -> Bool {
    return verboseLogging || !redactedLogsEnabled
}

private func logArcURLResolution(
    bundleId: String,
    sourceKind: ArcURLSourceKind?,
    attribute: String?,
    cacheHit: Bool,
    url: String?,
    startedAt: CFAbsoluteTime
) {
    guard shouldLogArcURLDiagnostics() else { return }

    let elapsedMs = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0).rounded())
    let sourceDescription = sourceKind?.rawValue ?? "none"
    let attributeDescription = attribute ?? "none"
    let urlDescription = url.map { redactForLogs($0) } ?? "nil"
    logDebug(
        "[ArcURL] bundle=\(bundleId) source=\(sourceDescription) attribute=\(attributeDescription) " +
        "cacheHit=\(cacheHit) elapsedMs=\(elapsedMs) url=\(urlDescription)"
    )
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
    
    let children = getAXTraversalChildren(of: element)
    if !children.isEmpty {
        for child in children {
            if let foundURL = findAddressBarRecursively(child, depth: depth + 1) {
                return foundURL
            }
        }
    }
    
    return nil
}

/// Attempts to read URL-like values from the active AXWebArea subtree.
/// This complements address-bar scraping for browsers that expose location on web content.
private func findWebAreaURL(_ root: AXUIElement) -> String? {
    return findWebAreaURLRecursively(root, depth: 0)
}

private func findWebAreaURLRecursively(_ element: AXUIElement, depth: Int) -> String? {
    guard depth < 12 else { return nil }

    var roleRef: CFTypeRef?
    let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
    if roleError == .success, let role = roleRef as? String, role == "AXWebArea" {
        let urlAttributes = [
            "AXURL",
            "AXDocument",
            kAXValueAttribute as String
        ]
        for attribute in urlAttributes {
            var valueRef: CFTypeRef?
            let valueError = AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef)
            guard valueError == .success, let valueRef = valueRef else { continue }

            if let normalizedURL = normalizeBrowserURLCandidate(valueRef) {
                return normalizedURL
            }
        }
    }

    let children = getAXTraversalChildren(of: element)
    for child in children {
        if let found = findWebAreaURLRecursively(child, depth: depth + 1) {
            return found
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

/// Gets the description/label information of the currently focused element (without role)
func getFocusedElementDescription(appElement: AXUIElement) -> String? {
    // Get focused element
    var focusedElement: CFTypeRef?
    let focusedError = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    
    guard focusedError == .success, let focusedElement = focusedElement else {
        return nil
    }
    
    let element = focusedElement as! AXUIElement
    
    // Collect description information from various accessibility attributes
    var descriptions: [String] = []
    
    // Try to get descriptive attributes in order of preference (omit role)
    let descriptiveAttributes = [
        ("AXLabel", "Label"),
        ("AXTitle", "Title"), 
        ("AXDescription", "Description"),
        ("AXHelp", "Help"),
        ("AXPlaceholderValue", "Placeholder")
    ]
    
    for (attribute, displayName) in descriptiveAttributes {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        
        if error == .success, let value = value, let text = value as? String, !text.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed.count > 1 { // Skip very short text that might be UI noise
                descriptions.append("\(displayName): \(trimmed)")
            }
        }
    }
    
    // If we have no meaningful descriptions, return nil to avoid clutter
    if descriptions.isEmpty {
        return nil
    }
    
    return descriptions.joined(separator: ", ")
}

/// Gets the content of the currently focused input field
func getInputFieldContent(appElement: AXUIElement) -> String? {
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
    let inputRoles = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
    var isInputLike = inputRoles.contains(roleString)

    if !isInputLike {
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let subroleString = subrole as? String {
            let inputSubroles = ["AXSearchField", "AXSecureTextField", "AXTextInput"]
            isInputLike = inputSubroles.contains(subroleString)
        }
    }

    if !isInputLike {
        var editableValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editableValue) == .success,
           let isEditable = editableValue as? Bool {
            isInputLike = isEditable
        }
    }

    guard isInputLike else {
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

/// Comprehensive debugging function to log all accessibility elements with their attributes
/// Specifically designed to help debug Arc browser URL detection issues
private func debugLogAllElements(_ element: AXUIElement, depth: Int, maxDepth: Int, prefix: String) {
    // Limit recursion depth for performance
    guard depth <= maxDepth else { return }
    if redactedLogsEnabled {
        let indent = String(repeating: "  ", count: depth)
        logInfo("\(prefix) \(indent)ELEMENT[depth=\(depth)]: [REDACTED accessibility element details]")
        return
    }
    
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
    
    let children = getAXTraversalChildren(of: element)
    if !children.isEmpty {
        logInfo("\(prefix) \(indent)  Traversal children count: \(children.count)")
        for (index, child) in children.enumerated() {
            if index < 200 { // Keep logs bounded but avoid hiding large browser subtrees
                debugLogAllElements(child, depth: depth + 1, maxDepth: maxDepth, prefix: prefix)
            } else {
                logInfo("\(prefix) \(indent)  ... (truncated remaining \(children.count - 200) children)")
                break
            }
        }
    }
}

/// Dumps focused window/focused element accessibility trees for frontmost app.
/// Intended for diagnostics when appContext/appVocabulary pick the wrong browser subtree.
func debugDumpFrontAppAccessibilityTree(maxDepth: Int = 8) {
    guard AXIsProcessTrusted() else {
        print("Accessibility permissions are required to dump AX tree.")
        return
    }

    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
        print("No frontmost application found.")
        return
    }

    let appName = frontApp.localizedName ?? "Unknown"
    let bundleId = frontApp.bundleIdentifier ?? "unknown.bundle"
    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

    print("Dumping AX tree for: \(appName) (\(bundleId)), depth=\(maxDepth)")
    print("Log file: ~/Library/Logs/Macrowhisper/macrowhisper.log")

    var focusedWindow: CFTypeRef?
    let focusedWindowError = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
    if focusedWindowError == .success, let focusedWindow = focusedWindow {
        logInfo("[AXDump] Focused window tree start (\(appName))")
        debugLogAllElements(focusedWindow as! AXUIElement, depth: 0, maxDepth: maxDepth, prefix: "[AXDump][Window]")
    } else {
        logWarning("[AXDump] Failed to get focused window for \(appName), error=\(focusedWindowError.rawValue)")
    }

    var focusedElement: CFTypeRef?
    let focusedElementError = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    if focusedElementError == .success, let focusedElement = focusedElement {
        logInfo("[AXDump] Focused element tree start (\(appName))")
        debugLogAllElements(focusedElement as! AXUIElement, depth: 0, maxDepth: maxDepth, prefix: "[AXDump][Focused]")
    } else {
        logWarning("[AXDump] Failed to get focused element for \(appName), error=\(focusedElementError.rawValue)")
    }

    if focusedWindowError == .success, let focusedWindow = focusedWindow {
        if let webArea = findBestWebArea(from: focusedWindow as! AXUIElement, maxDepth: 10, maxNodes: 2200) {
            logInfo("[AXDump] Web area tree start (\(appName))")
            debugLogAllElements(webArea, depth: 0, maxDepth: maxDepth, prefix: "[AXDump][WebArea]")
        } else {
            logInfo("[AXDump] No AXWebArea found in focused window (\(appName))")
        }
    }

    print("AX dump complete. Share lines with prefix [AXDump] from the log file.")
}
