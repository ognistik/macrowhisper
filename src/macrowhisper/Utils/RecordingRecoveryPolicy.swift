import Foundation

func hasCompletedRawTranscription(_ metaJson: [String: Any]) -> Bool {
    let result = (metaJson["result"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !result.isEmpty else {
        return false
    }

    if let duration = metaJson["duration"] as? NSNumber {
        return duration.doubleValue > 0
    }
    if let duration = metaJson["duration"] as? Double {
        return duration > 0
    }
    if let duration = metaJson["duration"] as? Int {
        return duration > 0
    }
    return false
}

func shouldStartLLMResultTimeout(_ metaJson: [String: Any]) -> Bool {
    let languageModelName = (metaJson["languageModelName"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !languageModelName.isEmpty, hasCompletedRawTranscription(metaJson) else {
        return false
    }

    let llmResult = (metaJson["llmResult"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return llmResult.isEmpty
}
