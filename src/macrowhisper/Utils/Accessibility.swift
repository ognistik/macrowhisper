import ApplicationServices
import Cocoa
import NaturalLanguage

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

/// Simple key press function
private func pressKey(_ keyCode: Int) {
    let source = CGEventSource(stateID: .hidSystemState)
    
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
    
    keyDown?.post(tap: .cghidEventTap)
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

/// Returns insertion boundary characters around the current cursor/selection in a focused input field.
/// The left character is immediately before selection start, and the right character is immediately after selection end.
/// Returns nil when context is unavailable or unreliable.
func getInputInsertionContext() -> InputInsertionContext? {
    guard AXIsProcessTrusted() else {
        logDebug("[SmartInsert] No accessibility permissions, cannot get insertion context")
        return nil
    }

    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
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

    let inputRoles = Set(["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"])
    guard inputRoles.contains(role) else {
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
    let isBrowserApp = appVocabularyBrowserBundleIds.contains(frontApp.bundleIdentifier ?? "")
    
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
    
    let inputContent = getInputFieldContent(appElement: appElement)

    // Active Element Content (optional - only if in input field)
    if let inputContent = inputContent {
        contextParts.append("ACTIVE ELEMENT CONTENT:\n\(inputContent)")
    }
    
    // Active Element Info (optional - description/label of focused element)
    if let elementDescription = getFocusedElementDescription(appElement: appElement) {
        contextParts.append("ACTIVE ELEMENT INFO: \(elementDescription)")
    }

    if isBrowserApp,
       inputContent == nil,
       focusedWindowError == .success,
       let focusedWindow = focusedWindow,
       let webArea = findFirstElement(withRole: "AXWebArea", from: focusedWindow as! AXUIElement, maxDepth: 10, maxNodes: 2200) {
        let webSample = buildBrowserWebContentSample(from: webArea, maxCharacters: 1500)
        if !webSample.isEmpty {
            contextParts.append("VISIBLE CONTENT SAMPLE:\n\(webSample)")
        }
    }
    
    let result = contextParts.joined(separator: "\n")
    logDebug("[AppContext] Generated app context with \(contextParts.count) sections")
    return result
}

private let appVocabularyMaxTraversalDepth = 4 //Used in tree crawl
private let appVocabularyMaxVisitedNodes = 360 //Hard cap on AX elements visited
private let appVocabularyMaxSnippets = 460 //text chunks/groups
private let appVocabularyMaxSnippetLength = 320 //snippet length outside .value (non-input fields)
private let appVocabularyMaxLongTextSnippetLength = 2600 //long descriptive text (titles/descriptions/help)
private let appVocabularyMaxValueSnippetLength = 4000 //snippet length inside .value (input fields)
private let appVocabularyMaxOutputTokens = 220 //total output terms after filtering and rules

private let appVocabularyStopWords: Set<String> = [
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "has", "have", "if", "in", "into",
    "is", "it", "its", "of", "on", "or", "that", "the", "their", "then", "there", "these", "this", "to",
    "was", "were", "will", "with", "you", "your", "not", "all", "any", "can", "do", "does", "done", "new",
    "open", "close", "copy", "paste", "edit", "view", "help", "file", "window", "tab", "menu", "button",
    "label", "title", "description", "placeholder", "search",
    "action", "also", "formatting", "text", "notes", "lock", "zoom",
    "day", "one", "entry", "time", "content", "filter", "side", "tags", "toggle", "progress",
    "another", "avoid", "both", "but", "even", "funny", "here", "interestingly",
    "just", "keep", "letting", "related", "say", "skip", "sometimes", "subject",
    "think", "use", "what", "writing", "films", "people", "remembering",
    "identify", "user",
    "keyboard", "shortcuts", "navigation", "section", "header", "body", "message", "messages",
    "press", "select", "group", "cursor", "arrow", "checkboxes", "cheatsheet", "invoke", "virtual",
    "needed", "learn", "storage", "primary", "reply", "mail", "yahoo", "conversation"
]

private let appVocabularyAllowedShortAcronyms: Set<String> = [
    "AI", "API", "CLI", "CSS", "CSV", "GPT", "HTML", "HTTP", "HTTPS", "ID", "IDS",
    "IP", "JS", "JSON", "LLM", "ML", "OCR", "QA", "SQL", "TS", "UI", "URL", "URLS", "UX", "XML"
]

private let appVocabularyBrowserBundleIds: Set<String> = [
    "com.apple.Safari",
    "com.google.Chrome",
    "org.mozilla.firefox",
    "com.microsoft.edgemac",
    "com.operasoftware.Opera",
    "com.brave.Browser",
    "com.vivaldi.Vivaldi",
    "company.thebrowser.Browser",
    "org.chromium.Chromium"
]

private let appVocabularyBrowserContentRoles: Set<String> = [
    "AXWebArea",
    "AXStaticText",
    "AXTextArea",
    "AXLink",
    "AXHeading",
    "AXGroup"
]

private enum VocabularySource {
    case appName
    case windowTitle
    case title
    case label
    case placeholder
    case description
    case help
    case value
}

private struct VocabularySnippet {
    let text: String
    let source: VocabularySource
}

private struct VocabularyCandidate {
    var token: String
    var score: Int
    var count: Int
}

/// Extracts vocabulary-like terms (names, nouns, identifiers) from the frontmost app lazily at execution time.
/// Output is a comma-separated list suitable for prompt placeholders.
func getAppVocabulary() -> String {
    guard AXIsProcessTrusted() else {
        logDebug("[AppVocabulary] No accessibility permissions, cannot get app vocabulary")
        return ""
    }

    guard let frontApp = NSWorkspace.shared.frontmostApplication else {
        logDebug("[AppVocabulary] No frontmost application found")
        return ""
    }

    let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
    var snippets: [VocabularySnippet] = []
    let directInputContent = getInputFieldContent(appElement: appElement)
    let hasDirectInputContent = !(directInputContent?.isEmpty ?? true)
    let isBrowserApp = appVocabularyBrowserBundleIds.contains(frontApp.bundleIdentifier ?? "")

    if let appName = frontApp.localizedName, !appName.isEmpty {
        let cleaned = normalizeVocabularySnippet(appName, source: .appName)
        if !cleaned.isEmpty {
            snippets.append(VocabularySnippet(text: cleaned, source: .appName))
        }
    }

    var focusedWindow: CFTypeRef?
    let focusedWindowError = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
    if focusedWindowError == .success, let focusedWindow = focusedWindow {
        let windowElement = focusedWindow as! AXUIElement
        var windowTitleValue: CFTypeRef?
        let windowTitleError = AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &windowTitleValue)
        if windowTitleError == .success, let title = windowTitleValue as? String, !title.isEmpty {
            let cleaned = normalizeVocabularySnippet(title, source: .windowTitle)
            if !cleaned.isEmpty {
                snippets.append(VocabularySnippet(text: cleaned, source: .windowTitle))
            }
        }

        // When focused input content is available, avoid broad window crawling to reduce UI noise.
        if !hasDirectInputContent {
            if isBrowserApp {
                if let webArea = findFirstElement(withRole: "AXWebArea", from: windowElement, maxDepth: 10, maxNodes: 2200) {
                    if let parameterizedWebText = extractWebAreaParameterizedText(webArea, maxCharacters: 12000) {
                        let cleaned = normalizeVocabularySnippet(parameterizedWebText, source: .description)
                        if !cleaned.isEmpty {
                            snippets.append(VocabularySnippet(text: cleaned, source: .description))
                        }
                    }

                    let webSnippets = collectVocabularySnippets(
                        from: webArea,
                        maxDepth: 6,
                        maxNodes: 900,
                        maxSnippets: 700
                    )
                    snippets.append(contentsOf: webSnippets)
                }
            } else {
                let windowSnippets = collectVocabularySnippets(
                    from: windowElement,
                    maxDepth: appVocabularyMaxTraversalDepth,
                    maxNodes: appVocabularyMaxVisitedNodes,
                    maxSnippets: appVocabularyMaxSnippets
                )
                snippets.append(contentsOf: windowSnippets)
            }
        }
    }

    // Use the same focused-element data paths as appContext for better reliability in input-field workflows.
    if let inputContent = directInputContent, !inputContent.isEmpty {
        let cleaned = normalizeVocabularySnippet(inputContent, source: .value)
        if !cleaned.isEmpty {
            snippets.append(VocabularySnippet(text: cleaned, source: .value))
        }
    }

    if let elementDescription = getFocusedElementDescription(appElement: appElement), !elementDescription.isEmpty {
        let cleaned = normalizeVocabularySnippet(elementDescription, source: .description)
        if !cleaned.isEmpty {
            snippets.append(VocabularySnippet(text: cleaned, source: .description))
        }
    }

    if let focusedRawText = getFocusedElementRawText(appElement: appElement), !focusedRawText.isEmpty {
        let cleaned = normalizeVocabularySnippet(focusedRawText, source: .description)
        if !cleaned.isEmpty {
            snippets.append(VocabularySnippet(text: cleaned, source: .description))
        }
    }

    var focusedElement: CFTypeRef?
    let focusedElementError = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    if !hasDirectInputContent, focusedElementError == .success, let focusedElement = focusedElement {
        let focusedAx = focusedElement as! AXUIElement
        if isBrowserApp, let role = getAXRole(of: focusedAx), !appVocabularyBrowserContentRoles.contains(role) {
            // Ignore focused browser chrome widgets when outside input fields.
        } else {
            let focusedSnippets = collectVocabularySnippets(
                from: focusedAx,
                maxDepth: isBrowserApp ? 3 : 2,
                maxNodes: isBrowserApp ? 180 : 90,
                maxSnippets: isBrowserApp ? 220 : 100
            )
            snippets.append(contentsOf: focusedSnippets)
        }
    }

    let tokens = extractVocabularyTokens(
        from: snippets,
        maxTokens: appVocabularyMaxOutputTokens,
        isInputFocused: hasDirectInputContent,
        isBrowserApp: isBrowserApp
    )
    if tokens.isEmpty {
        logDebug("[AppVocabulary] No vocabulary terms extracted")
        return ""
    }

    let result = tokens.joined(separator: ", ")
    logDebug("[AppVocabulary] Extracted \(tokens.count) vocabulary terms")
    return result
}

private func collectVocabularySnippets(
    from root: AXUIElement,
    maxDepth: Int,
    maxNodes: Int,
    maxSnippets: Int,
    excludedRoles: Set<String> = []
) -> [VocabularySnippet] {
    var snippets: [VocabularySnippet] = []
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var index = 0
    var visitedCount = 0

    while index < queue.count && visitedCount < maxNodes && snippets.count < maxSnippets {
        let (element, depth) = queue[index]
        index += 1
        visitedCount += 1

        let role = getAXRole(of: element)
        if role == nil || !excludedRoles.contains(role!) {
            let elementSnippets = getVocabularyTextAttributes(from: element)
            for snippet in elementSnippets {
                if snippets.count >= maxSnippets {
                    break
                }
                snippets.append(snippet)
            }
        }

        if depth >= maxDepth {
            continue
        }

        var childrenValue: CFTypeRef?
        let childrenError = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        if childrenError == .success, let children = childrenValue as? [AXUIElement], !children.isEmpty {
            for child in children {
                queue.append((child, depth + 1))
                if queue.count >= (maxNodes * 2) {
                    break
                }
            }
        }
    }

    return snippets
}

private func getAXRole(of element: AXUIElement) -> String? {
    var roleValue: CFTypeRef?
    let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
    guard roleError == .success, let role = roleValue as? String, !role.isEmpty else {
        return nil
    }
    return role
}

private func findFirstElement(withRole targetRole: String, from root: AXUIElement, maxDepth: Int, maxNodes: Int) -> AXUIElement? {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var index = 0
    var visited = 0

    while index < queue.count, visited < maxNodes {
        let (element, depth) = queue[index]
        index += 1
        visited += 1

        if getAXRole(of: element) == targetRole {
            return element
        }

        if depth >= maxDepth {
            continue
        }

        var childrenValue: CFTypeRef?
        let childrenError = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        if childrenError == .success, let children = childrenValue as? [AXUIElement], !children.isEmpty {
            for child in children {
                queue.append((child, depth + 1))
            }
        }
    }

    return nil
}

private func buildBrowserWebContentSample(from webArea: AXUIElement, maxCharacters: Int) -> String {
    if let parameterizedText = extractWebAreaParameterizedText(webArea, maxCharacters: maxCharacters), !parameterizedText.isEmpty {
        return parameterizedText
    }

    let snippets = collectVocabularySnippets(
        from: webArea,
        maxDepth: 5,
        maxNodes: 900,
        maxSnippets: 700
    )

    var seen = Set<String>()
    var parts: [String] = []
    var currentLength = 0

    for snippet in snippets {
        let compact = snippet.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count >= 4 else { continue }
        guard !seen.contains(compact) else { continue }
        seen.insert(compact)

        let separator = parts.isEmpty ? 0 : 1
        if currentLength + separator + compact.count > maxCharacters {
            break
        }
        parts.append(compact)
        currentLength += separator + compact.count
    }

    return parts.joined(separator: "\n")
}

private func extractWebAreaParameterizedText(_ webArea: AXUIElement, maxCharacters: Int) -> String? {
    if let fullRange = getWebAreaCharacterRange(webArea),
       let text = copyParameterizedText(from: webArea, range: fullRange),
       !text.isEmpty {
        return trimToMaximumCharacters(text, maxCharacters: maxCharacters)
    }

    if let visibleRange = getWebAreaVisibleRange(webArea),
       let text = copyParameterizedText(from: webArea, range: visibleRange),
       !text.isEmpty {
        return trimToMaximumCharacters(text, maxCharacters: maxCharacters)
    }

    return nil
}

private func getWebAreaCharacterRange(_ webArea: AXUIElement) -> CFRange? {
    var charactersValue: CFTypeRef?
    let countError = AXUIElementCopyAttributeValue(webArea, "AXNumberOfCharacters" as CFString, &charactersValue)
    if countError == .success,
       let number = charactersValue as? NSNumber {
        let count = max(0, number.intValue)
        return CFRange(location: 0, length: count)
    }
    return nil
}

private func getWebAreaVisibleRange(_ webArea: AXUIElement) -> CFRange? {
    var visibleRangeValue: CFTypeRef?
    let rangeError = AXUIElementCopyAttributeValue(webArea, "AXVisibleCharacterRange" as CFString, &visibleRangeValue)
    guard rangeError == .success,
          let visibleRangeValue = visibleRangeValue,
          CFGetTypeID(visibleRangeValue) == AXValueGetTypeID() else {
        return nil
    }

    let axRange = unsafeBitCast(visibleRangeValue, to: AXValue.self)
    guard AXValueGetType(axRange) == .cfRange else { return nil }

    var range = CFRange(location: 0, length: 0)
    guard AXValueGetValue(axRange, .cfRange, &range) else {
        return nil
    }
    return range
}

private func copyParameterizedText(from element: AXUIElement, range: CFRange) -> String? {
    var mutableRange = range
    guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else {
        return nil
    }

    var textValue: CFTypeRef?
    let stringError = AXUIElementCopyParameterizedAttributeValue(element, "AXStringForRange" as CFString, rangeValue, &textValue)
    if stringError == .success, let text = textValue as? String, !text.isEmpty {
        return text
    }

    textValue = nil
    let attributedError = AXUIElementCopyParameterizedAttributeValue(element, "AXAttributedStringForRange" as CFString, rangeValue, &textValue)
    if attributedError == .success, let attributed = textValue as? NSAttributedString, !attributed.string.isEmpty {
        return attributed.string
    }

    return nil
}

private func trimToMaximumCharacters(_ text: String, maxCharacters: Int) -> String {
    let compact = text
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    guard compact.count > maxCharacters else { return compact }
    return String(compact.prefix(maxCharacters))
}

private func getFocusedElementRawText(appElement: AXUIElement) -> String? {
    var focusedElement: CFTypeRef?
    let focusedError = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    guard focusedError == .success, let focusedElement = focusedElement else {
        return nil
    }

    let element = focusedElement as! AXUIElement
    let prioritizedAttributes: [CFString] = [
        kAXDescriptionAttribute as CFString,
        kAXValueAttribute as CFString,
        kAXTitleAttribute as CFString,
        kAXHelpAttribute as CFString
    ]

    var bestText: String?
    for attribute in prioritizedAttributes {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success, let value = value else { continue }

        let extracted = extractTextValuesFromAXAttribute(value)
        for candidate in extracted {
            let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count >= 20 else { continue }
            if bestText == nil || cleaned.count > bestText!.count {
                bestText = cleaned
            }
        }
    }

    return bestText
}

private func getVocabularyTextAttributes(from element: AXUIElement) -> [VocabularySnippet] {
    let attributes: [(name: CFString, source: VocabularySource)] = [
        (kAXTitleAttribute as CFString, .title),
        ("AXLabel" as CFString, .label),
        (kAXDescriptionAttribute as CFString, .description),
        (kAXHelpAttribute as CFString, .help),
        ("AXPlaceholderValue" as CFString, .placeholder),
        (kAXValueAttribute as CFString, .value)
    ]

    var snippets: [VocabularySnippet] = []
    for (attribute, source) in attributes {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success, let value = value else { continue }
        let rawTexts = extractTextValuesFromAXAttribute(value)
        guard !rawTexts.isEmpty else { continue }

        var seen = Set<String>()
        for text in rawTexts {
            let cleaned = normalizeVocabularySnippet(text, source: source)
            guard !cleaned.isEmpty else { continue }
            if seen.contains(cleaned) { continue }
            seen.insert(cleaned)
            snippets.append(VocabularySnippet(text: cleaned, source: source))
        }
    }

    return snippets
}

private func normalizeVocabularySnippet(_ text: String, source: VocabularySource) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    let compact = trimmed
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    guard compact.count > 1 else { return "" }

    let maxLength: Int
    switch source {
    case .value:
        maxLength = appVocabularyMaxValueSnippetLength
    case .description, .title, .help:
        maxLength = appVocabularyMaxLongTextSnippetLength
    default:
        maxLength = appVocabularyMaxSnippetLength
    }
    if compact.count > maxLength {
        return String(compact.prefix(maxLength))
    }
    return compact
}

