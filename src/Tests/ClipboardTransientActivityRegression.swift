import Foundation

private func assertEqual(_ actual: Bool, _ expected: Bool, _ label: String) {
    if actual != expected {
        fputs("FAIL: \(label)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func assertDecision(
    _ actual: SessionStartClipboardReplayDecision,
    _ expected: SessionStartClipboardReplayDecision,
    _ label: String
) {
    assertEqual(actual == expected, true, label)
}

private func runClipboardTransientActivityRegressionTests() {
    assertEqual(
        clipboardObservationMergeDecision(
            hasExistingObservation: true,
            existingContent: nil,
            incomingContent: "resolved payload"
        ) == .upgradeMissingContent,
        true,
        "a later sample repairs missing content for the same pasteboard operation"
    )
    assertEqual(
        clipboardObservationMergeDecision(
            hasExistingObservation: true,
            existingContent: "first complete sample",
            incomingContent: "later different sample"
        ) == .keepExisting,
        true,
        "a complete first sample is not overwritten by another sampler"
    )
    assertEqual(
        clipboardObservationMergeDecision(
            hasExistingObservation: false,
            existingContent: nil,
            incomingContent: "same user content"
        ) == .append,
        true,
        "a separate copy operation remains eligible even when its content is identical"
    )

    let filteredRepresentations = makeClipboardContextRepresentations(
        candidates: ["earlier", "superwhisper result"],
        swResult: "superwhisper result"
    )
    assertEqual(filteredRepresentations.single == "earlier", true, "single clipboard context falls back after filtering the latest Superwhisper result")
    assertEqual(filteredRepresentations.stacked == "earlier", true, "stacked clipboard context uses the same filtered candidate set")

    let multipleRepresentations = makeClipboardContextRepresentations(
        candidates: ["first", "", "superwhisper result", "second"],
        swResult: "superwhisper result"
    )
    assertEqual(multipleRepresentations.single == "second", true, "single clipboard context returns the latest eligible candidate")
    assertEqual(
        multipleRepresentations.stacked == "<clipboard-context-1>\nfirst\n</clipboard-context-1>\n\n<clipboard-context-2>\nsecond\n</clipboard-context-2>",
        true,
        "stacked clipboard context preserves all eligible candidates in order"
    )

    let resetBoundary = Date(timeIntervalSince1970: 100)
    assertEqual(
        shouldIncludeClipboardChange(
            timestamp: Date(timeIntervalSince1970: 99),
            resetAt: resetBoundary
        ),
        false,
        "clipboard changes captured before reset are excluded"
    )
    assertEqual(
        shouldIncludeClipboardChange(
            timestamp: Date(timeIntervalSince1970: 101),
            resetAt: resetBoundary
        ),
        true,
        "clipboard changes captured after reset are included"
    )
    assertEqual(
        shouldIncludeClipboardChange(
            timestamp: Date(timeIntervalSince1970: 99),
            resetAt: nil
        ),
        true,
        "clipboard changes remain eligible when no reset occurred"
    )

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

    let firstReplayAt = Date(timeIntervalSince1970: 200)
    let firstReplay = evaluateSessionStartClipboardReplay(
        currentClipboard: "seed",
        userOriginalClipboard: "seed",
        sessionStartInputFieldState: .outsideInputField,
        hasAudioRecordingStarted: false,
        observedAt: firstReplayAt,
        firstReplayObservedAt: nil,
        replayClusterWindow: 1.0
    )
    assertEqual(firstReplay.shouldIgnore, true, "outside-input-field sessions ignore the first matching replay")
    assertDecision(firstReplay.decision, .ignoredInitialReplay, "the first matching replay is diagnosed explicitly")
    assertEqual(firstReplay.matchesSessionStartClipboard, true, "the first replay reports a session-start clipboard match")
    assertEqual(firstReplay.millisecondsSinceFirstReplay == 0, true, "the first replay starts the diagnostic clock at zero")

    let secondReplay = evaluateSessionStartClipboardReplay(
        currentClipboard: "seed",
        userOriginalClipboard: "seed",
        sessionStartInputFieldState: .outsideInputField,
        hasAudioRecordingStarted: false,
        observedAt: firstReplayAt.addingTimeInterval(0.25),
        firstReplayObservedAt: firstReplayAt,
        replayClusterWindow: 1.0
    )
    assertEqual(secondReplay.shouldIgnore, true, "a second matching replay inside the cluster window is ignored")
    assertDecision(secondReplay.decision, .ignoredReplayCluster, "repeat replays are diagnosed as cluster members")
    assertEqual(secondReplay.millisecondsSinceFirstReplay == 250, true, "repeat replay diagnostics include elapsed milliseconds")

    let thirdReplay = evaluateSessionStartClipboardReplay(
        currentClipboard: "seed",
        userOriginalClipboard: "seed",
        sessionStartInputFieldState: .outsideInputField,
        hasAudioRecordingStarted: false,
        observedAt: firstReplayAt.addingTimeInterval(0.9),
        firstReplayObservedAt: firstReplayAt,
        replayClusterWindow: 1.0
    )
    assertEqual(thirdReplay.shouldIgnore, true, "multiple matching replay writes remain ignored inside the bounded cluster")

    let expiredReplay = evaluateSessionStartClipboardReplay(
        currentClipboard: "seed",
        userOriginalClipboard: "seed",
        sessionStartInputFieldState: .outsideInputField,
        hasAudioRecordingStarted: false,
        observedAt: firstReplayAt.addingTimeInterval(1.01),
        firstReplayObservedAt: firstReplayAt,
        replayClusterWindow: 1.0
    )
    assertEqual(expiredReplay.shouldIgnore, false, "matching clipboard content is captured after the replay cluster expires")
    assertDecision(expiredReplay.decision, .capturedReplayClusterExpired, "expired matching content has a distinct diagnostic decision")

    let differentContent = evaluateSessionStartClipboardReplay(
        currentClipboard: "fresh",
        userOriginalClipboard: "seed",
        sessionStartInputFieldState: .outsideInputField,
        hasAudioRecordingStarted: false,
        observedAt: firstReplayAt.addingTimeInterval(0.25),
        firstReplayObservedAt: firstReplayAt,
        replayClusterWindow: 1.0
    )
    assertEqual(differentContent.shouldIgnore, false, "different clipboard content is captured during the replay cluster window")
    assertDecision(differentContent.decision, .capturedDifferentContent, "different clipboard content is diagnosed without exposing it")
    assertEqual(differentContent.matchesSessionStartClipboard, false, "different content reports no session-start match")

    let unknownInputField = evaluateSessionStartClipboardReplay(
        currentClipboard: "seed",
        userOriginalClipboard: "seed",
        sessionStartInputFieldState: .unknown,
        hasAudioRecordingStarted: false,
        observedAt: firstReplayAt,
        firstReplayObservedAt: nil,
        replayClusterWindow: 1.0
    )
    assertEqual(unknownInputField.shouldIgnore, true, "unknown input-field state still enables startup replay protection")

    let inputFieldSession = evaluateSessionStartClipboardReplay(
        currentClipboard: "seed",
        userOriginalClipboard: "seed",
        sessionStartInputFieldState: .inInputField,
        hasAudioRecordingStarted: false,
        observedAt: firstReplayAt,
        firstReplayObservedAt: nil,
        replayClusterWindow: 1.0
    )
    assertEqual(inputFieldSession.shouldIgnore, false, "sessions that clearly start in an input field capture matching clipboard activity")
    assertDecision(inputFieldSession.decision, .capturedInputFieldSession, "input-field capture has an explicit diagnostic decision")

    let audioStarted = evaluateSessionStartClipboardReplay(
        currentClipboard: "seed",
        userOriginalClipboard: "seed",
        sessionStartInputFieldState: .outsideInputField,
        hasAudioRecordingStarted: true,
        observedAt: firstReplayAt.addingTimeInterval(0.25),
        firstReplayObservedAt: firstReplayAt,
        replayClusterWindow: 1.0
    )
    assertEqual(audioStarted.shouldIgnore, false, "audio start ends replay-cluster suppression immediately")
    assertDecision(audioStarted.decision, .capturedAudioStarted, "post-audio capture has an explicit diagnostic decision")

    assertEqual(
        executionGroupJoinDecision(
            age: 1,
            hasExecutingAction: false,
            hasPendingRestore: false
        ) == .noActiveOperation,
        true,
        "a recording waiting only for a result is not eligible for execution-group reuse"
    )
    assertEqual(
        executionGroupJoinDecision(
            age: 1,
            hasExecutingAction: true,
            hasPendingRestore: false
        ) == .executingAction,
        true,
        "a short active action overlap can reuse its execution group"
    )
    assertEqual(
        executionGroupJoinDecision(
            age: 1,
            hasExecutingAction: false,
            hasPendingRestore: true
        ) == .pendingRestore,
        true,
        "a short pending clipboard restore can reuse its execution group"
    )
    assertEqual(
        executionGroupJoinDecision(
            age: 30,
            hasExecutingAction: true,
            hasPendingRestore: true,
            maximumAge: 10
        ) == .stale,
        true,
        "stale execution groups are never reused even if their flags remain active"
    )

    let monitor = ClipboardMonitor(
        logger: Logger(),
        preRecordingBufferSeconds: 0,
        clipboardIgnore: ""
    )
    let overlappingRoot = "/tmp/macrowhisper-overlap-root"
    let overlappingChild = "/tmp/macrowhisper-overlap-child"
    monitor.startEarlyMonitoring(for: overlappingRoot)
    monitor.startActionExecution(for: overlappingRoot)
    monitor.startEarlyMonitoring(for: overlappingChild)
    assertEqual(
        monitor.getContextRootRecordingPath(for: overlappingChild) == overlappingRoot,
        true,
        "a genuine active-action overlap shares the root context"
    )

    let abortSummary = monitor.abortExecutionGroups(
        containing: [overlappingRoot],
        reason: "regression test"
    )
    assertEqual(abortSummary.groupCount == 1, true, "recovery abort removes the targeted execution group")
    assertEqual(abortSummary.sessionCount == 2, true, "recovery abort removes every session in the targeted group")
    assertEqual(
        monitor.getContextRootRecordingPath(for: overlappingChild) == overlappingChild,
        true,
        "recovery abort removes stale child-to-root mappings"
    )
    assertEqual(
        monitor.getMostRecentActiveRecordingPath() == nil,
        true,
        "recovery abort leaves no active clipboard session behind"
    )

    let staleRoot = "/tmp/macrowhisper-stale-root"
    let freshRecording = "/tmp/macrowhisper-fresh-recording"
    monitor.startEarlyMonitoring(
        for: staleRoot,
        sessionStartTime: Date().addingTimeInterval(-30)
    )
    monitor.startActionExecution(for: staleRoot)
    monitor.startEarlyMonitoring(for: freshRecording)
    assertEqual(
        monitor.getContextRootRecordingPath(for: freshRecording) == freshRecording,
        true,
        "a fresh recording does not inherit context from a stale active group"
    )
    _ = monitor.abortExecutionGroups(
        containing: [staleRoot, freshRecording],
        reason: "regression test cleanup"
    )
}

@main
struct ClipboardTransientActivityRegressionRunner {
    static func main() {
        runClipboardTransientActivityRegressionTests()
    }
}
