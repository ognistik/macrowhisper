import Foundation

private func assertEqual(_ actual: Bool, _ expected: Bool, _ label: String) {
    if actual != expected {
        fputs("FAIL: \(label)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func runRecordingRecoveryPolicyRegressionTests() {
    assertEqual(
        shouldStartLLMResultTimeout([
            "languageModelName": "Cloud LLM",
            "result": "",
            "duration": 180_000,
            "llmResult": ""
        ]),
        false,
        "an active long-form recording with no completed raw result is not timed out"
    )

    assertEqual(
        shouldStartLLMResultTimeout([
            "languageModelName": "Cloud LLM",
            "result": "Raw transcription is ready.",
            "duration": 0,
            "llmResult": ""
        ]),
        false,
        "a non-final raw transcription state does not start the LLM timeout"
    )

    assertEqual(
        shouldStartLLMResultTimeout([
            "languageModelName": "Cloud LLM",
            "result": "Raw transcription is ready.",
            "duration": 2_500,
            "llmResult": ""
        ]),
        true,
        "completed raw transcription with missing LLM output starts the timeout"
    )

    assertEqual(
        shouldStartLLMResultTimeout([
            "languageModelName": "Cloud LLM",
            "result": "Raw transcription is ready.",
            "duration": 2_500,
            "llmResult": "Processed output is ready."
        ]),
        false,
        "a completed LLM result never starts the recovery timeout"
    )

    assertEqual(
        shouldStartLLMResultTimeout([
            "languageModelName": "",
            "result": "Normal transcription is ready.",
            "duration": 2_500
        ]),
        false,
        "non-LLM modes are not subject to the LLM result timeout"
    )
}

@main
struct RecordingRecoveryPolicyRegressionRunner {
    static func main() {
        runRecordingRecoveryPolicyRegressionTests()
    }
}
