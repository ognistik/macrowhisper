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
        shouldIgnoreApp: false,
        containsIgnoredMarker: false
    )
    assertEqual(normalDecision.shouldCaptureInSessionHistory, true, "normal clipboard activity is captured")
    assertEqual(normalDecision.shouldCountAsRecentActivity, true, "normal clipboard activity counts for recent sync detection")

    let transientDecision = decideSessionClipboardObservation(
        shouldIgnoreApp: false,
        containsIgnoredMarker: true
    )
    assertEqual(transientDecision.shouldCaptureInSessionHistory, false, "transient clipboard activity stays out of session capture")
    assertEqual(transientDecision.shouldCountAsRecentActivity, true, "transient clipboard activity still counts for recent sync detection")

    let ignoredAppDecision = decideSessionClipboardObservation(
        shouldIgnoreApp: true,
        containsIgnoredMarker: false
    )
    assertEqual(ignoredAppDecision.shouldCaptureInSessionHistory, false, "ignored-app clipboard activity stays uncaptured")
    assertEqual(ignoredAppDecision.shouldCountAsRecentActivity, false, "ignored-app clipboard activity does not trigger recent sync detection")

    assertEqual(
        shouldIgnoreFirstSessionClipboardReplay(
            currentClipboard: "seed",
            userOriginalClipboard: "seed",
            sessionStartInputFieldState: .outsideInputField,
            hasAudioRecordingStarted: false,
            hasAlreadyIgnoredReplay: false
        ),
        true,
        "outside-input-field sessions ignore the first replay of the session-start clipboard before audio starts"
    )

    assertEqual(
        shouldIgnoreFirstSessionClipboardReplay(
            currentClipboard: "seed",
            userOriginalClipboard: "seed",
            sessionStartInputFieldState: .unknown,
            hasAudioRecordingStarted: false,
            hasAlreadyIgnoredReplay: false
        ),
        true,
        "unknown input-field state still enables the first replay guard before audio starts"
    )

    assertEqual(
        shouldIgnoreFirstSessionClipboardReplay(
            currentClipboard: "seed",
            userOriginalClipboard: "seed",
            sessionStartInputFieldState: .inInputField,
            hasAudioRecordingStarted: false,
            hasAlreadyIgnoredReplay: false
        ),
        false,
        "sessions that clearly started in an input field do not ignore the replay"
    )

    assertEqual(
        shouldIgnoreFirstSessionClipboardReplay(
            currentClipboard: "seed",
            userOriginalClipboard: "seed",
            sessionStartInputFieldState: .outsideInputField,
            hasAudioRecordingStarted: true,
            hasAlreadyIgnoredReplay: false
        ),
        false,
        "audio start ends the initial replay guard"
    )

    assertEqual(
        shouldIgnoreFirstSessionClipboardReplay(
            currentClipboard: "seed",
            userOriginalClipboard: "seed",
            sessionStartInputFieldState: .outsideInputField,
            hasAudioRecordingStarted: false,
            hasAlreadyIgnoredReplay: true
        ),
        false,
        "the initial replay guard only applies once per session"
    )

    assertEqual(
        shouldIgnoreFirstSessionClipboardReplay(
            currentClipboard: "fresh",
            userOriginalClipboard: "seed",
            sessionStartInputFieldState: .outsideInputField,
            hasAudioRecordingStarted: false,
            hasAlreadyIgnoredReplay: false
        ),
        false,
        "different clipboard content is still captured normally"
    )
}

@main
struct ClipboardTransientActivityRegressionRunner {
    static func main() {
        runClipboardTransientActivityRegressionTests()
    }
}
