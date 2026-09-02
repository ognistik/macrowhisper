import Foundation

private func assertTrue(_ condition: Bool, _ label: String, details: String = "") {
    if !condition {
        let suffix = details.isEmpty ? "" : "\n\(details)"
        fputs("FAIL: \(label)\(suffix)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func writeTempConfig(_ json: String, name: String) throws -> String {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macrowhisper-trigger-logic-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(name).path
    try Data(json.utf8).write(to: URL(fileURLWithPath: path))
    return path
}

private func reportDetails(_ report: ConfigValidationReport) -> String {
    report.issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
}

private func runTriggerLogicValidationRegressionTests() {
    do {
        let validPath = try writeTempConfig(
            """
            {
              "defaults": { "watch": "/tmp/trigger-logic-watch" },
              "inserts": {
                "insert": { "action": "{{swResult}}", "triggerLogic": "AND" }
              },
              "urls": {
                "url": { "action": "https://example.com", "triggerLogic": "Or" }
              },
              "shortcuts": {
                "shortcut": { "action": "Example", "triggerLogic": "or" }
              },
              "scriptsShell": {
                "shell": { "action": "true", "triggerLogic": null }
              },
              "scriptsAS": {
                "appleScript": { "action": "return" }
              }
            }
            """,
            name: "valid.json"
        )
        let validReport = ConfigurationManager.validateConfig(at: validPath)
        assertTrue(
            validReport.isValid,
            "triggerLogic accepts case-insensitive and/or plus null and omission",
            details: reportDetails(validReport)
        )

        let invalidPath = try writeTempConfig(
            """
            {
              "defaults": { "watch": "/tmp/trigger-logic-watch" },
              "inserts": {
                "insert": { "action": "{{swResult}}", "triggerLogic": "adn" }
              },
              "urls": {
                "url": { "action": "https://example.com", "triggerLogic": "" }
              },
              "shortcuts": {
                "shortcut": { "action": "Example", "triggerLogic": "and " }
              },
              "scriptsShell": {
                "shell": { "action": "true", "triggerLogic": "xor" }
              },
              "scriptsAS": {
                "appleScript": { "action": "return", "triggerLogic": " or" }
              }
            }
            """,
            name: "invalid.json"
        )
        let invalidReport = ConfigurationManager.validateConfig(at: invalidPath)
        let invalidPaths = Set(invalidReport.issues.map(\.path))
        let expectedPaths: Set<String> = [
            "inserts.insert.triggerLogic",
            "urls.url.triggerLogic",
            "shortcuts.shortcut.triggerLogic",
            "scriptsShell.shell.triggerLogic",
            "scriptsAS.appleScript.triggerLogic"
        ]
        assertTrue(
            !invalidReport.isValid && invalidPaths == expectedPaths,
            "invalid triggerLogic values fail semantic validation for every action type",
            details: reportDetails(invalidReport)
        )
        assertTrue(
            invalidReport.issues.allSatisfy {
                $0.kind == .semantic && $0.message.contains("expected 'and' or 'or'")
            },
            "triggerLogic validation reports actionable semantic errors",
            details: reportDetails(invalidReport)
        )

        testNotifications.removeAll()
        let runtimeManager = ConfigurationManager(configPath: invalidPath)
        assertTrue(
            runtimeManager.config.inserts["insert"] == nil,
            "runtime loading rejects a configuration with invalid triggerLogic"
        )
        assertTrue(
            testNotifications.contains {
                $0.title == "MacroWhisper - Configuration Error"
                    && $0.message.contains("Run --validate-config")
            },
            "runtime validation uses the existing configuration notification path"
        )
    } catch {
        fputs("FAIL: triggerLogic validation regression setup\n\(error)\n", stderr)
        exit(1)
    }
}

@main
struct TriggerLogicValidationRegressionRunner {
    static func main() {
        runTriggerLogicValidationRegressionTests()
    }
}
