import Foundation

private func assertTrue(_ condition: Bool, _ label: String) {
    if !condition {
        fputs("FAIL: \(label)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func assertEqual(_ actual: Bool, _ expected: Bool, _ label: String) {
    if actual != expected {
        fputs("FAIL: \(label)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func assertEqual(_ actual: String?, _ expected: String?, _ label: String) {
    if actual != expected {
        fputs("FAIL: \(label)\nexpected: \(String(describing: expected))\nactual:   \(String(describing: actual))\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func runCLIClipboardChainStateRegressionTests() {
    var state = CLIClipboardChainState(initialClipboardContent: "seed")
    assertEqual(state.initialClipboardContent, "seed", "captures chain-start clipboard snapshot")
    assertEqual(state.didMutateClipboard, false, "starts with no clipboard mutation recorded")
    assertEqual(state.isFirstStep, true, "starts on first step")
    assertEqual(state.isLastStep, false, "starts with last-step flag unset")
    assertEqual(state.shouldRestoreClipboard(finalRestoreEnabled: true), false, "does not restore when no mutation occurred")

    state.beginStep(isLastStep: false)
    assertEqual(state.isLastStep, false, "non-final step keeps last-step flag false")
    state.noteClipboardMutation(false)
    assertEqual(state.didMutateClipboard, false, "false mutation updates do not flip state")

    state.noteClipboardMutation(true)
    assertEqual(state.didMutateClipboard, true, "clipboard mutation is sticky once recorded")
    assertEqual(state.shouldRestoreClipboard(finalRestoreEnabled: false), false, "final restore flag still controls chain restore")
    assertEqual(state.shouldRestoreClipboard(finalRestoreEnabled: true), true, "restores only when final step enables it after mutation")

    state.advanceToNextStep()
    assertEqual(state.isFirstStep, false, "advance clears first-step flag")
    assertEqual(state.isLastStep, false, "advance clears last-step flag")

    state.beginStep(isLastStep: true)
    assertEqual(state.isLastStep, true, "final step can mark chain state as last step")

    var emptyClipboardState = CLIClipboardChainState(initialClipboardContent: nil)
    assertEqual(emptyClipboardState.initialClipboardContent, nil, "supports empty chain-start clipboard snapshots")
    emptyClipboardState.noteClipboardMutation(true)
    assertTrue(emptyClipboardState.shouldRestoreClipboard(finalRestoreEnabled: true), "empty starting clipboard still restores by clearing when mutation occurred")
}

@main
struct CLIClipboardChainStateRegressionRunner {
    static func main() {
        runCLIClipboardChainStateRegressionTests()
    }
}
