import Foundation

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual != expected {
        fputs("FAIL: \(label)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func runSmartInsertHeuristicsRegressionTests() {
    let suspiciousStaticTextOverride = SmartInsertHeuristics.BrowserOverrideEvidence(
        role: "AXStaticText",
        mappedRootLocation: 38,
        rootSelectionLocation: 25,
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
        true,
        "browser descendant override keeps exact root matches even when the fragment is one-sided"
    )

    let inputRoleOverride = SmartInsertHeuristics.BrowserOverrideEvidence(
        role: "AXTextArea",
        mappedRootLocation: 38,
        rootSelectionLocation: 25,
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