private func extractTextValuesFromAXAttribute(_ value: Any) -> [String] {
    var results: [String] = []
    appendTextValues(from: value, into: &results, depth: 0, maxDepth: 4)

    var deduped: [String] = []
    var seen = Set<String>()
    for raw in results {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { continue }
        if seen.contains(cleaned) { continue }
        seen.insert(cleaned)
        deduped.append(cleaned)
    }
    return deduped
}

private func appendTextValues(from value: Any, into results: inout [String], depth: Int, maxDepth: Int) {
    guard depth <= maxDepth else { return }

    if let str = value as? String {
        results.append(str)
        return
    }

    if let attributed = value as? NSAttributedString {
        results.append(attributed.string)
        return
    }

    if value is NSNumber || value is NSNull || value is Bool {
        return
    }

    if let array = value as? [Any] {
        for item in array {
            appendTextValues(from: item, into: &results, depth: depth + 1, maxDepth: maxDepth)
        }
        return
    }

    if let nsArray = value as? NSArray {
        for item in nsArray {
            appendTextValues(from: item, into: &results, depth: depth + 1, maxDepth: maxDepth)
        }
        return
    }

    if let dict = value as? [String: Any] {
        for dictValue in dict.values {
            appendTextValues(from: dictValue, into: &results, depth: depth + 1, maxDepth: maxDepth)
        }
        return
    }

    if let nsDict = value as? NSDictionary {
        for dictValue in nsDict.allValues {
            appendTextValues(from: dictValue, into: &results, depth: depth + 1, maxDepth: maxDepth)
        }
        return
    }

    if let object = value as? NSObject {
        let candidateSelectors = ["label", "value", "title", "string", "attributedValue", "attributedString"]
        for selectorName in candidateSelectors {
            let selector = NSSelectorFromString(selectorName)
            guard object.responds(to: selector), let unmanaged = object.perform(selector) else { continue }
            appendTextValues(from: unmanaged.takeUnretainedValue(), into: &results, depth: depth + 1, maxDepth: maxDepth)
        }
    }
}

