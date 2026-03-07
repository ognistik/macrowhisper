import Foundation

private func assertTrue(_ condition: Bool, _ label: String, details: String = "") {
    if !condition {
        let suffix = details.isEmpty ? "" : "\n\(details)"
        fputs("FAIL: \(label)\(suffix)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func assertEqual(_ actual: String, _ expected: String, _ label: String) {
    if actual != expected {
        fputs("FAIL: \(label)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func decodeConfig(_ json: String) throws -> AppConfiguration {
    try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
}

private func runDefaultsWatchRegressionTests() {
    let defaultWatch = AppConfiguration.Defaults.defaultValues().watch

    do {
        let missingWatch = try decodeConfig("""
        {
          "defaults": {
            "activeAction": null
          }
        }
        """)
        assertEqual(missingWatch.defaults.watch, defaultWatch, "missing defaults.watch falls back to built-in default")

        let nullWatch = try decodeConfig("""
        {
          "defaults": {
            "watch": null,
            "activeAction": null
          }
        }
        """)
        assertEqual(nullWatch.defaults.watch, defaultWatch, "null defaults.watch falls back to built-in default")

        let explicitWatch = try decodeConfig("""
        {
          "defaults": {
            "watch": "/tmp/custom-watch",
            "activeAction": null
          }
        }
        """)
        assertEqual(explicitWatch.defaults.watch, "/tmp/custom-watch", "explicit defaults.watch is preserved")

        let encoded = try JSONEncoder().encode(nullWatch)
        let roundTrip = try JSONDecoder().decode(AppConfiguration.self, from: encoded)
        assertEqual(roundTrip.defaults.watch, defaultWatch, "encoded config materializes the resolved watch path")

        do {
            _ = try decodeConfig("""
            {
              "defaults": {
                "watch": "/tmp/custom-watch"
              },
              "inserts": {
                "broken": {
                  "action": null
                }
              }
            }
            """)
            assertTrue(false, "action null remains invalid")
        } catch {
            print("PASS: action null remains invalid")
        }

        do {
            _ = try decodeConfig("""
            {
              "defaults": {
                "watch": "/tmp/custom-watch"
              },
              "inserts": {
                "broken": {}
              }
            }
            """)
            assertTrue(false, "missing action remains invalid")
        } catch {
            print("PASS: missing action remains invalid")
        }
    } catch {
        fputs("FAIL: defaults.watch regression setup\n\(error)\n", stderr)
        exit(1)
    }
}

@main
struct DefaultsWatchRegressionRunner {
    static func main() {
        runDefaultsWatchRegressionTests()
    }
}
