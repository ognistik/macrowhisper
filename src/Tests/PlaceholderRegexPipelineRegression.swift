import Foundation

private func assertEqual(_ actual: String, _ expected: String, _ label: String) {
    if actual != expected {
        fputs("FAIL: \(label)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func runPlaceholderRegexPipelineRegressionTests() {
    do {
        let action1 = "{{swResult||(?s)(.*)||${1}}}"
        let meta1: [String: Any] = ["llmResult": "hello world"]
        let result1 = processDynamicPlaceholders(action: action1, metaJson: meta1, actionType: .insert).text
        assertEqual(result1, "hello world", "brace capture reference ${1} in placeholder regex replacement")

        let action2 = "{{swResult::ensureSentence||(?s)(.*)||${1::lowercase}}}"
        let meta2: [String: Any] = ["llmResult": "HELLO WORLD"]
        let result2 = processDynamicPlaceholders(action: action2, metaJson: meta2, actionType: .insert).text
        assertEqual(result2, "hello world.", "transform + capture-scoped transform in same placeholder")

        let action3 = "{{swResult||foo||{bar}}}"
        let meta3: [String: Any] = ["llmResult": "foo"]
        let result3 = processDynamicPlaceholders(action: action3, metaJson: meta3, actionType: .insert).text
        assertEqual(result3, "{bar}", "replacement ending in brace does not break placeholder closing")

        let action4 = "{{swResult||([0-9]+)||{${1}}}}"
        let meta4: [String: Any] = ["llmResult": "abc123"]
        let result4 = processDynamicPlaceholders(action: action4, metaJson: meta4, actionType: .insert).text
        assertEqual(result4, "abc{123}", "nested brace + capture template remains parse-safe")

        let action5 = "{{swResult||([A-Z]+)||${1::doesNotExist}}}"
        let meta5: [String: Any] = ["llmResult": "ABC"]
        let result5 = processDynamicPlaceholders(action: action5, metaJson: meta5, actionType: .insert).text
        assertEqual(result5, "ABC", "unknown capture transform fails open")

        let action6 = "{{swResult::titleCase:fr}}"
        let meta6: [String: Any] = ["llmResult": "le seigneur des anneaux et l'amour perdu"]
        let result6 = processDynamicPlaceholders(action: action6, metaJson: meta6, actionType: .insert).text
        assertEqual(result6, "Le Seigneur des Anneaux et l'amour Perdu", "explicit French title case applies minor word rules")

        let action7 = "{{swResult::titleCase}}"
        let meta7: [String: Any] = ["llmResult": "l'été en provence et le chant du vent"]
        let result7 = processDynamicPlaceholders(action: action7, metaJson: meta7, actionType: .insert).text
        assertEqual(result7, "L'été en Provence et le Chant du Vent", "auto title case detects French")

        let action8 = "{{swResult::titleCase}}"
        let meta8: [String: Any] = ["llmResult": "la sopa de pollo"]
        let result8 = processDynamicPlaceholders(action: action8, metaJson: meta8, actionType: .insert).text
        assertEqual(result8, "La Sopa de Pollo", "auto title case preserves Spanish minor words in romance tie cases")
    }
}

@main
struct PlaceholderRegexPipelineRegressionRunner {
    static func main() {
        runPlaceholderRegexPipelineRegressionTests()
    }
}
