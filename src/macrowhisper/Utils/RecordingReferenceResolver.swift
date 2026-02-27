import Foundation

struct ValidRecordingReference {
    let path: String
    let metaJson: [String: Any]
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

/// Returns all valid recording directories sorted from newest to oldest.
func getValidRecordingReferences(configManager: ConfigurationManager?) -> [ValidRecordingReference] {
    var validReferences: [ValidRecordingReference] = []
    for directory in getSortedRecordingDirectories(configManager: configManager) {
        let metaJsonPath = directory.appendingPathComponent("meta.json").path
        guard FileManager.default.fileExists(atPath: metaJsonPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: metaJsonPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
    for directory in getSortedRecordingDirectories(configManager: configManager) {
        let metaJsonPath = directory.appendingPathComponent("meta.json").path
        guard FileManager.default.fileExists(atPath: metaJsonPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: metaJsonPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              isValidRecordingMetaJson(json) else {
            continue
        }

        return ValidRecordingReference(path: directory.path, metaJson: json)
    }
    return nil
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
       FileManager.default.fileExists(atPath: activePath) {
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
