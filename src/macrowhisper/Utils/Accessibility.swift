import ApplicationServices
import Cocoa

private struct InputFieldDetectionCacheKey: Equatable {
    let appPid: pid_t
    let focusedElementHash: CFHashCode
}

private struct InputFieldDetectionCacheEntry {
    let key: InputFieldDetectionCacheKey
    let result: Bool
    let reason: String
    let timestamp: Date
}

private struct FocusedAXContext {
    let app: NSRunningApplication
    let element: AXUIElement
}

private var inputFieldDetectionCacheEntry: InputFieldDetectionCacheEntry?
private let inputFieldDetectionCacheValidity: TimeInterval = 0.5
private let inputFieldDetectionCacheQueue = DispatchQueue(label: "inputFieldDetectionCache", attributes: .concurrent)
private let axFrontAppRetryAttempts = 3
private let axFrontAppRetryDelay: TimeInterval = 0.02
private let recentAXFrontAppFallbackWindow: TimeInterval = 0.75
private var recentAXFrontApp: (app: NSRunningApplication, timestamp: Date)?
private let recentAXFrontAppQueue = DispatchQueue(label: "frontAppResolutionCache", attributes: .concurrent)
private let browserInsertionCandidateCacheValidity: TimeInterval = 1.0
private let browserInsertionCandidateCacheQueue = DispatchQueue(label: "browserInsertionCandidateCache", attributes: .concurrent)
private var browserInsertionCandidateCache: BrowserInsertionCandidateCacheEntry?

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

private func cacheRecentAXFrontApp(_ app: NSRunningApplication?) {
    recentAXFrontAppQueue.sync(flags: .barrier) {
        if let app, !app.isTerminated {
            recentAXFrontApp = (app: app, timestamp: Date())
        } else {
            recentAXFrontApp = nil
        }
    }
}

private func getRecentAXFrontApp(maxAge: TimeInterval = recentAXFrontAppFallbackWindow) -> NSRunningApplication? {
    recentAXFrontAppQueue.sync {
        guard let cached = recentAXFrontApp,
              Date().timeIntervalSince(cached.timestamp) <= maxAge,
              !cached.app.isTerminated else {
            return nil
        }
        return cached.app
    }
}

private func runningApplication(for pid: pid_t?) -> NSRunningApplication? {
    guard let pid, pid > 0,
          let app = NSRunningApplication(processIdentifier: pid),
          !app.isTerminated else {
        return nil
    }
    return app
}

private func copyAXElementAttribute(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return unsafeBitCast(value, to: AXUIElement.self)
}

private func pidForAXElement(_ element: AXUIElement) -> pid_t? {
    var pid: pid_t = 0
    let error = AXUIElementGetPid(element, &pid)
    guard error == .success, pid > 0 else {
        return nil
    }
    return pid
}

private func getWorkspaceFrontmostApplication(timeout: TimeInterval = 0.1) -> NSRunningApplication? {
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

private func getAXFocusedElementOnce() -> AXUIElement? {
    let systemWideElement = AXUIElementCreateSystemWide()
    return copyAXElementAttribute(systemWideElement, attribute: kAXFocusedUIElementAttribute as CFString)
}

private func getAXFocusedApplicationOnce() -> NSRunningApplication? {
    if let focusedElement = getAXFocusedElementOnce(),
       let focusedElementApp = runningApplication(for: pidForAXElement(focusedElement)) {
        return focusedElementApp
    }

    let systemWideElement = AXUIElementCreateSystemWide()
    if let focusedAppElement = copyAXElementAttribute(systemWideElement, attribute: kAXFocusedApplicationAttribute as CFString),
       let focusedApp = runningApplication(for: pidForAXElement(focusedAppElement)) {
        return focusedApp
    }

    return nil
}

private func getAXFocusedApplicationWithRetries() -> NSRunningApplication? {
    guard AXIsProcessTrusted() else {
        return nil
    }

    for attempt in 0..<axFrontAppRetryAttempts {
        if let app = getAXFocusedApplicationOnce() {
            return app
        }

        if attempt + 1 < axFrontAppRetryAttempts {
            Thread.sleep(forTimeInterval: axFrontAppRetryDelay)
        }
    }

    return nil
}

private func getAXFocusedElementWithRetries() -> AXUIElement? {
    guard AXIsProcessTrusted() else {
        return nil
    }

    for attempt in 0..<axFrontAppRetryAttempts {
        if let focusedElement = getAXFocusedElementOnce() {
            return focusedElement
        }

        if attempt + 1 < axFrontAppRetryAttempts {
            Thread.sleep(forTimeInterval: axFrontAppRetryDelay)
        }
    }

    return nil
}

private func focusedAXContext(for app: NSRunningApplication) -> FocusedAXContext? {
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    guard let focusedElement = copyAXElementAttribute(appElement, attribute: kAXFocusedUIElementAttribute as CFString) else {
        return nil
    }
    return FocusedAXContext(app: app, element: focusedElement)
}

private func resolveFocusedAXContext(timeout: TimeInterval = 0.1) -> FocusedAXContext? {
    if let focusedElement = getAXFocusedElementWithRetries(),
       let app = runningApplication(for: pidForAXElement(focusedElement)) {
        cacheRecentAXFrontApp(app)
        globalState.lastDetectedFrontApp = app
        return FocusedAXContext(app: app, element: focusedElement)
    }

    if let recentApp = getRecentAXFrontApp(),
       let context = focusedAXContext(for: recentApp) {
        globalState.lastDetectedFrontApp = recentApp
        return context
    }

    let workspaceApp = getWorkspaceFrontmostApplication(timeout: timeout)
    if let workspaceApp,
       let context = focusedAXContext(for: workspaceApp) {
        globalState.lastDetectedFrontApp = workspaceApp
        return context
    }

    globalState.lastDetectedFrontApp = workspaceApp
    return nil
}

func resolveFrontApp(timeout: TimeInterval = 0.1) -> NSRunningApplication? {
    if let context = resolveFocusedAXContext(timeout: timeout) {
        return context.app
    }

    if let axFocusedApp = getAXFocusedApplicationWithRetries() {
        cacheRecentAXFrontApp(axFocusedApp)
        globalState.lastDetectedFrontApp = axFocusedApp
        return axFocusedApp
    }

    if let recentApp = getRecentAXFrontApp() {
        globalState.lastDetectedFrontApp = recentApp
        return recentApp
    }

    let workspaceApp = getWorkspaceFrontmostApplication(timeout: timeout)
    globalState.lastDetectedFrontApp = workspaceApp
    return workspaceApp
}

/// Fast front-app resolution for paths that only need the app identity, not the focused element.
/// Prefers NSWorkspace to avoid cold AX focused-element lookups during app startup.
func resolveFrontAppIdentity(timeout: TimeInterval = 0.1) -> NSRunningApplication? {
    if let workspaceApp = getWorkspaceFrontmostApplication(timeout: timeout), !workspaceApp.isTerminated {
        globalState.lastDetectedFrontApp = workspaceApp
        return workspaceApp
    }

    if let recentApp = getRecentAXFrontApp() {
        globalState.lastDetectedFrontApp = recentApp
        return recentApp
    }

    return resolveFrontApp(timeout: timeout)
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
    let startedAt = CFAbsoluteTimeGetCurrent()

    func finish(
        _ result: Bool,
        reason: String,
        cacheKey: InputFieldDetectionCacheKey? = nil
    ) -> Bool {
        let elapsedMs = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0).rounded())
        logDebug("[InputField] Completed detection result=\(result) elapsedMs=\(elapsedMs) reason=\(reason)")
        if let cacheKey {
            cacheInputFieldDetectionResult(result, reason: reason, for: cacheKey)
        }
        return result
    }

    logDebug("[InputField] Starting input field detection")

    if !AXIsProcessTrusted() {
        logDebug("[InputField] ❌ Accessibility permissions not granted")
        return finish(false, reason: "permissions")
    }

    guard let context = resolveFocusedAXContext() else {
        if resolveFrontApp() == nil {
            logDebug("[InputField] No frontmost app detected")
            globalState.lastDetectedFrontApp = nil
            return finish(false, reason: "noFrontApp")
        }
        logDebug("[InputField] No focused element found")
        return finish(false, reason: "noFocusedElement")
    }

    let app = context.app
    let axElement = context.element

    logDebug("[InputField] Detected app: \(app.localizedName ?? "Unknown") (PID: \(app.processIdentifier))")
    globalState.lastDetectedFrontApp = app

    let cacheKey = InputFieldDetectionCacheKey(
        appPid: app.processIdentifier,
        focusedElementHash: CFHash(axElement)
    )
    if let cached = cachedInputFieldDetectionResult(for: cacheKey) {
        let elapsedMs = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0).rounded())
        logDebug(
            "[InputField] Using cached input field detection result: \(cached.result) " +
            "elapsedMs=\(elapsedMs) reason=\(cached.reason)"
        )
        return cached.result
    }

    guard pidForAXElement(axElement) != nil else {
        logDebug("[InputField] Failed to resolve focused element PID")
        return finish(false, reason: "focusedElementPid", cacheKey: cacheKey)
    }

    if let focusedApp = runningApplication(for: pidForAXElement(axElement)),
       focusedApp.processIdentifier != app.processIdentifier {
        logDebug(
            "[InputField] Focused element PID mismatch: appPID=\(app.processIdentifier) " +
            "focusedPID=\(focusedApp.processIdentifier)"
        )
    }

    logDebug("[InputField] Found focused element, checking attributes...")

    var roleValue: AnyObject?
    if AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue) == .success,
       let role = roleValue as? String {

        logDebug("[InputField] Element role: \(role)")

        let definiteInputRoles = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
        if definiteInputRoles.contains(role) {
            logDebug("[InputField] ✅ Input field detected by role: \(role)")
            return finish(true, reason: "role:\(role)", cacheKey: cacheKey)
        }
    } else {
        logDebug("[InputField] Could not get role attribute")
    }

    var subroleValue: AnyObject?
    if AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subroleValue) == .success,
       let subrole = subroleValue as? String {

        logDebug("[InputField] Element subrole: \(subrole)")

        let definiteInputSubroles = ["AXSearchField", "AXSecureTextField", "AXTextInput"]
        if definiteInputSubroles.contains(subrole) {
            logDebug("[InputField] ✅ Input field detected by subrole: \(subrole)")
            return finish(true, reason: "subrole:\(subrole)", cacheKey: cacheKey)
        }
    } else {
        logDebug("[InputField] No subrole attribute found")
    }

    var editableValue: AnyObject?
    if AXUIElementCopyAttributeValue(axElement, "AXEditable" as CFString, &editableValue) == .success,
       let isEditable = editableValue as? Bool {

        logDebug("[InputField] Element editable: \(isEditable)")
        if isEditable {
            logDebug("[InputField] ✅ Input field detected by editable attribute")
            return finish(true, reason: "editable", cacheKey: cacheKey)
        }
    } else {
        logDebug("[InputField] No editable attribute found")
    }

    var actionsRef: CFArray?
    if AXUIElementCopyActionNames(axElement, &actionsRef) == .success,
       let actions = actionsRef as? [String] {

        logDebug("[InputField] Element actions: \(actions)")

        let inputActions = ["AXInsertText", "AXDelete"]
        let foundInputActions = actions.filter { inputActions.contains($0) }
        if !foundInputActions.isEmpty {
            logDebug("[InputField] ✅ Input field detected by actions: \(foundInputActions)")
            return finish(
                true,
                reason: "actions:\(foundInputActions.joined(separator: ","))",
                cacheKey: cacheKey
            )
        }
    } else {
        logInfo("[InputField] Could not get actions")
    }

    logInfo("[InputField] ❌ No input field detected")
    return finish(false, reason: "noMatch", cacheKey: cacheKey)
}

