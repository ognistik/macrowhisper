import ApplicationServices
import Cocoa
import CoreGraphics
import Dispatch
import Foundation

enum PasteDiagnosticChange: String {
    case changed
    case unchanged
    case unavailable
}

enum PasteDiagnosticFocus: String {
    case same
    case changed
    case unavailable
}

enum PasteDiagnosticReason: String {
    case observed
    case noBaseline
    case stale
    case frontAppChanged
    case accessibilityUnavailable
    case focusUnavailable
    case focusChanged
    case secureField
    case secureStatusUnavailable
    case chosenElementDiffers
    case baselineAfterDispatch
    case timeoutUnavailable
    case valueUnavailable
}

struct PasteDiagnosticObservation {
    let change: PasteDiagnosticChange
    let focus: PasteDiagnosticFocus
    let reason: PasteDiagnosticReason
    let frontmostPID: pid_t?
    let frontmostBundleID: String?
    let accessibilityTrusted: Bool?
    let postEventAccessAvailable: Bool?
    let postDispatchFlags: UInt64?

    static func unavailable(
        _ reason: PasteDiagnosticReason,
        frontmostPID: pid_t? = nil,
        frontmostBundleID: String? = nil,
        accessibilityTrusted: Bool? = nil,
        postEventAccessAvailable: Bool? = nil,
        focus: PasteDiagnosticFocus = .unavailable,
        postDispatchFlags: UInt64? = nil
    ) -> PasteDiagnosticObservation {
        PasteDiagnosticObservation(
            change: .unavailable,
            focus: focus,
            reason: reason,
            frontmostPID: frontmostPID,
            frontmostBundleID: frontmostBundleID,
            accessibilityTrusted: accessibilityTrusted,
            postEventAccessAvailable: postEventAccessAvailable,
            postDispatchFlags: postDispatchFlags
        )
    }
}

enum PasteDiagnosticAssessment {
    static func classify(
        focusMatches: Bool?,
        secureField: Bool,
        baselineText: String,
        baselineRange: CFRange,
        currentText: String?,
        currentRange: CFRange?
    ) -> PasteDiagnosticChange {
        guard focusMatches == true, !secureField else { return .unavailable }
        guard currentText != nil || currentRange != nil else { return .unavailable }

        if let currentText, currentText != baselineText { return .changed }
        if let currentRange,
           currentRange.location != baselineRange.location || currentRange.length != baselineRange.length {
            return .changed
        }
        guard currentText != nil, currentRange != nil else { return .unavailable }
        return .unchanged
    }
}

enum PasteDiagnosticSecurityPolicy {
    static func mayReadValue(role: String, subrole: String?, subroleError: AXError) -> Bool {
        let supportedRoles = ["AXComboBox", "AXSearchField", "AXTextArea", "AXTextField"]
        guard supportedRoles.contains(role),
              !role.localizedCaseInsensitiveContains("secure") else {
            return false
        }
        if let subrole {
            return !subrole.localizedCaseInsensitiveContains("secure")
        }
        return role == "AXTextArea" && (subroleError == .attributeUnsupported || subroleError == .noValue)
    }
}

final class PasteDiagnosticAdmission {
    private let semaphore: DispatchSemaphore

    init(capacity: Int) {
        semaphore = DispatchSemaphore(value: max(0, capacity))
    }

    func tryAcquire() -> Bool {
        semaphore.wait(timeout: .now()) == .success
    }

    func release() {
        semaphore.signal()
    }
}

struct PasteDiagnosticBaseline {
    let appPID: pid_t
    let appBundleID: String?
    let element: AXUIElement
    let focusedElement: AXUIElement
    let chosenElementWasFocused: Bool
    let text: String
    let range: CFRange
    let role: String
    let capturedAt: UInt64
}

final class PasteDiagnostics {
    private struct ClipboardWrite {
        let succeeded: Bool
        let changeCount: Int
        let capturedAt: UInt64
    }