private func extractVocabularyTokens(
    from snippets: [VocabularySnippet],
    maxTokens: Int,
    isInputFocused: Bool,
    isBrowserApp: Bool
) -> [String] {
    let tokenRegex = try? NSRegularExpression(pattern: "\\b[\\p{L}_][\\p{L}\\p{N}_]{1,}\\b", options: [])
    let identifierRegex = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}_-])(?:--)?[\\p{L}_][\\p{L}\\p{N}_-]{1,}(?:\\.[\\p{L}\\p{N}_-]+)*(?![\\p{L}\\p{N}_-])",
        options: []
    )
    let nlTokenBonuses = buildNaturalLanguageTokenBonuses(from: snippets)
    var candidates: [String: VocabularyCandidate] = [:]

    for snippet in snippets {
        let range = NSRange(snippet.text.startIndex..., in: snippet.text)
        var processedRanges = Set<String>()

        if let tokenRegex = tokenRegex {
            let matches = tokenRegex.matches(in: snippet.text, options: [], range: range)
            for match in matches {
                let rangeKey = "\(match.range.location):\(match.range.length)"
                if processedRanges.contains(rangeKey) { continue }
                processedRanges.insert(rangeKey)
                guard let tokenRange = Range(match.range, in: snippet.text) else { continue }
                let token = String(snippet.text[tokenRange])
                guard shouldKeepVocabularyToken(token, source: snippet.source) else { continue }
                let isSentenceStart = isLikelySentenceStartToken(in: snippet.text, matchRange: match.range)
                let tokenScore = scoreVocabularyToken(
                    token,
                    source: snippet.source,
                    isSentenceStart: isSentenceStart,
                    isInputFocused: isInputFocused,
                    isBrowserApp: isBrowserApp,
                    nlBonus: nlTokenBonuses[token.lowercased()] ?? 0
                )
                upsertVocabularyCandidate(token: token, score: tokenScore, candidates: &candidates)
            }
        }

        if let identifierRegex = identifierRegex {
            let matches = identifierRegex.matches(in: snippet.text, options: [], range: range)
            for match in matches {
                let rangeKey = "\(match.range.location):\(match.range.length)"
                if processedRanges.contains(rangeKey) { continue }
                processedRanges.insert(rangeKey)
                guard let tokenRange = Range(match.range, in: snippet.text) else { continue }
                let token = String(snippet.text[tokenRange])
                guard shouldKeepVocabularyToken(token, source: snippet.source) else { continue }
                let isSentenceStart = isLikelySentenceStartToken(in: snippet.text, matchRange: match.range)
                let tokenScore = scoreVocabularyToken(
                    token,
                    source: snippet.source,
                    isSentenceStart: isSentenceStart,
                    isInputFocused: isInputFocused,
                    isBrowserApp: isBrowserApp,
                    nlBonus: nlTokenBonuses[token.lowercased()] ?? 0
                )
                upsertVocabularyCandidate(token: token, score: tokenScore, candidates: &candidates)
            }
        }
    }

    let sorted = candidates.values.sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        if $0.count != $1.count { return $0.count > $1.count }
        return $0.token.localizedCaseInsensitiveCompare($1.token) == .orderedAscending
    }

    let minimumScore = 3
    return sorted
        .filter { $0.score >= minimumScore }
        .prefix(maxTokens)
        .map { $0.token }
}

