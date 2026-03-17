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
        hasMappedRightEvidence: true
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
        hasMappedRightEvidence: true
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
        hasMappedRightEvidence: true
    )
    assertEqual(
        SmartInsertHeuristics.shouldAllowBrowserDescendantOverride(inputRoleOverride),
        true,
        "input-like descendants are not blocked by the non-input override guard"
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