private func cachedInputFieldDetectionResult(
    for key: InputFieldDetectionCacheKey
) -> InputFieldDetectionCacheEntry? {
    inputFieldDetectionCacheQueue.sync {
        guard let cached = inputFieldDetectionCacheEntry,
              cached.key == key,
              Date().timeIntervalSince(cached.timestamp) < inputFieldDetectionCacheValidity else {
            return nil
        }
        return cached
    }
}

private func cacheInputFieldDetectionResult(
    _ result: Bool,
    reason: String,
    for key: InputFieldDetectionCacheKey
) {
    inputFieldDetectionCacheQueue.async(flags: .barrier) {
        inputFieldDetectionCacheEntry = InputFieldDetectionCacheEntry(
            key: key,
            result: result,
            reason: reason,
            timestamp: Date()
        )
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

    let browserAmbiguousNewlineBoundaryResolution: SmartInsertHeuristics.BrowserAmbiguousNewlineBoundaryResolution

    init(
        leftCharacter: Character?,
        leftNonWhitespaceCharacter: Character?,
        leftLinePrefix: String,
        rightCharacter: Character?,
        rightNonWhitespaceCharacter: Character?,
        rightHasLineBreakBeforeNextNonWhitespace: Bool,
        browserAmbiguousNewlineBoundaryResolution: SmartInsertHeuristics.BrowserAmbiguousNewlineBoundaryResolution = .unresolved
    ) {
        self.leftCharacter = leftCharacter
        self.leftNonWhitespaceCharacter = leftNonWhitespaceCharacter
        self.leftLinePrefix = leftLinePrefix
        self.rightCharacter = rightCharacter
        self.rightNonWhitespaceCharacter = rightNonWhitespaceCharacter
        self.rightHasLineBreakBeforeNextNonWhitespace = rightHasLineBreakBeforeNextNonWhitespace
        self.browserAmbiguousNewlineBoundaryResolution = browserAmbiguousNewlineBoundaryResolution
    }
}

private struct InputInsertionContextSnapshot {
    let element: AXUIElement
    let context: InputInsertionContext
    let role: String
    let textLength: Int
    let selectedRange: CFRange
    let depth: Int
    let neighborhood: String
    let fullText: String
}

private struct BrowserInsertionCandidateCacheEntry {
    let appPid: pid_t
    let rootHash: CFHashCode
    let element: AXUIElement
    let depth: Int
    let timestamp: Date
}

private enum BrowserInsertionReconciliationMethod: Int {
    case exactFragment = 2
    case caretAnchor = 1

    var label: String {
        switch self {
        case .exactFragment:
            return "exactFragment"
        case .caretAnchor:
            return "caretAnchor"
        }
    }
}

private struct BrowserInsertionReconciliation {
    let mappedRootRange: CFRange
    let deltaFromRootSelection: Int
    let matchedLength: Int
    let method: BrowserInsertionReconciliationMethod
}

private struct BrowserCaretAnchor {
    let text: String
    let caretOffset: Int
}

private func isIgnorableBoundaryCharacterForSmartInsert(_ character: Character?) -> Bool {
    guard let character = character else { return false }
    return SmartInsertBoundary.isIgnorableBoundaryCharacter(character)
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
func getInputInsertionContext(insertionText: String? = nil) -> InputInsertionContext? {
    if Thread.isMainThread {
        return readInputInsertionContext(insertionText: insertionText)
    }

    var context: InputInsertionContext?
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        context = readInputInsertionContext(insertionText: insertionText)
        semaphore.signal()
    }
    let waitResult = semaphore.wait(timeout: .now() + 0.2)
    if waitResult == .timedOut {
        logDebug("[SmartInsert] Timed out while reading insertion context on main thread")
    }
    return context
}

private func readInputInsertionContext(insertionText: String?) -> InputInsertionContext? {
    let startedAt = CFAbsoluteTimeGetCurrent()

    guard AXIsProcessTrusted() else {
        logDebug("[SmartInsert] No accessibility permissions, cannot get insertion context")
        return nil
    }

    guard let context = resolveFocusedAXContext(timeout: 0.2) else {
        logDebug("[SmartInsert] No frontmost application found")
        return nil
    }
    let frontApp = context.app
    let element = context.element

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

    guard let rootSnapshot = buildInputInsertionContextSnapshot(
        for: element,
        role: role,
        frontApp: frontApp,
        depth: 0
    ) else {
        return nil
    }

    let isBrowserApp = appVocabularyBrowserBundleIds.contains(frontApp.bundleIdentifier ?? "")
    let rootHash = CFHash(element)
    let shouldInspectDescendants = isBrowserApp && shouldInspectBrowserDescendants(rootSnapshot)

    var chosenSnapshot: InputInsertionContextSnapshot
    if shouldInspectDescendants,
       let cachedSnapshot = cachedBrowserInsertionContextSnapshot(
        appPid: frontApp.processIdentifier,
        rootHash: rootHash,
        frontApp: frontApp,
        rootSnapshot: rootSnapshot,
        insertionText: insertionText
       ) {
        chosenSnapshot = cachedSnapshot
        cacheBrowserInsertionCandidate(
            appPid: frontApp.processIdentifier,
            rootHash: rootHash,
            snapshot: cachedSnapshot
        )
    } else if shouldInspectDescendants,
              let descendantSnapshot = findBestBrowserInsertionContextSnapshot(
                from: element,
                frontApp: frontApp,
                rootSnapshot: rootSnapshot,
                insertionText: insertionText
              ) {
        chosenSnapshot = descendantSnapshot
        if descendantSnapshot.depth > 0 {
            cacheBrowserInsertionCandidate(
                appPid: frontApp.processIdentifier,
                rootHash: rootHash,
                snapshot: descendantSnapshot
            )
            if let reconciliation = reconcileBrowserInsertionSnapshot(descendantSnapshot, against: rootSnapshot) {
                logDebug(
                    "[SmartInsert] Browser subtree candidate reconciled method=\(reconciliation.method.label) " +
                    "mappedRootLocation=\(reconciliation.mappedRootRange.location) " +
                    "rootLocation=\(rootSnapshot.selectedRange.location) " +
                    "delta=\(reconciliation.deltaFromRootSelection) matchedLength=\(reconciliation.matchedLength)"
                )
            }
            logDebug(
                "[SmartInsert] Browser subtree candidate chosen depth=\(descendantSnapshot.depth) " +
                "role=\(descendantSnapshot.role) range={location=\(descendantSnapshot.selectedRange.location), " +
                "length=\(descendantSnapshot.selectedRange.length)} textLength=\(descendantSnapshot.textLength) " +
                "neighborhood=\(descendantSnapshot.neighborhood)"
            )
        } else {
            clearBrowserInsertionCandidate(appPid: frontApp.processIdentifier, rootHash: rootHash)
        }
    } else {
        clearBrowserInsertionCandidate(appPid: frontApp.processIdentifier, rootHash: rootHash)
        chosenSnapshot = rootSnapshot
    }

    if isBrowserApp && chosenSnapshot.depth == 0 && chosenSnapshot.selectedRange.length == 0 {
        if let corrected = correctBrowserOffByOneUsingDescendants(
            rootSnapshot: chosenSnapshot,
            rootElement: element,
            frontApp: frontApp
        ) {
            chosenSnapshot = corrected
        }
    }

    let effectiveSnapshot: InputInsertionContextSnapshot
    if isBrowserApp {
        effectiveSnapshot = resolvedBrowserInsertionContextSnapshot(from: chosenSnapshot)
    } else {
        effectiveSnapshot = chosenSnapshot
    }

    logDebug(
        "[SmartInsert] Live AX read app=\(frontApp.bundleIdentifier ?? "unknown") role=\(effectiveSnapshot.role) " +
        "range={location=\(effectiveSnapshot.selectedRange.location), length=\(effectiveSnapshot.selectedRange.length)} " +
        "textLength=\(effectiveSnapshot.textLength) thread=\(Thread.isMainThread ? "main" : "background") " +
        "depth=\(effectiveSnapshot.depth) neighborhood=\(effectiveSnapshot.neighborhood) " +
        "elapsedMs=\(Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0).rounded()))"
    )

    return effectiveSnapshot.context
}

private func shouldInspectBrowserDescendants(_ rootSnapshot: InputInsertionContextSnapshot) -> Bool {
    let hasLeftEvidence =
        rootSnapshot.context.leftCharacter != nil || rootSnapshot.context.leftNonWhitespaceCharacter != nil
    let hasRightEvidence =
        rootSnapshot.context.rightCharacter != nil || rootSnapshot.context.rightNonWhitespaceCharacter != nil

    let evidence = SmartInsertHeuristics.BrowserRootSelectionEvidence(
        selectionLocation: rootSnapshot.selectedRange.location,
        selectionLength: rootSnapshot.selectedRange.length,
        textLength: rootSnapshot.textLength,
        hasLeftEvidence: hasLeftEvidence,
        hasRightEvidence: hasRightEvidence
    )
    return SmartInsertHeuristics.shouldInspectBrowserDescendants(evidence)
}

private func cachedBrowserInsertionContextSnapshot(
    appPid: pid_t,
    rootHash: CFHashCode,
    frontApp: NSRunningApplication,
    rootSnapshot: InputInsertionContextSnapshot,
    insertionText: String?
) -> InputInsertionContextSnapshot? {
    guard let cacheEntry = currentBrowserInsertionCandidate(appPid: appPid, rootHash: rootHash) else {
        return nil
    }

    let role = copyAXRole(from: cacheEntry.element)
    guard shouldConsiderBrowserSelectionCandidate(cacheEntry.element, roleHint: role),
          let snapshot = buildInputInsertionContextSnapshot(
            for: cacheEntry.element,
            role: role ?? "unknown",
            frontApp: frontApp,
            depth: cacheEntry.depth
          ),
          let reconciliation = reconcileBrowserInsertionSnapshot(snapshot, against: rootSnapshot) else {
        clearBrowserInsertionCandidate(appPid: appPid, rootHash: rootHash)
        return nil
    }

    let cachedScore = browserInsertionSnapshotScore(
        snapshot,
        insertionText: insertionText,
        reconciliation: reconciliation
    )
    let rootScore = browserInsertionSnapshotScore(
        rootSnapshot,
        insertionText: insertionText,
        reconciliation: nil
    )
    guard cachedScore >= rootScore else {
        clearBrowserInsertionCandidate(appPid: appPid, rootHash: rootHash)
        return nil
    }

    logDebug(
        "[SmartInsert] Reused cached browser subtree candidate depth=\(snapshot.depth) " +
        "role=\(snapshot.role) method=\(reconciliation.method.label) " +
        "delta=\(reconciliation.deltaFromRootSelection) matchedLength=\(reconciliation.matchedLength)"
    )
    return snapshot
}

private func buildInputInsertionContextSnapshot(
    for element: AXUIElement,
    role: String,
    frontApp: NSRunningApplication,
    depth: Int
) -> InputInsertionContextSnapshot? {
    var valueRef: CFTypeRef?
    let valueError = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
    guard valueError == .success, let valueRef = valueRef, let fullText = valueRef as? String else {
        if depth == 0 {
            logDebug("[SmartInsert] Could not get AXValue as String")
        }
        return nil
    }

    var selectedRangeRef: CFTypeRef?
    let selectedRangeError = AXUIElementCopyAttributeValue(element, "AXSelectedTextRange" as CFString, &selectedRangeRef)
    guard selectedRangeError == .success, let selectedRangeRef = selectedRangeRef else {
        if depth == 0 {
            logDebug("[SmartInsert] Could not get AXSelectedTextRange")
        }
        return nil
    }

    guard CFGetTypeID(selectedRangeRef) == AXValueGetTypeID(),
          AXValueGetType(selectedRangeRef as! AXValue) == .cfRange else {
        if depth == 0 {
            logDebug("[SmartInsert] AXSelectedTextRange has unexpected type")
        }
        return nil
    }

    var selectedRange = CFRange(location: 0, length: 0)
    guard AXValueGetValue(selectedRangeRef as! AXValue, .cfRange, &selectedRange) else {
        if depth == 0 {
            logDebug("[SmartInsert] Failed to decode AXSelectedTextRange value")
        }
        return nil
    }

    guard selectedRange.location >= 0, selectedRange.length >= 0 else {
        if depth == 0 {
            logDebug("[SmartInsert] AXSelectedTextRange has invalid negative values")
        }
        return nil
    }

    let nsText = fullText as NSString
    let textLength = nsText.length
    let insertionStart = Int(selectedRange.location)
    let insertionEnd = insertionStart + Int(selectedRange.length)

    guard insertionStart <= textLength, insertionEnd <= textLength else {
        if depth == 0 {
            logDebug("[SmartInsert] AXSelectedTextRange is out of bounds for AXValue")
        }
        return nil
    }

    guard let context = deriveInputInsertionContext(fullText: fullText, selectedRange: selectedRange) else {
        if depth == 0 {
            logDebug("[SmartInsert] Failed to derive insertion context from AXValue")
        }
        return nil
    }

    return InputInsertionContextSnapshot(
        element: element,
        context: context,
        role: role,
        textLength: textLength,
        selectedRange: selectedRange,
        depth: depth,
        neighborhood: debugCaretNeighborhoodSnippet(fullText: fullText, selectedRange: selectedRange),
        fullText: fullText
    )
}

private func deriveInputInsertionContext(
    fullText: String,
    selectedRange: CFRange
) -> InputInsertionContext? {
    guard selectedRange.location >= 0, selectedRange.length >= 0 else {
        return nil
    }

    let nsText = fullText as NSString
    let textLength = nsText.length
    let insertionStart = Int(selectedRange.location)
    let insertionEnd = insertionStart + Int(selectedRange.length)

    guard insertionStart <= textLength, insertionEnd <= textLength else {
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

private func resolvedBrowserInsertionContextSnapshot(
    from snapshot: InputInsertionContextSnapshot
) -> InputInsertionContextSnapshot {
    let inlineCorrectedSnapshot = correctedBrowserInlineCaretDriftSnapshot(from: snapshot)
    let effectiveSnapshot: InputInsertionContextSnapshot
    if inlineCorrectedSnapshot.selectedRange.location == snapshot.selectedRange.location {
        effectiveSnapshot = correctedBrowserTextPatternCaretSnapshot(from: snapshot)
    } else {
        effectiveSnapshot = inlineCorrectedSnapshot
    }
    return resolvedBrowserAmbiguousNewlineSnapshot(from: effectiveSnapshot)
}

private func correctBrowserOffByOneUsingDescendants(
    rootSnapshot: InputInsertionContextSnapshot,
    rootElement: AXUIElement,
    frontApp: NSRunningApplication
) -> InputInsertionContextSnapshot? {
    var queue: [(element: AXUIElement, depth: Int)] = [(rootElement, 0)]
    var seen = Set<CFHashCode>()
    var visited = 0
    let maxDepth = 6
    let maxNodes = 200

    while !queue.isEmpty && visited < maxNodes {
        let current = queue.removeFirst()
        visited += 1

        let hash = CFHash(current.element)
        if !seen.insert(hash).inserted { continue }

        if current.depth > 0 {
            let role = copyAXRole(from: current.element)
            if shouldConsiderBrowserSelectionCandidate(current.element, roleHint: role),
               let snapshot = buildInputInsertionContextSnapshot(
                for: current.element,
                role: role ?? "unknown",
                frontApp: frontApp,
                depth: current.depth
               ),
               let corrected = validateBrowserOffByOneDescendant(
                snapshot,
                rootSnapshot: rootSnapshot
               ) {
                return corrected
            }
        }

        guard current.depth < maxDepth else { continue }
        for child in getAXTraversalChildren(of: current.element) {
            queue.append((child, current.depth + 1))
        }
    }

    return nil
}

private func validateBrowserOffByOneDescendant(
    _ candidate: InputInsertionContextSnapshot,
    rootSnapshot: InputInsertionContextSnapshot
) -> InputInsertionContextSnapshot? {
    guard candidate.depth > 0,
          candidate.textLength >= 10,
          candidate.textLength < rootSnapshot.textLength,
          candidate.fullText != rootSnapshot.fullText else {
        return nil
    }

    guard candidate.selectedRange.location >= 3 else {
        return nil
    }

    guard let matchedRange = uniqueBrowserTextRange(
        of: candidate.fullText,
        in: rootSnapshot.fullText
    ) else {
        return nil
    }

    let mappedLocation = matchedRange.location + candidate.selectedRange.location
    let rootLocation = rootSnapshot.selectedRange.location
    guard mappedLocation == rootLocation + 1 else {
        return nil
    }

    let mappedRange = CFRange(location: mappedLocation, length: rootSnapshot.selectedRange.length)
    guard let mappedContext = deriveInputInsertionContext(
        fullText: rootSnapshot.fullText,
        selectedRange: mappedRange
    ) else {
        return nil
    }

    guard browserContextsMatch(candidate.context, mappedContext) else {
        return nil
    }

    logDebug(
        "[SmartInsert] Browser off-by-one corrected via descendant rawLocation=\(rootLocation) " +
        "correctedLocation=\(mappedLocation) depth=\(candidate.depth) " +
        "matchedLength=\(matchedRange.length)"
    )

    return InputInsertionContextSnapshot(
        element: rootSnapshot.element,
        context: mappedContext,
        role: rootSnapshot.role,
        textLength: rootSnapshot.textLength,
        selectedRange: mappedRange,
        depth: rootSnapshot.depth,
        neighborhood: debugCaretNeighborhoodSnippet(
            fullText: rootSnapshot.fullText,
            selectedRange: mappedRange
        ),
        fullText: rootSnapshot.fullText
    )
}

private func correctedBrowserTextPatternCaretSnapshot(
    from snapshot: InputInsertionContextSnapshot
) -> InputInsertionContextSnapshot {
    guard snapshot.depth == 0,
          snapshot.selectedRange.length == 0 else {
        return snapshot
    }

    let nsText = snapshot.fullText as NSString
    var currentLocation = Int(snapshot.selectedRange.location)

    guard currentLocation > 0, currentLocation < snapshot.textLength else {
        return snapshot
    }

    let leftRange = nsText.rangeOfComposedCharacterSequence(at: currentLocation - 1)
    let rightRange = nsText.rangeOfComposedCharacterSequence(at: currentLocation)
    guard let leftChar = nsText.substring(with: leftRange).first,
          let rightChar = nsText.substring(with: rightRange).first else {
        return snapshot
    }

    let leftIsWord = leftChar.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    let rightIsTerminalPunctuation = ".!?".contains(rightChar)

    guard leftIsWord && rightIsTerminalPunctuation else {
        return snapshot
    }

    let afterPunctCursor = rightRange.location + rightRange.length
    if afterPunctCursor < snapshot.textLength {
        let afterRange = nsText.rangeOfComposedCharacterSequence(at: afterPunctCursor)
        if let afterChar = nsText.substring(with: afterRange).first,
           !afterChar.isWhitespace {
            return snapshot
        }
    }

    currentLocation = afterPunctCursor

    if currentLocation < snapshot.textLength {
        let newRightRange = nsText.rangeOfComposedCharacterSequence(at: currentLocation)
        if let newRight = nsText.substring(with: newRightRange).first,
           newRight == " " || newRight == "\u{00A0}" {
            var scanCursor = newRightRange.location + newRightRange.length
            while scanCursor < snapshot.textLength {
                let scanRange = nsText.rangeOfComposedCharacterSequence(at: scanCursor)
                if let c = nsText.substring(with: scanRange).first, !c.isWhitespace {
                    if String(c).rangeOfCharacter(from: .uppercaseLetters) != nil {
                        currentLocation = newRightRange.location + newRightRange.length
                    }
                    break
                }
                scanCursor = scanRange.location + scanRange.length
            }
        }
    }

    guard currentLocation != Int(snapshot.selectedRange.location) else {
        return snapshot
    }

    let correctedRange = CFRange(location: currentLocation, length: snapshot.selectedRange.length)
    guard let correctedContext = deriveInputInsertionContext(
        fullText: snapshot.fullText,
        selectedRange: correctedRange
    ) else {
        return snapshot
    }

    logDebug(
        "[SmartInsert] Browser text-pattern caret correction rawLocation=\(snapshot.selectedRange.location) " +
        "correctedLocation=\(currentLocation)"
    )

    return InputInsertionContextSnapshot(
        element: snapshot.element,
        context: correctedContext,
        role: snapshot.role,
        textLength: snapshot.textLength,
        selectedRange: correctedRange,
        depth: snapshot.depth,
        neighborhood: debugCaretNeighborhoodSnippet(
            fullText: snapshot.fullText,
            selectedRange: correctedRange
        ),
        fullText: snapshot.fullText
    )
}

private func correctedBrowserInlineCaretDriftSnapshot(
    from snapshot: InputInsertionContextSnapshot
) -> InputInsertionContextSnapshot {
    guard snapshot.depth == 0,
          snapshot.selectedRange.length == 0,
          let correctedRange = correctedBrowserInlineCaretDriftRange(from: snapshot),
          correctedRange.location != snapshot.selectedRange.location,
          let correctedContext = deriveInputInsertionContext(
            fullText: snapshot.fullText,
            selectedRange: correctedRange
          ) else {
        return snapshot
    }

    logDebug(
        "[SmartInsert] Browser inline caret drift corrected rawLocation=\(snapshot.selectedRange.location) " +
        "correctedLocation=\(correctedRange.location)"
    )

    return InputInsertionContextSnapshot(
        element: snapshot.element,
        context: correctedContext,
        role: snapshot.role,
        textLength: snapshot.textLength,
        selectedRange: correctedRange,
        depth: snapshot.depth,
        neighborhood: debugCaretNeighborhoodSnippet(fullText: snapshot.fullText, selectedRange: correctedRange),
        fullText: snapshot.fullText
    )
}

private func correctedBrowserInlineCaretDriftRange(
    from snapshot: InputInsertionContextSnapshot
) -> CFRange? {
    let insertionLocation = Int(snapshot.selectedRange.location)
    guard insertionLocation < snapshot.textLength else {
        return nil
    }

    guard let caretBounds = copyAXBoundsForRange(
        NSRange(location: insertionLocation, length: 0),
        from: snapshot.element
    ), caretBounds.height >= 2 else {
        return nil
    }

    var correctedLocation: Int?
    var candidateLocation = insertionLocation

    while candidateLocation < snapshot.textLength,
          let candidate = browserInlineCaretDriftCandidate(
            in: snapshot,
            at: candidateLocation,
            caretBounds: caretBounds
          ),
          SmartInsertHeuristics.shouldCorrectBrowserInlineCaretDrift(candidate.evidence) {
        correctedLocation = candidate.nextLocation
        if SmartInsertHeuristics.shouldStopBrowserInlineCaretDriftAfterCorrection(candidate.evidence) {
            break
        }
        candidateLocation = candidate.nextLocation
    }

    guard let correctedLocation, correctedLocation != insertionLocation else {
        return nil
    }

    return CFRange(location: correctedLocation, length: snapshot.selectedRange.length)
}

private func browserInlineCaretDriftCandidate(
    in snapshot: InputInsertionContextSnapshot,
    at location: Int,
    caretBounds: CGRect
) -> (evidence: SmartInsertHeuristics.BrowserInlineCaretDriftEvidence, nextLocation: Int)? {
    guard location < snapshot.textLength else {
        return nil
    }

    let nsText = snapshot.fullText as NSString
    let rightRange = nsText.rangeOfComposedCharacterSequence(at: location)
    let rightString = nsText.substring(with: rightRange)
    guard let rightCharacter = rightString.first,
          let rightBounds = copyAXBoundsForRange(rightRange, from: snapshot.element),
          rightBounds.height >= 2 else {
        return nil
    }

    let nextCursor = rightRange.location + rightRange.length
    let nextCharacterAfterRight: Character?
    let nextCharacterAfterRightRange: NSRange?
    let nextCharacterAfterRightMinX: Double?
    if nextCursor < snapshot.textLength {
        let nextRange = nsText.rangeOfComposedCharacterSequence(at: nextCursor)
        nextCharacterAfterRight = nsText.substring(with: nextRange).first
        nextCharacterAfterRightRange = nextRange
        if let nextBounds = copyAXBoundsForRange(nextRange, from: snapshot.element) {
            nextCharacterAfterRightMinX = Double(nextBounds.minX)
        } else {
            nextCharacterAfterRightMinX = nil
        }
    } else {
        nextCharacterAfterRight = nil
        nextCharacterAfterRightRange = nil
        nextCharacterAfterRightMinX = nil
    }

    var hasWhitespaceBeforeNextNonWhitespaceAfterRight = false
    var hasNextNonWhitespaceAfterRight = false
    var nextNonWhitespaceAfterRightStartsUppercase = false
    var scanCursor = nextCursor
    while scanCursor < snapshot.textLength {
        let scanRange = nsText.rangeOfComposedCharacterSequence(at: scanCursor)
        let value = nsText.substring(with: scanRange)
        if let character = value.first,
           !character.isWhitespace,
           !isIgnorableBoundaryCharacterForSmartInsert(character) {
            hasNextNonWhitespaceAfterRight = true
            nextNonWhitespaceAfterRightStartsUppercase =
                String(character).rangeOfCharacter(from: .uppercaseLetters) != nil
            break
        }
        if value.contains(where: { $0.isWhitespace }) {
            hasWhitespaceBeforeNextNonWhitespaceAfterRight = true
        }
        scanCursor = scanRange.location + scanRange.length
    }

    let nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation: Bool
    if let nextCharacterAfterRight,
       ".!?".contains(nextCharacterAfterRight),
       let nextCharacterAfterRightRange {
        var hasWhitespaceBeforeNextNonWhitespaceAfterPunctuation = false
        var nextNonWhitespaceAfterPunctuationStartsUppercase = false
        var punctuationScanCursor = nextCharacterAfterRightRange.location + nextCharacterAfterRightRange.length

        while punctuationScanCursor < snapshot.textLength {
            let scanRange = nsText.rangeOfComposedCharacterSequence(at: punctuationScanCursor)
            let value = nsText.substring(with: scanRange)
            if let character = value.first,
               !character.isWhitespace,
               !isIgnorableBoundaryCharacterForSmartInsert(character) {
                nextNonWhitespaceAfterPunctuationStartsUppercase =
                    String(character).rangeOfCharacter(from: .uppercaseLetters) != nil
                break
            }
            if value.contains(where: { $0.isWhitespace }) {
                hasWhitespaceBeforeNextNonWhitespaceAfterPunctuation = true
            }
            punctuationScanCursor = scanRange.location + scanRange.length
        }

        nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation =
            hasWhitespaceBeforeNextNonWhitespaceAfterPunctuation &&
            nextNonWhitespaceAfterPunctuationStartsUppercase
    } else {
        nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation = false
    }

    return (
        SmartInsertHeuristics.BrowserInlineCaretDriftEvidence(
            caretX: Double(caretBounds.minX),
            rightCharacterMinX: Double(rightBounds.minX),
            rightCharacterMaxX: Double(rightBounds.maxX),
            caretAndRightShareLine: abs(caretBounds.midY - rightBounds.midY) < 4,
            rightCharacterIsWhitespace: rightCharacter.isWhitespace,
            rightCharacterContainsLineBreak: rightString.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }),
            rightCharacterIsWord: isSmartInsertWordCharacter(rightCharacter),
            rightCharacterIsTerminalPunctuation: ".!?".contains(rightCharacter),
            hasNextNonWhitespaceAfterRight: hasNextNonWhitespaceAfterRight,
            nextCharacterAfterRightMinX: nextCharacterAfterRightMinX,
            nextCharacterAfterRightIsWhitespace: nextCharacterAfterRight?.isWhitespace == true,
            nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation: nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation,
            rightCharacterFollowedBySentenceBoundaryBeforeNextNonWhitespace: hasWhitespaceBeforeNextNonWhitespaceAfterRight,
            nextNonWhitespaceAfterRightStartsUppercase: nextNonWhitespaceAfterRightStartsUppercase
        ),
        nextCursor
    )
}

private func resolvedBrowserAmbiguousNewlineSnapshot(
    from snapshot: InputInsertionContextSnapshot
) -> InputInsertionContextSnapshot {
    guard snapshot.depth == 0,
          snapshot.selectedRange.length == 0,
          SmartInsertHeuristics.isAmbiguousBrowserNewlineBoundary(
            leftCharacter: snapshot.context.leftCharacter,
            leftNonWhitespaceCharacter: snapshot.context.leftNonWhitespaceCharacter,
            rightCharacter: snapshot.context.rightCharacter,
            rightNonWhitespaceCharacter: snapshot.context.rightNonWhitespaceCharacter,
            rightHasLineBreakBeforeNextNonWhitespace: snapshot.context.rightHasLineBreakBeforeNextNonWhitespace
          ) else {
        return snapshot
    }

    let resolution = resolveAmbiguousBrowserNewlineBoundaryUsingGeometry(for: snapshot)
    switch resolution {
    case .lineStart:
        logDebug("[SmartInsert] Browser ambiguous newline boundary resolved via geometry as line-start")
    case .beforeNewline:
        logDebug("[SmartInsert] Browser ambiguous newline boundary resolved via geometry as before-newline")
    case .unresolved:
        logDebug("[SmartInsert] Browser ambiguous newline boundary unresolved by geometry; trusting root before-newline boundary")
    }

    return InputInsertionContextSnapshot(
        element: snapshot.element,
        context: InputInsertionContext(
            leftCharacter: snapshot.context.leftCharacter,
            leftNonWhitespaceCharacter: snapshot.context.leftNonWhitespaceCharacter,
            leftLinePrefix: snapshot.context.leftLinePrefix,
            rightCharacter: snapshot.context.rightCharacter,
            rightNonWhitespaceCharacter: snapshot.context.rightNonWhitespaceCharacter,
            rightHasLineBreakBeforeNextNonWhitespace: snapshot.context.rightHasLineBreakBeforeNextNonWhitespace,
            browserAmbiguousNewlineBoundaryResolution: resolution
        ),
        role: snapshot.role,
        textLength: snapshot.textLength,
        selectedRange: snapshot.selectedRange,
        depth: snapshot.depth,
        neighborhood: snapshot.neighborhood,
        fullText: snapshot.fullText
    )
}

private func resolveAmbiguousBrowserNewlineBoundaryUsingGeometry(
    for snapshot: InputInsertionContextSnapshot
) -> SmartInsertHeuristics.BrowserAmbiguousNewlineBoundaryResolution {
    guard let geometryEvidence = browserAmbiguousNewlineGeometryEvidence(for: snapshot) else {
        return .unresolved
    }

    return SmartInsertHeuristics.resolveAmbiguousBrowserNewlineBoundaryUsingGeometry(geometryEvidence)
}

private func browserAmbiguousNewlineGeometryEvidence(
    for snapshot: InputInsertionContextSnapshot
) -> SmartInsertHeuristics.BrowserAmbiguousNewlineGeometryEvidence? {
    let insertionLocation = Int(snapshot.selectedRange.location)

    guard let previousRange = previousMeaningfulSmartInsertCharacterRange(
        in: snapshot.fullText,
        before: insertionLocation
    ),
    let nextRange = nextMeaningfulSmartInsertCharacterRange(
        in: snapshot.fullText,
        from: insertionLocation
    ),
    let caretBounds = copyAXBoundsForRange(
        NSRange(location: insertionLocation, length: 0),
        from: snapshot.element
    ),
    let previousBounds = copyAXBoundsForRange(previousRange, from: snapshot.element),
    let nextBounds = copyAXBoundsForRange(nextRange, from: snapshot.element) else {
        return nil
    }

    return SmartInsertHeuristics.BrowserAmbiguousNewlineGeometryEvidence(
        caretMidY: Double(caretBounds.midY),
        previousMidY: Double(previousBounds.midY),
        nextMidY: Double(nextBounds.midY)
    )
}

private func previousMeaningfulSmartInsertCharacterRange(
    in fullText: String,
    before location: Int
) -> NSRange? {
    let nsText = fullText as NSString
    var cursor = location

    while cursor > 0 {
        let range = nsText.rangeOfComposedCharacterSequence(at: cursor - 1)
        let value = nsText.substring(with: range)
        if let character = value.first,
           !character.isWhitespace,
           !isIgnorableBoundaryCharacterForSmartInsert(character) {
            return range
        }
        cursor = range.location
    }

    return nil
}

private func nextMeaningfulSmartInsertCharacterRange(
    in fullText: String,
    from location: Int
) -> NSRange? {
    let nsText = fullText as NSString
    let textLength = nsText.length
    var cursor = location

    while cursor < textLength {
        let range = nsText.rangeOfComposedCharacterSequence(at: cursor)
        let value = nsText.substring(with: range)
        if let character = value.first,
           !character.isWhitespace,
           !isIgnorableBoundaryCharacterForSmartInsert(character) {
            return range
        }
        cursor = range.location + range.length
    }

    return nil
}

private func copyAXBoundsForRange(
    _ range: NSRange,
    from element: AXUIElement
) -> CGRect? {
    var cfRange = CFRange(location: range.location, length: range.length)
    guard let parameter = AXValueCreate(.cfRange, &cfRange) else {
        return nil
    }

    var boundsValue: CFTypeRef?
    let error = AXUIElementCopyParameterizedAttributeValue(
        element,
        "AXBoundsForRange" as CFString,
        parameter,
        &boundsValue
    )
    guard error == .success, let boundsValue else {
        return nil
    }

    guard CFGetTypeID(boundsValue) == AXValueGetTypeID() else {
        return nil
    }

    let axValue = unsafeBitCast(boundsValue, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgRect else {
        return nil
    }

    var rect = CGRect.zero
    guard AXValueGetValue(axValue, .cgRect, &rect) else {
        return nil
    }

    return rect
}

private func findBestBrowserInsertionContextSnapshot(
    from root: AXUIElement,
    frontApp: NSRunningApplication,
    rootSnapshot: InputInsertionContextSnapshot,
    insertionText: String?
) -> InputInsertionContextSnapshot? {
    var bestSnapshot: InputInsertionContextSnapshot?
    var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
    var seen = Set<CFHashCode>()
    var visited = 0
    let maxDepth = 14
    let maxNodes = 500

    while !queue.isEmpty && visited < maxNodes {
        let current = queue.removeFirst()
        visited += 1

        let hash = CFHash(current.element)
        if !seen.insert(hash).inserted {
            continue
        }

        let role = copyAXRole(from: current.element)

        if shouldConsiderBrowserSelectionCandidate(current.element, roleHint: role),
           let snapshot = buildInputInsertionContextSnapshot(
            for: current.element,
            role: role ?? "unknown",
            frontApp: frontApp,
            depth: current.depth
           ) {
            if bestSnapshot == nil || shouldPreferBrowserInsertionSnapshot(
                snapshot,
                over: bestSnapshot!,
                rootSnapshot: rootSnapshot,
                insertionText: insertionText
            ) {
                bestSnapshot = snapshot
            }
        }

        guard current.depth < maxDepth else { continue }
        for child in getAXTraversalChildren(of: current.element) {
            queue.append((child, current.depth + 1))
        }
    }

    return bestSnapshot
}

private func currentBrowserInsertionCandidate(appPid: pid_t, rootHash: CFHashCode) -> BrowserInsertionCandidateCacheEntry? {
    browserInsertionCandidateCacheQueue.sync {
        guard let cacheEntry = browserInsertionCandidateCache else {
            return nil
        }

        if cacheEntry.appPid != appPid || cacheEntry.rootHash != rootHash {
            return nil
        }

        if Date().timeIntervalSince(cacheEntry.timestamp) > browserInsertionCandidateCacheValidity {
            browserInsertionCandidateCacheQueue.async(flags: .barrier) {
                if let current = browserInsertionCandidateCache,
                   current.appPid == appPid,
                   current.rootHash == rootHash {
                    browserInsertionCandidateCache = nil
                }
            }
            return nil
        }

        return cacheEntry
    }
}

private func cacheBrowserInsertionCandidate(
    appPid: pid_t,
    rootHash: CFHashCode,
    snapshot: InputInsertionContextSnapshot
) {
    guard snapshot.depth > 0 else {
        clearBrowserInsertionCandidate(appPid: appPid, rootHash: rootHash)
        return
    }

    browserInsertionCandidateCacheQueue.sync(flags: .barrier) {
        browserInsertionCandidateCache = BrowserInsertionCandidateCacheEntry(
            appPid: appPid,
            rootHash: rootHash,
            element: snapshot.element,
            depth: snapshot.depth,
            timestamp: Date()
        )
    }
}

private func clearBrowserInsertionCandidate(appPid: pid_t, rootHash: CFHashCode) {
    browserInsertionCandidateCacheQueue.sync(flags: .barrier) {
        guard let cacheEntry = browserInsertionCandidateCache,
              cacheEntry.appPid == appPid,
              cacheEntry.rootHash == rootHash else {
            return
        }
        browserInsertionCandidateCache = nil
    }
}

private func shouldConsiderBrowserSelectionCandidate(_ element: AXUIElement, roleHint: String?) -> Bool {
    if isInputLikeElementForSmartInsert(element, roleHint: roleHint) {
        return true
    }

    if let roleHint {
        let excludedRoles = Set([
            "AXButton",
            "AXCheckBox",
            "AXDisclosureTriangle",
            "AXHeading",
            "AXImage",
            "AXLink",
            "AXMenuButton",
            "AXMenuItem",
            "AXPopUpButton",
            "AXRadioButton",
            "AXSwitch",
            "AXTab",
            "AXToolbar",
            "AXWindow"
        ])
        if excludedRoles.contains(roleHint) {
            return false
        }
    }

    var valueRef: CFTypeRef?
    let valueError = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
    guard valueError == .success, let value = valueRef as? String else {
        return false
    }

    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return false
    }

    var selectedRangeRef: CFTypeRef?
    let selectedRangeError = AXUIElementCopyAttributeValue(element, "AXSelectedTextRange" as CFString, &selectedRangeRef)
    guard selectedRangeError == .success, let selectedRangeRef else {
        return false
    }

    guard CFGetTypeID(selectedRangeRef) == AXValueGetTypeID(),
          AXValueGetType(selectedRangeRef as! AXValue) == .cfRange else {
        return false
    }

    return true
}

private func shouldPreferBrowserInsertionSnapshot(
    _ candidate: InputInsertionContextSnapshot,
    over current: InputInsertionContextSnapshot,
    rootSnapshot: InputInsertionContextSnapshot,
    insertionText: String?
) -> Bool {
    let candidateReconciliation = reconcileBrowserInsertionSnapshot(candidate, against: rootSnapshot)
    let currentReconciliation = reconcileBrowserInsertionSnapshot(current, against: rootSnapshot)

    if let reconciliationPreference = shouldPreferBrowserReconciliation(
        candidateReconciliation,
        over: currentReconciliation
    ) {
        return reconciliationPreference
    }

    let candidateScore = browserInsertionSnapshotScore(
        candidate,
        insertionText: insertionText,
        reconciliation: candidateReconciliation
    )
    let currentScore = browserInsertionSnapshotScore(
        current,
        insertionText: insertionText,
        reconciliation: currentReconciliation
    )

    if candidateScore != currentScore {
        return candidateScore > currentScore
    }

    if candidate.depth != current.depth {
        return candidate.depth > current.depth
    }

    if candidate.textLength != current.textLength {
        return candidate.textLength < current.textLength
    }

    return false
}

private func browserInsertionSnapshotScore(
    _ snapshot: InputInsertionContextSnapshot,
    insertionText: String?,
    reconciliation: BrowserInsertionReconciliation?
) -> Int {
    var score = 0

    switch snapshot.role {
    case "AXTextArea":
        score += 120
    case "AXTextField", "AXSearchField", "AXComboBox":
        score += 100
    case "AXStaticText":
        score += 20
    case "AXGroup":
        score += 10
    default:
        score += 0
    }

    if snapshot.textLength >= 200 {
        score += 60
    } else if snapshot.textLength >= 80 {
        score += 30
    } else if snapshot.textLength >= 40 {
        score += 5
    } else {
        score -= 40
    }

    if snapshot.selectedRange.location > 0 || snapshot.selectedRange.length > 0 {
        score += 30
    } else {
        score -= 25
    }

    if snapshot.context.leftCharacter != nil {
        score += 10
    }
    if snapshot.context.rightCharacter != nil {
        score += 10
    }

    if snapshot.context.leftNonWhitespaceCharacter != nil {
        score += 10
    }
    if snapshot.context.rightNonWhitespaceCharacter != nil {
        score += 10
    }

    if snapshot.context.leftCharacter.map({ $0.isWhitespace }) == true ||
        snapshot.context.rightCharacter.map({ $0.isWhitespace }) == true {
        score += 5
    }

    if snapshot.role == "AXStaticText" {
        if snapshot.textLength < 80 {
            score -= 50
        }
        if snapshot.selectedRange.location == 0 && snapshot.selectedRange.length == 0 {
            score -= 40
        }

        if let reconciliation,
           reconciliation.method == .exactFragment,
           reconciliation.deltaFromRootSelection == 0 {
            let hasLocalLeftEvidence =
                snapshot.context.leftCharacter != nil || snapshot.context.leftNonWhitespaceCharacter != nil
            let hasLocalRightEvidence =
                snapshot.context.rightCharacter != nil || snapshot.context.rightNonWhitespaceCharacter != nil
            if hasLocalLeftEvidence && hasLocalRightEvidence {
                score += 80
            }
        }
    }

    if let insertionText, isSentenceLikeSmartInsertText(insertionText) {
        score += browserSentenceBoundaryScore(snapshot)
    }

    if let reconciliation {
        switch reconciliation.method {
        case .exactFragment:
            score += 120
        case .caretAnchor:
            score += 80
        }

        if reconciliation.deltaFromRootSelection == 0 {
            score += 15
        } else if reconciliation.deltaFromRootSelection <= 48 {
            score += 900 - (reconciliation.deltaFromRootSelection * 12)
        } else if reconciliation.deltaFromRootSelection <= 160 {
            score += 220 - reconciliation.deltaFromRootSelection
        }

        score += min(reconciliation.matchedLength, 120) / 4
    }

    return score
}

private func shouldPreferBrowserReconciliation(
    _ candidate: BrowserInsertionReconciliation?,
    over current: BrowserInsertionReconciliation?
) -> Bool? {
    let candidateStrong = isStrongBrowserReconciliation(candidate)
    let currentStrong = isStrongBrowserReconciliation(current)

    if candidateStrong != currentStrong {
        return candidateStrong
    }

    guard candidateStrong, let candidate, let current else {
        return nil
    }

    if candidate.deltaFromRootSelection != current.deltaFromRootSelection {
        return candidate.deltaFromRootSelection < current.deltaFromRootSelection
    }

    if candidate.method.rawValue != current.method.rawValue {
        return candidate.method.rawValue > current.method.rawValue
    }

    if candidate.matchedLength != current.matchedLength {
        return candidate.matchedLength > current.matchedLength
    }

    return nil
}

private func isStrongBrowserReconciliation(_ reconciliation: BrowserInsertionReconciliation?) -> Bool {
    guard let reconciliation else {
        return false
    }
    return reconciliation.deltaFromRootSelection > 0 && reconciliation.deltaFromRootSelection <= 48
}

private func reconcileBrowserInsertionSnapshot(
    _ snapshot: InputInsertionContextSnapshot,
    against rootSnapshot: InputInsertionContextSnapshot
) -> BrowserInsertionReconciliation? {
    guard snapshot.depth > 0 else {
        return nil
    }
    guard snapshot.textLength >= 24, snapshot.textLength < rootSnapshot.textLength else {
        return nil
    }
    guard snapshot.fullText != rootSnapshot.fullText else {
        return nil
    }

    if let matchedRange = uniqueBrowserTextRange(of: snapshot.fullText, in: rootSnapshot.fullText),
       let reconciliation = makeBrowserInsertionReconciliation(
        candidate: snapshot,
        rootSnapshot: rootSnapshot,
        matchedRootRange: matchedRange,
        caretOffsetInMatch: snapshot.selectedRange.location,
        method: .exactFragment
       ) {
        return reconciliation
    }

    guard let caretAnchor = browserCaretAnchor(for: snapshot),
          let matchedRange = uniqueBrowserTextRange(of: caretAnchor.text, in: rootSnapshot.fullText) else {
        return nil
    }

    return makeBrowserInsertionReconciliation(
        candidate: snapshot,
        rootSnapshot: rootSnapshot,
        matchedRootRange: matchedRange,
        caretOffsetInMatch: caretAnchor.caretOffset,
        method: .caretAnchor
    )
}

private func makeBrowserInsertionReconciliation(
    candidate: InputInsertionContextSnapshot,
    rootSnapshot: InputInsertionContextSnapshot,
    matchedRootRange: NSRange,
    caretOffsetInMatch: Int,
    method: BrowserInsertionReconciliationMethod
) -> BrowserInsertionReconciliation? {
    let mappedRootLocation = matchedRootRange.location + caretOffsetInMatch
    let mappedRootRange = CFRange(location: mappedRootLocation, length: candidate.selectedRange.length)

    guard let mappedContext = deriveInputInsertionContext(
        fullText: rootSnapshot.fullText,
        selectedRange: mappedRootRange
    ) else {
        return nil
    }

    guard browserContextsMatch(candidate.context, mappedContext) else {
        return nil
    }

    let hasLocalLeftEvidence =
        candidate.context.leftCharacter != nil || candidate.context.leftNonWhitespaceCharacter != nil
    let hasLocalRightEvidence =
        candidate.context.rightCharacter != nil || candidate.context.rightNonWhitespaceCharacter != nil
    let hasMappedLeftEvidence =
        mappedContext.leftCharacter != nil || mappedContext.leftNonWhitespaceCharacter != nil
    let hasMappedRightEvidence =
        mappedContext.rightCharacter != nil || mappedContext.rightNonWhitespaceCharacter != nil
    let gapContainsLineBreak = browserSelectionGapContainsLineBreak(
        rootText: rootSnapshot.fullText,
        firstLocation: mappedRootLocation,
        secondLocation: rootSnapshot.selectedRange.location
    )

    let overrideEvidence = SmartInsertHeuristics.BrowserOverrideEvidence(
        role: candidate.role,
        mappedRootLocation: mappedRootLocation,
        rootSelectionLocation: rootSnapshot.selectedRange.location,
        gapContainsLineBreak: gapContainsLineBreak,
        hasLocalLeftEvidence: hasLocalLeftEvidence,
        hasLocalRightEvidence: hasLocalRightEvidence,
        hasMappedLeftEvidence: hasMappedLeftEvidence,
        hasMappedRightEvidence: hasMappedRightEvidence,
        mappedLeftCharacter: mappedContext.leftCharacter,
        mappedLeftNonWhitespaceCharacter: mappedContext.leftNonWhitespaceCharacter,
        mappedRightNonWhitespaceCharacter: mappedContext.rightNonWhitespaceCharacter
    )
    guard SmartInsertHeuristics.shouldAllowBrowserDescendantOverride(overrideEvidence) else {
        return nil
    }

    return BrowserInsertionReconciliation(
        mappedRootRange: mappedRootRange,
        deltaFromRootSelection: abs(rootSnapshot.selectedRange.location - mappedRootLocation),
        matchedLength: matchedRootRange.length,
        method: method
    )
}

private func browserSelectionGapContainsLineBreak(
    rootText: String,
    firstLocation: Int,
    secondLocation: Int
) -> Bool {
    let lowerBound = min(firstLocation, secondLocation)
    let upperBound = max(firstLocation, secondLocation)
    guard upperBound > lowerBound else {
        return false
    }

    let nsText = rootText as NSString
    let gapRange = NSRange(location: lowerBound, length: upperBound - lowerBound)
    let gapText = nsText.substring(with: gapRange)
    return gapText.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) })
}

