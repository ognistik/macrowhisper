import Foundation

private func assertTrue(_ condition: Bool, _ label: String, details: String = "") {
    if !condition {
        let suffix = details.isEmpty ? "" : "\n\(details)"
        fputs("FAIL: \(label)\(suffix)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual != expected {
        fputs("FAIL: \(label)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func runSimReturnBehaviorRegressionTests() {
    let defaultBehavior = SimReturnBehaviorResolver.resolve(
        actionSimReturn: nil,
        defaultSimReturn: true,
        returnDelay: 0.15,
        autoReturnEnabled: false
    )
    assertTrue(defaultBehavior.shouldPressReturn, "defaults can enable simReturn when action override is nil")
    assertEqual(defaultBehavior.delay, 0.15, "simReturn preserves configured returnDelay")

    let autoReturnBehavior = SimReturnBehaviorResolver.resolve(
        actionSimReturn: false,
        defaultSimReturn: false,
        returnDelay: 0.05,
        autoReturnEnabled: true
    )
    assertTrue(autoReturnBehavior.shouldPressReturn, "auto-return still forces one return when simReturn is false")
    assertTrue(autoReturnBehavior.clearsAutoReturn, "auto-return simReturn behavior clears one-shot state")
    assertEqual(autoReturnBehavior.logMessage, "Simulating return key press due to auto-return", "auto-return uses the dedicated log reason")

    let bothEnabledBehavior = SimReturnBehaviorResolver.resolve(
        actionSimReturn: true,
        defaultSimReturn: false,
        returnDelay: 0.02,
        autoReturnEnabled: true
    )
    assertEqual(
        bothEnabledBehavior.logMessage,
        "Simulating return key press due to simReturn setting (auto-return was also set)",
        "simReturn keeps precedence for log messaging when auto-return is also enabled"
    )

    var events: [String] = []
    let chainedBehavior = SimReturnBehaviorResolver.resolve(
        actionSimReturn: true,
        defaultSimReturn: false,
        returnDelay: 0.25,
        autoReturnEnabled: false
    )
    SimReturnBehaviorResolver.perform(
        chainedBehavior,
        sleep: { delay in events.append("sleep:\(delay)") },
        log: { message in events.append("log:\(message)") },
        postReturn: { events.append("return") },
        clearAutoReturn: { events.append("clear") }
    )
    events.append("nextAction")
    assertEqual(
        events,
        [
            "log:Simulating return key press due to simReturn setting",
            "sleep:0.25",
            "return",
            "nextAction"
        ],
        "simReturn completes before a chained next action can begin"
    )

    var autoReturnEvents: [String] = []
    SimReturnBehaviorResolver.perform(
        autoReturnBehavior,
        sleep: { _ in },
        log: { _ in },
        postReturn: { autoReturnEvents.append("return") },
        clearAutoReturn: { autoReturnEvents.append("clear") }
    )
    assertEqual(autoReturnEvents, ["return", "clear"], "auto-return state is cleared only after the return key is emitted")
}

@main
struct SimReturnBehaviorRegressionRunner {
    static func main() {
        runSimReturnBehaviorRegressionTests()
    }
}
