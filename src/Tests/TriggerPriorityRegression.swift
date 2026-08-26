import Foundation

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    guard actual == expected else {
        fputs("FAIL: \(label)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func makePriorityInsert(
    voice: String? = nil,
    app: String? = nil,
    mode: String? = nil,
    url: String? = nil,
    logic: String? = "or"
) -> AppConfiguration.Insert {
    AppConfiguration.Insert(
        triggerVoice: voice,
        triggerApps: app,
        triggerModes: mode,
        triggerUrls: url,
        triggerLogic: logic
    )
}

private func evaluatePriorityMatches(
    _ inserts: [String: AppConfiguration.Insert],
    result: String = "",
    modeName: String? = nil,
    appName: String? = nil,
    bundleId: String? = nil,
    url: String? = nil
) -> [(name: String, strippedResult: String?)] {
    var metaJson: [String: Any] = [:]
    if let modeName {
        metaJson["modeName"] = modeName
    }

    let evaluator = TriggerEvaluator(logger: Logger())
    let manager = ConfigurationManager(config: AppConfiguration(inserts: inserts))
    return evaluator.evaluateTriggersForAllActions(
        configManager: manager,
        result: result,
        metaJson: metaJson,
        frontAppName: appName,
        frontAppBundleId: bundleId,
        frontAppUrl: url
    ).map { (name: $0.name, strippedResult: $0.strippedResult) }
}

private func names(_ matches: [(name: String, strippedResult: String?)]) -> [String] {
    matches.map(\.name)
}

private func runTriggerPriorityRegressionTests() {
    let allSources = evaluatePriorityMatches(
        [
            "a-app": makePriorityInsert(app: "Safari"),
            "b-url": makePriorityInsert(url: "github.com"),
            "c-mode": makePriorityInsert(mode: "Writing"),
            "z-voice": makePriorityInsert(voice: "command")
        ],
        result: "command create an issue",
        modeName: "Writing",
        appName: "Safari",
        bundleId: "com.apple.Safari",
        url: "https://github.com/issues/new"
    )
    assertEqual(
        names(allSources),
        ["z-voice", "c-mode", "b-url", "a-app"],
        "positive trigger sources use voice, mode, URL, app priority"
    )

    let actualSource = evaluatePriorityMatches(
        [
            "a-voice-configured-app-match": makePriorityInsert(voice: "never", app: "Safari"),
            "z-mode-match": makePriorityInsert(mode: "Writing")
        ],
        result: "ordinary dictation",
        modeName: "Writing",
        appName: "Safari"
    )
    assertEqual(
        names(actualSource),
        ["z-mode-match", "a-voice-configured-app-match"],
        "priority uses the trigger source that actually matched"
    )

    let requiredConditions = evaluatePriorityMatches(
        [
            "a-voice-only": makePriorityInsert(voice: "command"),
            "z-voice-and-mode": makePriorityInsert(voice: "command", mode: "Writing", logic: "and")
        ],
        result: "command now",
        modeName: "Writing"
    )
    assertEqual(
        names(requiredConditions),
        ["z-voice-and-mode", "a-voice-only"],
        "more required matching conditions win within the same trigger source"
    )

    let voiceSpecificity = evaluatePriorityMatches(
        [
            "a-short-voice": makePriorityInsert(voice: "ask"),
            "z-long-voice": makePriorityInsert(voice: "ask google")
        ],
        result: "ask google for weather"
    )
    assertEqual(
        names(voiceSpecificity),
        ["z-long-voice", "a-short-voice"],
        "longer matching voice prefixes win before action names"
    )

    let urlSpecificity = evaluatePriorityMatches(
        [
            "a-domain": makePriorityInsert(url: "github.com"),
            "z-path": makePriorityInsert(url: "https://github.com/issues")
        ],
        url: "https://github.com/issues/123"
    )
    assertEqual(
        names(urlSpecificity),
        ["z-path", "a-domain"],
        "more specific URL matches win before action names"
    )

    let catchAll = evaluatePriorityMatches(
        [
            "a-exclusion-only": makePriorityInsert(voice: "!never"),
            "z-positive-app": makePriorityInsert(app: "Safari")
        ],
        result: "ordinary dictation",
        appName: "Safari"
    )
    assertEqual(
        names(catchAll),
        ["z-positive-app", "a-exclusion-only"],
        "positive contextual matches win over exclusion-only catch-alls"
    )

    assertEqual(
        names(evaluatePriorityMatches(["positive-mode": makePriorityInsert(mode: "Writing")])),
        [],
        "positive mode trigger does not match when modeName is missing"
    )
    assertEqual(
        names(evaluatePriorityMatches(["excluded-mode": makePriorityInsert(mode: "!Email")])),
        [],
        "exception-only mode trigger does not match when modeName is missing"
    )
    assertEqual(
        names(evaluatePriorityMatches(["excluded-mode": makePriorityInsert(mode: "!Email")], modeName: "")),
        [],
        "mode trigger does not match when modeName is empty"
    )
    assertEqual(
        names(evaluatePriorityMatches(["excluded-mode": makePriorityInsert(mode: "!Email")], modeName: "Writing")),
        ["excluded-mode"],
        "exception-only mode trigger still matches a present non-excluded mode"
    )
    assertEqual(
        names(evaluatePriorityMatches(
            ["mode-and-app": makePriorityInsert(app: "Safari", mode: "Writing", logic: "and")],
            appName: "Safari"
        )),
        [],
        "AND action cannot match from app context when its mode context is missing"
    )

    let blockedVoice = evaluatePriorityMatches(
        ["app-fallback": makePriorityInsert(voice: "ask|!ask private", app: "Safari")],
        result: "ask private question",
        appName: "Safari"
    )
    assertEqual(names(blockedVoice), ["app-fallback"], "OR action can match from app when voice is excluded")
    assertEqual(
        blockedVoice.first?.strippedResult,
        nil,
        "excluded voice condition does not strip text from a lower-priority match"
    )

    let alphabeticalTie = evaluatePriorityMatches(
        [
            "z-app": makePriorityInsert(app: "Safari"),
            "a-app": makePriorityInsert(app: "Safari")
        ],
        appName: "Safari"
    )
    assertEqual(names(alphabeticalTie), ["a-app", "z-app"], "action name remains the final tie-breaker")
}

@main
struct TriggerPriorityRegressionRunner {
    static func main() {
        runTriggerPriorityRegressionTests()
    }
}