private func browserContextsMatch(
    _ candidateContext: InputInsertionContext,
    _ rootContext: InputInsertionContext
) -> Bool {
    if let leftCharacter = candidateContext.leftCharacter,
       rootContext.leftCharacter != leftCharacter {
        return false
    }

    if let rightCharacter = candidateContext.rightCharacter,
       rootContext.rightCharacter != rightCharacter {
        return false
    }

    if let leftNonWhitespaceCharacter = candidateContext.leftNonWhitespaceCharacter,
       rootContext.leftNonWhitespaceCharacter != leftNonWhitespaceCharacter {
        return false
    }

    if let rightNonWhitespaceCharacter = candidateContext.rightNonWhitespaceCharacter,
       rootContext.rightNonWhitespaceCharacter != rightNonWhitespaceCharacter {
        return false
    }

    return true
}

private func browserCaretAnchor(for snapshot: InputInsertionContextSnapshot) -> BrowserCaretAnchor? {
    let nsText = snapshot.fullText as NSString
    let selectionStart = Int(snapshot.selectedRange.location)
    let selectionEnd = selectionStart + Int(snapshot.selectedRange.length)
    let desiredSideLength = 24
    let maxSideLength = 40
    let minimumAnchorLength = 24

    var leftLength = min(desiredSideLength, selectionStart)
    var rightLength = min(desiredSideLength, snapshot.textLength - selectionEnd)

    if leftLength + Int(snapshot.selectedRange.length) + rightLength < minimumAnchorLength {
        var needed = minimumAnchorLength - (leftLength + Int(snapshot.selectedRange.length) + rightLength)

        let additionalRightCapacity = max(0, min(maxSideLength, snapshot.textLength - selectionEnd) - rightLength)
        let growRight = min(needed, additionalRightCapacity)
        rightLength += growRight
        needed -= growRight

        let additionalLeftCapacity = max(0, min(maxSideLength, selectionStart) - leftLength)
        let growLeft = min(needed, additionalLeftCapacity)
        leftLength += growLeft
    }

    let anchorLength = leftLength + Int(snapshot.selectedRange.length) + rightLength
    guard anchorLength >= minimumAnchorLength else {
        return nil
    }

    let anchorRange = NSRange(location: selectionStart - leftLength, length: anchorLength)
    guard anchorRange.location >= 0,
          anchorRange.location + anchorRange.length <= snapshot.textLength else {
        return nil
    }

    return BrowserCaretAnchor(
        text: nsText.substring(with: anchorRange),
        caretOffset: leftLength
    )
}