private func shouldKeepVocabularyToken(_ token: String, source: VocabularySource) -> Bool {
    if token.count < 2 {
        return false
    }

    let trimmedToken = token.hasPrefix("--") ? String(token.dropFirst(2)) : token
    guard trimmedToken.count >= 2 else { return false }

    let lowercase = trimmedToken.lowercased()
    if appVocabularyStopWords.contains(lowercase) {
        return false
    }

    if lowercase.hasPrefix("ax") {
        return false
    }

    if lowercase.hasPrefix("http") || lowercase.hasPrefix("www") {
        return false
    }

    if trimmedToken.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
        return false
    }

    if isLikelyInternalUIToken(trimmedToken) {
        return false
    }

    // Keep short tokens only when they match useful acronyms.
    if trimmedToken.count <= 2 {
        return appVocabularyAllowedShortAcronyms.contains(trimmedToken.uppercased())
    }

    // Global strictness: keep only structured identifier-like tokens or title/upper-case terms.
    if !isPreferredVocabularyToken(token: token, trimmedToken: trimmedToken) {
        return false
    }

    return true
}

private func isPreferredVocabularyToken(token: String, trimmedToken: String) -> Bool {
    if token.hasPrefix("--") {
        return true
    }

    if looksIdentifierLike(trimmedToken) {
        return true
    }

    if trimmedToken.first?.isUppercase == true {
        return true
    }

    let hasLetter = trimmedToken.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    if hasLetter && trimmedToken == trimmedToken.uppercased() && trimmedToken.count >= 2 {
        return true
    }

    return false
}

