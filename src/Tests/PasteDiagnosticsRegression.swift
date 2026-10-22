import ApplicationServices
import Cocoa
import CoreGraphics
import Foundation

func logDebug(_ message: String) {}
func logWarning(_ message: String) {}

@main
struct PasteDiagnosticsRegression {
    private final class TestState {
        private let lock = NSLock()
        private var time: UInt64 = 1_000_000_000
        private var pendingLogs: [() -> Void] = []
        private var scheduled: [(UInt64, () -> Void)] = []
        private(set) var emitted: [(String, Bool)] = []

        func now() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return time
        }

        func setNow(_ value: UInt64) {
            lock.lock()
            time = value
            lock.unlock()
        }

        func enqueue(_ work: @escaping () -> Void) {
            lock.lock()
            pendingLogs.append(work)
            lock.unlock()
        }

        func schedule(_ delay: UInt64, _ work: @escaping () -> Void) {
            lock.lock()
            scheduled.append((delay, work))
            lock.unlock()
        }

        func runScheduled(_ index: Int, at time: UInt64) {
            lock.lock()
            let work = scheduled[index].1
            lock.unlock()
            setNow(time)
            work()
        }

        func scheduledDelays() -> [UInt64] {
            lock.lock()
            defer { lock.unlock() }
            return scheduled.map(\.0)
        }

        func drainLogs() {
            while true {
                lock.lock()
                guard !pendingLogs.isEmpty else {
                    lock.unlock()
                    return
                }
                let work = pendingLogs.removeFirst()
                lock.unlock()
                work()
            }
        }

        func record(_ message: String, warning: Bool) {
            lock.lock()
            emitted.append((message, warning))
            lock.unlock()
        }