private func uniqueBrowserTextRange(of needle: String, in haystack: String) -> NSRange? {
    guard !needle.isEmpty else {
        return nil
    }

    let haystackNSString = haystack as NSString
    let firstMatch = haystackNSString.range(of: needle)
    guard firstMatch.location != NSNotFound else {
        return nil
    }

    let nextSearchLocation = firstMatch.location + 1
    if nextSearchLocation < haystackNSString.length {
        let remainingRange = NSRange(
            location: nextSearchLocation,
            length: haystackNSString.length - nextSearchLocation
        )
        let secondMatch = haystackNSString.range(of: needle, options: [], range: remainingRange)
        if secondMatch.location != NSNotFound {
            return nil
        }
    }

    return firstMatch
}

private func browserSentenceBoundaryScore(_ snapshot: InputInsertionContextSnapshot) -> Int {
    var score = 0

    let leftIsWord = snapshot.context.leftCharacter.map(isSmartInsertWordCharacter) ?? false
    let rightIsWord = snapshot.context.rightCharacter.map(isSmartInsertWordCharacter) ?? false
    let leftIsWhitespace = snapshot.context.leftCharacter?.isWhitespace == true
    let rightIsWhitespace = snapshot.context.rightCharacter?.isWhitespace == true
    let leftIsTerminalPunctuation = snapshot.context.leftNonWhitespaceCharacter.map { ".!?".contains($0) } ?? false
    let rightIsPunctuation = snapshot.context.rightCharacter.map { ".,;:!?".contains($0) } ?? false
    let rightIsClosingWrapper = snapshot.context.rightCharacter.map { ")]}>\"'”’»›".contains($0) } ?? false
    let rightIsLowercaseLetter = snapshot.context.rightCharacter.map {
        String($0).rangeOfCharacter(from: .lowercaseLetters) != nil
    } ?? false

    if leftIsWord && rightIsWord {
        score -= 180
    }
    if leftIsWhitespace || rightIsWhitespace {
        score += 40
    }
    if leftIsTerminalPunctuation {
        score += 120
    }
    if rightIsPunctuation || rightIsClosingWrapper {
        score += 240
    }
    if snapshot.context.rightCharacter == nil {
        score += 20
    }
    if leftIsWhitespace && rightIsWord {
        score -= 80
    }
    if rightIsLowercaseLetter {
        score -= 40
    }

    return score
}

