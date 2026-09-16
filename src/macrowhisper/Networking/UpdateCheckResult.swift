import Foundation

struct UpdateCheckResult: Codable, Equatable {
    enum Status: String, Codable {
        case upToDate
        case updateAvailable
        case failed
    }

    let status: Status
    let currentVersion: String
    let latestVersion: String?
    let failureReason: String?

    var succeeded: Bool {
        status != .failed
    }

    var cliExitCode: Int32 {
        succeeded ? 0 : 1
    }

    var userMessage: String {
        switch status {
        case .upToDate:
            return "Macrowhisper v\(currentVersion) is up to date."
        case .updateAvailable:
            let availableVersion = latestVersion ?? "unknown"
            return "Update available: v\(currentVersion) → v\(availableVersion). The release dialog is opening."
        case .failed:
            let reason = failureReason ?? "unknown error"
            return "Couldn't check for updates: \(reason)\nFor more details, see ~/Library/Logs/Macrowhisper/macrowhisper.log."
        }
    }

    static func upToDate(currentVersion: String, latestVersion: String) -> UpdateCheckResult {
        UpdateCheckResult(
            status: .upToDate,
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            failureReason: nil
        )
    }

    static func updateAvailable(currentVersion: String, latestVersion: String) -> UpdateCheckResult {
        UpdateCheckResult(
            status: .updateAvailable,
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            failureReason: nil
        )
    }

    static func failed(currentVersion: String, reason: String) -> UpdateCheckResult {
        UpdateCheckResult(
            status: .failed,
            currentVersion: currentVersion,
            latestVersion: nil,
            failureReason: reason
        )
    }

    func socketPayload() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func fromSocketPayload(_ payload: String) -> UpdateCheckResult? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(UpdateCheckResult.self, from: data)
    }
}

struct UpdateCheckEvaluation: Equatable {
    let result: UpdateCheckResult
    let releaseDescription: String
}

enum UpdateCheckEvaluator {
    static func evaluate(data: Data, currentVersion: String) -> UpdateCheckEvaluation {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return failure(currentVersion: currentVersion, reason: "the update server returned invalid data")
        }

        guard let latestVersion = json["version"] as? String else {
            return failure(currentVersion: currentVersion, reason: "the update server response is missing a version")
        }

        guard let latestComponents = versionComponents(latestVersion) else {
            return failure(currentVersion: currentVersion, reason: "the update server returned an invalid version")
        }

        guard let currentComponents = versionComponents(currentVersion) else {
            return failure(currentVersion: currentVersion, reason: "the installed version is invalid")
        }

        let description = json["description"] as? String ?? ""
        let result: UpdateCheckResult
        if isNewerVersion(latestComponents: latestComponents, currentComponents: currentComponents) {
            result = .updateAvailable(currentVersion: currentVersion, latestVersion: latestVersion)
        } else {
            result = .upToDate(currentVersion: currentVersion, latestVersion: latestVersion)
        }

        return UpdateCheckEvaluation(result: result, releaseDescription: description)
    }

    private static func failure(currentVersion: String, reason: String) -> UpdateCheckEvaluation {
        UpdateCheckEvaluation(
            result: .failed(currentVersion: currentVersion, reason: reason),
            releaseDescription: ""
        )
    }

    private static func versionComponents(_ version: String) -> [Int]? {
        let rawComponents = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !rawComponents.isEmpty else { return nil }

        let components = rawComponents.compactMap { component -> Int? in
            guard !component.isEmpty, component.allSatisfy(\.isNumber) else { return nil }
            return Int(component)
        }
        return components.count == rawComponents.count ? components : nil
    }

    private static func isNewerVersion(latestComponents: [Int], currentComponents: [Int]) -> Bool {
        let maxCount = max(latestComponents.count, currentComponents.count)
        for index in 0..<maxCount {
            let latestPart = index < latestComponents.count ? latestComponents[index] : 0
            let currentPart = index < currentComponents.count ? currentComponents[index] : 0
            if latestPart != currentPart {
                return latestPart > currentPart
            }
        }
        return false
    }
}
