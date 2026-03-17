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
        SmartInsertHeuristics.isAmbiguousBrowserNewlineBoundary(
            leftCharacter: ".".first,
            leftNonWhitespaceCharacter: ".".first,
            rightCharacter: "\n".first,
            rightNonWhitespaceCharacter: "S".first,
            rightHasLineBreakBeforeNextNonWhitespace: true
        ),
        true,
        "ambiguous browser newline boundary is detected from root AX punctuation-newline-uppercase evidence"
    )

    assertEqual(
        SmartInsertHeuristics.isAmbiguousBrowserNewlineBoundary(
            leftCharacter: ".".first,
            leftNonWhitespaceCharacter: ".".first,
            rightCharacter: "\n".first,
            rightNonWhitespaceCharacter: "s".first,
            rightHasLineBreakBeforeNextNonWhitespace: true
        ),
        false,
        "ambiguous browser newline detection stays off for lowercase continuation"
    )

    assertEqual(
        SmartInsertHeuristics.resolveAmbiguousBrowserNewlineBoundaryUsingGeometry(
            SmartInsertHeuristics.BrowserAmbiguousNewlineGeometryEvidence(
                caretMidY: 114,
                previousMidY: 112,
                nextMidY: 132
            )
        ),
        .beforeNewline,
        "browser ambiguous newline geometry resolves to before-newline when the caret stays closer to the previous line"
    )

    assertEqual(
        SmartInsertHeuristics.resolveAmbiguousBrowserNewlineBoundaryUsingGeometry(
            SmartInsertHeuristics.BrowserAmbiguousNewlineGeometryEvidence(
                caretMidY: 130,
                previousMidY: 112,
                nextMidY: 132
            )
        ),
        .lineStart,
        "browser ambiguous newline geometry resolves to line-start when the caret stays closer to the next line"
    )

    assertEqual(
        SmartInsertHeuristics.resolveAmbiguousBrowserNewlineBoundaryUsingGeometry(
            SmartInsertHeuristics.BrowserAmbiguousNewlineGeometryEvidence(
                caretMidY: 122,
                previousMidY: 112,
                nextMidY: 132
            )
        ),
        .unresolved,
        "browser ambiguous newline geometry stays unresolved when the caret is not clearly closer to either line"
    )

    assertEqual(
        SmartInsertHeuristics.shouldNormalizeAmbiguousNewlineBoundaryForSentenceInsertion(
            insertionIsSentenceLike: true,
            browserAmbiguousNewlineBoundaryResolution: .lineStart
        ),
        true,
        "sentence insertion normalizes only when browser geometry resolves the ambiguity to line-start"
    )

    assertEqual(
        SmartInsertHeuristics.shouldNormalizeAmbiguousNewlineBoundaryForSentenceInsertion(
            insertionIsSentenceLike: true,
            browserAmbiguousNewlineBoundaryResolution: .beforeNewline
        ),
        false,
        "sentence insertion keeps the root before-newline boundary when browser geometry resolves to paragraph end"
    )

    assertEqual(
        SmartInsertHeuristics.shouldNormalizeAmbiguousNewlineBoundaryForSentenceInsertion(
            insertionIsSentenceLike: true,
            browserAmbiguousNewlineBoundaryResolution: .unresolved
        ),
        false,
        "sentence insertion falls back to the root before-newline boundary when browser geometry is unavailable"
    )

    assertEqual(
        SmartInsertHeuristics.shouldCorrectBrowserInlineCaretDrift(
            SmartInsertHeuristics.BrowserInlineCaretDriftEvidence(
                caretX: 148,
                rightCharacterMaxX: 146,
                caretAndRightShareLine: true,
                rightCharacterIsWhitespace: true,
                rightCharacterIsWord: false,
                rightCharacterIsTerminalPunctuation: false,
                nextCharacterAfterRightIsWhitespace: false,
                nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation: false,
                rightCharacterFollowedBySentenceBoundaryBeforeNextNonWhitespace: false,
                nextNonWhitespaceAfterRightStartsUppercase: false
            )
        ),
        true,
        "browser inline caret drift correction shifts right when the caret is already past a reported whitespace boundary"
    )

    assertEqual(
        SmartInsertHeuristics.shouldCorrectBrowserInlineCaretDrift(
            SmartInsertHeuristics.BrowserInlineCaretDriftEvidence(
                caretX: 221,
                rightCharacterMaxX: 220,
                caretAndRightShareLine: true,
                rightCharacterIsWhitespace: false,
                rightCharacterIsWord: true,
                rightCharacterIsTerminalPunctuation: false,
                nextCharacterAfterRightIsWhitespace: true,
                nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation: false,
                rightCharacterFollowedBySentenceBoundaryBeforeNextNonWhitespace: false,
                nextNonWhitespaceAfterRightStartsUppercase: false
            )
        ),
        true,
        "browser inline caret drift correction shifts right when AX reports the caret one character before a word-ending space"
    )

    assertEqual(
        SmartInsertHeuristics.shouldCorrectBrowserInlineCaretDrift(
            SmartInsertHeuristics.BrowserInlineCaretDriftEvidence(
                caretX: 218,
                rightCharacterMaxX: 220,
                caretAndRightShareLine: true,
                rightCharacterIsWhitespace: false,
                rightCharacterIsWord: true,
                rightCharacterIsTerminalPunctuation: false,
                nextCharacterAfterRightIsWhitespace: true,
                nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation: false,
                rightCharacterFollowedBySentenceBoundaryBeforeNextNonWhitespace: false,
                nextNonWhitespaceAfterRightStartsUppercase: false
            )
        ),
        false,
        "browser inline caret drift correction stays off when the caret is still visually before the reported right character"
    )

    assertEqual(
        SmartInsertHeuristics.shouldCorrectBrowserInlineCaretDrift(
            SmartInsertHeuristics.BrowserInlineCaretDriftEvidence(
                caretX: 148,
                rightCharacterMaxX: 146,
                caretAndRightShareLine: false,
                rightCharacterIsWhitespace: true,
                rightCharacterIsWord: false,
                rightCharacterIsTerminalPunctuation: false,
                nextCharacterAfterRightIsWhitespace: false,
                nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation: false,
                rightCharacterFollowedBySentenceBoundaryBeforeNextNonWhitespace: false,
                nextNonWhitespaceAfterRightStartsUppercase: false
            )
        ),
        false,
        "browser inline caret drift correction stays off when the caret geometry is not on the same line as the reported right character"
    )

    assertEqual(
        SmartInsertHeuristics.shouldCorrectBrowserInlineCaretDrift(
            SmartInsertHeuristics.BrowserInlineCaretDriftEvidence(
                caretX: 322,
                rightCharacterMaxX: 320,
                caretAndRightShareLine: true,
                rightCharacterIsWhitespace: false,
                rightCharacterIsWord: false,
                rightCharacterIsTerminalPunctuation: true,
                nextCharacterAfterRightIsWhitespace: true,
                nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation: false,
                rightCharacterFollowedBySentenceBoundaryBeforeNextNonWhitespace: true,
                nextNonWhitespaceAfterRightStartsUppercase: true
            )
        ),
        true,
        "browser inline caret drift correction shifts right when AX reports the caret one character before sentence-final punctuation"
    )

    assertEqual(
        SmartInsertHeuristics.shouldCorrectBrowserInlineCaretDrift(
            SmartInsertHeuristics.BrowserInlineCaretDriftEvidence(
                caretX: 322,
                rightCharacterMaxX: 320,
                caretAndRightShareLine: true,
                rightCharacterIsWhitespace: false,
                rightCharacterIsWord: false,
                rightCharacterIsTerminalPunctuation: true,
                nextCharacterAfterRightIsWhitespace: true,
                nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation: false,
                rightCharacterFollowedBySentenceBoundaryBeforeNextNonWhitespace: true,
                nextNonWhitespaceAfterRightStartsUppercase: true
            )
        ),
        true,
        "browser inline caret drift correction shifts right when AX reports the caret one character before sentence-final punctuation followed by a space"
    )

    assertEqual(
        SmartInsertHeuristics.shouldCorrectBrowserInlineCaretDrift(
            SmartInsertHeuristics.BrowserInlineCaretDriftEvidence(
                caretX: 322,
                rightCharacterMaxX: 320,
                caretAndRightShareLine: true,
                rightCharacterIsWhitespace: false,
                rightCharacterIsWord: true,
                rightCharacterIsTerminalPunctuation: false,
                nextCharacterAfterRightIsWhitespace: false,
                nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation: true,
                rightCharacterFollowedBySentenceBoundaryBeforeNextNonWhitespace: true,
                nextNonWhitespaceAfterRightStartsUppercase: true
            )
        ),
        true,
        "browser inline caret drift correction shifts right when AX reports the caret before a word character whose next boundary is sentence-final punctuation"
    )

    assertEqual(
        SmartInsertHeuristics.shouldCorrectBrowserInlineCaretDrift(
            SmartInsertHeuristics.BrowserInlineCaretDriftEvidence(
                caretX: 322,
                rightCharacterMaxX: 320,
                caretAndRightShareLine: true,
                rightCharacterIsWhitespace: false,
                rightCharacterIsWord: true,
                rightCharacterIsTerminalPunctuation: false,
                nextCharacterAfterRightIsWhitespace: false,
                nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation: false,
                rightCharacterFollowedBySentenceBoundaryBeforeNextNonWhitespace: true,
                nextNonWhitespaceAfterRightStartsUppercase: true
            )
        ),
        false,
        "browser inline caret drift correction stays off for a word character when the following punctuation is not a sentence boundary"
    )

    assertEqual(
        SmartInsertHeuristics.shouldStopBrowserInlineCaretDriftAfterCorrection(
            SmartInsertHeuristics.BrowserInlineCaretDriftEvidence(
                caretX: 322,
                rightCharacterMaxX: 320,
                caretAndRightShareLine: true,
                rightCharacterIsWhitespace: false,
                rightCharacterIsWord: false,
                rightCharacterIsTerminalPunctuation: true,
                nextCharacterAfterRightIsWhitespace: true,
                nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation: false,
                rightCharacterFollowedBySentenceBoundaryBeforeNextNonWhitespace: true,
                nextNonWhitespaceAfterRightStartsUppercase: true
            )
        ),
        true,
        "browser inline caret drift walk stops at sentence-final punctuation so generic|.⏎This stays before the newline"
    )

    assertEqual(
        SmartInsertHeuristics.shouldStopBrowserInlineCaretDriftAfterCorrection(
            SmartInsertHeuristics.BrowserInlineCaretDriftEvidence(
                caretX: 322,
                rightCharacterMaxX: 320,
                caretAndRightShareLine: true,
                rightCharacterIsWhitespace: false,
                rightCharacterIsWord: true,
                rightCharacterIsTerminalPunctuation: false,
                nextCharacterAfterRightIsWhitespace: false,
                nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation: true,
                rightCharacterFollowedBySentenceBoundaryBeforeNextNonWhitespace: true,
                nextNonWhitespaceAfterRightStartsUppercase: true
            )
        ),
        false,
        "browser inline caret drift walk does not stop early on tha|t.⏎You before it reaches the sentence-final punctuation"
    )

    assertEqual(
        SmartInsertHeuristics.shouldStopBrowserInlineCaretDriftAfterCorrection(
            SmartInsertHeuristics.BrowserInlineCaretDriftEvidence(
                caretX: 148,
                rightCharacterMaxX: 146,
                caretAndRightShareLine: true,
                rightCharacterIsWhitespace: true,
                rightCharacterIsWord: false,
                rightCharacterIsTerminalPunctuation: false,
                nextCharacterAfterRightIsWhitespace: false,
                nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation: false,
                rightCharacterFollowedBySentenceBoundaryBeforeNextNonWhitespace: false,
                nextNonWhitespaceAfterRightStartsUppercase: false
            )
        ),
        false,
        "browser inline caret drift walk keeps existing space and NBSP corrections from stopping early"
    )

    assertEqual(
        SmartInsertHeuristics.shouldStopBrowserInlineCaretDriftAfterCorrection(
            SmartInsertHeuristics.BrowserInlineCaretDriftEvidence(
                caretX: 322,
                rightCharacterMaxX: 320,
                caretAndRightShareLine: true,
                rightCharacterIsWhitespace: false,
                rightCharacterIsWord: false,
                rightCharacterIsTerminalPunctuation: true,
                nextCharacterAfterRightIsWhitespace: true,
                nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation: false,
                rightCharacterFollowedBySentenceBoundaryBeforeNextNonWhitespace: true,
                nextNonWhitespaceAfterRightStartsUppercase: true
            )
        ),
        true,
        "browser inline caret drift walk stops at sentence-final punctuation so use|. Sometimes stays before the space"
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