private func isSentenceLikeSmartInsertText(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    guard trimmed.contains(where: { $0.isWhitespace }) else { return false }
    guard let firstLetter = trimmed.first(where: { String($0).rangeOfCharacter(from: .letters) != nil }) else {
        return false
    }
    return String(firstLetter).rangeOfCharacter(from: .uppercaseLetters) != nil
}

private func isSmartInsertWordCharacter(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
}

private func copyAXRole(from element: AXUIElement) -> String? {
    var roleRef: CFTypeRef?
    let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
    guard roleError == .success else { return nil }
    return roleRef as? String
}

private func debugCaretNeighborhoodSnippet(fullText: String, selectedRange: CFRange) -> String {
    let nsText = fullText as NSString
    let textLength = nsText.length
    let location = max(0, min(selectedRange.location, textLength))
    let length = max(0, min(selectedRange.length, textLength - location))

    let contextRadius = 80
    let snippetStart = max(0, location - contextRadius)
    let snippetEnd = min(textLength, location + length + contextRadius)
    let snippetRange = NSRange(location: snippetStart, length: snippetEnd - snippetStart)
    let snippet = nsText.substring(with: snippetRange)

    let caretOffset = location - snippetStart
    let selectionOffsetEnd = caretOffset + length
    let markedSnippet = length > 0
        ? "\(snippet.prefix(caretOffset))|<SEL>|\(snippet.dropFirst(selectionOffsetEnd))"
        : "\(snippet.prefix(caretOffset))|\(snippet.dropFirst(caretOffset))"

    let normalized = markedSnippet
        .replacingOccurrences(of: "\n", with: "⏎")
        .replacingOccurrences(of: "\t", with: "⇥")
    return summarizeForLogs(normalized, maxPreview: 220)
}

