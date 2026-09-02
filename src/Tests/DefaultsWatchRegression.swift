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

private func assertOptionalEqual(_ actual: String?, _ expected: String?, _ label: String) {
    if actual != expected {
        fputs("FAIL: \(label)\nexpected: \(String(describing: expected))\nactual:   \(String(describing: actual))\n", stderr)
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
        assertEqual(starterDefaults.clipboardAttachments, false, "starter defaults use clipboardAttachments false")
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
        assertTrue(starterJson.contains("\"clipboardAttachments\":false"), "starter config persists clipboardAttachments false")
        assertTrue(starterJson.contains("\"clipboardIgnore\":\"\""), "starter config persists empty clipboardIgnore")
        assertTrue(starterJson.contains("\"nextAction\":\"\""), "starter config persists empty nextAction")

        let home = "/Users/example"
        let currentPath = "/Users/example/superwhisper"
        let legacyPath = "/Users/example/Documents/superwhisper"
        let persistedCurrentPath = "~/superwhisper"
        let persistedLegacyPath = "~/Documents/superwhisper"

        let freshInstallPath = AppConfiguration.resolveWatchPathForNewConfiguration(
            homeDirectory: home,
            configuredParentDirectory: nil,
            pathExists: { _ in false }
        )
        assertEqual(freshInstallPath, persistedCurrentPath, "fresh installations persist the current Superwhisper folder with tilde")

        let legacyInstallPath = AppConfiguration.resolveWatchPathForNewConfiguration(
            homeDirectory: home,
            configuredParentDirectory: nil,
            pathExists: { $0 == "\(legacyPath)/recordings" }
        )
        assertEqual(legacyInstallPath, persistedLegacyPath, "legacy recordings folder is detected and persisted with tilde")

        let currentInstallPath = AppConfiguration.resolveWatchPathForNewConfiguration(
            homeDirectory: home,
            configuredParentDirectory: nil,
            pathExists: { $0 == "\(currentPath)/recordings" }
        )
        assertEqual(currentInstallPath, persistedCurrentPath, "current recordings folder is detected and persisted with tilde")

        let ambiguousPath = AppConfiguration.resolveWatchPathForNewConfiguration(
            homeDirectory: home,
            configuredParentDirectory: nil,
            pathExists: { $0 == currentPath || $0 == legacyPath }
        )
        assertEqual(ambiguousPath, persistedCurrentPath, "current folder wins an ambiguous filesystem-only tie")

        let configuredLegacyPath = AppConfiguration.resolveWatchPathForNewConfiguration(
            homeDirectory: home,
            configuredParentDirectory: "~/Documents",
            pathExists: { _ in false }
        )
        assertEqual(configuredLegacyPath, persistedLegacyPath, "Superwhisper's configured legacy parent is honored with tilde")

        let configuredCustomPath = AppConfiguration.resolveWatchPathForNewConfiguration(
            homeDirectory: home,
            configuredParentDirectory: "/Volumes/Voice Data",
            pathExists: { _ in false }
        )
        assertEqual(configuredCustomPath, "/Volumes/Voice Data/superwhisper", "Superwhisper's custom parent is honored")

        let healthyPathRecovery = AppConfiguration.resolveWatchPathForRecovery(
            configuredWatchPath: persistedLegacyPath,
            homeDirectory: home,
            configuredParentDirectory: home,
            pathIsDirectory: { $0 == "\(legacyPath)/recordings" || $0 == "\(currentPath)/recordings" }
        )
        assertNil(healthyPathRecovery, "a healthy explicit watch path is never migrated")

        let manualMoveRecovery = AppConfiguration.resolveWatchPathForRecovery(
            configuredWatchPath: persistedLegacyPath,
            homeDirectory: home,
            configuredParentDirectory: "~/Documents",
            pathIsDirectory: { $0 == "\(currentPath)/recordings" }
        )
        assertEqual(manualMoveRecovery ?? "", persistedCurrentPath, "a manual legacy-to-current move recovers despite a stale Superwhisper preference")

        let preferenceRecovery = AppConfiguration.resolveWatchPathForRecovery(
            configuredWatchPath: persistedLegacyPath,
            homeDirectory: home,
            configuredParentDirectory: "/Volumes/Voice Data",
            pathIsDirectory: { $0 == "/Volumes/Voice Data/superwhisper/recordings" }
        )
        assertEqual(preferenceRecovery ?? "", "/Volumes/Voice Data/superwhisper", "a valid Superwhisper preference repairs a broken watch path")

        let protectedCustomPathRecovery = AppConfiguration.resolveWatchPathForRecovery(
            configuredWatchPath: "/Volumes/Archived Voice/superwhisper",
            homeDirectory: home,
            configuredParentDirectory: nil,
            pathIsDirectory: { $0 == "\(currentPath)/recordings" }
        )
        assertNil(protectedCustomPathRecovery, "the current default is not guessed for an unrelated custom path")

        let missingReplacementRecovery = AppConfiguration.resolveWatchPathForRecovery(
            configuredWatchPath: persistedLegacyPath,
            homeDirectory: home,
            configuredParentDirectory: home,
            pathIsDirectory: { _ in false }
        )
        assertNil(missingReplacementRecovery, "recovery requires a real recordings folder")

        let newInsert = AppConfiguration.Insert(action: "")
        let insertData = try JSONEncoder().encode(newInsert)
        let insertJson = String(decoding: insertData, as: UTF8.self)
        assertTrue(insertJson.contains("\"icon\":null"), "new insert action stays sparse with null icon")
        assertTrue(insertJson.contains("\"moveTo\":null"), "new insert action stays sparse with null moveTo")
        assertTrue(insertJson.contains("\"clipboardStacking\":null"), "new insert action inherits clipboardStacking with null")
        assertTrue(insertJson.contains("\"clipboardAttachments\":null"), "new insert action inherits clipboardAttachments with null")
        assertTrue(insertJson.contains("\"nextAction\":null"), "new insert action stays sparse with null nextAction")
        assertTrue(insertJson.contains("\"triggerLogic\":\"or\""), "new insert action still persists triggerLogic")

        let newActionEncodings: [(String, Data)] = [
            ("URL", try JSONEncoder().encode(AppConfiguration.Url(action: ""))),
            ("Shortcut", try JSONEncoder().encode(AppConfiguration.Shortcut(action: ""))),
            ("Shell", try JSONEncoder().encode(AppConfiguration.ScriptShell(action: ""))),
            ("AppleScript", try JSONEncoder().encode(AppConfiguration.ScriptAppleScript(action: "")))
        ]
        for (actionType, data) in newActionEncodings {
            let json = String(decoding: data, as: UTF8.self)
            assertTrue(json.contains("\"clipboardStacking\":null"), "new \(actionType) action inherits clipboardStacking with null")
            assertTrue(json.contains("\"clipboardAttachments\":null"), "new \(actionType) action inherits clipboardAttachments with null")
        }

        assertEqual(
            effectiveClipboardStacking(for: newInsert, defaultValue: true),
            true,
            "null action clipboardStacking inherits true default"
        )
        assertEqual(
            effectiveClipboardStacking(
                for: AppConfiguration.Insert(action: "", clipboardStacking: false),
                defaultValue: true
            ),
            false,
            "false action clipboardStacking overrides true default"
        )
        assertEqual(
            effectiveClipboardStacking(
                for: AppConfiguration.Insert(action: "", clipboardStacking: true),
                defaultValue: false
            ),
            true,
            "true action clipboardStacking overrides false default"
        )

        assertEqual(
            effectiveClipboardAttachments(for: newInsert, defaultValue: true),
            true,
            "null action clipboardAttachments inherits true default"
        )
        assertEqual(
            effectiveClipboardAttachments(
                for: AppConfiguration.Insert(action: "", clipboardAttachments: false),
                defaultValue: true
            ),
            false,
            "false action clipboardAttachments overrides true default"
        )
        assertEqual(
            effectiveClipboardAttachments(
                for: AppConfiguration.Insert(action: "", clipboardAttachments: true),
                defaultValue: false
            ),
            true,
            "true action clipboardAttachments overrides false default"
        )

        let moveToDefault = ".delete"
        let moveToActionFactories: [(String, (String?) -> Any)] = [
            ("insert", { AppConfiguration.Insert(action: "", moveTo: $0) }),
            ("URL", { AppConfiguration.Url(action: "", moveTo: $0) }),
            ("Shortcut", { AppConfiguration.Shortcut(action: "", moveTo: $0) }),
            ("Shell", { AppConfiguration.ScriptShell(action: "", moveTo: $0) }),
            ("AppleScript", { AppConfiguration.ScriptAppleScript(action: "", moveTo: $0) })
        ]

        for (actionType, makeAction) in moveToActionFactories {
            assertOptionalEqual(
                effectiveMoveTo(for: makeAction(nil), defaultValue: moveToDefault),
                moveToDefault,
                "\(actionType) nil moveTo inherits the nonempty default"
            )
            assertOptionalEqual(
                effectiveMoveTo(for: makeAction(""), defaultValue: moveToDefault),
                "",
                "\(actionType) empty moveTo suppresses the nonempty default"
            )
            assertOptionalEqual(
                effectiveMoveTo(for: makeAction("/tmp/\(actionType)"), defaultValue: moveToDefault),
                "/tmp/\(actionType)",
                "\(actionType) nonempty moveTo overrides the default"
            )
            assertOptionalEqual(
                effectiveMoveTo(for: makeAction(".delete"), defaultValue: "/tmp/default"),
                ".delete",
                "\(actionType) .delete moveTo overrides the default"
            )
        }

        let decodedMoveToInheritance = try decodeConfig("""
        {
          "configVersion": 2,
          "defaults": { "moveTo": ".delete" },
          "inserts": {
            "omitted": { "action": "" },
            "null": { "action": "", "moveTo": null }
          },
          "urls": {
            "omitted": { "action": "" },
            "null": { "action": "", "moveTo": null }
          },
          "shortcuts": {
            "omitted": { "action": "" },
            "null": { "action": "", "moveTo": null }
          },
          "scriptsShell": {
            "omitted": { "action": "" },
            "null": { "action": "", "moveTo": null }
          },
          "scriptsAS": {
            "omitted": { "action": "" },
            "null": { "action": "", "moveTo": null }
          }
        }
        """)
        let decodedMoveToActions: [(String, Any?)] = [
            ("insert omitted", decodedMoveToInheritance.inserts["omitted"]),
            ("insert null", decodedMoveToInheritance.inserts["null"]),
            ("URL omitted", decodedMoveToInheritance.urls["omitted"]),
            ("URL null", decodedMoveToInheritance.urls["null"]),
            ("Shortcut omitted", decodedMoveToInheritance.shortcuts["omitted"]),
            ("Shortcut null", decodedMoveToInheritance.shortcuts["null"]),
            ("Shell omitted", decodedMoveToInheritance.scriptsShell["omitted"]),
            ("Shell null", decodedMoveToInheritance.scriptsShell["null"]),
            ("AppleScript omitted", decodedMoveToInheritance.scriptsAS["omitted"]),
            ("AppleScript null", decodedMoveToInheritance.scriptsAS["null"])
        ]
        for (label, action) in decodedMoveToActions {
            assertOptionalEqual(
                effectiveMoveTo(for: action, defaultValue: decodedMoveToInheritance.defaults.moveTo),
                moveToDefault,
                "configVersion 2 \(label) moveTo inherits the default"
            )
        }

        let explicitAttachmentInheritance = try decodeConfig("""
        {
          "configVersion": 2,
          "defaults": {
            "clipboardAttachments": true
          },
          "inserts": {
            "omitted": { "action": "" },
            "null": { "action": "", "clipboardAttachments": null },
            "false": { "action": "", "clipboardAttachments": false },
            "true": { "action": "", "clipboardAttachments": true }
          }
        }
        """)
        assertEqual(
            effectiveClipboardAttachments(
                for: explicitAttachmentInheritance.inserts["omitted"],
                defaultValue: explicitAttachmentInheritance.defaults.clipboardAttachments
            ),
            true,
            "configVersion 2 omitted clipboardAttachments inherits defaults"
        )
        assertEqual(
            effectiveClipboardAttachments(
                for: explicitAttachmentInheritance.inserts["null"],
                defaultValue: explicitAttachmentInheritance.defaults.clipboardAttachments
            ),
            true,
            "configVersion 2 null clipboardAttachments inherits defaults"
        )
        assertEqual(
            effectiveClipboardAttachments(
                for: explicitAttachmentInheritance.inserts["false"],
                defaultValue: explicitAttachmentInheritance.defaults.clipboardAttachments
            ),
            false,
            "configVersion 2 false clipboardAttachments overrides defaults"
        )
        assertEqual(
            effectiveClipboardAttachments(
                for: explicitAttachmentInheritance.inserts["true"],
                defaultValue: false
            ),
            true,
            "configVersion 2 true clipboardAttachments overrides defaults"
        )
        assertEqual(
            explicitAttachmentInheritance.canCaptureClipboardAttachments,
            true,
            "true default enables process-wide binary clipboard capture"
        )

        let explicitAttachmentOptIn = try decodeConfig("""
        {
          "configVersion": 2,
          "defaults": {
            "clipboardAttachments": false
          },
          "scriptsShell": {
            "attachment consumer": {
              "action": "{{clipboardContext}}",
              "clipboardAttachments": true
            }
          }
        }
        """)
        assertEqual(
            explicitAttachmentOptIn.canCaptureClipboardAttachments,
            true,
            "an explicit action opt-in enables process-wide binary clipboard capture"
        )
        assertEqual(
            AppConfiguration.defaultConfig().canCaptureClipboardAttachments,
            false,
            "default configuration avoids continuous binary clipboard capture"
        )

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
