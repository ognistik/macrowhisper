import ApplicationServices
import Cocoa

var lastDetectedFrontApp: NSRunningApplication?

func requestAccessibilityPermission() -> Bool {
    let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
    return AXIsProcessTrustedWithOptions(options)
}

func isInInputField() -> Bool {

    
    // Get the frontmost application with a small delay to ensure accuracy
    var frontApp: NSRunningApplication?
    
    // Use a semaphore to make this synchronous
    let semaphore = DispatchSemaphore(value: 0)
    
    DispatchQueue.main.async {
        // Get fresh reference to frontmost app
        frontApp = NSWorkspace.shared.frontmostApplication
        semaphore.signal()
    }
    
    // Wait for the main thread to get the frontmost app
    _ = semaphore.wait(timeout: .now() + 0.1)
    
    guard let app = frontApp else {
        lastDetectedFrontApp = nil
        return false
    }
    
    // Log the detected app
    logInfo("Detected app: \(app)")
    
    // Store reference to current app
    lastDetectedFrontApp = app
    
    // Get the application's process ID and create accessibility element
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    
    // Get the focused UI element in the application
    var focusedElement: AnyObject?
    let focusedError = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
    
    if focusedError != .success || focusedElement == nil {
        return false
    }
    
    let axElement = focusedElement as! AXUIElement
    
    // Check role (fastest check)
    var roleValue: AnyObject?
    if AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue) == .success,
       let role = roleValue as? String {
        
        // Definitive input field roles - quick return
        let definiteInputRoles = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
        if definiteInputRoles.contains(role) {
            return true
        }
    }
    
    // Check subrole
    var subroleValue: AnyObject?
    if AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subroleValue) == .success,
       let subrole = subroleValue as? String {
        
        let definiteInputSubroles = ["AXSearchField", "AXSecureTextField", "AXTextInput"]
        if definiteInputSubroles.contains(subrole) {
            return true
        }
    }
    
    // Check editable attribute
    var editableValue: AnyObject?
    if AXUIElementCopyAttributeValue(axElement, "AXEditable" as CFString, &editableValue) == .success,
       let isEditable = editableValue as? Bool,
       isEditable {
        return true
    }
    
    // Only check actions if we haven't determined it's an input field yet
    var actionsRef: CFArray?
    if AXUIElementCopyActionNames(axElement, &actionsRef) == .success,
       let actions = actionsRef as? [String] {
        
        let inputActions = ["AXInsertText", "AXDelete"]
        if actions.contains(where: inputActions.contains) {
            return true
        }
    }
    
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