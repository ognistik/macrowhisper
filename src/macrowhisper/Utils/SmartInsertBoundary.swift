import Foundation

enum SmartInsertBoundary {
    private static let boundaryConflictPunctuation = ".,;:!?"
    private static let midSentenceStrippableTrailingPunctuation = ".!?"
    private static let ignoredBoundaryScalars: Set<UnicodeScalar> = [
        "\u{FEFF}", // ZERO WIDTH NO-BREAK SPACE / BOM
        "\u{200B}", // ZERO WIDTH SPACE
        "\u{200C}", // ZERO WIDTH NON-JOINER
        "\u{200D}", // ZERO WIDTH JOINER
        "\u{2060}", // WORD JOINER
        "\u{FFFC}"  // OBJECT REPLACEMENT CHARACTER
    ]

    static func isIgnorableBoundaryCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            ignoredBoundaryScalars.contains(scalar) || scalar.properties.isJoinControl
        }
    }

    static func isSkippableTrailingDelimiterForBoundary(_ character: Character) -> Bool {
        let delimiters = "*_~`()[]{}<>\"'“”‘’«»‹›"
        return delimiters.contains(character)
    }

    static func isBoundaryConflictPunctuation(_ character: Character) -> Bool {
        boundaryConflictPunctuation.contains(character)
    }

    static func shouldInsertLeadingSpaceAfterPunctuation(_ character: Character) -> Bool {
        let punctuationNeedingTrailingSpace = ".,;:!?…)]}\"”’»›"
        return punctuationNeedingTrailingSpace.contains(character)
    }

    static func isJoinableTrailingBoundary(_ character: Character) -> Bool {
        ".,;:!?…".contains(character)
    }

    static func isMidSentenceStrippableTrailingPunctuation(_ character: Character) -> Bool {
        midSentenceStrippableTrailingPunctuation.contains(character)
    }

    static func effectiveLeftContextCharacter(
        leftCharacter: Character?,
        leftLinePrefix: String
    ) -> Character? {
        guard let leftCharacter else {
            return nil
        }
        if !isIgnorableBoundaryCharacter(leftCharacter) &&
            !isSkippableTrailingDelimiterForBoundary(leftCharacter) {
            return leftCharacter
        }

        for character in leftLinePrefix.reversed() {
            if character.isWhitespace || isIgnorableBoundaryCharacter(character) {
                continue
            }
            if isSkippableTrailingDelimiterForBoundary(character) {
                continue
            }
            return character
        }

        return nil
    }

    static func effectiveRightContextCharacter(in rightText: String) -> Character? {
        for character in rightText {
            if character.isWhitespace || isIgnorableBoundaryCharacter(character) {
                continue
            }
            if isSkippableTrailingDelimiterForBoundary(character) {
                continue
            }
            return character
        }

        return nil
    }

    static func isLineStartBoundary(_ leftCharacter: Character?) -> Bool {
        if leftCharacter == nil {
            return true
        }
        return leftCharacter?.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) == true
    }

    static func shouldPreserveTrailingPunctuationAtLineStart(
        rightNonWhitespaceCharacter: Character?
    ) -> Bool {
        guard let rightNonWhitespaceCharacter else {
            return false
        }
        return String(rightNonWhitespaceCharacter).rangeOfCharacter(from: .uppercaseLetters) != nil
    }

    static func isEllipsisContinuationBoundary(
        leftCharacter: Character?,
        leftLinePrefix: String
    ) -> Bool {
        if leftCharacter == "…" {
            return true
        }

        var meaningfulPrefix = leftLinePrefix
        while let last = meaningfulPrefix.last {
            if last.isWhitespace || isIgnorableBoundaryCharacter(last) || isSkippableTrailingDelimiterForBoundary(last) {
                meaningfulPrefix.removeLast()
                continue
            }
            break
        }

        return meaningfulPrefix.hasSuffix("...") || meaningfulPrefix.hasSuffix("…")
    }
}
