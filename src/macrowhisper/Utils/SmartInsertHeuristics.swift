import Foundation

enum SmartInsertHeuristics {
    struct BrowserOverrideEvidence {
        let role: String
        let mappedRootLocation: Int
        let rootSelectionLocation: Int
        let hasLocalLeftEvidence: Bool
        let hasLocalRightEvidence: Bool
        let hasMappedLeftEvidence: Bool
        let hasMappedRightEvidence: Bool
        let mappedLeftCharacter: Character?
        let mappedLeftNonWhitespaceCharacter: Character?
        let mappedRightNonWhitespaceCharacter: Character?
    }

    private static let inputLikeRoles: Set<String> = [
        "AXTextArea",
        "AXTextField",
        "AXSearchField",
        "AXComboBox"
    ]
    private static let recoverableStaticTextDeltaThreshold = 48
    private static let terminalSentencePunctuation = ".!?"

    static func shouldAllowBrowserDescendantOverride(_ evidence: BrowserOverrideEvidence) -> Bool {
        guard !inputLikeRoles.contains(evidence.role) else {
            return true
        }

        let deltaFromRootSelection = abs(evidence.mappedRootLocation - evidence.rootSelectionLocation)
        guard deltaFromRootSelection > 0 else {
            return true
        }

        if !evidence.hasLocalLeftEvidence &&
            evidence.hasMappedLeftEvidence &&
            !allowsRecoverableStaticTextLeftBoundaryGap(
                evidence,
                deltaFromRootSelection: deltaFromRootSelection
            ) {
            return false
        }

        if !evidence.hasLocalRightEvidence && evidence.hasMappedRightEvidence {
            return false
        }

        return true
    }

    private static func allowsRecoverableStaticTextLeftBoundaryGap(
        _ evidence: BrowserOverrideEvidence,
        deltaFromRootSelection: Int
    ) -> Bool {
        guard evidence.role == "AXStaticText" else {
            return false
        }

        guard deltaFromRootSelection <= recoverableStaticTextDeltaThreshold else {
            return false
        }

        if evidence.mappedRootLocation > 0 &&
            SmartInsertBoundary.isLineStartBoundary(evidence.mappedLeftCharacter) {
            return true
        }

        guard let mappedLeftNonWhitespaceCharacter = evidence.mappedLeftNonWhitespaceCharacter,
              let mappedRightNonWhitespaceCharacter = evidence.mappedRightNonWhitespaceCharacter else {
            return false
        }

        return terminalSentencePunctuation.contains(mappedLeftNonWhitespaceCharacter) &&
            startsWithUppercaseLetter(mappedRightNonWhitespaceCharacter)
    }

    private static func startsWithUppercaseLetter(_ character: Character) -> Bool {
        String(character).rangeOfCharacter(from: .uppercaseLetters) != nil
    }

    static func shouldInsertLeadingSpace(
        immediateLeftIsWhitespace: Bool,
        startsWithBoundaryNeedingLeadingSpace: Bool,
        isImmediatelyAfterOpeningWrapper: Bool,
        shouldInsertLeadingSpaceForMarkdownList: Bool,
        shouldInsertLeadingSpaceAfterWord: Bool,
        shouldInsertLeadingSpaceAfterPunctuation: Bool,
        shouldInsertLeadingSpaceBeforeOpeningWrapper: Bool
    ) -> Bool {
        guard startsWithBoundaryNeedingLeadingSpace else {
            return false
        }

        guard !isImmediatelyAfterOpeningWrapper else {
            return false
        }

        if shouldInsertLeadingSpaceForMarkdownList {
            return true
        }

        if immediateLeftIsWhitespace {
            return false
        }

        return shouldInsertLeadingSpaceAfterWord ||
            shouldInsertLeadingSpaceAfterPunctuation ||
            shouldInsertLeadingSpaceBeforeOpeningWrapper
    }
}
