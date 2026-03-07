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

private func assertEqual(_ actual: Double, _ expected: Double, _ label: String) {
    if actual != expected {
        fputs("FAIL: \(label)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
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

private func assertNil<T>(_ value: T?, _ label: String) {
    if value != nil {
        fputs("FAIL: \(label)\nexpected: nil\nactual:   \(String(describing: value))\n", stderr)
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

        let starterDefaults = AppConfiguration.Defaults.defaultValues()
        assertEqual(starterDefaults.returnDelay, 0.15, "starter defaults use returnDelay 0.15")
        assertEqual(starterDefaults.restoreClipboardDelay ?? -1, 0.3, "starter defaults use restoreClipboardDelay 0.3")
        assertEqual(starterDefaults.scriptAsync ?? false, true, "starter defaults use scriptAsync true")
        assertEqual(starterDefaults.scriptWaitTimeout ?? -1, 3, "starter defaults use scriptWaitTimeout 3")
        assertEqual(starterDefaults.icon ?? "__nil__", "", "starter defaults use explicit empty icon")
        assertEqual(starterDefaults.moveTo ?? "__nil__", "", "starter defaults use explicit empty moveTo")
        assertEqual(starterDefaults.clipboardIgnore ?? "__nil__", "", "starter defaults use explicit empty clipboardIgnore")
        assertEqual(starterDefaults.bypassModes ?? "__nil__", "", "starter defaults use explicit empty bypassModes")
        assertEqual(starterDefaults.nextAction ?? "__nil__", "", "starter defaults use explicit empty nextAction")

        var canonicalized = try decodeConfig("""
        {
          "defaults": {
            "watch": "/tmp/custom-watch",
            "activeAction": "autoPaste",
            "icon": null,
            "moveTo": null,
            "history": null,
            "restoreClipboardDelay": null,
            "scriptAsync": null,
            "scriptWaitTimeout": null,
            "clipboardIgnore": null,
            "bypassModes": null,
            "nextAction": null
          }
        }
        """)
        let changed = canonicalized.defaults.canonicalizeRootDefaultsForPersistence()
        assertEqual(changed, true, "canonicalization reports changes for fallback-style null root defaults")
        assertEqual(canonicalized.defaults.icon ?? "__nil__", "", "root icon null canonicalizes to empty string")
        assertEqual(canonicalized.defaults.moveTo ?? "__nil__", "", "root moveTo null canonicalizes to empty string")
        assertEqual(canonicalized.defaults.restoreClipboardDelay ?? -1, 0.3, "root restoreClipboardDelay null canonicalizes to 0.3")
        assertEqual(canonicalized.defaults.scriptAsync ?? false, true, "root scriptAsync null canonicalizes to true")
        assertEqual(canonicalized.defaults.scriptWaitTimeout ?? -1, 3, "root scriptWaitTimeout null canonicalizes to 3")
        assertEqual(canonicalized.defaults.clipboardIgnore ?? "__nil__", "", "root clipboardIgnore null canonicalizes to empty string")
        assertEqual(canonicalized.defaults.bypassModes ?? "__nil__", "", "root bypassModes null canonicalizes to empty string")
        assertEqual(canonicalized.defaults.nextAction ?? "__nil__", "", "root nextAction null canonicalizes to empty string")
        assertNil(canonicalized.defaults.history, "root history nil remains nil")

        var explicitDefaults = try decodeConfig("""
        {
          "defaults": {
            "watch": "/tmp/custom-watch",
            "activeAction": "autoPaste",
            "icon": "*",
            "moveTo": ".delete",
            "returnDelay": 0.4,
            "history": 7,
            "restoreClipboardDelay": 0.8,
            "scriptAsync": false,
            "scriptWaitTimeout": 9,
            "clipboardIgnore": "Arc",
            "bypassModes": "dictation",
            "nextAction": "followUp"
          }
        }
        """)
        let explicitChanged = explicitDefaults.defaults.canonicalizeRootDefaultsForPersistence()
        assertEqual(explicitChanged, false, "canonicalization leaves explicit root defaults unchanged")
        assertEqual(explicitDefaults.defaults.returnDelay, 0.4, "explicit returnDelay stays unchanged")
        assertEqual(explicitDefaults.defaults.scriptWaitTimeout ?? -1, 9, "explicit scriptWaitTimeout stays unchanged")

        let missingReturnDelay = try decodeConfig("""
        {
          "defaults": {
            "watch": "/tmp/custom-watch",
            "activeAction": "autoPaste"
          }
        }
        """)
        assertEqual(missingReturnDelay.defaults.returnDelay, 0.15, "missing returnDelay falls back to new built-in default")

        let explicitLegacyReturnDelay = try decodeConfig("""
        {
          "defaults": {
            "watch": "/tmp/custom-watch",
            "activeAction": "autoPaste",
            "returnDelay": 0.1
          }
        }
        """)
        assertEqual(explicitLegacyReturnDelay.defaults.returnDelay, 0.1, "explicit legacy returnDelay value is preserved")

        let starterConfig = AppConfiguration.defaultConfig()
        let starterData = try JSONEncoder().encode(starterConfig)
        let starterJson = String(decoding: starterData, as: UTF8.self)
        assertTrue(starterJson.contains("\"returnDelay\":0.15"), "starter config persists returnDelay 0.15")
        assertTrue(starterJson.contains("\"scriptWaitTimeout\":3"), "starter config persists scriptWaitTimeout without trailing .0")
        assertTrue(starterJson.contains("\"clipboardIgnore\":\"\""), "starter config persists empty clipboardIgnore")
        assertTrue(starterJson.contains("\"nextAction\":\"\""), "starter config persists empty nextAction")

        let newInsert = AppConfiguration.Insert(action: "")
        let insertData = try JSONEncoder().encode(newInsert)
        let insertJson = String(decoding: insertData, as: UTF8.self)
        assertTrue(insertJson.contains("\"icon\":null"), "new insert action stays sparse with null icon")
        assertTrue(insertJson.contains("\"moveTo\":null"), "new insert action stays sparse with null moveTo")
        assertTrue(insertJson.contains("\"nextAction\":null"), "new insert action stays sparse with null nextAction")
        assertTrue(insertJson.contains("\"triggerLogic\":\"or\""), "new insert action still persists triggerLogic")

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
