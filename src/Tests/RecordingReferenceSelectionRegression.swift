import Foundation

struct RegressionDefaults {
    let watch: String
}

struct RegressionConfiguration {
    let defaults: RegressionDefaults
}

final class ConfigurationManager {
    let config: RegressionConfiguration

    init(watch: String = "/tmp") {
        config = RegressionConfiguration(defaults: RegressionDefaults(watch: watch))
    }
}

final class RecordingsFolderWatcher {
    var activePath: String?

    init(activePath: String? = nil) {
        self.activePath = activePath
    }

    func getMostRecentActiveRecordingPath() -> String? {
        activePath
    }
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    guard actual == expected else {
        fputs("FAIL: \(label)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func candidate(
    _ path: String,
    languageModelName: String,
    result: String,
    llmResult: String? = nil
) -> (path: String, metaJson: [String: Any]) {
    var metaJson: [String: Any] = [
        "languageModelName": languageModelName,
        "result": result
    ]
    if let llmResult {
        metaJson["llmResult"] = llmResult
    }
    return (path: path, metaJson: metaJson)
}

private func runRecordingReferenceSelectionRegressionTests() {
    let fallback = selectLatestValidRecordingReference(from: [
        candidate("/recordings/newest", languageModelName: "OSS", result: "Raw result"),
        candidate("/recordings/older", languageModelName: "", result: "Older result")
    ])
    assertEqual(fallback.reference?.path, "/recordings/older", "older valid recording is selected")
    assertEqual(fallback.skippedNewerRecordings.count, 1, "completed newer recording missing llmResult is reported")
    assertEqual(fallback.skippedNewerRecordings.first?.path, "/recordings/newest", "reported recording is the skipped newer recording")
    assertEqual(fallback.skippedNewerRecordings.first?.languageModelName, "OSS", "reported recording includes its language model")
    assertEqual(
        latestRecordingFallbackWarningMessage(for: fallback, requestDescription: "exec-action 'swResult'"),
        "[MetaSource] exec-action 'swResult' skipped 1 newer completed recording still waiting for llmResult: newest [OSS]; using older recording older",
        "fallback warning identifies the command, skipped recording, model, and selected recording"
    )

    let activeDictation = selectLatestValidRecordingReference(from: [
        candidate("/recordings/active", languageModelName: "OSS", result: ""),
        candidate("/recordings/older", languageModelName: "", result: "Older result")
    ])
    assertEqual(activeDictation.reference?.path, "/recordings/older", "older valid recording remains selectable during an active dictation")
    assertEqual(activeDictation.skippedNewerRecordings.count, 0, "active dictation without raw result does not produce a fallback warning candidate")
    assertEqual(latestRecordingFallbackWarningMessage(for: activeDictation, requestDescription: "run-auto"), nil, "active dictation does not produce a fallback warning")

    let completedLLM = selectLatestValidRecordingReference(from: [
        candidate("/recordings/newest", languageModelName: "OSS", result: "Raw result", llmResult: "Clean result"),
        candidate("/recordings/older", languageModelName: "", result: "Older result")
    ])
    assertEqual(completedLLM.reference?.path, "/recordings/newest", "completed LLM result is selected")
    assertEqual(completedLLM.skippedNewerRecordings.count, 0, "completed LLM result is not reported as skipped")
    assertEqual(latestRecordingFallbackWarningMessage(for: completedLLM, requestDescription: "run-auto"), nil, "latest valid LLM result does not produce a fallback warning")

    let multipleFailures = selectLatestValidRecordingReference(from: [
        candidate("/recordings/newest", languageModelName: "OSS", result: "First raw result", llmResult: ""),
        candidate("/recordings/newer", languageModelName: "Gemini", result: "Second raw result"),
        candidate("/recordings/older", languageModelName: "", result: "Older result")
    ])
    assertEqual(multipleFailures.reference?.path, "/recordings/older", "selection continues past multiple missing LLM results")
    assertEqual(multipleFailures.skippedNewerRecordings.map(\.path), ["/recordings/newest", "/recordings/newer"], "all skipped newer completed recordings are reported in order")
    assertEqual(
        latestRecordingFallbackWarningMessage(for: multipleFailures, requestDescription: "run-auto"),
        "[MetaSource] run-auto skipped 2 newer completed recordings still waiting for llmResult: newest [OSS], newer [Gemini]; using older recording older",
        "multiple skipped recordings produce one summarized warning"
    )

    let noFallback = selectLatestValidRecordingReference(from: [
        candidate("/recordings/newest", languageModelName: "OSS", result: "Raw result")
    ])
    assertEqual(noFallback.reference?.path, nil, "missing LLM result remains invalid when no older result exists")
    assertEqual(latestRecordingFallbackWarningMessage(for: noFallback, requestDescription: "run-auto"), nil, "no warning is produced when no older recording is selected")

    let malformedLLMResult = selectLatestValidRecordingReference(from: [
        (
            path: "/recordings/malformed",
            metaJson: [
                "languageModelName": "OSS",
                "result": "Raw result",
                "llmResult": ["unexpected": true]
            ]
        ),
        candidate("/recordings/older", languageModelName: "", result: "Older result")
    ])
    assertEqual(malformedLLMResult.reference?.path, "/recordings/older", "malformed llmResult remains invalid")
    assertEqual(malformedLLMResult.skippedNewerRecordings.count, 0, "malformed llmResult is not misreported as missing")
    assertEqual(latestRecordingFallbackWarningMessage(for: malformedLLMResult, requestDescription: "run-auto"), nil, "malformed llmResult does not produce a waiting warning")

    let nonLLM = selectLatestValidRecordingReference(from: [
        candidate("/recordings/newest", languageModelName: "", result: "Raw result"),
        candidate("/recordings/older", languageModelName: "", result: "Older result")
    ])
    assertEqual(nonLLM.reference?.path, "/recordings/newest", "non-LLM raw result remains immediately valid")
    assertEqual(nonLLM.skippedNewerRecordings.count, 0, "non-LLM recording is not reported as skipped")

    var meeting = candidate("/recordings/meeting", languageModelName: "", result: "Meeting notes")
    meeting.metaJson["kind"] = "meeting"
    assertEqual(isMeetingRecordingMetaJson(meeting.metaJson), true, "meeting kind is recognized")
    assertEqual(isValidRecordingMetaJson(meeting.metaJson), true, "explicit meeting metadata remains valid for manual CLI use")

    let meetingFallback = selectLatestValidRecordingReference(from: [
        meeting,
        candidate("/recordings/dictation", languageModelName: "", result: "Dictation")
    ])
    assertEqual(meetingFallback.reference?.path, "/recordings/dictation", "implicit latest selection skips meetings")
    assertEqual(meetingFallback.skippedNewerRecordings.count, 0, "meetings are not reported as pending LLM results")

    var incompleteMeeting = candidate("/recordings/incomplete-meeting", languageModelName: "OSS", result: "Raw notes")
    incompleteMeeting.metaJson["kind"] = " Meeting \n"
    let incompleteMeetingFallback = selectLatestValidRecordingReference(from: [
        incompleteMeeting,
        candidate("/recordings/dictation", languageModelName: "", result: "Dictation")
    ])
    assertEqual(incompleteMeetingFallback.reference?.path, "/recordings/dictation", "incomplete meetings are skipped")
    assertEqual(incompleteMeetingFallback.skippedNewerRecordings.count, 0, "incomplete meetings produce no LLM warning")

    var otherKind = candidate("/recordings/other", languageModelName: "", result: "Other result")
    otherKind.metaJson["kind"] = "other"
    assertEqual(isMeetingRecordingMetaJson(otherKind.metaJson), false, "other kinds remain eligible")
    assertEqual(isMeetingRecordingMetaJson(candidate("/recordings/legacy", languageModelName: "", result: "Legacy").metaJson), false, "missing kind remains eligible")
    assertEqual(
        selectLatestValidRecordingReference(from: [otherKind, meeting]).reference?.path,
        "/recordings/other",
        "other kinds retain normal selection"
    )

    var meetingModeDictation = candidate("/recordings/meeting-mode-dictation", languageModelName: "", result: "Dictation")
    meetingModeDictation.metaJson["kind"] = "dictation"
    meetingModeDictation.metaJson["modeName"] = "Meeting"
    assertEqual(isMeetingRecordingMetaJson(meetingModeDictation.metaJson), false, "mode name does not determine recording kind")

    let root = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("macrowhisper-recording-selection-\(UUID().uuidString)")
    let recordingsPath = (root as NSString).appendingPathComponent("recordings")
    let meetingPath = (recordingsPath as NSString).appendingPathComponent("meeting")
    let dictationPath = (recordingsPath as NSString).appendingPathComponent("dictation")
    defer { try? FileManager.default.removeItem(atPath: root) }
    do {
        try FileManager.default.createDirectory(atPath: meetingPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dictationPath, withIntermediateDirectories: true)
        let meetingData = try JSONSerialization.data(withJSONObject: meeting.metaJson)
        let dictationData = try JSONSerialization.data(withJSONObject: meetingModeDictation.metaJson)
        try meetingData.write(to: URL(fileURLWithPath: (meetingPath as NSString).appendingPathComponent("meta.json")))
        try dictationData.write(to: URL(fileURLWithPath: (dictationPath as NSString).appendingPathComponent("meta.json")))
    } catch {
        fputs("FAIL: could not create recording fixtures: \(error)\n", stderr)
        exit(1)
    }

    let manager = ConfigurationManager(watch: root)
    let watcher = RecordingsFolderWatcher(activePath: meetingPath)
    assertEqual(
        resolveRecordingFolderPath(configManager: manager, recordingsWatcher: watcher, index: 0)
            .map { ($0 as NSString).lastPathComponent },
        "dictation",
        "folder lookup skips active and completed meetings"
    )
    assertEqual(
        resolveRecordingFolderPath(configManager: manager, recordingsWatcher: watcher, index: 1),
        nil,
        "meeting does not occupy a folder index"
    )
    assertEqual(
        getValidRecordingReferences(configManager: manager).map { ($0.path as NSString).lastPathComponent },
        ["dictation"],
        "valid recording list excludes meetings"
    )
}

@main
struct RecordingReferenceSelectionRegressionRunner {
    static func main() {
        runRecordingReferenceSelectionRegressionTests()
    }
}
