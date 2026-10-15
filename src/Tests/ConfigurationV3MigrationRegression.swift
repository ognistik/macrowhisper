import Foundation

private func expect(_ condition: Bool, _ message: String) {
    guard condition else { fatalError("Configuration v3 regression failed: \(message)") }
}

private func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
}

private func write(_ data: Data, to path: String) throws {
    try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try data.write(to: URL(fileURLWithPath: path))
}

private func rootObject(_ data: Data) throws -> [String: Any] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fatalError("Expected a JSON object")
    }
    return root
}

private func actionValue(_ root: [String: Any], section: String, name: String) -> String? {
    (root[section] as? [String: Any])?[name].flatMap { $0 as? [String: Any] }?["action"] as? String
}

private func fixture(
    version: Int? = 2,
    autoUpdate: Bool = false,
    insert: String? = nil,
    url: String? = nil,
    shortcut: String? = nil,
    shell: String? = nil,
    appleScript: String? = nil,
    additionalRoot: [String: Any] = [:]
) throws -> Data {
    var root: [String: Any] = [
        "defaults": ["autoUpdateConfig": autoUpdate]
    ]
    if let version { root["configVersion"] = version }
    if let insert { root["inserts"] = ["insert": ["action": insert]] }
    if let url { root["urls"] = ["url": ["action": url]] }
    if let shortcut { root["shortcuts"] = ["shortcut": ["action": shortcut]] }
    if let shell { root["scriptsShell"] = ["shell": ["action": shell]] }
    if let appleScript { root["scriptsAS"] = ["appleScript": ["action": appleScript]] }
    for (key, value) in additionalRoot { root[key] = value }
    return try jsonData(root)
}

