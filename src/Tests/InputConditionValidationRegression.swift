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
        .appendingPathComponent("macrowhisper-input-condition-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(name).path
    try Data(json.utf8).write(to: URL(fileURLWithPath: path))
    return path
}

private func reportDetails(_ report: ConfigValidationReport) -> String {
    report.issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
}

private func runInputConditionValidationRegressionTests() {
    do {
        let insertPath = try writeTempConfig(
            """
            {
              "defaults": {
                "watch": "/tmp/input-condition-watch",
                "activeAction": "autoPaste"
              },
              "inserts": {
                "autoPaste": {
                  "action": "{{swResult}}",
                  "simReturn": true,
                  "inputCondition": "simReturn|!actionDelay"
                }
              }
            }
            """,
            name: "insert-simreturn.json"
        )
        let insertReport = ConfigurationManager.validateConfig(at: insertPath)
        assertTrue(
            insertReport.isValid,
            "insert inputCondition accepts simReturn token",
            details: reportDetails(insertReport)
        )

        let urlPath = try writeTempConfig(
            """
            {
              "defaults": {
                "watch": "/tmp/input-condition-watch",
                "activeAction": "openDocs"
              },
              "urls": {
                "openDocs": {
                  "action": "https://example.com",
                  "inputCondition": "simReturn"
                }
              }
            }
            """,
            name: "url-simreturn-invalid.json"
        )
        let urlReport = ConfigurationManager.validateConfig(at: urlPath)
        assertTrue(
            !urlReport.isValid && urlReport.issues.contains(where: { $0.message.contains("invalid inputCondition token 'simReturn'") }),
            "non-insert inputCondition still rejects simReturn token",
            details: reportDetails(urlReport)
        )
    } catch {
        fputs("FAIL: inputCondition validation regression setup\n\(error)\n", stderr)
        exit(1)
    }
}

@main
struct InputConditionValidationRegressionRunner {
    static func main() {
        runInputConditionValidationRegressionTests()
    }
}
