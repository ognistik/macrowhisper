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
}

@main
struct RecordingMetadataSettlePolicyRegressionRunner {
    static func main() {
        runRecordingMetadataSettlePolicyRegressionTests()
    }
}