private func withTemporaryDirectory(_ body: (String) throws -> Void) throws {
    let path = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("macrowhisper-config-v3-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: path) }
    try body(path)
}

private func testProductionNewlineHelpers() {
    for count in 0...8 {
        let legacy = String(repeating: "\\", count: count) + "n"
        let expected = legacy.replacingOccurrences(of: "\\n", with: "\n")
        let migrated = canonicalizeLegacyMacrowhisperInsertAction(legacy)
        expect(decodeMacrowhisperNewlineEscapes(migrated) == expected, "legacy Insert slash run \(count) must match the old replace-all behavior")
    }

    for count in 0...8 {
        let source = "before" + String(repeating: "\\", count: count) + "\n" + "after"
        let canonical = canonicalizeMacrowhisperInsertAction(source)
        expect(decodeMacrowhisperNewlineEscapes(canonical) == source, "v3 Insert LF with \(count) preceding slashes must round-trip")
    }

    let lineEndings = ["LF\nend", "CR\rend", "CRLF\r\nend"]
    for source in lineEndings {
        expect(decodeMacrowhisperNewlineEscapes(canonicalizeMacrowhisperInsertAction(source)) == source, "Insert must preserve LF/CR/CRLF exactly")
        let withSlash = "before\\" + source
        expect(decodeMacrowhisperNewlineEscapes(canonicalizeMacrowhisperInsertAction(withSlash)) == withSlash, "Insert must preserve a preceding slash and each line-ending form")
    }

    let replacement = "{{result||x||before\r\nafter}}"
    let canonicalReplacement = canonicalizePlaceholderReplacementNewlines(replacement, legacy: false)
    expect(decodeMacrowhisperNewlineEscapes(canonicalReplacement) == replacement, "placeholder replacement must preserve CRLF through the production helper")
    let legacyReplacement = "{{result||x||before\nafter}}"
    expect(decodeMacrowhisperNewlineEscapes(canonicalizePlaceholderReplacementNewlines(legacyReplacement, legacy: true)) == legacyReplacement, "legacy placeholder migration must preserve raw LF")
    let staticText = "https://example.test/path\r\nnext"
    expect(canonicalizePlaceholderReplacementNewlines(staticText, legacy: false) == staticText, "static URL text must remain outside placeholder replacement escaping")
}

private func testAutomaticUpdateDisabledRuntimeParity() throws {
    try withTemporaryDirectory { directory in
        let path = (directory as NSString).appendingPathComponent("legacy-v2.json")
        let legacyAction = "one\\n|two" + String(repeating: "\\", count: 2) + "n|three" + String(repeating: "\\", count: 3) + "n"
        let original = try fixture(version: 2, autoUpdate: false, insert: legacyAction)
        try write(original, to: path)

        let manager = ConfigurationManager(configPath: path)
        let expectedLegacyOutput = legacyAction.replacingOccurrences(of: "\\n", with: "\n")
        let runtimeAction = manager.config.inserts["insert"]?.action ?? ""
        expect(decodeMacrowhisperNewlineEscapes(runtimeAction) == expectedLegacyOutput, "autoUpdate=false must retain legacy Insert runtime behavior")
        expect(try Data(contentsOf: URL(fileURLWithPath: path)) == original, "loading a legacy config must not rewrite its bytes")
        expect(manager.hasLegacyConfigOnDisk, "legacy config should remain marked on disk")
    }
}

private func testSequentialMigrationAndCrossActionEscapes() throws {
    try withTemporaryDirectory { directory in
        let path = (directory as NSString).appendingPathComponent("legacy-v1.json")
        let insert = "prefix" + String(repeating: "\\", count: 2) + "n|raw" + String(repeating: "\\", count: 1) + "\r\nend"
        let url = "https://example.test/static\r\n{{result||x||url\r\nreplacement}}"
        let shortcut = "{{result||x||shortcut\nreplacement}}"
        let shell = "printf '{{result||x||shell\r\nreplacement}}'"
        let appleScript = "return {{result||x||apple\nreplacement}}"
        let original = try fixture(
            version: nil,
            autoUpdate: false,
            insert: insert,
            url: url,
            shortcut: shortcut,
            shell: shell,
            appleScript: appleScript
        )
        try write(original, to: path)

        let manager = ConfigurationManager(configPath: path)
        expect(manager.migrateConfigurationIfNeeded() == .migrated, "v1 configuration should migrate")

        let finalData = try Data(contentsOf: URL(fileURLWithPath: path))
        let finalRoot = try rootObject(finalData)
        expect(finalRoot["configVersion"] as? Int == 3, "final file should have configVersion 3")
        expect(try Data(contentsOf: URL(fileURLWithPath: path + ".backup.pre-v2")) == original, "pre-v2 backup should preserve exact original bytes")

        let preV3Data = try Data(contentsOf: URL(fileURLWithPath: path + ".backup.pre-v3"))
        let preV3Root = try rootObject(preV3Data)
        expect(preV3Root["configVersion"] as? Int == 2, "pre-v3 backup should capture the sequential v2 representation")
        let preV3Config = try JSONDecoder().decode(AppConfiguration.self, from: preV3Data)
        expect(preV3Config.inserts["insert"]?.action == insert, "v2 backup should retain the legacy Insert payload before v3 conversion")

        let finalConfig = manager.config
        let expectedInsert = insert.replacingOccurrences(of: "\\n", with: "\n")
        expect(decodeMacrowhisperNewlineEscapes(finalConfig.inserts["insert"]!.action) == expectedInsert, "migrated Insert should retain historical output")
        let migratedURL = finalConfig.urls["url"]!.action
        expect(migratedURL.hasPrefix("https://example.test/static\r\n"), "static URL text and CRLF must remain literal")
        expect(migratedURL.contains("url\r\\nreplacement"), "URL replacement CRLF should retain CR and use the v3 LF token")
        expect(finalConfig.shortcuts["shortcut"]!.action.contains("shortcut\\nreplacement"), "Shortcut replacement LF should use v3 token")
        expect(finalConfig.scriptsShell["shell"]!.action.contains("shell\r\\nreplacement"), "shell replacement CRLF should retain CR and use the v3 LF token")
        expect(finalConfig.scriptsAS["appleScript"]!.action.contains("apple\\nreplacement"), "AppleScript replacement LF should use v3 token")
        expect(!FileManager.default.fileExists(atPath: path + ".macrowhisper-backup"), "migration should not create a rotating editor backup")
        let preV2BeforeRepeat = try Data(contentsOf: URL(fileURLWithPath: path + ".backup.pre-v2"))
        let preV3BeforeRepeat = try Data(contentsOf: URL(fileURLWithPath: path + ".backup.pre-v3"))
        expect(manager.migrateConfigurationIfNeeded() == .alreadyCurrent, "a repeated migration should be a no-op")
        expect(try Data(contentsOf: URL(fileURLWithPath: path + ".backup.pre-v2")) == preV2BeforeRepeat, "pre-v2 backup must remain immutable")
        expect(try Data(contentsOf: URL(fileURLWithPath: path + ".backup.pre-v3")) == preV3BeforeRepeat, "pre-v3 backup must remain immutable")
    }
}

private func testCurrentNoWriteAndBackupFailure() throws {
    try withTemporaryDirectory { directory in
        let currentPath = (directory as NSString).appendingPathComponent("current.json")
        let currentBytes = try fixture(version: 3, autoUpdate: true, insert: "current\\ntext")
        try write(currentBytes, to: currentPath)
        let currentManager = ConfigurationManager(configPath: currentPath)
        expect(currentManager.migrateConfigurationIfNeeded() == .alreadyCurrent, "current config should not be migrated")
        expect(try Data(contentsOf: URL(fileURLWithPath: currentPath)) == currentBytes, "current config bytes must remain unchanged")
        expect(!FileManager.default.fileExists(atPath: currentPath + ".backup.pre-v3"), "current config must not receive a migration backup")

        let legacyPath = (directory as NSString).appendingPathComponent("backup-failure.json")
        let legacyBytes = try fixture(version: 2, insert: "old\\ntext")
        try write(legacyBytes, to: legacyPath)
        try FileManager.default.createDirectory(atPath: legacyPath + ".backup.pre-v3", withIntermediateDirectories: true)
        let legacyManager = ConfigurationManager(configPath: legacyPath)
        expect(legacyManager.migrateConfigurationIfNeeded() == .failed, "backup creation failure must stop migration")
        expect(try Data(contentsOf: URL(fileURLWithPath: legacyPath)) == legacyBytes, "failed backup must leave the source untouched")

        let sequentialPath = (directory as NSString).appendingPathComponent("sequential-backup-failure.json")
        let sequentialBytes = try fixture(version: nil, insert: "old\\ntext")
        try write(sequentialBytes, to: sequentialPath)
        try FileManager.default.createDirectory(atPath: sequentialPath + ".backup.pre-v3", withIntermediateDirectories: true)
        let sequentialManager = ConfigurationManager(configPath: sequentialPath)
        expect(sequentialManager.migrateConfigurationIfNeeded() == .failed, "later step backup failure should stop before replacing v1")
        expect(try Data(contentsOf: URL(fileURLWithPath: sequentialPath)) == sequentialBytes, "all migration backups should succeed before replacing the source")
        expect(try Data(contentsOf: URL(fileURLWithPath: sequentialPath + ".backup.pre-v2")) == sequentialBytes, "successful earlier backup should preserve v1 bytes")
    }
}

private func testCurrentConfigSavePreservesUntouchedActions() throws {
    try withTemporaryDirectory { directory in
        let path = (directory as NSString).appendingPathComponent("current-save.json")
        let actions = [
            "insert": "first\nsecond " + String(repeating: "\\", count: 2) + "n",
            "url": "https://example.test/static\r\nnext",
            "shortcut": "{{result||x||replacement\r\nvalue}}",
            "shell": "echo 12.34567\nprintf '%s' " + String(repeating: "\\", count: 3) + "n",
            "appleScript": "return 12.34567\r\nvalue"
        ]
        let original = try fixture(
            version: 3,
            autoUpdate: true,
            insert: actions["insert"],
            url: actions["url"],
            shortcut: actions["shortcut"],
            shell: actions["shell"],
            appleScript: actions["appleScript"]
        )
        try write(original, to: path)

        let manager = ConfigurationManager(configPath: path)
        var settingsOnlyEdit = manager.config
        settingsOnlyEdit.defaults.activeAction = "insert"
        settingsOnlyEdit.defaults.muteTriggers = true
        manager.config = settingsOnlyEdit
        try manager.saveConfig()

        var savedRoot = try rootObject(Data(contentsOf: URL(fileURLWithPath: path)))
        expect(actionValue(savedRoot, section: "inserts", name: "insert") == actions["insert"], "settings-only save must preserve untouched Insert action bytes as a string")
        expect(actionValue(savedRoot, section: "urls", name: "url") == actions["url"], "settings-only save must preserve untouched URL action bytes as a string")
        expect(actionValue(savedRoot, section: "shortcuts", name: "shortcut") == actions["shortcut"], "settings-only save must preserve untouched Shortcut action bytes as a string")
        expect(actionValue(savedRoot, section: "scriptsShell", name: "shell") == actions["shell"], "settings-only save must preserve untouched numeric-looking shell text")
        expect(actionValue(savedRoot, section: "scriptsAS", name: "appleScript") == actions["appleScript"], "settings-only save must preserve untouched AppleScript line endings")

        let editedInsert = "typed\ninsert\r\nline " + String(repeating: "\\", count: 2) + "x"
        let editedURL = "https://edited.test/static\r\n{{result||x||replacement\ntext}}"
        let editedShortcut = "{{result||x||shortcut\r\nreplacement}}"
        let editedShell = "echo 12.34567\n{{result||x||shell\nreplacement}}"
        let editedAppleScript = "return {{result||x||apple\r\nreplacement}}"
        var changedActions = manager.config
        var insert = changedActions.inserts["insert"]!
        insert.action = editedInsert
        changedActions.inserts["insert"] = insert
        var url = changedActions.urls["url"]!
        url.action = editedURL
        changedActions.urls["url"] = url
        var shortcut = changedActions.shortcuts["shortcut"]!
        shortcut.action = editedShortcut
        changedActions.shortcuts["shortcut"] = shortcut
        var shell = changedActions.scriptsShell["shell"]!
        shell.action = editedShell
        changedActions.scriptsShell["shell"] = shell
        var appleScript = changedActions.scriptsAS["appleScript"]!
        appleScript.action = editedAppleScript
        changedActions.scriptsAS["appleScript"] = appleScript
        manager.config = changedActions
        try manager.saveConfig()

        savedRoot = try rootObject(Data(contentsOf: URL(fileURLWithPath: path)))
        let expectedInsert = "typed\\ninsert\r\\nline " + String(repeating: "\\", count: 2) + "x"
        let expectedURL = "https://edited.test/static\r\n{{result||x||replacement\\ntext}}"
        let expectedShortcut = "{{result||x||shortcut\r\\nreplacement}}"
        let expectedShell = "echo 12.34567\n{{result||x||shell\\nreplacement}}"
        let expectedAppleScript = "return {{result||x||apple\r\\nreplacement}}"
        expect(actionValue(savedRoot, section: "inserts", name: "insert") == expectedInsert, "edited Insert should store the canonical v3 escape sequence")
        expect(actionValue(savedRoot, section: "urls", name: "url") == expectedURL, "edited URL should escape only placeholder LF while retaining static CRLF")
        expect(actionValue(savedRoot, section: "shortcuts", name: "shortcut") == expectedShortcut, "edited Shortcut should escape replacement LF and retain CR")
        expect(actionValue(savedRoot, section: "scriptsShell", name: "shell") == expectedShell, "edited shell action should preserve numeric literal and encode replacement LF")
        expect(actionValue(savedRoot, section: "scriptsAS", name: "appleScript") == expectedAppleScript, "edited AppleScript should escape only replacement LF while retaining CR")
        expect(decodeMacrowhisperNewlineEscapes(actionValue(savedRoot, section: "inserts", name: "insert")!) == editedInsert, "edited Insert runtime text should round-trip exactly")
        expect(decodeMacrowhisperNewlineEscapes(actionValue(savedRoot, section: "urls", name: "url")!) == editedURL, "edited URL runtime text should round-trip exactly")
        expect(decodeMacrowhisperNewlineEscapes(actionValue(savedRoot, section: "shortcuts", name: "shortcut")!) == editedShortcut, "edited Shortcut runtime text should round-trip exactly")
        expect(decodeMacrowhisperNewlineEscapes(actionValue(savedRoot, section: "scriptsShell", name: "shell")!) == editedShell, "edited shell runtime text should round-trip exactly")
        expect(decodeMacrowhisperNewlineEscapes(actionValue(savedRoot, section: "scriptsAS", name: "appleScript")!) == editedAppleScript, "edited AppleScript runtime text should round-trip exactly")
    }
}

private func testRaceSymlinkAndInvalidPreservation() throws {
    try withTemporaryDirectory { directory in
        let racePath = (directory as NSString).appendingPathComponent("race.json")
        let original = try fixture(version: 2, insert: "old\\nvalue")
        try write(original, to: racePath)
        let external = try fixture(version: 3, insert: "external")
        let raceManager = ConfigurationManager(configPath: racePath)
        ConfigurationManager.migrationAfterBackupHook = {
            try? external.write(to: URL(fileURLWithPath: racePath))
        }
        let raceResult = raceManager.migrateConfigurationIfNeeded()
        ConfigurationManager.migrationAfterBackupHook = nil
        expect(raceResult == .failed, "a changed source after backup must stop migration")
        expect(try Data(contentsOf: URL(fileURLWithPath: racePath)) == external, "migration must not overwrite a concurrent external edit")
        expect(try Data(contentsOf: URL(fileURLWithPath: racePath + ".backup.pre-v3")) == original, "race backup should preserve the pre-migration bytes")

        let targetPath = (directory as NSString).appendingPathComponent("symlink-target.json")
        let linkPath = (directory as NSString).appendingPathComponent("symlink.json")
        let symlinkSource = try fixture(version: 2, insert: "link\\nvalue")
        try write(symlinkSource, to: targetPath)
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: targetPath)
        let linkManager = ConfigurationManager(configPath: linkPath)
        expect(linkManager.migrateConfigurationIfNeeded() == .migrated, "migration through symlink should succeed")
        expect(FileManager.default.fileExists(atPath: targetPath + ".backup.pre-v3"), "symlink migration backup should sit beside the target")
        expect(try Data(contentsOf: URL(fileURLWithPath: targetPath + ".backup.pre-v3")) == symlinkSource, "symlink backup should preserve target bytes")
        expect((try FileManager.default.attributesOfItem(atPath: linkPath)[.type] as? FileAttributeType) == .typeSymbolicLink, "migration should keep the selected symlink intact")

        let invalidPath = (directory as NSString).appendingPathComponent("invalid.json")
        let invalidBytes = Data("{broken".utf8)
        try write(invalidBytes, to: invalidPath)
        let invalidManager = ConfigurationManager(configPath: invalidPath)
        expect(invalidManager.migrateConfigurationIfNeeded() == .failed, "invalid JSON must not migrate")
        expect(try Data(contentsOf: URL(fileURLWithPath: invalidPath)) == invalidBytes, "invalid JSON must remain byte-for-byte unchanged")

        let emptyPath = (directory as NSString).appendingPathComponent("empty.json")
        try write(Data(), to: emptyPath)
        let emptyManager = ConfigurationManager(configPath: emptyPath)
        expect(emptyManager.migrateConfigurationIfNeeded() == .failed, "empty config must not migrate")
        expect(try Data(contentsOf: URL(fileURLWithPath: emptyPath)).isEmpty, "empty config must not be reset during startup or migration")

        let invalidVersionPath = (directory as NSString).appendingPathComponent("invalid-version.json")
        let invalidVersionBytes = try fixture(version: 0, insert: "old\\nvalue")
        try write(invalidVersionBytes, to: invalidVersionPath)
        let invalidVersionManager = ConfigurationManager(configPath: invalidVersionPath)
        expect(invalidVersionManager.migrateConfigurationIfNeeded() == .failed, "configVersion below 1 must remain invalid")
        expect(try Data(contentsOf: URL(fileURLWithPath: invalidVersionPath)) == invalidVersionBytes, "invalid configVersion must remain unchanged")

        let unknownPath = (directory as NSString).appendingPathComponent("unknown.json")
        let unknownBytes = try fixture(version: 2, insert: "old\\nvalue", additionalRoot: ["futureField": ["keep": true]])
        try write(unknownBytes, to: unknownPath)
        let unknownManager = ConfigurationManager(configPath: unknownPath)
        expect(unknownManager.migrateConfigurationIfNeeded() == .failed, "unknown fields must block typed migration")
        expect(try Data(contentsOf: URL(fileURLWithPath: unknownPath)) == unknownBytes, "unknown-field config must remain unchanged")

        let currentUnknownPath = (directory as NSString).appendingPathComponent("current-unknown.json")
        let currentUnknownBytes = try fixture(version: 3, insert: "current", additionalRoot: ["futureField": ["keep": true]])
        try write(currentUnknownBytes, to: currentUnknownPath)
        let currentUnknownManager = ConfigurationManager(configPath: currentUnknownPath)
        expect(currentUnknownManager.migrateConfigurationIfNeeded() == .failed, "current-version unknown fields must not report successful update")
        expect(try Data(contentsOf: URL(fileURLWithPath: currentUnknownPath)) == currentUnknownBytes, "current-version unknown-field config must remain unchanged")

        let futurePath = (directory as NSString).appendingPathComponent("future.json")
        let futureBytes = try fixture(version: 4, insert: "future\\nvalue")
        try write(futureBytes, to: futurePath)
        let futureManager = ConfigurationManager(configPath: futurePath)
        expect(futureManager.migrateConfigurationIfNeeded() == .failed, "future version must fail closed")
        futureManager.config = AppConfiguration.defaultConfig()
        do {
            try futureManager.saveConfig()
            fatalError("future config save should be refused")
        } catch {}
        expect(try Data(contentsOf: URL(fileURLWithPath: futurePath)) == futureBytes, "future config must survive attempted save unchanged")
    }
}

@main
private struct ConfigurationV3MigrationRegression {
    static func main() {
        do {
            testProductionNewlineHelpers()
            try testAutomaticUpdateDisabledRuntimeParity()
            try testSequentialMigrationAndCrossActionEscapes()
            try testCurrentNoWriteAndBackupFailure()
            try testCurrentConfigSavePreservesUntouchedActions()
            try testRaceSymlinkAndInvalidPreservation()
            print("Configuration v3 migration regression passed")
        } catch {
            fatalError("Configuration v3 migration regression threw: \(error)")
        }
    }
}