private func scoreVocabularyToken(
    _ token: String,
    source: VocabularySource,
    isSentenceStart: Bool,
    isInputFocused: Bool,
    isBrowserApp: Bool,
    nlBonus: Int
) -> Int {
    var score = baseScore(for: source)

    if token.first?.isUppercase == true {
        score += 2
    } else {
        if source == .value || source == .description {
            score += 0
        } else {
            score -= 2
        }
    }

    if looksIdentifierLike(token) {
        score += 5
    }

    if hasMixedCaps(token) {
        score += 3
    }

    if token == token.uppercased(), token.count <= 8 {
        score += 2
    }

    if token.hasPrefix("--") {
        score += 4
    }

    if token.contains("-") {
        score += 2
    }

    if token == token.lowercased() && token.count > 3 {
        if source == .value || source == .description {
            score -= 1
        } else {
            score -= 3
        }
    }

    // Strongly suppress sentence-initial prose words from focused field content.
    if source == .value && isSentenceStart && !looksIdentifierLike(token) {
        score -= 2
    }

    if !isInputFocused && (source == .label || source == .title || source == .placeholder) {
        score -= 2
    }

    if isBrowserApp && !isInputFocused {
        if source == .appName {
            score -= 5
        } else if source == .windowTitle {
            score -= 2
        }
    }

    if isBrowserApp && !looksIdentifierLike(token) {
        score += nlBonus
    } else {
        score += (nlBonus / 2)
    }

    return score
}

