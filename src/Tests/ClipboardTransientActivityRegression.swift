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
    let markerObservedAt = Date(timeIntervalSince1970: 50)
    var markerSequence = IgnoredClipboardMarkerSequenceTracker()
    assertEqual(
        markerSequence.decision(
            changeCount: 100,
            containsIgnoredMarker: true,
            observedAt: markerObservedAt
        ) == .ignoreMarker,
        true,
        "a marked clipboard operation starts an ignored sequence"
    )
    assertEqual(
        markerSequence.decision(
            changeCount: 101,
            containsIgnoredMarker: false,
            observedAt: markerObservedAt.addingTimeInterval(0.5)
        ) == .ignoreFollowUp,
        true,
        "the immediate unmarked successor of a marked operation is ignored"
    )
    assertEqual(
        markerSequence.decision(
            changeCount: 101,
            containsIgnoredMarker: false,
            observedAt: markerObservedAt.addingTimeInterval(0.6)
        ) == .ignorePreviouslyClassified,
        true,
        "the global and session samplers share the ignored successor classification"
    )
    assertEqual(
        markerSequence.decision(
            changeCount: 102,
            containsIgnoredMarker: false,
            observedAt: markerObservedAt.addingTimeInterval(0.7)
        ) == .capture,
        true,
        "normal clipboard activity resumes after the single ignored successor"
    )

    var skippedCountSequence = IgnoredClipboardMarkerSequenceTracker()
    _ = skippedCountSequence.decision(
        changeCount: 200,
        containsIgnoredMarker: true,
        observedAt: markerObservedAt
    )
    assertEqual(
        skippedCountSequence.decision(
            changeCount: 202,
            containsIgnoredMarker: false,
            observedAt: markerObservedAt.addingTimeInterval(0.2)
        ) == .capture,
        true,
        "a count jump is not broadly suppressed as transient follow-up activity"
    )

    var expiredSequence = IgnoredClipboardMarkerSequenceTracker()
    _ = expiredSequence.decision(
        changeCount: 300,
        containsIgnoredMarker: true,
        observedAt: markerObservedAt
    )
    assertEqual(
        expiredSequence.decision(
            changeCount: 301,
            containsIgnoredMarker: false,
            observedAt: markerObservedAt.addingTimeInterval(IGNORED_MARKER_FOLLOW_UP_WINDOW + 0.01)
        ) == .capture,
        true,
        "a later genuine copy is not suppressed after the follow-up window expires"
    )

    var repeatedMarkerSequence = IgnoredClipboardMarkerSequenceTracker()
    _ = repeatedMarkerSequence.decision(
        changeCount: 400,
        containsIgnoredMarker: true,
        observedAt: markerObservedAt
    )
    _ = repeatedMarkerSequence.decision(
        changeCount: 401,
        containsIgnoredMarker: true,
        observedAt: markerObservedAt.addingTimeInterval(0.1)
    )
    assertEqual(
        repeatedMarkerSequence.decision(
            changeCount: 402,
            containsIgnoredMarker: false,
            observedAt: markerObservedAt.addingTimeInterval(0.2)
        ) == .ignoreFollowUp,
        true,
        "a newer marker replaces the pending successor from an earlier marker"
    )

    var outOfOrderSequence = IgnoredClipboardMarkerSequenceTracker()
    _ = outOfOrderSequence.decision(
        changeCount: 500,
        containsIgnoredMarker: true,
        observedAt: markerObservedAt.addingTimeInterval(0.2)
    )
    assertEqual(
        outOfOrderSequence.decision(
            changeCount: 499,
            containsIgnoredMarker: false,
            observedAt: markerObservedAt.addingTimeInterval(0.1)
        ) == .capture,
        true,
        "an older queued sample does not consume a newer marker sequence"
    )
    assertEqual(
        outOfOrderSequence.decision(
            changeCount: 501,
            containsIgnoredMarker: false,
            observedAt: markerObservedAt.addingTimeInterval(0.3)
        ) == .ignoreFollowUp,
        true,
        "the marked successor remains ignored after an older queued sample"
    )

    var resetSequence = IgnoredClipboardMarkerSequenceTracker()
    _ = resetSequence.decision(
        changeCount: 600,
        containsIgnoredMarker: true,
        observedAt: markerObservedAt
    )
    resetSequence.reset()
    assertEqual(
        resetSequence.decision(
            changeCount: 601,
            containsIgnoredMarker: false,
            observedAt: markerObservedAt.addingTimeInterval(0.1)
        ) == .capture,
        true,
        "a fresh clipboard capture boundary clears pending marker suppression"
    )

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

    let folderDetectedAt = Date(timeIntervalSince1970: 200)
    let startupGuardEndsAt = folderDetectedAt.addingTimeInterval(5)

    assertEqual(
        isSameContentClipboardRewrite(currentClipboard: "seed", previousClipboard: "seed"),
        true,
        "a new pasteboard write with unchanged string content is classified as a rewrite"
    )
    assertEqual(
        isSameContentClipboardRewrite(currentClipboard: "fresh", previousClipboard: "seed"),
        false,
        "different clipboard content is not classified as a rewrite"
    )
    assertEqual(
        isSameContentClipboardRewrite(currentClipboard: nil, previousClipboard: "seed"),
        false,
        "missing clipboard content is not classified as a same-content rewrite"
    )

    let preFolderReplay = evaluateSessionStartClipboardReplay(
        isSameContentRewrite: true,
        sessionStartTime: folderDetectedAt,
        guardEndsAt: startupGuardEndsAt,
        observedAt: folderDetectedAt.addingTimeInterval(-2.2),
        lookback: 3
    )
    assertEqual(preFolderReplay.shouldIgnore, true, "same-content replay 2.2 seconds before folder detection is ignored")
    assertDecision(preFolderReplay.decision, .ignoredStartupReplay, "pre-folder replay is diagnosed explicitly")
    assertEqual(preFolderReplay.matchesPreviousClipboard, true, "startup replay reports a previous-content match")
    assertEqual(preFolderReplay.millisecondsFromSessionStart == -2200, true, "pre-folder diagnostics preserve signed timing")

    let tooEarlyReplay = evaluateSessionStartClipboardReplay(
        isSameContentRewrite: true,
        sessionStartTime: folderDetectedAt,
        guardEndsAt: startupGuardEndsAt,
        observedAt: folderDetectedAt.addingTimeInterval(-3.01),
        lookback: 3
    )
    assertEqual(tooEarlyReplay.shouldIgnore, false, "same-content copy before the three-second lookback remains eligible")
    assertDecision(tooEarlyReplay.decision, .capturedBeforeWindow, "too-early copies have a distinct diagnostic decision")

    let liveStartupReplay = evaluateSessionStartClipboardReplay(
        isSameContentRewrite: true,
        sessionStartTime: folderDetectedAt,
        guardEndsAt: startupGuardEndsAt,
        observedAt: folderDetectedAt.addingTimeInterval(0.074),
        lookback: 3
    )
    assertEqual(liveStartupReplay.shouldIgnore, true, "captured 74ms post-folder Superwhisper replay is ignored")

    let lateStartupReplay = evaluateSessionStartClipboardReplay(
        isSameContentRewrite: true,
        sessionStartTime: folderDetectedAt,
        guardEndsAt: startupGuardEndsAt,
        observedAt: folderDetectedAt.addingTimeInterval(4.999),
        lookback: 3
    )
    assertEqual(lateStartupReplay.shouldIgnore, true, "same-content replay remains ignored through the five-second forward window")

    let expiredReplay = evaluateSessionStartClipboardReplay(
        isSameContentRewrite: true,
        sessionStartTime: folderDetectedAt,
        guardEndsAt: startupGuardEndsAt,
        observedAt: folderDetectedAt.addingTimeInterval(5.001),
        lookback: 3
    )
    assertEqual(expiredReplay.shouldIgnore, false, "matching clipboard content is captured after the startup window expires")
    assertDecision(expiredReplay.decision, .capturedAfterWindow, "expired matching content has a distinct diagnostic decision")

    let differentContent = evaluateSessionStartClipboardReplay(
        isSameContentRewrite: false,
        sessionStartTime: folderDetectedAt,
        guardEndsAt: startupGuardEndsAt,
        observedAt: folderDetectedAt.addingTimeInterval(0.25),
        lookback: 3
    )
    assertEqual(differentContent.shouldIgnore, false, "genuine content changes remain eligible during startup")
    assertDecision(differentContent.decision, .capturedDifferentContent, "different content is diagnosed without exposing it")

    let actionStarted = evaluateSessionStartClipboardReplay(
        isSameContentRewrite: true,
        sessionStartTime: folderDetectedAt,
        guardEndsAt: nil,
        observedAt: folderDetectedAt.addingTimeInterval(0.25),
        lookback: 3
    )
    assertEqual(actionStarted.shouldIgnore, false, "action start removes startup replay suppression immediately")
    assertDecision(actionStarted.decision, .capturedGuardEnded, "ended guard has an explicit diagnostic decision")

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
