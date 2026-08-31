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
    let diagnosticContent = "private clipboard payload"
    let diagnosticMetadata = makeClipboardObservationDiagnosticMetadata(
        changeCount: 703,
        previousChangeCount: 700,
        observedAt: Date(timeIntervalSince1970: 100),
        previousObservedAt: Date(timeIntervalSince1970: 99.625),
        content: diagnosticContent,
        previousContent: diagnosticContent,
        pasteboardTypes: ["public.utf8-plain-text", "org.example.marker"]
    )
    assertEqual(
        diagnosticMetadata.changeCountDelta == 3,
        true,
        "clipboard diagnostics expose skipped change counts"
    )
    assertEqual(
        diagnosticMetadata.elapsedMilliseconds == 375,
        true,
        "clipboard diagnostics expose observation timing"
    )
    assertEqual(
        diagnosticMetadata.contentLength == diagnosticContent.count &&
            diagnosticMetadata.matchesPreviousContent == true,
        true,
        "clipboard diagnostics describe content without needing its value"
    )
    assertEqual(
        diagnosticMetadata.pasteboardTypes == ["org.example.marker", "public.utf8-plain-text"],
        true,
        "clipboard diagnostics sort complete pasteboard type names"
    )

    let diagnosticMessage = clipboardObservationDiagnosticLogMessage(
        source: "global",
        metadata: diagnosticMetadata
    )
    assertEqual(
        diagnosticMessage.contains("delta=3 gap=true elapsedMs=375"),
        true,
        "clipboard diagnostic logs identify an unobserved change-count gap"
    )
    assertEqual(
        diagnosticMessage.contains(diagnosticContent),
        false,
        "clipboard diagnostic logs never include raw clipboard content"
    )
    assertEqual(
        diagnosticMetadata.contentToken == clipboardDiagnosticContentToken(diagnosticContent) &&
            diagnosticMetadata.contentToken != clipboardDiagnosticContentToken("different payload"),
        true,
        "clipboard diagnostic tokens correlate content only within the running process"
    )

    let missingContentDiagnostic = makeClipboardObservationDiagnosticMetadata(
        changeCount: 1,
        previousChangeCount: nil,
        observedAt: Date(timeIntervalSince1970: 1),
        previousObservedAt: nil,
        content: nil,
        previousContent: nil,
        pasteboardTypes: []
    )
    assertEqual(
        missingContentDiagnostic.changeCountDelta == nil &&
            missingContentDiagnostic.elapsedMilliseconds == nil &&
            missingContentDiagnostic.contentLength == nil &&
            missingContentDiagnostic.matchesPreviousContent == nil &&
            missingContentDiagnostic.contentToken == "none",
        true,
        "clipboard diagnostics represent unavailable baseline and content safely"
    )

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

    let inferredObservedAt = Date(timeIntervalSince1970: 75)
    var inferredRestore = InferredTransientRestoreTracker()
    assertEqual(
        inferredRestore.decision(
            changeCount: 703,
            content: "temporary transcription",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt,
            previousChangeCount: 700,
            previousContent: "user clipboard"
        ) == .captureCandidate(changeCount: 703),
        true,
        "a skipped-count content change remains captured while a restore is only possible"
    )
    assertEqual(
        inferredRestore.decision(
            changeCount: 704,
            content: "user clipboard",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt.addingTimeInterval(0.5),
            previousChangeCount: 703,
            previousContent: "temporary transcription"
        ) == .ignoreTransaction(candidateChangeCount: 703, restoreChangeCount: 704),
        true,
        "an exact prompt return to the baseline classifies the whole skipped transaction as transient"
    )
    assertEqual(
        inferredRestore.decision(
            changeCount: 703,
            content: "temporary transcription",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt.addingTimeInterval(0.6),
            previousChangeCount: 700,
            previousContent: "user clipboard"
        ) == .ignorePreviouslyClassified(candidateChangeCount: 703, restoreChangeCount: 704),
        true,
        "a delayed sampler cannot reinsert the temporary transcription"
    )
    assertEqual(
        inferredRestore.isIgnored(changeCount: 704, observedAt: inferredObservedAt.addingTimeInterval(0.7)),
        true,
        "the restoring write remains excluded for delayed sampler work"
    )

    var adjacentStartupRestore = InferredTransientRestoreTracker()
    assertEqual(
        adjacentStartupRestore.decision(
            changeCount: 1501,
            content: "selected Finder item",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt,
            previousChangeCount: 1500,
            previousContent: "user clipboard",
            restoreWindow: ADJACENT_STARTUP_TRANSIENT_RESTORE_WINDOW,
            allowAdjacentInitialCount: true
        ) == .captureCandidate(changeCount: 1501),
        true,
        "an eligible adjacent startup copy is retained while waiting for an exact restore"
    )
    assertEqual(
        adjacentStartupRestore.decision(
            changeCount: 1502,
            content: "user clipboard",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt.addingTimeInterval(0.05),
            previousChangeCount: 1501,
            previousContent: "selected Finder item",
            canArmCandidate: false
        ) == .ignoreTransaction(candidateChangeCount: 1501, restoreChangeCount: 1502),
        true,
        "an immediate adjacent return to the startup clipboard excludes the whole transaction"
    )

    var nonAdjacentStartupCandidate = InferredTransientRestoreTracker()
    assertEqual(
        nonAdjacentStartupCandidate.decision(
            changeCount: 1552,
            content: "possible startup copy",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt,
            previousChangeCount: 1550,
            previousContent: "user clipboard",
            restoreWindow: ADJACENT_STARTUP_TRANSIENT_RESTORE_WINDOW,
            allowAdjacentInitialCount: true
        ) == .capture,
        true,
        "the startup exception requires an exact one-count transition"
    )

    var adjacentStartupWithoutRestore = InferredTransientRestoreTracker()
    _ = adjacentStartupWithoutRestore.decision(
        changeCount: 1601,
        content: "genuine user copy",
        containsIgnoredMarker: false,
        observedAt: inferredObservedAt,
        previousChangeCount: 1600,
        previousContent: "user clipboard",
        restoreWindow: ADJACENT_STARTUP_TRANSIENT_RESTORE_WINDOW,
        allowAdjacentInitialCount: true
    )
    assertEqual(
        adjacentStartupWithoutRestore.decision(
            changeCount: 1602,
            content: "another genuine copy",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt.addingTimeInterval(0.05),
            previousChangeCount: 1601,
            previousContent: "genuine user copy",
            canArmCandidate: false
        ) == .capture,
        true,
        "an adjacent startup copy remains eligible when the next write does not restore the baseline"
    )

    var expiredAdjacentStartupRestore = InferredTransientRestoreTracker()
    _ = expiredAdjacentStartupRestore.decision(
        changeCount: 1701,
        content: "temporary startup copy",
        containsIgnoredMarker: false,
        observedAt: inferredObservedAt,
        previousChangeCount: 1700,
        previousContent: "user clipboard",
        restoreWindow: 0.1,
        allowAdjacentInitialCount: true
    )
    assertEqual(
        expiredAdjacentStartupRestore.decision(
            changeCount: 1702,
            content: "user clipboard",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt.addingTimeInterval(0.11),
            previousChangeCount: 1701,
            previousContent: "temporary startup copy",
            canArmCandidate: false
        ) == .capture,
        true,
        "an adjacent return after the candidate's narrow restore window remains eligible"
    )

    var resolveOnly = InferredTransientRestoreTracker()
    assertEqual(
        resolveOnly.decision(
            changeCount: 1803,
            content: "unclassified change",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt,
            previousChangeCount: 1800,
            previousContent: "baseline",
            canArmCandidate: false
        ) == .capture,
        true,
        "restore-first classification never arms a new transient candidate"
    )

    var normalSingleCopy = InferredTransientRestoreTracker()
    assertEqual(
        normalSingleCopy.decision(
            changeCount: 801,
            content: "normal copy",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt,
            previousChangeCount: 800,
            previousContent: "before"
        ) == .capture,
        true,
        "an ordinary unmarked single clipboard write remains captured"
    )

    var noRestore = InferredTransientRestoreTracker()
    _ = noRestore.decision(
        changeCount: 903,
        content: "first normal copy",
        containsIgnoredMarker: false,
        observedAt: inferredObservedAt,
        previousChangeCount: 900,
        previousContent: "before"
    )
    assertEqual(
        noRestore.decision(
            changeCount: 904,
            content: "second normal copy",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt.addingTimeInterval(0.2),
            previousChangeCount: 903,
            previousContent: "first normal copy"
        ) == .capture,
        true,
        "rapid non-restoring clipboard changes remain captured"
    )

    var expiredRestore = InferredTransientRestoreTracker()
    _ = expiredRestore.decision(
        changeCount: 1003,
        content: "temporary",
        containsIgnoredMarker: false,
        observedAt: inferredObservedAt,
        previousChangeCount: 1000,
        previousContent: "baseline"
    )
    assertEqual(
        expiredRestore.decision(
            changeCount: 1004,
            content: "baseline",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt.addingTimeInterval(INFERRED_TRANSIENT_RESTORE_WINDOW + 0.01),
            previousChangeCount: 1003,
            previousContent: "temporary"
        ) == .capture,
        true,
        "a later recopy of the baseline remains captured after the restore window"
    )

    var nonAdjacentRestore = InferredTransientRestoreTracker()
    _ = nonAdjacentRestore.decision(
        changeCount: 1103,
        content: "temporary",
        containsIgnoredMarker: false,
        observedAt: inferredObservedAt,
        previousChangeCount: 1100,
        previousContent: "baseline"
    )
    assertEqual(
        nonAdjacentRestore.decision(
            changeCount: 1105,
            content: "baseline",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt.addingTimeInterval(0.2),
            previousChangeCount: 1103,
            previousContent: "temporary"
        ) == .capture,
        true,
        "a non-adjacent return to baseline is not inferred as a transient restore"
    )

    var insufficientGap = InferredTransientRestoreTracker()
    assertEqual(
        insufficientGap.decision(
            changeCount: 1202,
            content: "possible temporary",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt,
            previousChangeCount: 1200,
            previousContent: "baseline"
        ) == .capture,
        true,
        "a two-count gap is too small to infer hidden transient writes"
    )

    var markerBoundary = InferredTransientRestoreTracker()
    assertEqual(
        markerBoundary.decision(
            changeCount: 1303,
            content: "marked temporary",
            containsIgnoredMarker: true,
            observedAt: inferredObservedAt,
            previousChangeCount: 1300,
            previousContent: "baseline"
        ) == .capture,
        true,
        "explicitly marked activity does not arm the missed-marker restore inference"
    )
    assertEqual(
        markerBoundary.decision(
            changeCount: 1304,
            content: "baseline",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt.addingTimeInterval(0.2),
            previousChangeCount: 1303,
            previousContent: "marked temporary"
        ) == .capture,
        true,
        "an explicit marker boundary cannot suppress a later unmarked observation through inference"
    )

    var cancelledCandidate = InferredTransientRestoreTracker()
    _ = cancelledCandidate.decision(
        changeCount: 1353,
        content: "possible temporary",
        containsIgnoredMarker: false,
        observedAt: inferredObservedAt,
        previousChangeCount: 1350,
        previousContent: "baseline"
    )
    cancelledCandidate.cancelPendingCandidate(
        boundaryChangeCount: 1353,
        observedAt: inferredObservedAt.addingTimeInterval(0.1)
    )
    assertEqual(
        cancelledCandidate.decision(
            changeCount: 1354,
            content: "baseline",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt.addingTimeInterval(0.2),
            previousChangeCount: 1353,
            previousContent: "possible temporary"
        ) == .capture,
        true,
        "an ignored application or internal clipboard boundary cancels pending inference"
    )

    var olderBoundary = InferredTransientRestoreTracker()
    _ = olderBoundary.decision(
        changeCount: 1373,
        content: "temporary",
        containsIgnoredMarker: false,
        observedAt: inferredObservedAt.addingTimeInterval(0.2),
        previousChangeCount: 1370,
        previousContent: "baseline"
    )
    olderBoundary.cancelPendingCandidate(
        boundaryChangeCount: 1372,
        observedAt: inferredObservedAt.addingTimeInterval(0.1)
    )
    assertEqual(
        olderBoundary.decision(
            changeCount: 1374,
            content: "baseline",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt.addingTimeInterval(0.3),
            previousChangeCount: 1373,
            previousContent: "temporary"
        ) == .ignoreTransaction(candidateChangeCount: 1373, restoreChangeCount: 1374),
        true,
        "an older ignored boundary does not cancel a newer restore candidate"
    )

    var inferredOutOfOrder = InferredTransientRestoreTracker()
    _ = inferredOutOfOrder.decision(
        changeCount: 1403,
        content: "temporary",
        containsIgnoredMarker: false,
        observedAt: inferredObservedAt.addingTimeInterval(0.2),
        previousChangeCount: 1400,
        previousContent: "baseline"
    )
    assertEqual(
        inferredOutOfOrder.decision(
            changeCount: 1402,
            content: "older queued content",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt.addingTimeInterval(0.1),
            previousChangeCount: 1400,
            previousContent: "baseline"
        ) == .capture,
        true,
        "an older queued sample does not consume a newer restore candidate"
    )
    assertEqual(
        inferredOutOfOrder.decision(
            changeCount: 1404,
            content: "baseline",
            containsIgnoredMarker: false,
            observedAt: inferredObservedAt.addingTimeInterval(0.3),
            previousChangeCount: 1403,
            previousContent: "temporary"
        ) == .ignoreTransaction(candidateChangeCount: 1403, restoreChangeCount: 1404),
        true,
        "the restore candidate survives an older queued sampler observation"
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
        shouldAllowAdjacentStartupTransientCandidate(
            sessionStartInputFieldState: .outsideInputField,
            sessionStartTime: folderDetectedAt,
            startupReplayGuardEndsAt: startupGuardEndsAt,
            startingChangeCount: 66,
            changeCount: 67,
            observedAt: folderDetectedAt.addingTimeInterval(0.087)
        ),
        true,
        "the first prompt outside-input clipboard change can begin an adjacent restore transaction"
    )
    assertEqual(
        shouldAllowAdjacentStartupTransientCandidate(
            sessionStartInputFieldState: .inInputField,
            sessionStartTime: folderDetectedAt,
            startupReplayGuardEndsAt: startupGuardEndsAt,
            startingChangeCount: 66,
            changeCount: 67,
            observedAt: folderDetectedAt.addingTimeInterval(0.087)
        ),
        false,
        "input-field sessions keep ordinary adjacent clipboard capture behavior"
    )
    assertEqual(
        shouldAllowAdjacentStartupTransientCandidate(
            sessionStartInputFieldState: .unknown,
            sessionStartTime: folderDetectedAt,
            startupReplayGuardEndsAt: startupGuardEndsAt,
            startingChangeCount: 66,
            changeCount: 67,
            observedAt: folderDetectedAt.addingTimeInterval(0.087)
        ),
        false,
        "unknown input-field state does not enable the different-content startup exception"
    )
    assertEqual(
        shouldAllowAdjacentStartupTransientCandidate(
            sessionStartInputFieldState: .outsideInputField,
            sessionStartTime: folderDetectedAt,
            startupReplayGuardEndsAt: startupGuardEndsAt,
            startingChangeCount: 66,
            changeCount: 68,
            observedAt: folderDetectedAt.addingTimeInterval(0.087)
        ),
        false,
        "only the first change count after session start receives the adjacent transaction exception"
    )
    assertEqual(
        shouldAllowAdjacentStartupTransientCandidate(
            sessionStartInputFieldState: .outsideInputField,
            sessionStartTime: folderDetectedAt,
            startupReplayGuardEndsAt: startupGuardEndsAt,
            startingChangeCount: 66,
            changeCount: 67,
            observedAt: folderDetectedAt.addingTimeInterval(
                ADJACENT_STARTUP_TRANSIENT_CANDIDATE_WINDOW + 0.001
            )
        ),
        false,
        "later outside-input copies are not reclassified as startup restore candidates"
    )
    assertEqual(
        shouldAllowAdjacentStartupTransientCandidate(
            sessionStartInputFieldState: .outsideInputField,
            sessionStartTime: folderDetectedAt,
            startupReplayGuardEndsAt: nil,
            startingChangeCount: 66,
            changeCount: 67,
            observedAt: folderDetectedAt.addingTimeInterval(0.087)
        ),
        false,
        "action execution closes the adjacent startup transaction window"
    )

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

    let attachmentStoreRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("macrowhisper-transient-test-attachments-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: attachmentStoreRoot) }
    let monitor = ClipboardMonitor(
        logger: Logger(),
        preRecordingBufferSeconds: 0,
        clipboardIgnore: "",
        attachmentFileStore: ClipboardAttachmentFileStore(rootDirectory: attachmentStoreRoot)
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
