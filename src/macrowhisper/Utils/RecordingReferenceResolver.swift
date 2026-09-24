import Foundation

struct ValidRecordingReference {
    let path: String
    let metaJson: [String: Any]
}

struct SkippedRecordingAwaitingLLMResult {
    let path: String
    let languageModelName: String
}

struct LatestValidRecordingResolution {
    let reference: ValidRecordingReference?
    let skippedNewerRecordings: [SkippedRecordingAwaitingLLMResult]
}

private func getSortedRecordingDirectories(configManager: ConfigurationManager?) -> [URL] {
    guard let configManager = configManager else { return [] }

    let expandedWatchPath = (configManager.config.defaults.watch as NSString).expandingTildeInPath
    let recordingsPath = expandedWatchPath + "/recordings"

    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: recordingsPath),
        includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
        options: .skipsHiddenFiles
    ) else {
        return []
    }

    return contents
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
        .sorted {
            let date1 = try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate
            let date2 = try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate
            return (date1 ?? .distantPast) > (date2 ?? .distantPast)
        }
}

/// Superwhisper meetings are not dictations. Other and missing kinds keep the
/// existing recording behavior for compatibility with older metadata.
func isMeetingRecordingMetaJson(_ json: [String: Any]) -> Bool {
    guard let kind = json["kind"] as? String else { return false }
    return kind.trimmingCharacters(in: .whitespacesAndNewlines)
        .caseInsensitiveCompare("meeting") == .orderedSame
}

private func isMeetingRecording(at directoryPath: String) -> Bool {
    let metaJsonPath = (directoryPath as NSString).appendingPathComponent("meta.json")
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: metaJsonPath)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return false
    }
    return isMeetingRecordingMetaJson(json)
}

/// Validates whether a recording meta.json contains a usable transcription result.
/// If `languageModelName` is present/non-empty, `llmResult` must be non-empty.
/// Otherwise, `result` must be non-empty.
func isValidRecordingMetaJson(_ json: [String: Any]) -> Bool {
    if let languageModelName = json["languageModelName"] as? String,
       !languageModelName.isEmpty {
        guard let llmResult = json["llmResult"], !(llmResult is NSNull) else {
            return false
        }
        guard let llmResultString = llmResult as? String, !llmResultString.isEmpty else {
            return false
        }
        return true
    }

    guard let result = json["result"], !(result is NSNull) else {
        return false
    }
    guard let resultString = result as? String, !resultString.isEmpty else {
        return false
    }
    return true
}

