import Foundation

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual != expected {
        fputs("FAIL: \(label)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func assertTrue(_ condition: Bool, _ label: String, details: String = "") {
    if !condition {
        let suffix = details.isEmpty ? "" : "\n\(details)"
        fputs("FAIL: \(label)\(suffix)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func runSmartInsertBoundaryRegressionTests() {
    let objectReplacement = "\u{FFFC}"
    let zeroWidthJoiner = "\u{200D}"

    let effectiveAfterInlineCode = SmartInsertBoundary.effectiveLeftContextCharacter(
        leftCharacter: objectReplacement.first,
        leftLinePrefix: "\(objectReplacement)`This is some text`\(objectReplacement)"
    )
    assertEqual(
        effectiveAfterInlineCode,
        "t",
        "inline code boundary skips attachment character and trailing backtick"
    )

    let effectiveAfterInlineCodePeriod = SmartInsertBoundary.effectiveLeftContextCharacter(
        leftCharacter: objectReplacement.first,
        leftLinePrefix: "\(objectReplacement)`This is some text.`\(objectReplacement)"
    )
    assertEqual(
        effectiveAfterInlineCodePeriod,
        ".",
        "inline code boundary preserves sentence punctuation behind attachment character"
    )

    assertTrue(
        SmartInsertBoundary.isIgnorableBoundaryCharacter(zeroWidthJoiner.first!),
        "zero-width joiner is classified as an ignorable boundary character"
    )

    assertTrue(
        SmartInsertBoundary.isLineStartBoundary(nil),
        "nil left boundary is treated as line start"
    )
    assertTrue(
        SmartInsertBoundary.isLineStartBoundary("\n".first),
        "newline left boundary is treated as line start"
    )
    assertTrue(
        !SmartInsertBoundary.isLineStartBoundary(objectReplacement.first),
        "attachment character alone is not treated as line start"
    )

    let nonSentenceStarts: [(Character?, String)] = [
        (nil, "missing right boundary does not preserve line-start punctuation"),
        ("a".first, "lowercase continuation does not preserve line-start punctuation"),
        (",".first, "comma continuation does not preserve line-start punctuation"),
        (";".first, "semicolon continuation does not preserve line-start punctuation"),
        (":".first, "colon continuation does not preserve line-start punctuation"),
        ("!".first, "punctuation continuation does not preserve line-start punctuation"),
        ("?".first, "question-mark continuation does not preserve line-start punctuation")
    ]

    for (character, label) in nonSentenceStarts {
        assertTrue(
            !SmartInsertBoundary.shouldPreserveTrailingPunctuationAtLineStart(
                rightNonWhitespaceCharacter: character
            ),
            label
        )
    }

    assertTrue(
        SmartInsertBoundary.shouldPreserveTrailingPunctuationAtLineStart(
            rightNonWhitespaceCharacter: "T".first
        ),
        "line-start punctuation is preserved before an uppercase sentence start"
    )

    let boundaryConflictCharacters: [Character] = [".", ",", ";", ":", "!", "?"]
    for character in boundaryConflictCharacters {
        assertTrue(
            SmartInsertBoundary.isBoundaryConflictPunctuation(character),
            "boundary conflict punctuation includes \(character)"
        )
    }

    let midSentenceStrippableCharacters: [Character] = [".", "!", "?"]
    for character in midSentenceStrippableCharacters {
        assertTrue(
            SmartInsertBoundary.isMidSentenceStrippableTrailingPunctuation(character),
            "mid-sentence stripping keeps \(character) removable"
        )
    }

    let midSentencePreservedCharacters: [Character] = [",", ";", ":"]
    for character in midSentencePreservedCharacters {
        assertTrue(
            !SmartInsertBoundary.isMidSentenceStrippableTrailingPunctuation(character),
            "mid-sentence stripping preserves \(character)"
        )
    }
}

@main
struct SmartInsertBoundaryRegressionRunner {
    static func main() {
        runSmartInsertBoundaryRegressionTests()
    }
}
