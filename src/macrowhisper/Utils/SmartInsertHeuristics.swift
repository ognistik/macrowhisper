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
    }

    private static let inputLikeRoles: Set<String> = [
        "AXTextArea",
        "AXTextField",
        "AXSearchField",
        "AXComboBox"
    ]

    static func shouldAllowBrowserDescendantOverride(_ evidence: BrowserOverrideEvidence) -> Bool {
        guard !inputLikeRoles.contains(evidence.role) else {
            return true
        }

        let deltaFromRootSelection = abs(evidence.mappedRootLocation - evidence.rootSelectionLocation)
        guard deltaFromRootSelection > 0 else {
            return true
        }

        if !evidence.hasLocalLeftEvidence && evidence.hasMappedLeftEvidence {
            return false
        }

        if !evidence.hasLocalRightEvidence && evidence.hasMappedRightEvidence {
            return false
        }

        return true
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