    private struct DispatchSnapshot {
        let baseline: PasteDiagnosticBaseline?
        let writes: [ClipboardWrite]
        let postedAt: UInt64
    }

    private final class ObservationCompletion {
        private let lock = NSLock()
        private var remaining = 2
        private let completed: () -> Void

        init(completed: @escaping () -> Void) {
            self.completed = completed
        }

        func finishOne() {
            lock.lock()
            remaining -= 1
            let shouldComplete = remaining == 0
            lock.unlock()
            if shouldComplete { completed() }
        }
    }

    private static let workerQueue = DispatchQueue(label: "com.macrowhisper.paste-diagnostics", qos: .utility, attributes: .concurrent)
    private static let loggingQueue = DispatchQueue(label: "com.macrowhisper.paste-diagnostics-logging", qos: .utility)
    private static let defaultAdmission = PasteDiagnosticAdmission(capacity: 4)
    private static let observationOffsets: [(name: String, nanoseconds: UInt64)] = [
        ("early", 100_000_000),
        ("late", 500_000_000)
    ]
    private static let maximumObservationAge: UInt64 = 3_000_000_000
    private static let axMessagingTimeout: Float = 0.02

    private let attemptID = UUID().uuidString.lowercased()
    private let lock = NSLock()
    private let admission: PasteDiagnosticAdmission
    private let now: () -> UInt64
    private let enqueue: (@escaping () -> Void) -> Void
    private let schedule: (UInt64, @escaping () -> Void) -> Void
    private let probe: (PasteDiagnosticBaseline?, UInt64) -> PasteDiagnosticObservation
    private let emit: (String, Bool) -> Void
    private var baseline: PasteDiagnosticBaseline?
    private var clipboardWrites: [ClipboardWrite] = []
    private var dispatchSnapshotFrozen = false

    init() {
        admission = Self.defaultAdmission
        now = { DispatchTime.now().uptimeNanoseconds }
        enqueue = { work in Self.loggingQueue.async(execute: work) }
        schedule = { delay, work in
            let boundedDelay = Int(clamping: delay)
            Self.workerQueue.asyncAfter(deadline: .now() + .nanoseconds(boundedDelay), execute: work)
        }
        probe = { baseline, postedAt in
            Self.observe(baseline: baseline, postedAt: postedAt)
        }
        emit = { message, warning in
            if warning {
                logWarning(message)
            } else {
                logDebug(message)
            }
        }
    }

    init(
        testAdmission: PasteDiagnosticAdmission,
        testNow: @escaping () -> UInt64,
        testEnqueue: @escaping (@escaping () -> Void) -> Void,
        testSchedule: @escaping (UInt64, @escaping () -> Void) -> Void,
        testProbe: @escaping (PasteDiagnosticBaseline?, UInt64) -> PasteDiagnosticObservation,
        testEmit: @escaping (String, Bool) -> Void
    ) {
        admission = testAdmission
        now = testNow
        enqueue = testEnqueue
        schedule = testSchedule
        probe = testProbe
        emit = testEmit
    }

    func captureContext(
        app: NSRunningApplication,
        element: AXUIElement,
        focusedElement: AXUIElement,
        text: String,
        range: CFRange,
        role: String
    ) {
        lock.lock()
        guard !dispatchSnapshotFrozen else {
            lock.unlock()
            return
        }
        lock.unlock()

        let capturedAt = now()
        let capturedBaseline = PasteDiagnosticBaseline(
            appPID: app.processIdentifier,
            appBundleID: app.bundleIdentifier,
            element: element,
            focusedElement: focusedElement,
            chosenElementWasFocused: CFEqual(element as CFTypeRef, focusedElement as CFTypeRef),
            text: text,
            range: range,
            role: role,
            capturedAt: capturedAt
        )

        lock.lock()
        guard !dispatchSnapshotFrozen else {
            lock.unlock()
            return
        }
        baseline = capturedBaseline
        lock.unlock()
    }

