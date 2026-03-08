import Foundation

enum SmartInsertBoundary {
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

    static func isLineStartBoundary(_ leftCharacter: Character?) -> Bool {
        if leftCharacter == nil {
            return true
        }
        return leftCharacter?.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) == true
    }
}