/// Gets the currently selected text from the frontmost application using accessibility APIs
/// Returns the selected text if any, or empty string if no text is selected or accessibility fails
func getSelectedText() -> String {
    // Check if we have accessibility permissions
    guard AXIsProcessTrusted() else {
        logDebug("[SelectedText] No accessibility permissions, cannot get selected text")
        return ""
    }
    
    // Resolve the front app cheaply; focused-element AX access happens on the target app below.
    guard let frontApp = resolveFrontAppIdentity(timeout: 0.2) else {
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
    return resolveFrontAppIdentity()
}

/// Gets active URL for the target app (or current frontmost app when pid is nil).
/// Returns nil when accessibility isn't available, app can't be resolved, or URL cannot be extracted.
func getActiveURL(targetPid: Int32? = nil, fallbackBundleId: String? = nil) -> String? {
    let startedAt = CFAbsoluteTimeGetCurrent()

    func finish(_ url: String?, bundleId: String?) -> String? {
        let elapsedMs = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0).rounded())
        let bundleDescription = bundleId ?? fallbackBundleId ?? "unknown"
        logDebug(
            "[ActiveURL] Lookup bundle=\(bundleDescription) hit=\(url != nil) elapsedMs=\(elapsedMs)"
        )
        return url
    }

    guard AXIsProcessTrusted() else {
        logDebug("[AppContext] No accessibility permissions, cannot get active URL")
        return finish(nil, bundleId: nil)
    }

    guard let targetApp = resolveTargetApp(targetPid: targetPid) else {
        logDebug("[AppContext] No target application found for active URL lookup")
        return finish(nil, bundleId: nil)
    }

    let appElement = AXUIElementCreateApplication(targetApp.processIdentifier)
    return finish(
        getBrowserURL(appElement: appElement, frontApp: targetApp, fallbackBundleId: fallbackBundleId),
        bundleId: targetApp.bundleIdentifier
    )
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
    let bundleId = frontApp.bundleIdentifier ?? fallbackBundleId ?? "unknown"
    logDebug("[AppContext] Current app bundle ID: \(bundleId)")
    guard supportedBrowserBundleIds.contains(bundleId) else {
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

            let selectionDiagnostics = debugSelectionDiagnostics(
                for: element,
                role: roleStr,
                attributeNames: attributeNamesArray,
                prefix: prefix,
                indent: indent
            )
            if !selectionDiagnostics.isEmpty {
                logInfo(selectionDiagnostics)
            }
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

    guard let frontApp = resolveFrontApp(timeout: 0.2) else {
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

private func debugSelectionDiagnostics(
    for element: AXUIElement,
    role: String,
    attributeNames: [String],
    prefix: String,
    indent: String
) -> String {
    let selectionAttributes = [
        "AXSelectedText",
        "AXSelectedTextRange",
        "AXSelectedTextRanges",
        "AXSelectedTextMarkerRange",
        "AXVisibleCharacterRange",
        "AXInsertionPointLineNumber",
        "AXNumberOfCharacters",
        "AXStartTextMarker",
        "AXEndTextMarker",
        "AXHighestEditableAncestor",
        "AXEditableAncestor"
    ]

    let shouldLogSelectionDiagnostics =
        role == "AXTextArea" ||
        role == "AXTextField" ||
        role == "AXSearchField" ||
        selectionAttributes.contains(where: attributeNames.contains)

    guard shouldLogSelectionDiagnostics else {
        return ""
    }

    var lines: [String] = []
    lines.append("\(prefix) \(indent)  Selection Diagnostics:")

    for attribute in selectionAttributes where attributeNames.contains(attribute) {
        lines.append("\(prefix) \(indent)    \(attribute): \(debugStringForAXAttribute(element, attribute: attribute))")
    }

    if attributeNames.contains("AXSelectedTextMarkerRange") {
        lines.append(
            "\(prefix) \(indent)    AXStringForTextMarkerRange: \(debugStringForAXParameterizedAttribute(element, attribute: "AXStringForTextMarkerRange", parameterAttribute: "AXSelectedTextMarkerRange"))"
        )
    }

    if attributeNames.contains("AXSelectedTextRange") {
        lines.append(
            "\(prefix) \(indent)    AXStringForRange(selected): \(debugStringForAXParameterizedAttribute(element, attribute: "AXStringForRange", parameterAttribute: "AXSelectedTextRange"))"
        )
    }

    if let caretNeighborhood = debugCaretNeighborhood(
        for: element,
        attributeNames: attributeNames
    ) {
        lines.append("\(prefix) \(indent)    CaretNeighborhood: \(caretNeighborhood)")
    }

    return lines.joined(separator: "\n")
}

private func debugStringForAXAttribute(_ element: AXUIElement, attribute: String) -> String {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success else {
        return "error=\(error.rawValue)"
    }
    guard let value else {
        return "nil"
    }

    return debugDescribeAXValue(value)
}

private func debugStringForAXParameterizedAttribute(
    _ element: AXUIElement,
    attribute: String,
    parameterAttribute: String
) -> String {
    var parameterValue: CFTypeRef?
    let parameterError = AXUIElementCopyAttributeValue(element, parameterAttribute as CFString, &parameterValue)
    guard parameterError == .success else {
        return "parameterError=\(parameterError.rawValue)"
    }
    guard let parameterValue else {
        return "parameter=nil"
    }

    var value: CFTypeRef?
    let error = AXUIElementCopyParameterizedAttributeValue(
        element,
        attribute as CFString,
        parameterValue,
        &value
    )
    guard error == .success else {
        return "error=\(error.rawValue)"
    }
    guard let value else {
        return "nil"
    }

    return debugDescribeAXValue(value)
}

private func debugDescribeAXValue(_ value: CFTypeRef) -> String {
    if let stringValue = value as? String {
        return summarizeForLogs(stringValue, maxPreview: 200)
    }

    if let attributedString = value as? NSAttributedString {
        return summarizeForLogs(attributedString.string, maxPreview: 200)
    }

    if let numberValue = value as? NSNumber {
        return numberValue.stringValue
    }

    if let boolValue = value as? Bool {
        return String(boolValue)
    }

    if CFGetTypeID(value) == AXValueGetTypeID() {
        let axValue = unsafeBitCast(value, to: AXValue.self)
        switch AXValueGetType(axValue) {
        case .cfRange:
            var range = CFRange()
            if AXValueGetValue(axValue, .cfRange, &range) {
                return "{location=\(range.location), length=\(range.length)}"
            }
            return "AXValue(cfRange decode failed)"
        case .cgPoint:
            var point = CGPoint.zero
            if AXValueGetValue(axValue, .cgPoint, &point) {
                return "{x=\(point.x), y=\(point.y)}"
            }
            return "AXValue(cgPoint decode failed)"
        case .cgRect:
            var rect = CGRect.zero
            if AXValueGetValue(axValue, .cgRect, &rect) {
                return "{x=\(rect.origin.x), y=\(rect.origin.y), w=\(rect.size.width), h=\(rect.size.height)}"
            }
            return "AXValue(cgRect decode failed)"
        case .cgSize:
            var size = CGSize.zero
            if AXValueGetValue(axValue, .cgSize, &size) {
                return "{w=\(size.width), h=\(size.height)}"
            }
            return "AXValue(cgSize decode failed)"
        default:
            return "AXValue(type=\(AXValueGetType(axValue).rawValue))"
        }
    }

    if CFGetTypeID(value) == CFArrayGetTypeID(), let arrayValue = value as? [Any] {
        let rendered = arrayValue.prefix(5).map { item -> String in
            if let itemValue = item as CFTypeRef? {
                return debugDescribeAXValue(itemValue)
            }
            return String(describing: item)
        }
        let suffix = arrayValue.count > 5 ? ", … total=\(arrayValue.count)" : ""
        return "[\(rendered.joined(separator: ", "))\(suffix)]"
    }

    if CFGetTypeID(value) == AXUIElementGetTypeID() {
        return debugDescribeAXElementSummary(unsafeBitCast(value, to: AXUIElement.self))
    }

    let typeDescription = CFCopyTypeIDDescription(CFGetTypeID(value)) as String? ?? "unknown"
    return "<\(typeDescription)>"
}

private func debugDescribeAXElementSummary(_ element: AXUIElement) -> String {
    var role: CFTypeRef?
    var title: CFTypeRef?
    var description: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
    AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &description)

    let roleText = (role as? String) ?? "unknown"
    let titleText = summarizeForLogs((title as? String) ?? "", maxPreview: 80)
    let descriptionText = summarizeForLogs((description as? String) ?? "", maxPreview: 80)
    return "{role=\(roleText), title=\(titleText), description=\(descriptionText)}"
}

private func debugCaretNeighborhood(
    for element: AXUIElement,
    attributeNames: [String]
) -> String? {
    guard attributeNames.contains("AXValue"), attributeNames.contains("AXSelectedTextRange") else {
        return nil
    }

    var valueRef: CFTypeRef?
    let valueError = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
    guard valueError == .success, let fullText = valueRef as? String else {
        return "valueError=\(valueError.rawValue)"
    }

    var rangeRef: CFTypeRef?
    let rangeError = AXUIElementCopyAttributeValue(element, "AXSelectedTextRange" as CFString, &rangeRef)
    guard rangeError == .success, let rangeRef else {
        return "selectedTextRangeError=\(rangeError.rawValue)"
    }

    guard CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
        return "selectedTextRangeTypeMismatch"
    }

    let axRange = unsafeBitCast(rangeRef, to: AXValue.self)
    guard AXValueGetType(axRange) == .cfRange else {
        return "selectedTextRangeNotCFRange"
    }

    var selectedRange = CFRange()
    guard AXValueGetValue(axRange, .cfRange, &selectedRange) else {
        return "selectedTextRangeDecodeFailed"
    }

    let nsText = fullText as NSString
    let textLength = nsText.length
    let location = max(0, min(selectedRange.location, textLength))
    let length = max(0, min(selectedRange.length, textLength - location))

    let contextRadius = 80
    let snippetStart = max(0, location - contextRadius)
    let snippetEnd = min(textLength, location + length + contextRadius)
    let snippetRange = NSRange(location: snippetStart, length: snippetEnd - snippetStart)
    let snippet = nsText.substring(with: snippetRange)

    let caretOffset = location - snippetStart
    let selectionOffsetEnd = caretOffset + length
    let marker = length > 0
        ? "\(snippet.prefix(caretOffset))|<SEL>|\(snippet.dropFirst(selectionOffsetEnd))"
        : "\(snippet.prefix(caretOffset))|\(snippet.dropFirst(caretOffset))"

    let normalized = marker
        .replacingOccurrences(of: "\n", with: "⏎")
        .replacingOccurrences(of: "\t", with: "⇥")

    return "location=\(location) length=\(length) snippet=\(summarizeForLogs(normalized, maxPreview: 260))"
}
