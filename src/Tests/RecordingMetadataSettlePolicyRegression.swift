import Foundation

private func assertEqual(_ actual: Bool, _ expected: Bool, _ label: String) {
    guard actual == expected else {
        fputs("FAIL: \(label)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func shouldWait(_ metaJson: [String: Any]) -> Bool {
    RecordingMetadataSettlePolicy.shouldAwaitIntegratedS1Result(in: metaJson)
}

private func parsedJSON(_ object: [String: Any]) -> [String: Any] {
    do {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fputs("FAIL: JSON metadata did not parse as an object\n", stderr)
            exit(1)
        }
        return parsed
    } catch {
        fputs("FAIL: could not serialize JSON metadata: \(error)\n", stderr)
        exit(1)
    }
}

private func runRecordingMetadataSettlePolicyRegressionTests() {
    assertEqual(
        RecordingMetadataSettlePolicy.integratedS1ResultGraceSeconds > 0
            && RecordingMetadataSettlePolicy.integratedS1ResultGraceSeconds <= 1.0,
        true,
        "S1 integrated-pipeline grace remains positive and bounded to one second"
    )

    assertEqual(
        shouldWait([
            "languageModelKey": "sl-1",
            "modelKey": "sv-1",
            "llmResult": "Cleaned output",
            "result": ""
        ]),
        true,
        "S1-Language + S1-Voice waits when llmResult precedes result"
    )

    assertEqual(
        shouldWait([
            "languageModelKey": "sl-1",
            "modelKey": "sv-1",
            "llmResult": "Cleaned output",
            "result": "ask google for weather"
        ]),
        false,
        "S1-Language + S1-Voice does not wait once result is available"
    )

    assertEqual(
        shouldWait([
            "languageModelKey": "sl-1",
            "modelKey": "other-voice",
            "llmResult": "Cleaned output",
            "result": ""
        ]),
        false,
        "S1-Language with another voice model is unchanged"
    )

    assertEqual(
        shouldWait([
            "languageModelKey": "other-language",
            "modelKey": "sv-1",
            "llmResult": "Cleaned output",
            "result": ""
        ]),
        false,
        "S1-Voice with another language model is unchanged"
    )

    assertEqual(
        shouldWait([
            "languageModelKey": "sl-1",
            "modelKey": "sv-1",
            "llmResult": "",
            "result": ""
        ]),
        false,
        "S1 pair still follows normal llmResult readiness before grace starts"
    )

    runRealtimeFinalResultTests()
}

private func runRealtimeFinalResultTests() {
    let realtimeMetadata: [String: Any] = [
        "appVersion": "3.4.0",
        "realtimeEnabled": true,
        "result": "Partial transcript"
    ]
    let cases: [(String, [String: Any], Bool)] = [
        ("the first partial awaits final metadata", ["modelKey": "sv-1"], true),
        ("a subsequent partial still awaits", ["result": "Longer partial"], true),
        ("zero is a valid final time", ["roundTripTime": 0], false),
        ("a decimal is a valid final time", ["roundTripTime": 1.25], false),
        ("a string is not a final time", ["roundTripTime": "424"], true),
        ("a boolean is not a final time", ["roundTripTime": true], true),
        ("null is not a final time", ["roundTripTime": NSNull()], true),
        ("Realtime off keeps normal readiness", ["realtimeEnabled": false], false),
        ("numeric 1 does not enable Realtime", ["realtimeEnabled": 1], false),
        ("an LLM mode uses its normal readiness", ["languageModelName": "OSS"], false),
        ("an empty LLM name indicates voice-only", ["languageModelName": ""], true),
        ("3.3.x keeps legacy readiness", ["appVersion": "3.3.99"], false),
        ("malformed versions keep legacy readiness", ["appVersion": "3.4.bad"], false),
        ("3.10 is newer than 3.4", ["appVersion": "3.10.0"], true),
        ("a newer major version also waits", ["appVersion": "4.0.0"], true)
    ]

    for (label, overrides, expected) in cases {
        let metadata = realtimeMetadata.merging(overrides) { _, override in override }
        assertEqual(
            RecordingMetadataSettlePolicy.shouldAwaitRealtimeFinalResult(in: parsedJSON(metadata)),
            expected,
            label
        )
    }

    let withoutVersion = ["realtimeEnabled": true]
    let withoutRealtime = ["appVersion": "3.4.0"]
    assertEqual(
        RecordingMetadataSettlePolicy.shouldAwaitRealtimeFinalResult(in: parsedJSON(withoutVersion)),
        false,
        "missing appVersion preserves legacy behavior"
    )
    assertEqual(
        RecordingMetadataSettlePolicy.shouldAwaitRealtimeFinalResult(in: parsedJSON(withoutRealtime)),
        false,
        "missing realtimeEnabled preserves legacy behavior"
    )
}

@main
struct RecordingMetadataSettlePolicyRegressionRunner {
    static func main() {
        runRecordingMetadataSettlePolicyRegressionTests()
    }
}