    func recordClipboardWrite(succeeded: Bool, changeCount: Int) {
        let capturedAt = now()
        lock.lock()
        guard !dispatchSnapshotFrozen else {
            lock.unlock()
            return
        }
        if clipboardWrites.count < 4 {
            clipboardWrites.append(ClipboardWrite(
                succeeded: succeeded,
                changeCount: changeCount,
                capturedAt: capturedAt
            ))
        }
        lock.unlock()
    }

    func recordDispatch(
        key: Int,
        flags: CGEventFlags,
        sourceCreated: Bool,
        keyDownCreated: Bool,
        keyUpCreated: Bool,
        postedAt: UInt64
    ) {
        lock.lock()
        guard !dispatchSnapshotFrozen else {
            lock.unlock()
            return
        }
        dispatchSnapshotFrozen = true
        let snapshot = DispatchSnapshot(baseline: baseline, writes: clipboardWrites, postedAt: postedAt)
        lock.unlock()

        if let baseline = snapshot.baseline {
            enqueueLog(phase: "context_captured", timestamp: baseline.capturedAt) { "baseline=available" }
        }
        for write in snapshot.writes {
            enqueueLog(
                phase: "clipboard_write",
                timestamp: write.capturedAt,
                warning: !write.succeeded
            ) { "succeeded=\(write.succeeded) change_count=\(write.changeCount)" }
        }

        enqueueLog(
            phase: "dispatch",
            timestamp: postedAt,
            warning: !keyDownCreated || !keyUpCreated
        ) {
            let baselineTiming: String
            let baselineAge: String
            let baselineCapturedAt: String
            let baselineAppPID: String
            let baselineBundleID: String
            let baselineRole: String
            let baselineRange: String
            if let baseline = snapshot.baseline {
                baselineCapturedAt = String(baseline.capturedAt)
                baselineAppPID = String(baseline.appPID)
                baselineBundleID = baseline.appBundleID.map(Self.safeBundleID) ?? "unknown"
                baselineRole = Self.safeToken(baseline.role)
                baselineRange = "\(baseline.range.location):\(baseline.range.length)"
                if baseline.capturedAt <= postedAt {
                    baselineTiming = "pre_dispatch"
                    baselineAge = String((postedAt - baseline.capturedAt) / 1_000_000)
                } else {
                    baselineTiming = "post_dispatch"
                    baselineAge = "unknown"
                }
            } else {
                baselineTiming = "unavailable"
                baselineAge = "unknown"
                baselineCapturedAt = "unknown"
                baselineAppPID = "unknown"
                baselineBundleID = "unknown"
                baselineRole = "unknown"
                baselineRange = "unknown"
            }

            let writeSummary = snapshot.writes.map {
                "\($0.succeeded):\($0.changeCount):\($0.capturedAt)"
            }.joined(separator: ",")
            return "key=\(key) flags=\(flags.rawValue) source_created=\(sourceCreated) " +
                "key_down_created=\(keyDownCreated) key_up_created=\(keyUpCreated) " +
                "clipboard_writes=\(snapshot.writes.count) clipboard_write_summary=\(writeSummary) " +
                "baseline_timing=\(baselineTiming) baseline_age_ms=\(baselineAge) " +
                "baseline_captured_at_ns=\(baselineCapturedAt) baseline_pid=\(baselineAppPID) " +
                "baseline_bundle=\(baselineBundleID) baseline_role=\(baselineRole) " +
                "baseline_range=\(baselineRange)"
        }

        guard admission.tryAcquire() else {
            enqueueLog(phase: "observation_skipped", timestamp: now()) { "reason=overloaded" }
            clearSnapshotPayload()
            return
        }

        let admission = self.admission
        let completion = ObservationCompletion { [self] in
            admission.release()
            clearSnapshotPayload()
        }
        let dispatchTime = now()
        for offset in Self.observationOffsets {
            let deadline = postedAt.addingReportingOverflow(offset.nanoseconds)
            let delay = deadline.overflow || deadline.partialValue <= dispatchTime
                ? 0
                : deadline.partialValue - dispatchTime
            schedule(delay) { [self] in
                let timestamp = self.now()
                if timestamp >= postedAt,
                   timestamp - postedAt > Self.maximumObservationAge {
                    self.enqueueLog(
                        phase: "observation_skipped",
                        timestamp: timestamp,
                    ) { "sample=\(offset.name) reason=stale" }
                } else {
                    let observation = self.probe(snapshot.baseline, postedAt)
                    self.enqueueLog(
                        phase: "observation",
                        timestamp: timestamp,
                    ) { Self.observationFields(observation, sample: offset.name) }
                }
                completion.finishOne()
            }
        }
    }