private func baseScore(for source: VocabularySource) -> Int {
    switch source {
    case .appName: return 8
    case .windowTitle: return 6
    case .title: return 4
    case .label: return 4
    case .placeholder: return 3
    case .description: return 4
    case .help: return 2
    case .value: return 5
    }
}

private func looksIdentifierLike(_ token: String) -> Bool {
    if token.contains("_") {
        return true
    }

    if token.contains("-") {
        return true
    }

    let hasUppercase = token.contains { $0.isUppercase }
    let hasLowercase = token.contains { $0.isLowercase }
    if hasUppercase && hasLowercase {
        return true // camelCase / PascalCase
    }

    let hasLetter = token.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    let hasDigit = token.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    if hasLetter && hasDigit {
        return true
    }

    return false
}

private func upsertVocabularyCandidate(token: String, score: Int, candidates: inout [String: VocabularyCandidate]) {
    let key = token.lowercased()
    if var existing = candidates[key] {
        existing.count += 1
        if score > existing.score {
            existing.score = score
            existing.token = token
        }
        candidates[key] = existing
    } else {
        candidates[key] = VocabularyCandidate(token: token, score: score, count: 1)
    }
}

private func buildNaturalLanguageTokenBonuses(from snippets: [VocabularySnippet]) -> [String: Int] {
    var bonuses: [String: Int] = [:]

    for snippet in snippets {
        guard !snippet.text.isEmpty else { continue }
        let text = snippet.text
        let fullRange = text.startIndex..<text.endIndex

        let lexicalTagger = NLTagger(tagSchemes: [.lexicalClass])
        lexicalTagger.string = text
        lexicalTagger.enumerateTags(in: fullRange, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            guard let tag = tag else { return true }
            if tag == .noun {
                let token = String(text[range])
                addNaturalLanguageBonus(for: token, amount: 2, bonuses: &bonuses)
            }
            return true
        }

        let nameTagger = NLTagger(tagSchemes: [.nameType])
        nameTagger.string = text
        nameTagger.enumerateTags(in: fullRange, unit: .word, scheme: .nameType, options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            guard let tag = tag else { return true }
            if tag == .personalName || tag == .placeName || tag == .organizationName {
                let token = String(text[range])
                addNaturalLanguageBonus(for: token, amount: 4, bonuses: &bonuses)
            }
            return true
        }
    }

    return bonuses
}

