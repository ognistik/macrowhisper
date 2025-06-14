import ApplicationServices
import Cocoa

func requestAccessibilityPermission() -> Bool {
    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
    return AXIsProcessTrustedWithOptions(options)
}

func isInInputField() -> Bool {
    logInfo("[InputField] Starting input field detection")
    
    // Small delay to ensure UI has settled after transcription
    Thread.sleep(forTimeInterval: 0.05)
    
    // Check accessibility permissions first
    if !AXIsProcessTrusted() {
        logInfo("[InputField] ❌ Accessibility permissions not granted")
        return false
    }
    
    // Get the frontmost application - handle main thread case properly
    var frontApp: NSRunningApplication?
    
    if Thread.isMainThread {
        // We're already on the main thread, get the app directly
        frontApp = NSWorkspace.shared.frontmostApplication
        logInfo("[InputField] Getting frontmost app directly (main thread)")
    } else {
        // We're on a background thread, use semaphore
        logInfo("[InputField] Getting frontmost app via dispatch (background thread)")
        let semaphore = DispatchSemaphore(value: 0)
        
        DispatchQueue.main.async {
            frontApp = NSWorkspace.shared.frontmostApplication
            semaphore.signal()
        }
        
        // Wait for the main thread to get the frontmost app
        _ = semaphore.wait(timeout: .now() + 0.1)
    }
    
    guard let app = frontApp else {
        logInfo("[InputField] No frontmost app detected")
        lastDetectedFrontApp = nil
        return false
    }
    
    // Log the detected app
    logInfo("[InputField] Detected app: \(app.localizedName ?? "Unknown") (PID: \(app.processIdentifier))")
    
    // Store reference to current app
    lastDetectedFrontApp = app
    
    // Get the application's process ID and create accessibility element
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    
    // Get the focused UI element in the application
    var focusedElement: AnyObject?
    let focusedError = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    
    if focusedError != .success {
        logInfo("[InputField] Failed to get focused element, error: \(focusedError.rawValue)")
        return false
    }
    
    if focusedElement == nil {
        logInfo("[InputField] No focused element found")
        return false
    }
    
    let axElement = focusedElement as! AXUIElement
    logInfo("[InputField] Found focused element, checking attributes...")
    
    // Check role (fastest check)
    var roleValue: AnyObject?
    if AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue) == .success,
       let role = roleValue as? String {
        
        logInfo("[InputField] Element role: \(role)")
        
        // Definitive input field roles - quick return
        let definiteInputRoles = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
        if definiteInputRoles.contains(role) {
            logInfo("[InputField] ✅ Input field detected by role: \(role)")
            return true
        }
    } else {
        logInfo("[InputField] Could not get role attribute")
    }
    
    // Check subrole
    var subroleValue: AnyObject?
    if AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subroleValue) == .success,
       let subrole = subroleValue as? String {
        
        logInfo("[InputField] Element subrole: \(subrole)")
        
        let definiteInputSubroles = ["AXSearchField", "AXSecureTextField", "AXTextInput"]
        if definiteInputSubroles.contains(subrole) {
            logInfo("[InputField] ✅ Input field detected by subrole: \(subrole)")
            return true
        }
    } else {
        logInfo("[InputField] No subrole attribute found")
    }
    
    // Check editable attribute
    var editableValue: AnyObject?
    if AXUIElementCopyAttributeValue(axElement, "AXEditable" as CFString, &editableValue) == .success,
       let isEditable = editableValue as? Bool {
        
        logInfo("[InputField] Element editable: \(isEditable)")
        if isEditable {
            logInfo("[InputField] ✅ Input field detected by editable attribute")
            return true
        }
    } else {
        logInfo("[InputField] No editable attribute found")
    }
    
    // Only check actions if we haven't determined it's an input field yet
    var actionsRef: CFArray?
    if AXUIElementCopyActionNames(axElement, &actionsRef) == .success,
       let actions = actionsRef as? [String] {
        
        logInfo("[InputField] Element actions: \(actions)")
        
        let inputActions = ["AXInsertText", "AXDelete"]
        let foundInputActions = actions.filter { inputActions.contains($0) }
        if !foundInputActions.isEmpty {
            logInfo("[InputField] ✅ Input field detected by actions: \(foundInputActions)")
            return true
        }
    } else {
        logInfo("[InputField] Could not get actions")
    }
    
    logInfo("[InputField] ❌ No input field detected")
    return false
}

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

func simulateEscKeyPress(activeInsert: AppConfiguration.Insert?) {
    // First check if there's an insert-specific noEsc setting
    if let insert = activeInsert, let insertNoEsc = insert.noEsc {
        // Use the insert-specific setting if available
        if insertNoEsc {
            logInfo("ESC key simulation disabled by insert-specific noEsc setting")
            return
        }
    }
    // Otherwise fall back to the global setting
    else if let noEsc = globalConfigManager?.config.defaults.noEsc, noEsc == true {
        logInfo("ESC key simulation disabled by global noEsc setting")
        return
    }
    
    // Simulate ESC key press
    simulateKeyDown(key: 53)
} 