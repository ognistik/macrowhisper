import Foundation

private func assertTrue(_ condition: Bool, _ label: String) {
    if !condition {
        fputs("FAIL: \(label)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual != expected {
        fputs("FAIL: \(label)\nexpected: \(expected)\nactual:   \(actual)\n", stderr)
        exit(1)
    }
    print("PASS: \(label)")
}

private func assertSocketRoundTrip(_ result: UpdateCheckResult, _ label: String) {
    guard let payload = result.socketPayload() else {
        fputs("FAIL: \(label) payload encoding\n", stderr)
        exit(1)
    }
    guard let decoded = UpdateCheckResult.fromSocketPayload(payload) else {
        fputs("FAIL: \(label) payload decoding\n", stderr)
        exit(1)
    }
    assertEqual(decoded, result, "\(label) socket round trip")
}

private func evaluate(_ json: String, currentVersion: String = "2.2.0") -> UpdateCheckEvaluation {
    UpdateCheckEvaluator.evaluate(data: Data(json.utf8), currentVersion: currentVersion)
}

private func runUpdateCheckResultRegressionTests() {
    let upToDate = UpdateCheckResult.upToDate(currentVersion: "2.2.0", latestVersion: "2.2.0")
    assertEqual(upToDate.status, .upToDate, "up-to-date status")
    assertTrue(upToDate.succeeded, "up-to-date result succeeds")
    assertEqual(upToDate.cliExitCode, 0, "up-to-date result exits successfully")
    assertEqual(upToDate.userMessage, "Macrowhisper v2.2.0 is up to date.", "up-to-date message is self-contained")
    assertTrue(!upToDate.userMessage.contains("Logs"), "up-to-date message does not direct users to logs")
    assertSocketRoundTrip(upToDate, "up-to-date result")

    let updateAvailable = UpdateCheckResult.updateAvailable(currentVersion: "2.2.0", latestVersion: "2.3.0")
    assertEqual(updateAvailable.status, .updateAvailable, "update-available status")
    assertTrue(updateAvailable.succeeded, "update-available result succeeds")
    assertEqual(updateAvailable.cliExitCode, 0, "update-available result exits successfully")
    assertTrue(updateAvailable.userMessage.contains("v2.2.0 → v2.3.0"), "update-available message includes both versions")
    assertTrue(updateAvailable.userMessage.contains("release dialog"), "update-available message explains the dialog")
    assertSocketRoundTrip(updateAvailable, "update-available result")

    let failed = UpdateCheckResult.failed(currentVersion: "2.2.0", reason: "network unavailable")
    assertEqual(failed.status, .failed, "failure status")
    assertTrue(!failed.succeeded, "failure result does not succeed")
    assertEqual(failed.cliExitCode, 1, "failure result exits nonzero")
    assertTrue(failed.userMessage.contains("network unavailable"), "failure message includes the reason")
    assertTrue(
        failed.userMessage.contains("~/Library/Logs/Macrowhisper/macrowhisper.log"),
        "failure message includes the exact diagnostic log path"
    )
    assertSocketRoundTrip(failed, "failure result")

    assertTrue(UpdateCheckResult.fromSocketPayload("not json") == nil, "invalid socket payload is rejected")

    let currentManifest = evaluate(#"{"version":"2.2.0","description":"Current release"}"#)
    assertEqual(currentManifest.result.status, .upToDate, "current manifest resolves as up to date")
    assertEqual(currentManifest.releaseDescription, "Current release", "manifest description is preserved")

    let newerManifest = evaluate(#"{"version":"2.3.0","description":"New release"}"#)
    assertEqual(newerManifest.result.status, .updateAvailable, "newer manifest resolves as update available")
    assertEqual(newerManifest.result.latestVersion, "2.3.0", "newer manifest preserves latest version")

    let olderManifest = evaluate(#"{"version":"2.1.9"}"#)
    assertEqual(olderManifest.result.status, .upToDate, "older manifest does not report an update")

    let missingVersion = evaluate(#"{"description":"No version"}"#)
    assertEqual(missingVersion.result.status, .failed, "missing manifest version fails")
    assertTrue(
        missingVersion.result.failureReason?.contains("missing a version") == true,
        "missing manifest version explains the failure"
    )

    let malformedVersion = evaluate(#"{"version":"2.2.bad"}"#)
    assertEqual(malformedVersion.result.status, .failed, "malformed manifest version fails")

    let malformedJSON = evaluate("not json")
    assertEqual(malformedJSON.result.status, .failed, "malformed manifest JSON fails")
}

@main
struct UpdateCheckResultRegressionRunner {
    static func main() {
        runUpdateCheckResultRegressionTests()
    }
}