private func addNaturalLanguageBonus(for token: String, amount: Int, bonuses: inout [String: Int]) {
    let normalized = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,:;!?()[]{}<>"))
    guard normalized.count >= 2 else { return }
    let key = normalized.lowercased()
    bonuses[key, default: 0] += amount
}

private func hasMixedCaps(_ token: String) -> Bool {
    let hasUppercase = token.contains { $0.isUppercase }
    let hasLowercase = token.contains { $0.isLowercase }
    return hasUppercase && hasLowercase
}

private func isLikelySentenceStartToken(in text: String, matchRange: NSRange) -> Bool {
    if matchRange.location == 0 {
        return true
    }

    let nsText = text as NSString
    var index = matchRange.location - 1

    while index >= 0 {
        let previous = nsText.substring(with: NSRange(location: index, length: 1))
        if previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            index -= 1
            continue
        }

        return previous == "." || previous == "!" || previous == "?" || previous == "\n" || previous == ":" || previous == ";"
    }

    return true
}

private func isLikelyInternalUIToken(_ token: String) -> Bool {
    if token.hasPrefix("_") {
        return true
    }

    let internalPrefixes = ["NS", "SF", "AX", "UI", "WK", "CG", "CF", "MTK"]
    for prefix in internalPrefixes where token.hasPrefix(prefix) && token.count > prefix.count + 3 {
        if token.contains(where: { $0.isUppercase }) {
            return true
        }
    }

    let internalSuffixes = [
        "View", "Window", "Controller", "Editor", "Split", "Scroll", "Cell",
        "Button", "Field", "Toolbar", "Outline", "Table", "Collection", "Detached"
    ]
    for suffix in internalSuffixes where token.hasSuffix(suffix) {
        return true
    }

    return false
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
            logDebug("[AppContext] Successfully found full Arc URL via AppleScript: \(redactForLogs(scriptUrl))")
            return scriptUrl
        } else {
            // Fallback to accessibility method for basic domain
            if let arcUrl = findArcBrowserURL(windowElement) {
                logDebug("[AppContext] AppleScript failed, using accessibility Arc URL: \(redactForLogs(arcUrl))")
                return arcUrl
            }
        }
    }
    
    // Look for URL in address bar for other browsers
    let urlString = findAddressBarURL(windowElement)
    
    if let url = urlString, !url.isEmpty {
        logDebug("[AppContext] Successfully found URL: \(redactForLogs(url))")
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
                        logDebug("[ARC URL] Found Arc domain: \(redactForLogs(trimmed)), adding https://")
                        return "https://\(trimmed)"
                    } else if trimmed.hasPrefix("http") {
                        logDebug("[ARC URL] Found Arc URL with protocol: \(redactForLogs(trimmed))")
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
                        logDebug("[ARC APPLESCRIPT] Successfully retrieved full URL (approach \(index + 1)): \(redactForLogs(trimmed))")
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

/// Gets the description/label information of the currently focused element (without role)
private func getFocusedElementDescription(appElement: AXUIElement) -> String? {
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

/// Dumps focused window/focused element accessibility trees for frontmost app.
/// Intended for diagnostics when appContext/appVocabulary pick the wrong browser subtree.
func debugDumpFrontAppAccessibilityTree(maxDepth: Int = 4) {
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
        if let webArea = findFirstElement(withRole: "AXWebArea", from: focusedWindow as! AXUIElement, maxDepth: 10, maxNodes: 2200) {
            logInfo("[AXDump] Web area tree start (\(appName))")
            debugLogAllElements(webArea, depth: 0, maxDepth: maxDepth, prefix: "[AXDump][WebArea]")
        } else {
            logInfo("[AXDump] No AXWebArea found in focused window (\(appName))")
        }
    }

    print("AX dump complete. Share lines with prefix [AXDump] from the log file.")
}