private func missingExpectedLLMResult(in json: [String: Any]) -> String? {
    let languageModelName = (json["languageModelName"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !languageModelName.isEmpty else {
        return nil
    }

    let result = (json["result"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !result.isEmpty else {
        return nil
    }

    guard let llmResult = json["llmResult"] else {
        return languageModelName
    }
    if llmResult is NSNull {
        return languageModelName
    }
    guard let llmResultString = llmResult as? String else {
        return nil
    }
    return llmResultString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? languageModelName
        : nil
}

func selectLatestValidRecordingReference(
    from candidates: [(path: String, metaJson: [String: Any])]
) -> LatestValidRecordingResolution {
    var skippedNewerRecordings: [SkippedRecordingAwaitingLLMResult] = []

    for candidate in candidates {
        if isMeetingRecordingMetaJson(candidate.metaJson) {
            continue
        }

        if isValidRecordingMetaJson(candidate.metaJson) {
            return LatestValidRecordingResolution(
                reference: ValidRecordingReference(path: candidate.path, metaJson: candidate.metaJson),
                skippedNewerRecordings: skippedNewerRecordings
            )
        }

        if let languageModelName = missingExpectedLLMResult(in: candidate.metaJson) {
            skippedNewerRecordings.append(
                SkippedRecordingAwaitingLLMResult(
                    path: candidate.path,
                    languageModelName: languageModelName
                )
            )
        }
    }

    return LatestValidRecordingResolution(
        reference: nil,
        skippedNewerRecordings: skippedNewerRecordings
    )
}

func latestRecordingFallbackWarningMessage(
    for resolution: LatestValidRecordingResolution,
    requestDescription: String
) -> String? {
    guard let selectedRecording = resolution.reference,
          !resolution.skippedNewerRecordings.isEmpty else {
        return nil
    }

    let skippedSummary = resolution.skippedNewerRecordings.map { skipped in
        let folderName = (skipped.path as NSString).lastPathComponent
        return "\(folderName) [\(skipped.languageModelName)]"
    }.joined(separator: ", ")
    let selectedFolderName = (selectedRecording.path as NSString).lastPathComponent
    let recordingLabel = resolution.skippedNewerRecordings.count == 1 ? "recording" : "recordings"

    return "[MetaSource] \(requestDescription) skipped \(resolution.skippedNewerRecordings.count) newer completed " +
        "\(recordingLabel) still waiting for llmResult: \(skippedSummary); using older recording " +
        "\(selectedFolderName)"
}

/// Returns all valid recording directories sorted from newest to oldest.
func getValidRecordingReferences(configManager: ConfigurationManager?) -> [ValidRecordingReference] {
    var validReferences: [ValidRecordingReference] = []
    for directory in getSortedRecordingDirectories(configManager: configManager) {
        let metaJsonPath = directory.appendingPathComponent("meta.json").path
        guard FileManager.default.fileExists(atPath: metaJsonPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: metaJsonPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !isMeetingRecordingMetaJson(json),
              isValidRecordingMetaJson(json) else {
            continue
        }

        validReferences.append(ValidRecordingReference(path: directory.path, metaJson: json))
    }

    return validReferences
}

/// Returns only the latest valid recording reference.
/// This is optimized for commands that only need the most recent valid result.
func getLatestValidRecordingReference(configManager: ConfigurationManager?) -> ValidRecordingReference? {
    getLatestValidRecordingResolution(configManager: configManager).reference
}

/// Resolves the latest valid recording and reports any newer completed raw
/// transcriptions that are still missing an expected LLM result.
func getLatestValidRecordingResolution(configManager: ConfigurationManager?) -> LatestValidRecordingResolution {
    var candidates: [(path: String, metaJson: [String: Any])] = []

    for directory in getSortedRecordingDirectories(configManager: configManager) {
        let metaJsonPath = directory.appendingPathComponent("meta.json").path
        guard FileManager.default.fileExists(atPath: metaJsonPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: metaJsonPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            continue
        }

        if isMeetingRecordingMetaJson(json) {
            continue
        }

        candidates.append((path: directory.path, metaJson: json))
        if isValidRecordingMetaJson(json) {
            return selectLatestValidRecordingReference(from: candidates)
        }
    }

    return selectLatestValidRecordingReference(from: candidates)
}

/// Resolves a recording folder path by index.
/// Ordering: most recent active recording session first (if available), then valid completed recordings.
func resolveRecordingFolderPath(
    configManager: ConfigurationManager?,
    recordingsWatcher: RecordingsFolderWatcher?,
    index: Int
) -> String? {
    guard index >= 0 else { return nil }

    var seen: Set<String> = []
    var currentIndex = 0

    if let activePath = recordingsWatcher?.getMostRecentActiveRecordingPath(),
       FileManager.default.fileExists(atPath: activePath),
       !isMeetingRecording(at: activePath) {
        seen.insert(activePath)
        if index == 0 {
            return activePath
        }
        currentIndex += 1
    }

    for directory in getSortedRecordingDirectories(configManager: configManager) {
        let path = directory.path
        if seen.contains(path) { continue }

        let metaJsonPath = directory.appendingPathComponent("meta.json").path
        guard FileManager.default.fileExists(atPath: metaJsonPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: metaJsonPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !isMeetingRecordingMetaJson(json),
              isValidRecordingMetaJson(json) else {
            continue
        }

        if currentIndex == index {
            return path
        }
        currentIndex += 1
        seen.insert(path)
    }

    return nil
}
