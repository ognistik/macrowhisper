import Dispatch
import Foundation

/// Emits bounded, privacy-safe phase markers around runtime work that can
/// otherwise end in an unhelpful Objective-C release crash.
enum RuntimeDiagnostics {
    private static let sequenceLock = NSLock()
    private static var nextPhaseID: UInt64 = 1

    /// Runs `body` inside a local autorelease pool and records three markers:
    /// begin, body-finished (before pool drain), and end (after pool drain).
    ///
    /// If a release crashes while the pool drains, the body-finished marker
    /// remains as the last completed boundary in the log.
    @discardableResult
    static func withPhase<T>(
        _ phase: String,
        recordingPath: String? = nil,
        _ body: () throws -> T
    ) rethrows -> T {
        let phaseID = allocatePhaseID()
        let phaseName = safeToken(phase, maxLength: 80)
        let recordingName = recordingPath.map(recordingBasename) ?? "none"
        let thread = Thread.isMainThread ? "main" : "background"
        let processID = ProcessInfo.processInfo.processIdentifier
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let context = "pid=\(processID) phase_id=\(phaseID) thread=\(thread) phase=\(phaseName) recording=\(recordingName)"

        logDebug("[RuntimeDiagnostics] begin \(context)")

        var outcome = "throw"
        defer {
            let totalDuration = elapsedMilliseconds(since: startedAt)
            logDebug("[RuntimeDiagnostics] end \(context) outcome=\(outcome) duration_ms=\(totalDuration)")
        }

        return try autoreleasepool { () throws -> T in
            defer {
                let bodyDuration = elapsedMilliseconds(since: startedAt)
                logDebug("[RuntimeDiagnostics] body-finished \(context) outcome=\(outcome) duration_ms=\(bodyDuration)")
            }

            let value = try body()
            outcome = "success"
            return value
        }
    }

    private static func allocatePhaseID() -> UInt64 {
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        let phaseID = nextPhaseID
        nextPhaseID &+= 1
        return phaseID
    }

    private static func elapsedMilliseconds(since start: UInt64) -> String {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= start ? now - start : 0
        return String(format: "%.3f", Double(elapsed) / 1_000_000)
    }

    /// Restricts log fields to one short token so caller-provided values cannot
    /// inject new log lines or accidentally include arbitrary path contents.
    private static func safeToken(_ value: String, maxLength: Int) -> String {
        let token = value.unicodeScalars.map { scalar -> Character in
            let value = scalar.value
            if (value >= 48 && value <= 57)
                || (value >= 65 && value <= 90)
                || (value >= 97 && value <= 122)
                || value == 45 || value == 46 || value == 95 {
                return Character(scalar)
            }
            return "_"
        }
        let bounded = String(token.prefix(maxLength))
        return bounded.isEmpty ? "unknown" : bounded
    }

    private static func recordingBasename(_ path: String) -> String {
        let basename = (path as NSString).lastPathComponent
        return safeToken(basename, maxLength: 96)
    }
}
