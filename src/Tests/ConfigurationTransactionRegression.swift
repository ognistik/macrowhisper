import Foundation

private func fail(_ label: String, details: String = "") -> Never {
    let suffix = details.isEmpty ? "" : "\n\(details)"
    fputs("FAIL: \(label)\(suffix)\n", stderr)
    exit(1)
}

private func assertTrue(_ condition: Bool, _ label: String, details: String = "") {
    guard condition else { fail(label, details: details) }
    print("PASS: \(label)")
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    guard actual == expected else {
        fail(label, details: "expected: \(expected)\nactual:   \(actual)")
    }
    print("PASS: \(label)")
}

private func makeTemporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("macrowhisper-configuration-transaction-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private let validConfigurationJSON = """
{
  "configVersion": 2,
  "defaults": {
    "watch": "/tmp/macrowhisper-transaction-watch",
    "activeAction": "autoPaste"
  },
  "inserts": {
    "autoPaste": {
      "action": "Value 1.23456",
      "triggerLogic": "or"
    }
  }
}
"""

private func write(_ json: String, to path: URL) throws {
    try Data(json.utf8).write(to: path, options: .atomic)
}

private func write(_ config: AppConfiguration, to path: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(config).write(to: path, options: .atomic)
}

private func encoded(_ config: AppConfiguration) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(config)
}

private func readConfig(at path: URL) throws -> AppConfiguration {
    try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: path))
}

private func pumpMainQueue(for seconds: TimeInterval = 0.12) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

private func rejectionCode(_ result: ConfigurationTransactionResult) -> ConfigurationTransactionErrorCode? {
    guard case .rejected(let error) = result else { return nil }
    return error.code
}

private struct InjectedWriteFailure: Error, LocalizedError {
    var errorDescription: String? { "injected temporary write failure" }
}

private func runConfigurationTransactionRegressionTests() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let path = root.appendingPathComponent("config.json")
    try write(validConfigurationJSON, to: path)
    let manager = ConfigurationManager(configPath: path.path)
    var callbackReasons: [String?] = []
    manager.onConfigChanged = { callbackReasons.append($0) }

    let initial = manager.configurationSnapshot()
    assertTrue(initial.diskIsValid, "valid configuration snapshot reports valid disk")
    assertTrue(!initial.isLegacyOnDisk, "current configuration snapshot is writable")
    assertEqual(initial.diskIssues.count, 0, "valid snapshot has no disk issues")
    assertEqual(initial.config.inserts["autoPaste"]?.action, "Value 1.23456", "payload decimal text survives initial load")

    let numericEdit = ConfigurationEdit(
        path: ["defaults", "actionDelay"],
        operation: .set,
        value: .number(1.23456)
    )
    let firstCommit = manager.applyConfigurationEdits(
        [numericEdit],
        expectedRevision: initial.revision,
        reason: "transaction-test"
    )
    guard case .committed(let committed) = firstCommit else {
        fail("valid transaction commits", details: String(describing: rejectionCode(firstCommit)))
    }
    assertEqual(committed.config.defaults.actionDelay, 1.23456, "numeric edit keeps its value")
    let committedOnDisk = try readConfig(at: path)
    assertEqual(committedOnDisk.defaults.actionDelay, 1.23456, "numeric edit is persisted")
    assertEqual(committedOnDisk.inserts["autoPaste"]?.action, "Value 1.23456", "numeric serialization does not round payload strings")
    pumpMainQueue()
    assertEqual(callbackReasons.filter { $0 == "transaction-test" }.count, 1, "successful transaction publishes one callback")

    let watcherBeforeReload = ConfigChangeWatcher.latest
    let callbackCountBeforeReload = callbackReasons.count
    assertTrue(manager.reloadConfiguration(), "explicit reload succeeds for an unchanged valid file")
    pumpMainQueue()
    assertEqual(callbackReasons.count, callbackCountBeforeReload + 1, "explicit reload publishes one callback")
    assertEqual(callbackReasons.last ?? nil, "configFileChanged", "explicit reload uses the config change callback reason")
    assertTrue(ConfigChangeWatcher.latest !== watcherBeforeReload, "explicit reload re-arms the watcher")

    // Scalar edits preserve the JSON value domain used by the editor: false,
    // zero, an explicit empty string, and remove are all distinct operations.
    func commitScalar(_ edit: ConfigurationEdit, _ label: String, _ snapshot: inout ConfigurationSnapshot) {
        let result = manager.applyConfigurationEdits(
            [edit],
            expectedRevision: snapshot.revision,
            reason: "scalar-test"
        )
        guard case .committed(let committed) = result else {
            fail(label, details: String(describing: rejectionCode(result)))
        }
        snapshot = committed
        assertTrue(true, label)
    }

    var scalarSnapshot = manager.configurationSnapshot()
    commitScalar(
        ConfigurationEdit(path: ["defaults", "muteNotifications"], operation: .set, value: .boolean(false)),
        "explicit false edit commits",
        &scalarSnapshot
    )
    commitScalar(
        ConfigurationEdit(path: ["defaults", "actionDelay"], operation: .set, value: .number(0)),
        "explicit zero edit commits",
        &scalarSnapshot
    )
    commitScalar(
        ConfigurationEdit(path: ["defaults", "icon"], operation: .set, value: .string("")),
        "explicit empty string edit commits",
        &scalarSnapshot
    )
    commitScalar(
        ConfigurationEdit(path: ["defaults", "icon"], operation: .set, value: .string("temporary-icon")),
        "set value before remove commits",
        &scalarSnapshot
    )
    commitScalar(
        ConfigurationEdit(path: ["defaults", "icon"], operation: .remove),
        "remove edit commits",
        &scalarSnapshot
    )
    let scalarOnDisk = try readConfig(at: path)
    assertTrue(!scalarOnDisk.defaults.muteNotifications, "false edit remains false on disk")
    assertEqual(scalarOnDisk.defaults.actionDelay, 0, "zero edit remains zero on disk")
    assertTrue(scalarOnDisk.defaults.icon == nil, "remove edit restores nil semantics")
    pumpMainQueue()

    // A write failure occurs before the temporary file is published. Runtime,
    // revision, bytes, and callbacks must all remain unchanged.
#if CONFIGURATION_TRANSACTION_TESTING
    let failedWriteBase = manager.configurationSnapshot()
    let failedWriteBytes = try Data(contentsOf: path)
#if CONFIGURATION_TRANSACTION_TESTING
    ConfigurationManager.transactionBeforeTemporaryWriteHook = { _, _ in
        throw InjectedWriteFailure()
    }
#endif
    let callbackCountBeforeFailedWrite = callbackReasons.count
    let failedWriteResult = manager.applyConfigurationEdits(
        [ConfigurationEdit(path: ["defaults", "actionDelay"], operation: .set, value: .number(2.5))],
        expectedRevision: failedWriteBase.revision,
        reason: "failed-write-test"
    )
#if CONFIGURATION_TRANSACTION_TESTING
    ConfigurationManager.transactionBeforeTemporaryWriteHook = nil
#endif
    assertEqual(rejectionCode(failedWriteResult), .persistenceFailed, "failed mutation write is rejected")
    assertEqual(manager.configurationSnapshot().revision, failedWriteBase.revision, "failed write does not advance revision")
    assertEqual(manager.config.defaults.actionDelay, failedWriteBase.config.defaults.actionDelay, "failed write does not publish runtime state")
    assertEqual(try Data(contentsOf: path), failedWriteBytes, "failed write leaves configuration bytes unchanged")
    pumpMainQueue()
    assertEqual(callbackReasons.count, callbackCountBeforeFailedWrite, "failed write does not publish a callback")
#endif

    let beforeInvalid = manager.configurationSnapshot()
    let invalidEdit = ConfigurationEdit(
        path: ["inserts", "autoPaste", "triggerLogic"],
        operation: .set,
        value: .string("xor")
    )
    let invalidResult = manager.applyConfigurationEdits([invalidEdit], expectedRevision: beforeInvalid.revision)
    assertEqual(rejectionCode(invalidResult), .validationFailed, "invalid semantic edit is rejected")
    assertEqual(manager.configurationSnapshot().revision, beforeInvalid.revision, "invalid edit does not advance revision")
    assertEqual(try readConfig(at: path).inserts["autoPaste"]?.triggerLogic, "or", "invalid edit leaves the file unchanged")

    let crossSectionEdit = ConfigurationEdit(
        path: ["defaults", "openWith"],
        operation: .set,
        value: .string("Preview")
    )
    let crossSectionResult = manager.applyConfigurationEdits([crossSectionEdit], expectedRevision: beforeInvalid.revision)
    assertEqual(rejectionCode(crossSectionResult), .invalidPath, "cross-section field is rejected")

    let wrongActionField = ConfigurationEdit(
        path: ["inserts", "autoPaste", "openWith"],
        operation: .set,
        value: .string("Preview")
    )
    let wrongActionFieldResult = manager.applyConfigurationEdits([wrongActionField], expectedRevision: beforeInvalid.revision)
    assertEqual(rejectionCode(wrongActionFieldResult), .invalidPath, "action field is limited to its action section")

    let unknownActionObject = ConfigurationEdit(
        path: ["inserts", "newInsert"],
        operation: .set,
        value: .object(["action": .string("Text"), "openWith": .string("Preview")])
    )
    let unknownActionObjectResult = manager.applyConfigurationEdits([unknownActionObject], expectedRevision: beforeInvalid.revision)
    assertEqual(rejectionCode(unknownActionObjectResult), .unknownKey, "unknown keys in a new action object are rejected")

    let explicitNull = ConfigurationEdit(
        path: ["defaults", "icon"],
        operation: .set,
        value: .null
    )
    let nullWire = try JSONEncoder().encode(explicitNull)
    let decodedNullEdit = try JSONDecoder().decode(ConfigurationEdit.self, from: nullWire)
    guard case .null = decodedNullEdit.value else {
        fail("wire null remains explicit", details: String(decoding: nullWire, as: UTF8.self))
    }
    let nullResult = manager.applyConfigurationEdits([decodedNullEdit], expectedRevision: manager.configurationSnapshot().revision)
    guard case .committed(let nullSnapshot) = nullResult else {
        fail("explicit null edit commits", details: String(describing: rejectionCode(nullResult)))
    }
    assertTrue(nullSnapshot.config.defaults.icon == nil, "explicit null remains nil in the committed model")
    let nullObject = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    let nullDefaults = nullObject?["defaults"] as? [String: Any]
    assertTrue(nullDefaults?["icon"] is NSNull, "explicit null remains null on the wire")

    let omittedSet = try JSONDecoder().decode(
        ConfigurationEdit.self,
        from: Data("{\"path\":[\"defaults\",\"icon\"],\"operation\":\"set\"}".utf8)
    )
    let omittedResult = manager.applyConfigurationEdits([omittedSet], expectedRevision: nullSnapshot.revision)
    assertEqual(rejectionCode(omittedResult), .malformedEdit, "omitted set value is distinct from explicit null")

    // An edit arriving after a disk write but before its watcher event sees the
    // new fingerprint and fails stale instead of overwriting the external edit.
    let staleBase = manager.configurationSnapshot()
    var external = try readConfig(at: path)
    external.defaults.muteNotifications = true
    try write(external, to: path)
    let staleEdit = ConfigurationEdit(
        path: ["defaults", "muteNotifications"],
        operation: .set,
        value: .boolean(false)
    )
    let staleResult = manager.applyConfigurationEdits([staleEdit], expectedRevision: staleBase.revision)
    assertEqual(rejectionCode(staleResult), .staleRevision, "external edit before watcher makes the draft stale")
    assertTrue(manager.config.defaults.muteNotifications, "stale rejection accepts the external runtime value")
    assertTrue(try readConfig(at: path).defaults.muteNotifications, "stale rejection preserves the external file")
    pumpMainQueue()

    // The identity marker must not hide an unrelated edit that arrives before
    // the watcher consumes an internal-write event.
    let markerBase = manager.configurationSnapshot()
    let markerCommit = manager.applyConfigurationEdits(
        [ConfigurationEdit(path: ["defaults", "muteNotifications"], operation: .set, value: .boolean(false))],
        expectedRevision: markerBase.revision
    )
    guard case .committed = markerCommit else { fail("marker transaction commits") }
    var unrelated = try readConfig(at: path)
    unrelated.defaults.muteNotifications = true
    try write(unrelated, to: path)
    let callbackCountBeforeExternalWatcher = callbackReasons.count
    ConfigChangeWatcher.triggerLatest()
    pumpMainQueue()
    assertTrue(manager.config.defaults.muteNotifications, "watcher identity check applies the unrelated external edit")
    assertTrue(callbackReasons.count > callbackCountBeforeExternalWatcher, "unrelated watcher edit publishes a callback")

    let unknownPath = root.appendingPathComponent("unknown.json")
    try write("""
    {
      "configVersion": 2,
      "defaults": { "watch": "/tmp/unknown-watch", "activeAction": "autoPaste", "openWith": "wrong-section" },
      "inserts": { "autoPaste": { "action": "Text" } }
    }
    """, to: unknownPath)
    let unknownManager = ConfigurationManager(configPath: unknownPath.path)
    let unknownSnapshot = unknownManager.configurationSnapshot()
    assertTrue(!unknownSnapshot.diskIsValid, "unknown field makes disk read-only")
    assertTrue(unknownSnapshot.diskIssues.contains { $0.path == "defaults.openWith" }, "snapshot identifies the unknown field")
    let unknownResult = unknownManager.applyConfigurationEdits(
        [ConfigurationEdit(path: ["defaults", "muteNotifications"], operation: .set, value: .boolean(true))],
        expectedRevision: unknownSnapshot.revision
    )
    assertEqual(rejectionCode(unknownResult), .unknownKey, "transaction rejects unknown disk data before re-encoding")

    let invalidPath = root.appendingPathComponent("invalid.json")
    try write("{ invalid json", to: invalidPath)
    let invalidManager = ConfigurationManager(configPath: invalidPath.path)
    let invalidSnapshot = invalidManager.configurationSnapshot()
    assertTrue(!invalidSnapshot.diskIsValid && !invalidSnapshot.diskIssues.isEmpty, "invalid disk snapshot keeps diagnostics")
    let invalidBytesBefore = try Data(contentsOf: invalidPath)
    let invalidDiskResult = invalidManager.applyConfigurationEdits(
        [ConfigurationEdit(path: ["defaults", "muteNotifications"], operation: .set, value: .boolean(true))],
        expectedRevision: invalidSnapshot.revision
    )
    assertEqual(rejectionCode(invalidDiskResult), .invalidDiskState, "invalid disk rejects edits without recovery writes")
    assertEqual(try Data(contentsOf: invalidPath), invalidBytesBefore, "invalid disk bytes remain untouched")

    let duplicatePath = root.appendingPathComponent("duplicate.json")
    try write("""
    {
      "configVersion": 2,
      "defaults": { "watch": "/tmp/duplicate-watch", "activeAction": "same" },
      "inserts": { "same": { "action": "Insert" } },
      "urls": { "same": { "action": "https://example.invalid" } }
    }
    """, to: duplicatePath)
    let duplicateManager = ConfigurationManager(configPath: duplicatePath.path)
    let duplicateSnapshot = duplicateManager.configurationSnapshot()
    let duplicateResult = duplicateManager.applyConfigurationEdits(
        [ConfigurationEdit(path: ["defaults", "muteNotifications"], operation: .set, value: .boolean(true))],
        expectedRevision: duplicateSnapshot.revision
    )
    guard case .rejected(let duplicateError) = duplicateResult else {
        fail("duplicate action configuration is rejected")
    }
    assertEqual(duplicateError.code, .validationFailed, "duplicate action configuration reports validation failure")
    assertEqual(duplicateError.path, ["inserts", "same"], "duplicate action error points to a real action root")

    let cyclePath = root.appendingPathComponent("cycle.json")
    try write("""
    {
      "configVersion": 2,
      "defaults": { "watch": "/tmp/cycle-watch", "activeAction": "first" },
      "inserts": {
        "first": { "action": "First", "nextAction": "second" },
        "second": { "action": "Second", "nextAction": "first" }
      }
    }
    """, to: cyclePath)
    let cycleManager = ConfigurationManager(configPath: cyclePath.path)
    let cycleSnapshot = cycleManager.configurationSnapshot()
    let cycleResult = cycleManager.applyConfigurationEdits(
        [ConfigurationEdit(path: ["defaults", "muteNotifications"], operation: .set, value: .boolean(true))],
        expectedRevision: cycleSnapshot.revision
    )
    guard case .rejected(let cycleError) = cycleResult else {
        fail("cyclic action configuration is rejected")
    }
    assertEqual(cycleError.code, .validationFailed, "cyclic action configuration reports validation failure")
    assertEqual(cycleError.path, ["inserts", "first", "nextAction"], "cycle error points to the real action field")

    let reloadInvalidPath = root.appendingPathComponent("reload-invalid.json")
    try write(validConfigurationJSON, to: reloadInvalidPath)
    let reloadInvalidManager = ConfigurationManager(configPath: reloadInvalidPath.path)
    var reloadInvalidReasons: [String?] = []
    reloadInvalidManager.onConfigChanged = { reloadInvalidReasons.append($0) }
    try Data("{ invalid after startup".utf8).write(to: reloadInvalidPath, options: .atomic)
    let notificationCountBeforeReloadInvalid = testNotifications.count
    assertTrue(!reloadInvalidManager.reloadConfiguration(), "explicit reload rejects external malformed JSON")
    pumpMainQueue()
    let reloadInvalidSnapshot = reloadInvalidManager.configurationSnapshot()
    assertTrue(!reloadInvalidSnapshot.diskIsValid, "explicit reload exposes malformed disk state")
    assertEqual(reloadInvalidReasons.count, 1, "external malformed reload publishes one fallback callback")
    assertEqual(reloadInvalidReasons.first ?? nil, "configValidationFallback", "external malformed reload uses fallback callback reason")
    assertEqual(testNotifications.count, notificationCountBeforeReloadInvalid + 1, "external malformed reload emits the existing notification")

    let watcherInvalidPath = root.appendingPathComponent("watcher-invalid.json")
    try write(validConfigurationJSON, to: watcherInvalidPath)
    let watcherInvalidManager = ConfigurationManager(configPath: watcherInvalidPath.path)
    var watcherInvalidReasons: [String?] = []
    watcherInvalidManager.onConfigChanged = { watcherInvalidReasons.append($0) }
    let watcherNotificationCount = testNotifications.count
    try Data("{ invalid from watcher".utf8).write(to: watcherInvalidPath, options: .atomic)
    ConfigChangeWatcher.triggerLatest()
    pumpMainQueue(for: 0.25)
    let watcherInvalidSnapshot = watcherInvalidManager.configurationSnapshot()
    assertTrue(!watcherInvalidSnapshot.diskIsValid, "watcher exposes malformed external disk state")
    assertEqual(watcherInvalidReasons.count, 1, "watcher malformed edit publishes one fallback callback")
    assertEqual(watcherInvalidReasons.first ?? nil, "configValidationFallback", "watcher malformed edit uses fallback callback reason")
    assertEqual(testNotifications.count, watcherNotificationCount + 1, "watcher malformed edit emits the existing notification")

    let emptyPath = root.appendingPathComponent("empty.json")
    try Data().write(to: emptyPath)
    let emptyManager = ConfigurationManager(configPath: emptyPath.path)
    let emptyBytesBefore = try Data(contentsOf: emptyPath)
    let emptySnapshot = emptyManager.configurationSnapshot()
    assertTrue(!emptySnapshot.diskIsValid, "empty disk snapshot is invalid")
    assertTrue(emptySnapshot.diskIssues.contains { $0.message.contains("empty") }, "empty disk reports its diagnostic")
    assertEqual(try Data(contentsOf: emptyPath), emptyBytesBefore, "empty disk remains untouched")
    let emptyResult = emptyManager.applyConfigurationEdits(
        [ConfigurationEdit(path: ["defaults", "actionDelay"], operation: .set, value: .number(1))],
        expectedRevision: emptySnapshot.revision
    )
    assertEqual(rejectionCode(emptyResult), .invalidDiskState, "empty disk rejects edits")

    let futurePath = root.appendingPathComponent("future.json")
    let futureJSON = validConfigurationJSON.replacingOccurrences(of: "\"configVersion\": 2", with: "\"configVersion\": 999")
    try write(futureJSON, to: futurePath)
    let futureManager = ConfigurationManager(configPath: futurePath.path)
    let futureBytesBefore = try Data(contentsOf: futurePath)
    let futureSnapshot = futureManager.configurationSnapshot()
    assertTrue(!futureSnapshot.diskIsValid, "future-version disk snapshot is read-only")
    assertTrue(futureSnapshot.diskIssues.contains { $0.path == "configVersion" }, "future-version disk reports its diagnostic")
    assertEqual(try Data(contentsOf: futurePath), futureBytesBefore, "future-version disk remains untouched")
    let futureResult = futureManager.applyConfigurationEdits(
        [ConfigurationEdit(path: ["defaults", "actionDelay"], operation: .set, value: .number(1))],
        expectedRevision: futureSnapshot.revision
    )
    assertEqual(rejectionCode(futureResult), .unsupportedVersion, "future-version disk rejects edits")

    // AppConfiguration's established decoder treats null containers like
    // omitted containers. Keep that compatibility behavior for hand-edited
    // files while still validating the typed candidate before a write.
    let nullContainerPath = root.appendingPathComponent("null-containers.json")
    try write("""
    {
      "configVersion": 2,
      "defaults": null,
      "inserts": { "autoPaste": { "action": "Null container" } },
      "urls": null,
      "shortcuts": null,
      "scriptsShell": null,
      "scriptsAS": null
    }
    """, to: nullContainerPath)
    let nullContainerManager = ConfigurationManager(configPath: nullContainerPath.path)
    let nullContainerSnapshot = nullContainerManager.configurationSnapshot()
    assertTrue(nullContainerSnapshot.diskIsValid, "null configuration containers retain omission semantics")
    assertEqual(nullContainerSnapshot.config.defaults.activeAction, "autoPaste", "null defaults container uses the established defaults")
    assertTrue(nullContainerSnapshot.config.urls.isEmpty, "null action container decodes as an empty map")
    let nullContainerResult = nullContainerManager.applyConfigurationEdits(
        [ConfigurationEdit(path: ["defaults", "muteNotifications"], operation: .set, value: .boolean(true))],
        expectedRevision: nullContainerSnapshot.revision
    )
    guard case .committed(let nullContainerCommitted) = nullContainerResult else {
        fail("null container edit preserves decoder semantics", details: String(describing: rejectionCode(nullContainerResult)))
    }
    assertTrue(nullContainerCommitted.config.defaults.muteNotifications, "null container candidate remains editable")

    let legacyPath = root.appendingPathComponent("legacy.json")
    try write("""
    {
      "defaults": { "watch": "/tmp/legacy-watch", "activeAction": "autoPaste" },
      "inserts": { "autoPaste": { "action": "Legacy" } }
    }
    """, to: legacyPath)
    let legacyNotificationCountBeforeStartup = testNotifications.count
    let legacyManager = ConfigurationManager(configPath: legacyPath.path)
    let legacySnapshot = legacyManager.configurationSnapshot()
    assertTrue(legacySnapshot.isLegacyOnDisk, "legacy disk is identified separately from runtime fallback")
    assertEqual(testNotifications.count, legacyNotificationCountBeforeStartup + 1, "legacy startup emits an outdated-config notification")
    assertEqual(testNotifications.last?.title, "Macrowhisper - Outdated Config", "legacy startup notification has the stable title")
    let legacyEditResult = legacyManager.applyConfigurationEdits(
        [ConfigurationEdit(path: ["defaults", "muteNotifications"], operation: .set, value: .boolean(true))],
        expectedRevision: legacySnapshot.revision
    )
    assertEqual(rejectionCode(legacyEditResult), .legacyConfiguration, "editor write to legacy disk is rejected")
    assertTrue(legacyManager.updateConfiguration(), "explicit update command migrates legacy configuration")
    assertTrue(FileManager.default.fileExists(atPath: legacyPath.path + ".backup.pre-v2"), "legacy migration keeps a pre-migration backup")
    assertTrue(FileManager.default.fileExists(atPath: legacyPath.path + ".macrowhisper-backup"), "transaction keeps the latest write snapshot")
    assertEqual(try readConfig(at: legacyPath).configVersion, AppConfiguration.currentConfigVersion, "legacy migration writes current version")

    let activeSwitchPath = root.appendingPathComponent("active-before-switch.json")
    let legacySwitchPath = root.appendingPathComponent("legacy-switch-target.json")
    try write(validConfigurationJSON, to: activeSwitchPath)
    try write("""
    {
      "defaults": { "watch": "/tmp/legacy-switch-watch", "activeAction": "autoPaste" },
      "inserts": { "autoPaste": { "action": "Legacy switch target" } }
    }
    """, to: legacySwitchPath)
    let activeSwitchBytesBefore = try Data(contentsOf: activeSwitchPath)
    let switchManager = ConfigurationManager(configPath: activeSwitchPath.path)
    assertTrue(switchManager.switchConfigPath(to: legacySwitchPath.path), "path switch migrates a legacy target")
    assertTrue(FileManager.default.fileExists(atPath: legacySwitchPath.path + ".backup.pre-v2"), "path switch keeps the target pre-migration backup")
    assertTrue(!FileManager.default.fileExists(atPath: activeSwitchPath.path + ".backup.pre-v2"), "path switch does not back up the previous active file")
    assertEqual(try Data(contentsOf: activeSwitchPath), activeSwitchBytesBefore, "path switch leaves the previous active file untouched")
    assertEqual(try readConfig(at: legacySwitchPath).configVersion, AppConfiguration.currentConfigVersion, "path switch writes the migrated target version")

    let legacyWatcherPath = root.appendingPathComponent("legacy-watcher.json")
    try write(validConfigurationJSON, to: legacyWatcherPath)
    let legacyWatcherManager = ConfigurationManager(configPath: legacyWatcherPath.path)
    _ = legacyWatcherManager.configurationSnapshot()
    let legacyWatcherNotificationCount = testNotifications.count
    try write("""
    {
      "defaults": { "watch": "/tmp/legacy-watcher", "activeAction": "autoPaste" },
      "inserts": { "autoPaste": { "action": "Legacy watcher" } }
    }
    """, to: legacyWatcherPath)
    ConfigChangeWatcher.triggerLatest()
    _ = legacyWatcherManager.configurationSnapshot()
    pumpMainQueue()
    assertEqual(testNotifications.count, legacyWatcherNotificationCount + 1, "external legacy watcher edit emits an outdated-config notification")

    let targetPath = root.appendingPathComponent("target/config.json")
    try FileManager.default.createDirectory(at: targetPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try write(validConfigurationJSON, to: targetPath)
    let linkPath = root.appendingPathComponent("linked.json")
    try FileManager.default.createSymbolicLink(atPath: linkPath.path, withDestinationPath: targetPath.path)
    let linkedManager = ConfigurationManager(configPath: linkPath.path)
    let linkedBase = linkedManager.configurationSnapshot()
    let linkedResult = linkedManager.applyConfigurationEdits(
        [ConfigurationEdit(path: ["defaults", "actionDelay"], operation: .set, value: .number(0.12345))],
        expectedRevision: linkedBase.revision
    )
    guard case .committed = linkedResult else { fail("symlink transaction commits", details: String(describing: rejectionCode(linkedResult))) }
    assertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkPath.path), targetPath.path, "symlink is retained during replacement")
    assertEqual(try readConfig(at: targetPath).defaults.actionDelay, 0.12345, "symlink target receives the committed value")

#if CONFIGURATION_TRANSACTION_TESTING
    // Re-resolving the link after candidate preparation prevents a write from
    // following a target that an external actor selected in the meantime.
    let retargetA = root.appendingPathComponent("retarget-a.json")
    let retargetB = root.appendingPathComponent("retarget-b.json")
    try write(validConfigurationJSON, to: retargetA)
    try write(validConfigurationJSON.replacingOccurrences(of: "Value 1.23456", with: "Retarget B"), to: retargetB)
    let retargetLink = root.appendingPathComponent("retargeted.json")
    try FileManager.default.createSymbolicLink(atPath: retargetLink.path, withDestinationPath: retargetA.path)
    let retargetManager = ConfigurationManager(configPath: retargetLink.path)
    let retargetBase = retargetManager.configurationSnapshot()
    ConfigurationManager.transactionBeforeReplaceHook = {
        try? FileManager.default.removeItem(at: retargetLink)
        try? FileManager.default.createSymbolicLink(atPath: retargetLink.path, withDestinationPath: retargetB.path)
    }
    let retargetResult = retargetManager.applyConfigurationEdits(
        [ConfigurationEdit(path: ["defaults", "actionDelay"], operation: .set, value: .number(9.75))],
        expectedRevision: retargetBase.revision,
        reason: "symlink-retarget-test"
    )
    ConfigurationManager.transactionBeforeReplaceHook = nil
    assertEqual(rejectionCode(retargetResult), .resourceMismatch, "symlink retarget during preparation is rejected")
    assertEqual(try readConfig(at: retargetA).defaults.actionDelay, 0, "retargeted old target remains unchanged")
    assertEqual(try readConfig(at: retargetB).defaults.actionDelay, 0, "retargeted new target remains unchanged")

    // An external atomic writer that wins immediately after replacement must
    // not be hidden by the internal-write marker on the next snapshot.
    let postReplacePath = root.appendingPathComponent("post-replace.json")
    try write(validConfigurationJSON, to: postReplacePath)
    let postReplaceManager = ConfigurationManager(configPath: postReplacePath.path)
    var externalPostReplace = try readConfig(at: postReplacePath)
    externalPostReplace.defaults.muteNotifications = true
    let externalPostReplaceData = try encoded(externalPostReplace)
    let postReplaceBase = postReplaceManager.configurationSnapshot()
    ConfigurationManager.transactionAfterReplaceHook = { targetPath in
        try? externalPostReplaceData.write(to: URL(fileURLWithPath: targetPath), options: .atomic)
    }
    let postReplaceResult = postReplaceManager.applyConfigurationEdits(
        [ConfigurationEdit(path: ["defaults", "actionDelay"], operation: .set, value: .number(4.25))],
        expectedRevision: postReplaceBase.revision,
        reason: "post-replace-test"
    )
    ConfigurationManager.transactionAfterReplaceHook = nil
    guard case .committed = postReplaceResult else {
        fail("post-replace external writer transaction commits", details: String(describing: rejectionCode(postReplaceResult)))
    }
    let postReplaceObserved = postReplaceManager.configurationSnapshot()
    assertTrue(postReplaceObserved.config.defaults.muteNotifications, "post-replace external edit is observed")
    assertEqual(postReplaceObserved.config.defaults.actionDelay, 0, "post-replace external bytes replace the candidate")
#endif

    let pathB = root.appendingPathComponent("second.json")
    try write(validConfigurationJSON.replacingOccurrences(of: "autoPaste", with: "autoPaste"), to: pathB)
    let pathBase = manager.configurationSnapshot()
    let oldGeneration = pathBase.revision.generation
    callbackReasons.removeAll()
    assertTrue(manager.switchConfigPath(to: pathB.path), "valid config path switch commits atomically")
    let switched = manager.configurationSnapshot()
    assertEqual(switched.configPath, pathB.path, "path switch selects the requested path")
    assertTrue(switched.revision.generation != oldGeneration, "path switch changes configuration generation")
    let stalePathResult = manager.applyConfigurationEdits(
        [ConfigurationEdit(path: ["defaults", "actionDelay"], operation: .set, value: .number(8.5))],
        expectedRevision: pathBase.revision,
        reason: "stale-path-test"
    )
    assertEqual(rejectionCode(stalePathResult), .staleRevision, "draft from the previous path generation is stale")
    pumpMainQueue()
    assertTrue(callbackReasons.contains("configPathChanged"), "path switch publishes a callback")

    let watcherBeforeReset = ConfigChangeWatcher.latest
    manager.resetFileWatcher()
    pumpMainQueue(for: 0.7)
    assertTrue(ConfigChangeWatcher.latest !== watcherBeforeReset, "watcher reset installs a fresh watcher")

    let blocker = root.appendingPathComponent("directory-blocker")
    try Data("blocker".utf8).write(to: blocker)
    let failedPath = blocker.appendingPathComponent("config.json")
    let stablePath = manager.getCurrentConfigPath()
    assertTrue(!manager.switchConfigPath(to: failedPath.path), "failed path switch reports a write failure")
    assertEqual(manager.getCurrentConfigPath(), stablePath, "failed path switch leaves the active path unchanged")
}

@main
struct ConfigurationTransactionRegressionRunner {
    static func main() {
        do {
            try runConfigurationTransactionRegressionTests()
        } catch {
            fail("transaction regression setup", details: error.localizedDescription)
        }
    }
}
