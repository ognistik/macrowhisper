import Foundation

private func assertTrue(_ condition: Bool, _ label: String) {
    guard condition else {
        fputs("FAIL: \(label)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func assertFalse(_ condition: Bool, _ label: String) {
    assertTrue(!condition, label)
}

private func runAccessibilityFocusPolicyRegressionTests() {
    let chrome = AccessibilityActivationKind.resolve(
        bundleIdentifier: "com.google.Chrome",
        hasElectronFramework: false
    )
    assertTrue(chrome == .chromiumBrowser, "Chrome is eligible for activation")

    let edge = AccessibilityActivationKind.resolve(
        bundleIdentifier: "com.microsoft.edgemac",
        hasElectronFramework: false
    )
    assertTrue(edge == .chromiumBrowser, "Microsoft Edge is eligible for activation")

    let brave = AccessibilityActivationKind.resolve(
        bundleIdentifier: "com.brave.Browser",
        hasElectronFramework: false
    )
    assertTrue(brave == .chromiumBrowser, "Brave is eligible for activation")

    let safari = AccessibilityActivationKind.resolve(
        bundleIdentifier: "com.apple.Safari",
        hasElectronFramework: false
    )
    assertTrue(safari == .none, "native Safari is not activated")

    let firefox = AccessibilityActivationKind.resolve(
        bundleIdentifier: "org.mozilla.firefox",
        hasElectronFramework: false
    )
    assertTrue(firefox == .none, "native Firefox is not activated")

    let electron = AccessibilityActivationKind.resolve(
        bundleIdentifier: nil,
        hasElectronFramework: true
    )
    assertTrue(electron == .electron, "Electron framework identifies an eligible app without a bundle ID")

    let unknown = AccessibilityActivationKind.resolve(
        bundleIdentifier: "org.example.unknown",
        hasElectronFramework: false
    )
    assertTrue(unknown == .none, "unknown apps are not activated")

    let chromeIdentity = AccessibilityAppIdentity(
        processIdentifier: 101,
        bundleIdentifier: "com.google.Chrome"
    )
    let edgeIdentity = AccessibilityAppIdentity(
        processIdentifier: 404,
        bundleIdentifier: "com.microsoft.edgemac"
    )
    let electronIdentity = AccessibilityAppIdentity(
        processIdentifier: 202,
        bundleIdentifier: "org.example.electron"
    )
    let unknownIdentity = AccessibilityAppIdentity(
        processIdentifier: 303,
        bundleIdentifier: "org.example.unknown"
    )

    var activationBudget = AccessibilityActivationAttemptBudget()
    assertFalse(
        activationBudget.shouldAttempt(
            for: unknownIdentity,
            kind: .none,
            now: 1.0,
            cooldown: 1.0,
            maximumAttempts: 2
        ),
        "unsupported app does not consume an activation attempt"
    )
    assertFalse(
        activationBudget.shouldAttempt(
            for: unknownIdentity,
            kind: .none,
            now: 20.0,
            cooldown: 1.0,
            maximumAttempts: 2
        ),
        "unsupported apps remain ineligible across repeated checks"
    )
    assertTrue(
        activationBudget.shouldAttempt(
            for: chromeIdentity,
            kind: chrome,
            now: 1.0,
            cooldown: 1.0,
            maximumAttempts: 2
        ),
        "first supported-app activation is allowed"
    )
    activationBudget.record(.retryable, for: chromeIdentity)
    assertFalse(
        activationBudget.shouldAttempt(
            for: chromeIdentity,
            kind: chrome,
            now: 1.999,
            cooldown: 1.0,
            maximumAttempts: 2
        ),
        "activation retry is suppressed before its cooldown expires"
    )
    assertTrue(
        activationBudget.shouldAttempt(
            for: chromeIdentity,
            kind: chrome,
            now: 2.0,
            cooldown: 1.0,
            maximumAttempts: 2
        ),
        "one activation retry is allowed after the cooldown"
    )
    activationBudget.record(.retryable, for: chromeIdentity)
    assertFalse(
        activationBudget.shouldAttempt(
            for: chromeIdentity,
            kind: chrome,
            now: 3.0,
            cooldown: 1.0,
            maximumAttempts: 2
        ),
        "activation stops after the configured maximum attempts"
    )
    assertTrue(
        activationBudget.shouldAttempt(
            for: electronIdentity,
            kind: electron,
            now: 1.0,
            cooldown: 1.0,
            maximumAttempts: 2
        ),
        "a separate supported app process gets its own activation attempt"
    )
    activationBudget.record(.succeeded, for: electronIdentity)
    assertFalse(
        activationBudget.shouldAttempt(
            for: electronIdentity,
            kind: electron,
            now: 3.0,
            cooldown: 1.0,
            maximumAttempts: 2
        ),
        "successful activation is not retried"
    )
    assertTrue(
        AccessibilityActivationOutcome.classify(.cannotComplete) == .retryable,
        "transient AX activation failure is eligible for the bounded retry"
    )
    assertTrue(
        AccessibilityActivationOutcome.classify(.success) == .succeeded,
        "successful AX activation is recorded as complete"
    )
    assertTrue(
        AccessibilityActivationOutcome.classify(.attributeUnsupported) == .unavailable,
        "unsupported activation attribute is classified as unavailable"
    )
    assertTrue(
        activationBudget.shouldAttempt(
            for: edgeIdentity,
            kind: edge,
            now: 1.0,
            cooldown: 1.0,
            maximumAttempts: 2
        ),
        "Edge's first activation attempt is allowed"
    )
    activationBudget.record(
        AccessibilityActivationOutcome.classify(.attributeUnsupported),
        for: edgeIdentity
    )
    assertFalse(
        activationBudget.shouldAttempt(
            for: edgeIdentity,
            kind: edge,
            now: 20.0,
            cooldown: 1.0,
            maximumAttempts: 2
        ),
        "unavailable activation outcome blocks retries even after a long delay"
    )

    var failureMemo = AccessibilityFocusFailureMemo()
    assertFalse(
        failureMemo.shouldReuseMiss(for: chromeIdentity, now: 100.0),
        "a missing memo never suppresses the first accessibility lookup"
    )
    failureMemo.recordMiss(for: chromeIdentity, at: 100.0)
    assertTrue(
        failureMemo.shouldReuseMiss(for: chromeIdentity, now: 100.149),
        "same app reuses a recent no-focus result inside the cooldown"
    )
    assertFalse(
        failureMemo.shouldReuseMiss(for: chromeIdentity, now: 100.151),
        "expired no-focus result permits a fresh accessibility lookup"
    )
    failureMemo.recordMiss(for: chromeIdentity, at: 101.0)
    assertTrue(
        failureMemo.shouldReuseMiss(for: chromeIdentity, now: 101.05),
        "active no-focus memo matches its app identity"
    )
    assertFalse(
        failureMemo.shouldReuseMiss(for: electronIdentity, now: 101.05),
        "a no-focus result is isolated by process identity"
    )

    let replacementBundleIdentity = AccessibilityAppIdentity(
        processIdentifier: chromeIdentity.processIdentifier,
        bundleIdentifier: "org.example.replacement"
    )
    failureMemo.recordMiss(for: chromeIdentity, at: 101.0)
    assertFalse(
        failureMemo.shouldReuseMiss(for: replacementBundleIdentity, now: 101.05),
        "a no-focus result is isolated by bundle identity"
    )

    failureMemo.recordMiss(for: chromeIdentity, at: 150.0)
    assertTrue(
        failureMemo.shouldReuseMiss(for: chromeIdentity, now: 150.05),
        "app A can reuse its own active miss before switching apps"
    )
    assertFalse(
        failureMemo.shouldReuseMiss(for: electronIdentity, now: 150.06),
        "switching to app B requires a fresh lookup"
    )
    assertFalse(
        failureMemo.shouldReuseMiss(for: chromeIdentity, now: 150.07),
        "switching back to app A cannot reuse its pre-switch miss"
    )

    failureMemo.recordMiss(for: chromeIdentity, at: 160.0)
    assertTrue(
        failureMemo.shouldReuseMiss(for: chromeIdentity, now: 160.05),
        "a new active miss is available before clearing the memo"
    )
    failureMemo.clear()
    assertFalse(
        failureMemo.shouldReuseMiss(for: chromeIdentity, now: 160.06),
        "clearing the memo allows immediate recovery after a transient miss"
    )

    failureMemo.recordMiss(for: chromeIdentity, at: 200.0)
    assertTrue(
        failureMemo.shouldReuseMiss(for: chromeIdentity, now: 200.1),
        "a later miss starts a new cooldown after the expired miss was bypassed"
    )
    assertFalse(
        failureMemo.shouldReuseMiss(for: chromeIdentity, now: 199.9),
        "a backwards clock sample does not extend a no-focus memo"
    )

    let relaunchedChromeIdentity = AccessibilityAppIdentity(
        processIdentifier: 404,
        bundleIdentifier: "com.google.Chrome"
    )
    assertTrue(
        activationBudget.shouldAttempt(
            for: relaunchedChromeIdentity,
            kind: chrome,
            now: 1.0,
            cooldown: 1.0,
            maximumAttempts: 2
        ),
        "a relaunched app process receives a fresh activation budget"
    )
}

@main
struct AccessibilityFocusPolicyRegressionRunner {
    static func main() {
        runAccessibilityFocusPolicyRegressionTests()
    }
}
