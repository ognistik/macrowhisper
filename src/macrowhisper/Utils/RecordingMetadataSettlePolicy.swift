import Foundation

enum RecordingMetadataSettlePolicy {
    /// S1-Language and S1-Voice share an integrated server pipeline that can publish
    /// llmResult shortly before the source transcript reaches result.
    static let integratedS1ResultGraceSeconds: TimeInterval = 1.0

    static func shouldAwaitIntegratedS1Result(in metaJson: [String: Any]) -> Bool {
        guard metaJson["languageModelKey"] as? String == "sl-1",
              metaJson["modelKey"] as? String == "sv-1",
              let llmResult = metaJson["llmResult"] as? String,
              !llmResult.isEmpty else {
            return false
        }

        let result = metaJson["result"] as? String ?? ""
        return result.isEmpty
    }
}