    static func recordClipboardFinalization(stage: String, changeCount: Int, delay: TimeInterval? = nil) {
        let capturedAt = DispatchTime.now().uptimeNanoseconds
        loggingQueue.async {
            let eventID = "finalization-\(UUID().uuidString.lowercased())"
            let safeStage = safeToken(stage)
            let delayField: String
            if let delay, delay.isFinite, delay >= 0, delay <= Double(Int.max) / 1_000 {
                delayField = String(Int((delay * 1_000).rounded()))
            } else {
                delayField = "unknown"
            }
            logDebug(
                "[PasteDiagnostic] attempt=\(eventID) phase=clipboard_finalization t_ns=\(capturedAt) " +
                "stage=\(safeStage) change_count=\(changeCount) delay_ms=\(delayField)"
            )
        }
    }

    static func safeToken(_ value: String) -> String {
        guard !value.isEmpty,
              value.utf8.count <= 48,
              value.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
                      .contains($0)
              }) else {
            return "unspecified"
        }
        return value
    }

    private func enqueueLog(
        phase: String,
        timestamp: UInt64,
        warning: Bool = false,
        fields: @escaping () -> String
    ) {
        let attemptID = self.attemptID
        enqueue {
            self.emit("[PasteDiagnostic] attempt=\(attemptID) phase=\(phase) t_ns=\(timestamp) \(fields())", warning)
        }
    }

    private func clearSnapshotPayload() {
        lock.lock()
        baseline = nil
        clipboardWrites.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private static func observationFields(_ observation: PasteDiagnosticObservation, sample: String) -> String {
        let pid = observation.frontmostPID.map(String.init) ?? "unknown"
        let bundleID = observation.frontmostBundleID.map(safeBundleID) ?? "unknown"
        let trusted = observation.accessibilityTrusted.map(String.init) ?? "unknown"
        let postEventAccess = observation.postEventAccessAvailable.map(String.init) ?? "unknown"
        let flags = observation.postDispatchFlags.map(String.init) ?? "unknown"
        return "sample=\(sample) change=\(observation.change.rawValue) focus=\(observation.focus.rawValue) " +
            "reason=\(observation.reason.rawValue) frontmost_pid=\(pid) frontmost_bundle=\(bundleID) " +
            "ax_process_trusted=\(trusted) post_event_access_after_dispatch=\(postEventAccess) " +
            "post_dispatch_flags=\(flags) evidence_only=true"
    }

    private static func safeBundleID(_ value: String) -> String {
        guard !value.isEmpty,
              value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
                      .contains($0)
              }) else {
            return "unknown"
        }
        return value
    }

    private static func observe(
        baseline: PasteDiagnosticBaseline?,
        postedAt: UInt64
    ) -> PasteDiagnosticObservation {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let trusted = AXIsProcessTrusted()
        let postEventAccess = CGPreflightPostEventAccess()
        let postDispatchFlags = CGEventSource.flagsState(.combinedSessionState).rawValue
        let frontmostPID = frontmostApp?.processIdentifier
        let frontmostBundleID = frontmostApp?.bundleIdentifier

        func unavailable(
            _ reason: PasteDiagnosticReason,
            focus: PasteDiagnosticFocus = .unavailable,
            trusted overrideTrusted: Bool? = nil
        ) -> PasteDiagnosticObservation {
            .unavailable(
                reason,
                frontmostPID: frontmostPID,
                frontmostBundleID: frontmostBundleID,
                accessibilityTrusted: overrideTrusted ?? trusted,
                postEventAccessAvailable: postEventAccess,
                focus: focus,
                postDispatchFlags: postDispatchFlags
            )
        }

        guard let baseline else {
            return unavailable(.noBaseline)
        }
        guard baseline.capturedAt <= postedAt else {
            return unavailable(.baselineAfterDispatch)
        }
        guard !baseline.role.localizedCaseInsensitiveContains("secure") else {
            return unavailable(.secureField)
        }
        guard ["AXComboBox", "AXSearchField", "AXTextArea", "AXTextField"].contains(baseline.role) else {
            return unavailable(.valueUnavailable)
        }
        guard trusted else {
            return unavailable(.accessibilityUnavailable, trusted: false)
        }
        guard frontmostPID == baseline.appPID else {
            return unavailable(.frontAppChanged, trusted: true)
        }

        let appElement = AXUIElementCreateApplication(baseline.appPID)
        guard AXUIElementSetMessagingTimeout(appElement, axMessagingTimeout) == .success else {
            return unavailable(.timeoutUnavailable, trusted: true)
        }

        var focusedElementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        ) == .success,
        let focusedElementValue,
        CFGetTypeID(focusedElementValue) == AXUIElementGetTypeID() else {
            return unavailable(.focusUnavailable, trusted: true)
        }

        let focusedElement = unsafeBitCast(focusedElementValue, to: AXUIElement.self)
        guard AXUIElementSetMessagingTimeout(focusedElement, axMessagingTimeout) == .success else {
            return unavailable(.timeoutUnavailable, trusted: true)
        }

        guard CFEqual(focusedElementValue, baseline.focusedElement as CFTypeRef) else {
            return unavailable(.focusChanged, focus: .changed, trusted: true)
        }
        guard baseline.chosenElementWasFocused else {
            return unavailable(.chosenElementDiffers, focus: .same, trusted: true)
        }

        var subroleValue: CFTypeRef?
        let subroleError = AXUIElementCopyAttributeValue(focusedElement, kAXSubroleAttribute as CFString, &subroleValue)
        let subrole = subroleError == .success ? subroleValue as? String : nil
        guard PasteDiagnosticSecurityPolicy.mayReadValue(
            role: baseline.role,
            subrole: subrole,
            subroleError: subroleError
        ) else {
            let reason = subrole?.localizedCaseInsensitiveContains("secure") == true
                ? PasteDiagnosticReason.secureField
                : PasteDiagnosticReason.secureStatusUnavailable
            return unavailable(reason, focus: .same, trusted: true)
        }

        var currentTextValue: CFTypeRef?
        let textError = AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &currentTextValue)
        let currentText = textError == .success ? currentTextValue as? String : nil
        let currentRange = selectedRange(from: focusedElement)
        let change = PasteDiagnosticAssessment.classify(
            focusMatches: true,
            secureField: false,
            baselineText: baseline.text,
            baselineRange: baseline.range,
            currentText: currentText,
            currentRange: currentRange
        )

        return PasteDiagnosticObservation(
            change: change,
            focus: .same,
            reason: change == .unavailable ? .valueUnavailable : .observed,
            frontmostPID: frontmostPID,
            frontmostBundleID: frontmostBundleID,
            accessibilityTrusted: true,
            postEventAccessAvailable: postEventAccess,
            postDispatchFlags: postDispatchFlags
        )
    }

    private static func selectedRange(from element: AXUIElement) -> CFRange? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextRange" as CFString, &rangeValue) == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeBitCast(rangeValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }
}
