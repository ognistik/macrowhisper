import CoreFoundation
import Foundation

enum RecordingMetadataSettlePolicy {
    /// S1-Language and S1-Voice share an integrated server pipeline that can publish
    /// llmResult shortly before the source transcript reaches result.
    static let integratedS1ResultGraceSeconds: TimeInterval = 1.0

    /// Superwhisper 3.4.0 metadata can contain interim voice-only results.
    /// The completed recording supplies roundTripTime.
    static func shouldAwaitRealtimeFinalResult(in metaJson: [String: Any]) -> Bool {
        guard (metaJson["languageModelName"] as? String ?? "").isEmpty,
              let realtime = metaJson["realtimeEnabled"] as? NSNumber,
              CFGetTypeID(realtime) == CFBooleanGetTypeID(),
              realtime.boolValue,
              let version = metaJson["appVersion"] as? String else {
            return false
        }

        // Earlier versions can have Realtime enabled without ever writing roundTripTime.
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = UInt(components[0]),
              let minor = UInt(components[1]),
              UInt(components[2]) != nil,
              major > 3 || (major == 3 && minor >= 4) else {
            return false
        }

        guard let roundTripTime = metaJson["roundTripTime"] as? NSNumber else {
            return true
        }
        return CFGetTypeID(roundTripTime) == CFBooleanGetTypeID()
    }

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
