import Foundation

private struct PlaceholderMigrationCase {
    let name: String
    let actionType: ActionType
    let legacyAction: String
    let metadata: [String: Any]
    let expected: String
}

// Expected values were captured from main's pre-v3 runtime at 90f01e4. Keep
// these as literal baselines so this runner checks migration compatibility
// without carrying a second copy of the old placeholder implementation.
private let cases: [PlaceholderMigrationCase] = [
    PlaceholderMigrationCase(
        name: "Insert slash runs before n",
        actionType: .insert,
        legacyAction: #"A\nB\\nC\\\nD\\\\nE"#,
        metadata: [:],
        expected: "A\nB\\\nC\\\\\nD\\\\\\\nE"
    ),
    PlaceholderMigrationCase(
        name: "Insert raw LF, CR, and CRLF",
        actionType: .insert,
        legacyAction: "LF\nCR\rCRLF\r\nEND",
        metadata: [:],
        expected: "LF\nCR\rCRLF\r\nEND"
    ),
    PlaceholderMigrationCase(
        name: "Insert replacement slash runs",
        actionType: .insert,
        legacyAction: #"{{swResult||middle||\n}}|{{swResult||middle||\\n}}"#,
        metadata: ["llmResult": "leftmiddleright"],
        expected: "left\nright|left\nright"
    ),
    PlaceholderMigrationCase(
        name: "Insert replacement raw control characters",
        actionType: .insert,
        legacyAction: "{{swResult||middle||L\nF\rC\r\nD}}",
        metadata: ["llmResult": "leftmiddleright"],
        expected: "leftL\nF\rC\r\nDright"
    ),
    PlaceholderMigrationCase(
        name: "Insert capture transform",
        actionType: .insert,
        legacyAction: #"{{swResult||\b(api|sdk)\b||${1::uppercase}}}"#,
        metadata: ["llmResult": "api sdk"],
        expected: "API SDK"
    ),
    PlaceholderMigrationCase(
        name: "Insert metadata preserves literal backslash-n",
        actionType: .insert,
        legacyAction: "{{swResult}}",
        metadata: ["llmResult": #"literal\nfrom metadata"#],
        expected: #"literal\nfrom metadata"#
    ),
    PlaceholderMigrationCase(
        name: "URL replacement newline token",
        actionType: .url,
        legacyAction: #"myapp://q={{swResult||middle||\n}}"#,
        metadata: ["llmResult": "leftmiddleright"],
        expected: "myapp://q=leftnright"
    ),
    PlaceholderMigrationCase(
        name: "URL raw odd and even slash runs",
        actionType: .url,
        legacyAction: #"myapp://q={{raw:swResult||middle||\n}}/{{raw:swResult||middle||\\n}}"#,
        metadata: ["llmResult": "leftmiddleright"],
        expected: #"myapp://q=leftnright/left\nright"#
    ),
    PlaceholderMigrationCase(
        name: "URL replacement raw control characters",
        actionType: .url,
        legacyAction: "myapp://q={{raw:swResult||middle||L\nF\rC\r\nD}}",
        metadata: ["llmResult": "leftmiddleright"],
        expected: "myapp://q=leftL\nF\rC\r\nDright"
    ),
    PlaceholderMigrationCase(
        name: "URL static backslash-n remains literal",
        actionType: .url,
        legacyAction: #"myapp://static/\n?q={{swResult}}"#,
        metadata: ["llmResult": "a b"],
        expected: #"myapp://static/\n?q=a%20b"#
    ),
    PlaceholderMigrationCase(
        name: "Shortcut replacement escapes",
        actionType: .shortcut,
        legacyAction: #"static\n|{{raw:swResult||middle||\n}}|{{raw:swResult||middle||\\n}}"#,
        metadata: ["llmResult": "leftmiddleright"],
        expected: #"static\n|leftnright|left\nright"#
    ),
    PlaceholderMigrationCase(
        name: "Shell replacement escapes",
        actionType: .shell,
        legacyAction: #"static\n|{{raw:swResult||middle||\n}}|{{raw:swResult||middle||\\n}}"#,
        metadata: ["llmResult": "leftmiddleright"],
        expected: #"static\n|leftnright|left\nright"#
    ),
    PlaceholderMigrationCase(
        name: "AppleScript replacement escapes",
        actionType: .appleScript,
        legacyAction: #"static\n|{{raw:swResult||middle||\n}}|{{raw:swResult||middle||\\n}}"#,
        metadata: ["llmResult": "leftmiddleright"],
        expected: #"static\n|leftnright|left\nright"#
    ),
    PlaceholderMigrationCase(
        name: "Escaped placeholder opener",
        actionType: .insert,
        legacyAction: #"escaped \{{swResult}}"#,
        metadata: ["llmResult": "VALUE"],
        expected: #"escaped \{{swResult}}"#
    ),
    PlaceholderMigrationCase(
        name: "Incomplete placeholder stays literal",
        actionType: .shell,
        legacyAction: #"script {{swResult||middle||\n"#,
        metadata: ["llmResult": "leftmiddleright"],
        expected: #"script {{swResult||middle||\n"#
    ),
    PlaceholderMigrationCase(
        name: "Invalid placeholder key stays literal",
        actionType: .appleScript,
        legacyAction: #"{{bad-key||x||y\n}}"#,
        metadata: ["llmResult": "x"],
        expected: #"{{bad-key||x||y\n}}"#
    ),
    PlaceholderMigrationCase(
        name: "Escaped double pipe in regex pattern",
        actionType: .insert,
        legacyAction: #"{{swResult||\|\|||joined}}"#,
        metadata: ["llmResult": "left||right"],
        expected: "leftjoinedright"
    ),
    PlaceholderMigrationCase(
        name: "Escaped double pipe in replacement",
        actionType: .insert,
        legacyAction: #"{{swResult||middle||\|\|}}"#,
        metadata: ["llmResult": "leftmiddleright"],
        expected: "left||right"
    ),
    PlaceholderMigrationCase(
        name: "Plain XML extraction and result cleanup",
        actionType: .insert,
        legacyAction: "{{xml:tag}}|{{swResult}}",
        metadata: ["llmResult": "before<tag>value</tag>after"],
        expected: "value|beforeafter"
    ),
    PlaceholderMigrationCase(
        name: "Plain JSON and raw XML escaping",
        actionType: .shell,
        legacyAction: "{{json:xml:tag}}|{{raw:xml:tag}}",
        metadata: ["llmResult": #"<tag>say "hi"</tag>"#],
        expected: "say \\\"hi\\\"|say \"hi\""
    ),
]

private func migratedAction(for testCase: PlaceholderMigrationCase) -> String {
    switch testCase.actionType {
    case .insert:
        return canonicalizeLegacyMacrowhisperInsertAction(testCase.legacyAction)
    case .url, .shortcut, .shell, .appleScript:
        return canonicalizePlaceholderReplacementNewlines(testCase.legacyAction, legacy: true)
    }
}

private func runPlaceholderMigrationCompatibilityRegression() {
    for testCase in cases {
        let actual = processAllPlaceholders(
            action: migratedAction(for: testCase),
            metaJson: testCase.metadata,
            actionType: testCase.actionType
        ).text
        guard actual == testCase.expected else {
            fputs(
                "FAIL: \(testCase.name)\nexpected: \(String(reflecting: testCase.expected))\nactual:   \(String(reflecting: actual))\n",
                stderr
            )
            exit(1)
        }
    }
    print("PASS: \(cases.count) placeholder migration compatibility cases")
}

@main
struct PlaceholderMigrationCompatibilityRegressionRunner {
    static func main() {
        runPlaceholderMigrationCompatibilityRegression()
    }
}
