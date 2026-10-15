import Foundation

private struct MatchSnapshot: Equatable {
    let name: String
    let strippedResult: String?
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    guard actual == expected else {
        fputs("FAIL: \(label)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func makeInsert(
    triggerVoice: String?,
    triggerLogic: String? = "or"
) -> AppConfiguration.Insert {
    AppConfiguration.Insert(
        triggerVoice: triggerVoice,
        triggerApps: nil,
        triggerModes: nil,
        triggerUrls: nil,
        triggerLogic: triggerLogic
    )
}

private func evaluate(
    inserts: [String: AppConfiguration.Insert],
    result: String,
    metaJson: [String: Any] = [:]
) -> [MatchSnapshot] {
    let evaluator = TriggerEvaluator(logger: Logger())
    let manager = ConfigurationManager(config: AppConfiguration(inserts: inserts))
    return evaluator.evaluateTriggersForAllActions(
        configManager: manager,
        result: result,
        metaJson: metaJson,
        frontAppName: nil,
        frontAppBundleId: nil,
        frontAppUrl: nil
    ).filter { $0.type == .insert }.map {
        MatchSnapshot(name: $0.name, strippedResult: $0.strippedResult)
    }
}

private func assertSuffixResult(
    triggerVoice: String,
    result: String,
    expected: String?,
    _ label: String
) {
    let matches = evaluate(
        inserts: ["action": makeInsert(triggerVoice: triggerVoice)],
        result: result
    )
    assertEqual(matches, [MatchSnapshot(name: "action", strippedResult: expected)], label)
}

private func runParsingAndExceptionTests() {
    let mixedSuffix = evaluate(
        inserts: ["send": makeInsert(triggerVoice: "*send it|!*cancel")],
        result: "Draft a reply, send it."
    )
    assertEqual(
        mixedSuffix,
        [MatchSnapshot(name: "send", strippedResult: "Draft a reply.")],
        "suffix positive and !* exception tokens parse in the expected order"
    )

    let excludedSuffix = evaluate(
        inserts: ["send": makeInsert(triggerVoice: "*send it|!*cancel")],
        result: "Draft a reply, cancel"
    )
    assertEqual(excludedSuffix, [], "suffix exception blocks a positive match")

    let exceptionOnlyAllowed = evaluate(
        inserts: ["not-cancel": makeInsert(triggerVoice: "!*cancel")],
        result: "Draft a reply, send it."
    )
    assertEqual(
        exceptionOnlyAllowed,
        [MatchSnapshot(name: "not-cancel", strippedResult: nil)],
        "exception-only suffix rule matches when its exception is absent without stripping"
    )

    let exceptionOnlyBlocked = evaluate(
        inserts: ["not-cancel": makeInsert(triggerVoice: "!*cancel")],
        result: "Draft a reply, cancel"
    )
    assertEqual(exceptionOnlyBlocked, [], "exception-only suffix rule rejects its exception")

    let rawPipe = evaluate(
        inserts: ["raw": makeInsert(triggerVoice: "==^(draft|note)$==")],
        result: "note"
    )
    assertEqual(
        rawPipe,
        [MatchSnapshot(name: "raw", strippedResult: nil)],
        "a pipe inside a raw regex remains part of that one trigger"
    )
}

private func runOriginalResultSelectionTests() {
    let originalResultMatch = evaluate(
        inserts: ["suffix": makeInsert(triggerVoice: "*send it")],
        result: "Draft a reply, send it.",
        metaJson: ["llmResult": "send it"]
    )
    assertEqual(
        originalResultMatch,
        [MatchSnapshot(name: "suffix", strippedResult: "Draft a reply.")],
        "voice suffix selection uses original result even when llmResult differs"
    )

    let llmOnlyMatch = evaluate(
        inserts: ["suffix": makeInsert(triggerVoice: "*send it")],
        result: "This does not contain the command",
        metaJson: ["llmResult": "Draft a reply, send it."]
    )
    assertEqual(llmOnlyMatch, [], "voice suffix selection does not fall back to llmResult")
}

private func runPunctuationTests() {
    assertSuffixResult(
        triggerVoice: "*send it",
        result: "This is something, send it.",
        expected: "This is something.",
        "suffix removal transfers terminal period after dropping a comma separator"
    )
    assertSuffixResult(
        triggerVoice: "*send it",
        result: "This is something, send it!",
        expected: "This is something!",
        "suffix removal transfers terminal exclamation mark"
    )
    assertSuffixResult(
        triggerVoice: "*send it",
        result: "This is something; send it?",
        expected: "This is something?",
        "suffix removal transfers terminal question mark and drops semicolon separator"
    )
    assertSuffixResult(
        triggerVoice: "*send it",
        result: "This is something: send it.",
        expected: "This is something.",
        "suffix removal drops colon separator"
    )
    assertSuffixResult(
        triggerVoice: "*send it",
        result: "This is something - send it.",
        expected: "This is something.",
        "suffix removal drops dash separator"
    )
    assertSuffixResult(
        triggerVoice: "*send it",
        result: "Something else... send it.",
        expected: "Something else...",
        "existing ellipsis before a suffix is preserved"
    )
    assertSuffixResult(
        triggerVoice: "*send it",
        result: "Already done? send it.",
        expected: "Already done?",
        "existing sentence-ending question mark before a suffix is preserved"
    )
    assertSuffixResult(
        triggerVoice: "*send it",
        result: "This is something, send it",
        expected: "This is something",
        "suffix removal does not invent punctuation when the command has none"
    )
}

private func runConfiguredPunctuationNormalizationTests() {
    for configuredPattern in ["*send it", "*send it.", "*send it..."] {
        assertSuffixResult(
            triggerVoice: configuredPattern,
            result: "Draft a reply, send it!",
            expected: "Draft a reply!",
            "configured trailing punctuation is normalized for \(configuredPattern)"
        )
    }

    assertEqual(
        evaluate(
            inserts: ["action": makeInsert(triggerVoice: "*send, it")],
            result: "Draft a reply, send it"
        ),
        [],
        "punctuation inside a literal suffix remains significant"
    )
    assertSuffixResult(
        triggerVoice: "*send, it",
        result: "Draft a reply, send, it",
        expected: "Draft a reply",
        "an internal punctuation mark is matched when it is present in the suffix"
    )
}

private func runRawRegexAndPrefixCompatibilityTests() {
    let rawMatch = evaluate(
        inserts: ["raw": makeInsert(triggerVoice: "==(?i)^send it\\.$==")],
        result: "send it."
    )
    assertEqual(
        rawMatch,
        [MatchSnapshot(name: "raw", strippedResult: nil)],
        "raw regex still matches without automatic stripping"
    )

    let rawDoesNotNormalize = evaluate(
        inserts: ["raw": makeInsert(triggerVoice: "==(?i)^send it\\.$==")],
        result: "send it"
    )
    assertEqual(rawDoesNotNormalize, [], "raw regex keeps its explicit punctuation semantics")

    assertEqual(
        evaluate(
            inserts: ["prefix": makeInsert(triggerVoice: "send it...")],
            result: "send it, draft"
        ),
        [MatchSnapshot(name: "prefix", strippedResult: "Draft")],
        "plain literal voice triggers normalize configured punctuation and retain prefix cleanup"
    )
    assertEqual(
        evaluate(
            inserts: ["prefix": makeInsert(triggerVoice: "send it")],
            result: "Draft, send it"
        ),
        [],
        "plain literal voice triggers do not become suffix matches"
    )
}

private func runSpecificityTests() {
    let matches = evaluate(
        inserts: [
            "short": makeInsert(triggerVoice: "*it"),
            "long": makeInsert(triggerVoice: "*send it")
        ],
        result: "Draft a reply, send it."
    )
    assertEqual(
        matches.map(\.name),
        ["long", "short"],
        "the longest matching literal suffix wins before the action-name tie-breaker"
    )
    assertEqual(
        matches.first?.strippedResult,
        "Draft a reply.",
        "the selected longest suffix returns the exact stripped result"
    )

    assertEqual(
        evaluate(
            inserts: ["exact": makeInsert(triggerVoice: "*send it")],
            result: "Draft a reply, send it later"
        ),
        [],
        "a suffix rule must end at the matched transcript rather than match an interior phrase"
    )

    assertEqual(
        evaluate(
            inserts: ["boundary": makeInsert(triggerVoice: "*title")],
            result: "Use the subtitle"
        ),
        [],
        "a suffix rule starts at a phrase boundary rather than matching the end of a larger word"
    )

    assertEqual(
        evaluate(
            inserts: ["one-action": makeInsert(triggerVoice: "*send it|*it")],
            result: "Draft a reply, send it."
        ),
        [MatchSnapshot(name: "one-action", strippedResult: "Draft a reply.")],
        "one action strips with its longest matching suffix rather than the last alternative"
    )

    let evaluator = TriggerEvaluator(logger: Logger())
    let manager = ConfigurationManager(
        config: AppConfiguration(
            inserts: ["one-action": makeInsert(triggerVoice: "*send it|*it")]
        )
    )
    let exactMatches = evaluator.evaluateTriggersForAllActions(
        configManager: manager,
        result: "Draft a reply, send it.",
        metaJson: [:],
        frontAppName: nil,
        frontAppBundleId: nil,
        frontAppUrl: nil
    )
    assertEqual(
        exactMatches.first?.matchedVoiceTrigger?.pattern,
        "send it",
        "the evaluator propagates the exact longest suffix rule that selected the action"
    )
    assertEqual(
        exactMatches.first?.matchedVoiceTrigger.flatMap {
            VoiceTriggerMatcher.strip("Rewritten reply, send it!", using: $0)
        },
        "Rewritten reply!",
        "the exact selected suffix rule can clean the LLM result without rescanning alternatives"
    )
}

private func runUnicodeSlicingTests() {
    assertSuffixResult(
        triggerVoice: "*发送 🚀",
        result: "准备好, 发送 🚀!",
        expected: "准备好!",
        "suffix slicing is Unicode-safe when the matched command contains an emoji"
    )

    assertEqual(
        evaluate(
            inserts: ["prefix": makeInsert(triggerVoice: "🚀 go")],
            result: "🚀 go now"
        ),
        [MatchSnapshot(name: "prefix", strippedResult: "Now")],
        "prefix slicing is Unicode-safe when the matched phrase contains an emoji"
    )
}

private func runTriggerVoiceSuffixRegressionTests() {
    runParsingAndExceptionTests()
    runOriginalResultSelectionTests()
    runPunctuationTests()
    runConfiguredPunctuationNormalizationTests()
    runRawRegexAndPrefixCompatibilityTests()
    runSpecificityTests()
    runUnicodeSlicingTests()
}

@main
struct TriggerVoiceSuffixRegressionRunner {
    static func main() {
        runTriggerVoiceSuffixRegressionTests()
    }
}
