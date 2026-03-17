import Foundation

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual != expected {
        fputs("FAIL: \(label)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func runSmartInsertHeuristicsRegressionTests() {
    let stableRootSelection = SmartInsertHeuristics.BrowserRootSelectionEvidence(
        selectionLocation: 29,
        selectionLength: 0,
        textLength: 254,
        hasLeftEvidence: true,
        hasRightEvidence: true
    )
    assertEqual(
        SmartInsertHeuristics.shouldInspectBrowserDescendants(stableRootSelection),
        false,
        "browser descendant scan stays off when the root selection already has both boundaries"
    )

    let missingRightBoundaryRootSelection = SmartInsertHeuristics.BrowserRootSelectionEvidence(
        selectionLocation: 29,
        selectionLength: 0,
        textLength: 254,
        hasLeftEvidence: true,
        hasRightEvidence: false
    )
    assertEqual(
        SmartInsertHeuristics.shouldInspectBrowserDescendants(missingRightBoundaryRootSelection),
        true,
        "browser descendant scan stays available when the root selection loses the right boundary unexpectedly"
    )

    let documentStartRootSelection = SmartInsertHeuristics.BrowserRootSelectionEvidence(
        selectionLocation: 0,
        selectionLength: 0,
        textLength: 254,
        hasLeftEvidence: false,
        hasRightEvidence: true
    )
    assertEqual(
        SmartInsertHeuristics.shouldInspectBrowserDescendants(documentStartRootSelection),
        false,
        "browser descendant scan stays off at the true document start"
    )

    assertEqual(
        SmartInsertHeuristics.shouldNormalizeAmbiguousNewlineBoundaryForSentenceInsertion(
            isBrowserApp: true,
            leftCharacter: ".".first,
            leftNonWhitespaceCharacter: ".".first,
            rightCharacter: "\n".first,
            rightNonWhitespaceCharacter: "S".first,
            rightHasLineBreakBeforeNextNonWhitespace: true,
            insertionIsSentenceLike: true
        ),
        true,
        "ambiguous newline boundary is normalized to line-start context for sentence insertion"
    )

    assertEqual(
        SmartInsertHeuristics.shouldNormalizeAmbiguousNewlineBoundaryForSentenceInsertion(
            isBrowserApp: true,
            leftCharacter: ".".first,
            leftNonWhitespaceCharacter: ".".first,
            rightCharacter: "\n".first,
            rightNonWhitespaceCharacter: "s".first,
            rightHasLineBreakBeforeNextNonWhitespace: true,
            insertionIsSentenceLike: true
        ),
        false,
        "ambiguous newline boundary normalization stays off for lowercase continuation"
    )

    assertEqual(
        SmartInsertHeuristics.shouldNormalizeAmbiguousNewlineBoundaryForSentenceInsertion(
            isBrowserApp: false,
            leftCharacter: ".".first,
            leftNonWhitespaceCharacter: ".".first,
            rightCharacter: "\n".first,
            rightNonWhitespaceCharacter: "T".first,
            rightHasLineBreakBeforeNextNonWhitespace: true,
            insertionIsSentenceLike: true
        ),
        false,
        "ambiguous newline boundary normalization stays off for non-browser text areas with a trustworthy root boundary"
    )

    let suspiciousStaticTextOverride = SmartInsertHeuristics.BrowserOverrideEvidence(
        role: "AXStaticText",
        mappedRootLocation: 38,
        rootSelectionLocation: 25,
        gapContainsLineBreak: false,
        hasLocalLeftEvidence: false,
        hasLocalRightEvidence: true,
        hasMappedLeftEvidence: true,
        hasMappedRightEvidence: true,
        mappedLeftCharacter: " ",
        mappedLeftNonWhitespaceCharacter: "t",
        mappedRightNonWhitespaceCharacter: "e"
    )
    assertEqual(
        SmartInsertHeuristics.shouldAllowBrowserDescendantOverride(suspiciousStaticTextOverride),
        false,
        "browser descendant override rejects one-sided static text fragment that disagrees with the root"
    )

    let exactMatchStaticTextOverride = SmartInsertHeuristics.BrowserOverrideEvidence(
        role: "AXStaticText",
        mappedRootLocation: 25,
        rootSelectionLocation: 25,
        gapContainsLineBreak: false,
        hasLocalLeftEvidence: false,
        hasLocalRightEvidence: true,
        hasMappedLeftEvidence: true,
        hasMappedRightEvidence: true,
        mappedLeftCharacter: " ",
        mappedLeftNonWhitespaceCharacter: ",",
        mappedRightNonWhitespaceCharacter: "t"
    )
    assertEqual(
        SmartInsertHeuristics.shouldAllowBrowserDescendantOverride(exactMatchStaticTextOverride),
        false,
        "browser descendant override rejects exact-match static text when the fragment still drops root boundary evidence"
    )

    let inputRoleOverride = SmartInsertHeuristics.BrowserOverrideEvidence(
        role: "AXTextArea",
        mappedRootLocation: 38,
        rootSelectionLocation: 25,
        gapContainsLineBreak: false,
        hasLocalLeftEvidence: false,
        hasLocalRightEvidence: true,
        hasMappedLeftEvidence: true,
        hasMappedRightEvidence: true,
        mappedLeftCharacter: " ",
        mappedLeftNonWhitespaceCharacter: "t",
        mappedRightNonWhitespaceCharacter: "e"
    )
    assertEqual(
        SmartInsertHeuristics.shouldAllowBrowserDescendantOverride(inputRoleOverride),
        true,
        "input-like descendants are not blocked by the non-input override guard"
    )

    let paragraphStartStaticTextOverride = SmartInsertHeuristics.BrowserOverrideEvidence(
        role: "AXStaticText",
        mappedRootLocation: 1025,
        rootSelectionLocation: 1021,
        gapContainsLineBreak: false,
        hasLocalLeftEvidence: false,
        hasLocalRightEvidence: true,
        hasMappedLeftEvidence: true,
        hasMappedRightEvidence: true,
        mappedLeftCharacter: "\n",
        mappedLeftNonWhitespaceCharacter: ".",
        mappedRightNonWhitespaceCharacter: "Y"
    )
    assertEqual(
        SmartInsertHeuristics.shouldAllowBrowserDescendantOverride(paragraphStartStaticTextOverride),
        true,
        "browser descendant override keeps paragraph-start static text when the mapped root boundary is structural"
    )

    let sentenceStartStaticTextOverride = SmartInsertHeuristics.BrowserOverrideEvidence(
        role: "AXStaticText",
        mappedRootLocation: 52,
        rootSelectionLocation: 48,
        gapContainsLineBreak: false,
        hasLocalLeftEvidence: false,
        hasLocalRightEvidence: true,
        hasMappedLeftEvidence: true,
        hasMappedRightEvidence: true,
        mappedLeftCharacter: " ",
        mappedLeftNonWhitespaceCharacter: ".",
        mappedRightNonWhitespaceCharacter: "Y"
    )
    assertEqual(
        SmartInsertHeuristics.shouldAllowBrowserDescendantOverride(sentenceStartStaticTextOverride),
        true,
        "browser descendant override keeps nearby sentence-start static text when the mapped boundary is strong"
    )

    let suspiciousGroupOverride = SmartInsertHeuristics.BrowserOverrideEvidence(
        role: "AXGroup",
        mappedRootLocation: 1025,
        rootSelectionLocation: 1021,
        gapContainsLineBreak: false,
        hasLocalLeftEvidence: false,
        hasLocalRightEvidence: true,
        hasMappedLeftEvidence: true,
        hasMappedRightEvidence: true,
        mappedLeftCharacter: "\n",
        mappedLeftNonWhitespaceCharacter: ".",
        mappedRightNonWhitespaceCharacter: "Y"
    )
    assertEqual(
        SmartInsertHeuristics.shouldAllowBrowserDescendantOverride(suspiciousGroupOverride),
        false,
        "browser descendant override recovery stays narrow and does not reopen generic group descendants"
    )

    let newlineGapStaticTextOverride = SmartInsertHeuristics.BrowserOverrideEvidence(
        role: "AXStaticText",
        mappedRootLocation: 170,
        rootSelectionLocation: 168,
        gapContainsLineBreak: true,
        hasLocalLeftEvidence: false,
        hasLocalRightEvidence: true,
        hasMappedLeftEvidence: true,
        hasMappedRightEvidence: true,
        mappedLeftCharacter: "\n",
        mappedLeftNonWhitespaceCharacter: ".",
        mappedRightNonWhitespaceCharacter: "H"
    )
    assertEqual(
        SmartInsertHeuristics.shouldAllowBrowserDescendantOverride(newlineGapStaticTextOverride),
        false,
        "browser descendant override rejects paragraph-start static text when the root already exposes a real newline gap"
    )

    let newlineSeparatedSentenceStartOverride = SmartInsertHeuristics.BrowserOverrideEvidence(
        role: "AXStaticText",
        mappedRootLocation: 202,
        rootSelectionLocation: 232,
        gapContainsLineBreak: true,
        hasLocalLeftEvidence: false,
        hasLocalRightEvidence: true,
        hasMappedLeftEvidence: true,
        hasMappedRightEvidence: true,
        mappedLeftCharacter: "\u{00A0}",
        mappedLeftNonWhitespaceCharacter: "?",
        mappedRightNonWhitespaceCharacter: "O"
    )
    assertEqual(
        SmartInsertHeuristics.shouldAllowBrowserDescendantOverride(newlineSeparatedSentenceStartOverride),
        false,
        "browser descendant override rejects sentence-start static text when the mapped gap crosses a real line break"
    )

    assertEqual(
        SmartInsertHeuristics.shouldInsertLeadingSpace(
            immediateLeftIsWhitespace: true,
            startsWithBoundaryNeedingLeadingSpace: true,
            isImmediatelyAfterOpeningWrapper: false,
            shouldInsertLeadingSpaceForMarkdownList: false,
            shouldInsertLeadingSpaceAfterWord: false,
            shouldInsertLeadingSpaceAfterPunctuation: true,
            shouldInsertLeadingSpaceBeforeOpeningWrapper: false
        ),
        false,
        "leading space is not duplicated when the immediate left boundary is already whitespace"
    )

    assertEqual(
        SmartInsertHeuristics.shouldInsertLeadingSpace(
            immediateLeftIsWhitespace: false,
            startsWithBoundaryNeedingLeadingSpace: true,
            isImmediatelyAfterOpeningWrapper: false,
            shouldInsertLeadingSpaceForMarkdownList: false,
            shouldInsertLeadingSpaceAfterWord: false,
            shouldInsertLeadingSpaceAfterPunctuation: true,
            shouldInsertLeadingSpaceBeforeOpeningWrapper: false
        ),
        true,
        "leading space is still added after punctuation when the left boundary has no whitespace"
    )
}

@main
struct SmartInsertHeuristicsRegressionRunner {
    static func main() {
        runSmartInsertHeuristicsRegressionTests()
    }
}
