import Foundation

enum SmartInsertHeuristics {
    enum BrowserAmbiguousNewlineBoundaryResolution: String {
        case unresolved
        case beforeNewline
        case lineStart

        var label: String { rawValue }
    }

    struct BrowserAmbiguousNewlineGeometryEvidence {
        let caretMidY: Double
        let previousMidY: Double
        let nextMidY: Double
    }

    struct BrowserInlineCaretDriftEvidence {
        let caretX: Double
        let rightCharacterMaxX: Double
        let caretAndRightShareLine: Bool
        let rightCharacterIsWhitespace: Bool
        let rightCharacterIsWord: Bool
        let rightCharacterIsTerminalPunctuation: Bool
        let nextCharacterAfterRightIsWhitespace: Bool
        let nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation: Bool
        let rightCharacterFollowedBySentenceBoundaryBeforeNextNonWhitespace: Bool
        let nextNonWhitespaceAfterRightStartsUppercase: Bool
    }

    struct BrowserRootSelectionEvidence {
        let selectionLocation: Int
        let selectionLength: Int
        let textLength: Int
        let hasLeftEvidence: Bool
        let hasRightEvidence: Bool
    }

    struct BrowserOverrideEvidence {
        let role: String
        let mappedRootLocation: Int
        let rootSelectionLocation: Int
        let gapContainsLineBreak: Bool
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

    static func isAmbiguousBrowserNewlineBoundary(
        leftCharacter: Character?,
        leftNonWhitespaceCharacter: Character?,
        rightCharacter: Character?,
        rightNonWhitespaceCharacter: Character?,
        rightHasLineBreakBeforeNextNonWhitespace: Bool
    ) -> Bool {
        guard rightHasLineBreakBeforeNextNonWhitespace,
              rightCharacter?.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) == true,
              let rightNonWhitespaceCharacter,
              startsWithUppercaseLetter(rightNonWhitespaceCharacter) else {
            return false
        }

        let effectiveLeft: Character?
        if let leftCharacter, !leftCharacter.isWhitespace {
            effectiveLeft = leftCharacter
        } else {
            effectiveLeft = leftNonWhitespaceCharacter
        }

        guard let effectiveLeft else {
            return false
        }

        return terminalSentencePunctuation.contains(effectiveLeft)
    }

    static func resolveAmbiguousBrowserNewlineBoundaryUsingGeometry(
        _ evidence: BrowserAmbiguousNewlineGeometryEvidence
    ) -> BrowserAmbiguousNewlineBoundaryResolution {
        let lineSeparation = abs(evidence.nextMidY - evidence.previousMidY)
        guard lineSeparation >= 4 else {
            return .unresolved
        }

        let distanceToPrevious = abs(evidence.caretMidY - evidence.previousMidY)
        let distanceToNext = abs(evidence.caretMidY - evidence.nextMidY)
        let minimumConfidenceGap = max(1.5, lineSeparation * 0.12)

        if distanceToPrevious + minimumConfidenceGap < distanceToNext {
            return .beforeNewline
        }

        if distanceToNext + minimumConfidenceGap < distanceToPrevious {
            return .lineStart
        }

        return .unresolved
    }

    static func shouldNormalizeAmbiguousNewlineBoundaryForSentenceInsertion(
        insertionIsSentenceLike: Bool,
        browserAmbiguousNewlineBoundaryResolution: BrowserAmbiguousNewlineBoundaryResolution
    ) -> Bool {
        insertionIsSentenceLike && browserAmbiguousNewlineBoundaryResolution == .lineStart
    }

    static func shouldCorrectBrowserInlineCaretDrift(
        _ evidence: BrowserInlineCaretDriftEvidence
    ) -> Bool {
        guard evidence.caretAndRightShareLine else {
            return false
        }

        let caretPastRightCharacter = evidence.caretX >= evidence.rightCharacterMaxX - 1.5
        guard caretPastRightCharacter else {
            return false
        }

        if evidence.rightCharacterIsWhitespace {
            return true
        }

        if evidence.rightCharacterIsWord && evidence.nextCharacterAfterRightIsWhitespace {
            return true
        }

        if evidence.rightCharacterIsWord && evidence.nextCharacterAfterRightIsSentenceBoundaryTerminalPunctuation {
            return true
        }

        return shouldStopBrowserInlineCaretDriftAfterCorrection(evidence)
    }

    static func shouldStopBrowserInlineCaretDriftAfterCorrection(
        _ evidence: BrowserInlineCaretDriftEvidence
    ) -> Bool {
        evidence.rightCharacterIsTerminalPunctuation &&
            evidence.rightCharacterFollowedBySentenceBoundaryBeforeNextNonWhitespace &&
            evidence.nextNonWhitespaceAfterRightStartsUppercase
    }

    static func shouldInspectBrowserDescendants(_ evidence: BrowserRootSelectionEvidence) -> Bool {
        let selectionEnd = evidence.selectionLocation + evidence.selectionLength
        let missingLeftUnexpected = evidence.selectionLocation > 0 && !evidence.hasLeftEvidence
        let missingRightUnexpected = selectionEnd < evidence.textLength && !evidence.hasRightEvidence
        return missingLeftUnexpected || missingRightUnexpected
    }

    static func shouldAllowBrowserDescendantOverride(_ evidence: BrowserOverrideEvidence) -> Bool {
        guard !inputLikeRoles.contains(evidence.role) else {
            return true
        }

        let deltaFromRootSelection = abs(evidence.mappedRootLocation - evidence.rootSelectionLocation)
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

        if evidence.gapContainsLineBreak {
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
