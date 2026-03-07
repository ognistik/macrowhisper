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
        .appendingPathComponent("macrowhisper-validation-tests", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(name).path
    try Data(json.utf8).write(to: URL(fileURLWithPath: path))
    return path
}

private func reportDetails(_ report: ConfigValidationReport) -> String {
    report.issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
}

private func runActionChainValidationRegressionTests() {
    do {
        let multiInsertPath = try writeTempConfig(
            """
            {
              "defaults": {
                "watch": "/tmp/multi-insert-watch",
                "activeAction": "firstInsert"
              },
              "inserts": {
                "firstInsert": {
                  "action": "{{swResult}}",
                  "nextAction": "waitForApp"
                },
                "secondInsert": {
                  "action": "Done: {{swResult}}"
                }
              },
              "scriptsShell": {
                "waitForApp": {
                  "action": "sleep 1",
                  "scriptAsync": false,
                  "nextAction": "secondInsert"
                }
              }
            }
            """,
            name: "multi-insert.json"
        )
        let multiInsertReport = ConfigurationManager.validateConfig(at: multiInsertPath)
        assertTrue(
            multiInsertReport.isValid,
            "multi-insert chains are accepted by validation",
            details: reportDetails(multiInsertReport)
        )

        let cyclePath = try writeTempConfig(
            """
            {
              "defaults": {
                "watch": "/tmp/cycle-watch",
                "activeAction": "alpha"
              },
              "inserts": {
                "alpha": {
                  "action": "{{swResult}}",
                  "nextAction": "beta"
                },
                "beta": {
                  "action": "After",
                  "nextAction": "alpha"
                }
              }
            }
            """,
            name: "cycle.json"
        )
        let cycleReport = ConfigurationManager.validateConfig(at: cyclePath)
        assertTrue(
            !cycleReport.isValid && cycleReport.issues.contains(where: { $0.message.contains("cycle") }),
            "cycle validation still fails",
            details: reportDetails(cycleReport)
        )

        let missingPath = try writeTempConfig(
            """
            {
              "defaults": {
                "watch": "/tmp/missing-watch",
                "activeAction": "firstInsert"
              },
              "inserts": {
                "firstInsert": {
                  "action": "{{swResult}}",
                  "nextAction": "missingStep"
                }
              }
            }
            """,
            name: "missing-step.json"
        )
        let missingReport = ConfigurationManager.validateConfig(at: missingPath)
        assertTrue(
            !missingReport.isValid && missingReport.issues.contains(where: { $0.message.contains("referenced action does not exist") }),
            "missing chained action still fails validation",
            details: reportDetails(missingReport)
        )
    } catch {
        fputs("FAIL: validation regression setup\n\(error)\n", stderr)
        exit(1)
    }
}

@main
struct ActionChainValidationRegressionRunner {
    static func main() {
        runActionChainValidationRegressionTests()
    }
}
