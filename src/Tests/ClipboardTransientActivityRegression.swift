import Foundation

private func assertEqual(_ actual: Bool, _ expected: Bool, _ label: String) {
    if actual != expected {
        fputs("FAIL: \(label)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func runClipboardTransientActivityRegressionTests() {
    let normalDecision = decideSessionClipboardObservation(
        currentClipboard: "fresh",
        lastCapturedClipboardContent: "older",
        isInIgnoreWindow: false,
        shouldIgnoreApp: false,
        containsIgnoredMarker: false
    )
    assertEqual(normalDecision.shouldCaptureInSessionHistory, true, "normal clipboard activity is captured")
    assertEqual(normalDecision.shouldCountAsRecentActivity, true, "normal clipboard activity counts for recent sync detection")

    let transientDecision = decideSessionClipboardObservation(
        currentClipboard: nil,
        lastCapturedClipboardContent: "older",
        isInIgnoreWindow: false,
        shouldIgnoreApp: false,
        containsIgnoredMarker: true
    )
    assertEqual(transientDecision.shouldCaptureInSessionHistory, false, "transient clipboard activity stays out of session capture")
    assertEqual(transientDecision.shouldCountAsRecentActivity, true, "transient clipboard activity still counts for recent sync detection")

    let transientBlackoutDecision = decideSessionClipboardObservation(
        currentClipboard: "transient",
        lastCapturedClipboardContent: "older",
        isInIgnoreWindow: true,
        shouldIgnoreApp: false,
        containsIgnoredMarker: true
    )
    assertEqual(transientBlackoutDecision.shouldCaptureInSessionHistory, false, "transient clipboard activity is not captured during blackout window")
    assertEqual(transientBlackoutDecision.shouldCountAsRecentActivity, true, "transient clipboard activity still counts during blackout window")

    let blackoutUniqueDecision = decideSessionClipboardObservation(
        currentClipboard: "fresh",
        lastCapturedClipboardContent: "older",
        isInIgnoreWindow: true,
        shouldIgnoreApp: false,
        containsIgnoredMarker: false
    )
    assertEqual(blackoutUniqueDecision.shouldCaptureInSessionHistory, true, "unique non-transient clipboard activity is still captured during blackout window")
    assertEqual(blackoutUniqueDecision.shouldCountAsRecentActivity, true, "unique non-transient blackout activity counts for recent sync detection")

    let blackoutDuplicateDecision = decideSessionClipboardObservation(
        currentClipboard: "same",
        lastCapturedClipboardContent: "same",
        isInIgnoreWindow: true,
        shouldIgnoreApp: false,
        containsIgnoredMarker: false
    )
    assertEqual(blackoutDuplicateDecision.shouldCaptureInSessionHistory, false, "duplicate blackout clipboard activity is not captured")
    assertEqual(blackoutDuplicateDecision.shouldCountAsRecentActivity, false, "duplicate blackout clipboard activity does not force recent sync detection")

    let ignoredAppDecision = decideSessionClipboardObservation(
        currentClipboard: "fresh",
        lastCapturedClipboardContent: "older",
        isInIgnoreWindow: false,
        shouldIgnoreApp: true,
        containsIgnoredMarker: false
    )
    assertEqual(ignoredAppDecision.shouldCaptureInSessionHistory, false, "ignored-app clipboard activity stays uncaptured outside blackout window")
    assertEqual(ignoredAppDecision.shouldCountAsRecentActivity, false, "ignored-app clipboard activity does not trigger recent sync detection")
}

@main
struct ClipboardTransientActivityRegressionRunner {
    static func main() {
        runClipboardTransientActivityRegressionTests()
    }
}