        func messages() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return emitted.map(\.0)
        }

        func warningMessages() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return emitted.filter(\.1).map(\.0)
        }
    }

    static func main() {
        testAssessment()
        testSecureFieldPolicy()
        testAsyncSchedulingWithoutBaseline()
        testSafeContextAndLifetime()
        testBoundedAdmissionAndFailureWarnings()
        testSafeTokens()
        print("Paste diagnostics regression passed")
    }

    private static func testAssessment() {
        let range = CFRange(location: 4, length: 0)
        assert(
            PasteDiagnosticAssessment.classify(
                focusMatches: true,
                secureField: false,
                baselineText: "before",
                baselineRange: range,
                currentText: "after",
                currentRange: range
            ) == .changed,
            "changed value is supporting evidence"
        )
        assert(
            PasteDiagnosticAssessment.classify(
                focusMatches: true,
                secureField: false,
                baselineText: "same",
                baselineRange: range,
                currentText: "same",
                currentRange: range
            ) == .unchanged,
            "matching value and selection are unchanged"
        )
        assert(
            PasteDiagnosticAssessment.classify(
                focusMatches: false,
                secureField: false,
                baselineText: "secret",
                baselineRange: range,
                currentText: "different",
                currentRange: CFRange(location: 9, length: 0)
            ) == .unavailable,
            "changed focus prevents a field comparison"
        )
        assert(
            PasteDiagnosticAssessment.classify(
                focusMatches: true,
                secureField: true,
                baselineText: "secret",
                baselineRange: range,
                currentText: "different",
                currentRange: CFRange(location: 9, length: 0)
            ) == .unavailable,
            "secure fields are never classified from their value"
        )
        assert(
            PasteDiagnosticAssessment.classify(
                focusMatches: true,
                secureField: false,
                baselineText: "same",
                baselineRange: range,
                currentText: nil,
                currentRange: nil
            ) == .unavailable,
            "missing observations remain unavailable"
        )
    }

    private static func testSecureFieldPolicy() {
        assert(
            PasteDiagnosticSecurityPolicy.mayReadValue(
                role: "AXTextArea",
                subrole: nil,
                subroleError: .attributeUnsupported
            ),
            "text areas remain observable when subroles are unsupported"
        )
        assert(
            PasteDiagnosticSecurityPolicy.mayReadValue(
                role: "AXTextArea",
                subrole: nil,
                subroleError: .noValue
            ),
            "text areas remain observable when subroles have no value"
        )
        assert(
            !PasteDiagnosticSecurityPolicy.mayReadValue(
                role: "AXTextField",
                subrole: nil,
                subroleError: .attributeUnsupported
            ),
            "fields without secure status are skipped"
        )
        assert(
            !PasteDiagnosticSecurityPolicy.mayReadValue(
                role: "AXTextField",
                subrole: "AXSecureTextField",
                subroleError: .success
            ),
            "explicit secure subroles are skipped"
        )
        assert(
            !PasteDiagnosticSecurityPolicy.mayReadValue(
                role: "AXWebArea",
                subrole: "AXTextInput",
                subroleError: .success
            ),
            "unknown roles are skipped"
        )
    }

    private static func testAsyncSchedulingWithoutBaseline() {
        let state = TestState()
        let diagnostics = makeDiagnostics(state: state, admission: PasteDiagnosticAdmission(capacity: 1))
        diagnostics.recordDispatch(
            key: 9,
            flags: .maskCommand,
            sourceCreated: true,
            keyDownCreated: true,
            keyUpCreated: true,
            postedAt: state.now()
        )

        assert(state.scheduledDelays() == [100_000_000, 500_000_000], "observations are scheduled at bounded offsets")
        assert(state.messages().isEmpty, "diagnostic emission waits for the injected background queue")

        state.runScheduled(0, at: 1_100_000_000)
        state.runScheduled(1, at: 1_500_000_000)
        state.drainLogs()

        let messages = state.messages()
        assert(messages.count == 3, "dispatch and both observations are emitted")
        assert(messages.allSatisfy { $0.contains("[PasteDiagnostic] attempt=") && $0.contains("t_ns=") }, "every phase has an attempt id and monotonic timestamp")
        assert(messages.contains { $0.contains("reason=noBaseline") }, "missing baseline is explicit")
        assert(messages.contains { $0.contains("post_dispatch_flags=") && $0.contains("post_event_access_after_dispatch=") && $0.contains("evidence_only=true") }, "permission and modifier samples are labeled as post-dispatch")
        assert(!messages.joined(separator: "\n").contains("https://"), "diagnostic logs contain no URLs")
    }

    private static func testBoundedAdmissionAndFailureWarnings() {
        let state = TestState()
        let admission = PasteDiagnosticAdmission(capacity: 1)
        let first = makeDiagnostics(state: state, admission: admission)
        let second = makeDiagnostics(state: state, admission: admission)

        first.recordDispatch(
            key: 9,
            flags: .maskCommand,
            sourceCreated: true,
            keyDownCreated: true,
            keyUpCreated: true,
            postedAt: state.now()
        )
        second.recordClipboardWrite(succeeded: false, changeCount: 21)
        second.recordDispatch(
            key: 9,
            flags: .maskCommand,
            sourceCreated: false,
            keyDownCreated: false,
            keyUpCreated: false,
            postedAt: state.now()
        )

        assert(state.scheduledDelays().count == 2, "overload skips scheduling additional probes")
        state.drainLogs()
        assert(state.warningMessages().contains { $0.contains("phase=clipboard_write") }, "clipboard write failure is warned asynchronously")
        assert(state.warningMessages().contains { $0.contains("phase=dispatch") && $0.contains("key_down_created=false") }, "missing key events are warned asynchronously")
        assert(state.messages().contains { $0.contains("reason=overloaded") }, "overload is observable")

        state.runScheduled(0, at: 1_100_000_000)
        state.runScheduled(1, at: 1_500_000_000)
        state.drainLogs()
        let third = makeDiagnostics(state: state, admission: admission)
        third.recordDispatch(
            key: 9,
            flags: .maskCommand,
            sourceCreated: true,
            keyDownCreated: true,
            keyUpCreated: true,
            postedAt: state.now()
        )
        assert(state.scheduledDelays().count == 4, "admission is released after both samples")
    }

    private static func testSafeContextAndLifetime() {
        let state = TestState()
        let admission = PasteDiagnosticAdmission(capacity: 1)
        var probeCount = 0
        var diagnostics: PasteDiagnostics? = PasteDiagnostics(
            testAdmission: admission,
            testNow: { state.now() },
            testEnqueue: { state.enqueue($0) },
            testSchedule: { state.schedule($0, $1) },
            testProbe: { baseline, _ in
                probeCount += 1
                return PasteDiagnosticObservation.unavailable(
                    baseline == nil ? .noBaseline : .observed,
                    frontmostPID: 42,
                    frontmostBundleID: "org.example.editor",
            accessibilityTrusted: true,
            postEventAccessAvailable: true
                )
            },
            testEmit: { state.record($0, warning: $1) }
        )
        let fakeElement = AXUIElementCreateApplication(getpid())
        diagnostics?.captureContext(
            app: NSRunningApplication.current,
            element: fakeElement,
            focusedElement: fakeElement,
            text: "private dictation https://private.example/path",
            range: CFRange(location: 0, length: 0),
            role: "AXTextField"
        )
        state.setNow(1_025_000_000)
        diagnostics?.captureContext(
            app: NSRunningApplication.current,
            element: fakeElement,
            focusedElement: fakeElement,
            text: "latest private dictation https://latest.example/path",
            range: CFRange(location: 1, length: 0),
            role: "AXTextArea"
        )
        diagnostics?.recordClipboardWrite(succeeded: false, changeCount: 30)
        state.drainLogs()
        assert(state.messages().isEmpty, "context and clipboard facts are not logged before dispatch")
        diagnostics?.recordDispatch(
            key: 9,
            flags: .maskCommand,
            sourceCreated: true,
            keyDownCreated: true,
            keyUpCreated: true,
            postedAt: state.now()
        )
        diagnostics = nil

        state.runScheduled(0, at: 1_125_000_000)
        state.runScheduled(1, at: 1_525_000_000)
        state.drainLogs()

        assert(probeCount == 2, "scheduled probes retain diagnostics after the caller releases it")
        let messages = state.messages().joined(separator: "\n")
        assert(messages.contains("baseline_timing=pre_dispatch baseline_age_ms=0"), "latest baseline capture time is compared with dispatch")
        assert(messages.contains("baseline_pid=\(NSRunningApplication.current.processIdentifier)"), "dispatch records the original target PID")
        assert(messages.contains("baseline_range=1:0"), "dispatch records the selected range without field content")
        assert(!messages.contains("private dictation") && !messages.contains("private.example"), "field text and URLs never enter logs")
        assert(!messages.contains("latest.example"), "replacement baselines also keep their contents out of logs")
        assert(messages.contains("phase=clipboard_write") && messages.contains("change_count=30"), "clipboard write diagnostics emit after dispatch")

        let next = makeDiagnostics(state: state, admission: admission)
        next.recordDispatch(
            key: 9,
            flags: .maskCommand,
            sourceCreated: true,
            keyDownCreated: true,
            keyUpCreated: true,
            postedAt: state.now()
        )
        assert(state.scheduledDelays().count == 4, "the admission slot is reclaimed after both samples")
    }

    private static func testSafeTokens() {
        assert(PasteDiagnostics.safeToken("restore_finished") == "restore_finished", "safe stage labels remain useful")
        assert(PasteDiagnostics.safeToken("https://example.com/private") == "unspecified", "URL stages are excluded")
        assert(PasteDiagnostics.safeToken("dictation secret") == "unspecified", "free text stages are excluded")
    }

    private static func makeDiagnostics(state: TestState, admission: PasteDiagnosticAdmission) -> PasteDiagnostics {
        PasteDiagnostics(
            testAdmission: admission,
            testNow: { state.now() },
            testEnqueue: { state.enqueue($0) },
            testSchedule: { state.schedule($0, $1) },
            testProbe: { baseline, _ in
                PasteDiagnosticObservation.unavailable(
                    baseline == nil ? .noBaseline : .observed,
                    frontmostPID: 42,
                    frontmostBundleID: "org.example.editor",
                    accessibilityTrusted: true,
                    postEventAccessAvailable: true,
                    postDispatchFlags: 1
                )
            },
            testEmit: { state.record($0, warning: $1) }
        )
    }

    private static func assert(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
        print("PASS: \(message)")
    }
}
