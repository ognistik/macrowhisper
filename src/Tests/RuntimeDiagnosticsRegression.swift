import Foundation

private enum RuntimeDiagnosticsLogCapture {
    private static let lock = NSLock()
    private static var storedMessages: [String] = []

    static func append(_ message: String) {
        lock.lock()
        storedMessages.append(message)
        lock.unlock()
    }

    static func takeMessages() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let messages = storedMessages
        storedMessages.removeAll()
        return messages
    }
}

func logDebug(_ message: String) {
    RuntimeDiagnosticsLogCapture.append(message)
}

@main
struct RuntimeDiagnosticsRegression {
    private struct ExpectedError: Error {}

    static func main() {
        testSuccessMarkersAndPrivacy()
        testThrownBodyStillClosesPhase()
        testBackgroundMarker()
        print("Runtime diagnostics regression passed")
    }

    private static func testSuccessMarkersAndPrivacy() {
        let value = RuntimeDiagnostics.withPhase(
            "test.success",
            recordingPath: "/private/user/recordings/meta folder"
        ) {
            "returned"
        }
        assert(value == "returned", "phase wrapper returns the body value")

        let messages = RuntimeDiagnosticsLogCapture.takeMessages()
        assert(messages.count == 3, "success emits begin, body-finished, and end")
        assert(messages[0].contains("[RuntimeDiagnostics] begin "), "first marker is begin")
        assert(messages[1].contains("[RuntimeDiagnostics] body-finished "), "second marker is body-finished")
        assert(messages[2].contains("[RuntimeDiagnostics] end "), "last marker is end")
        assert(messages.allSatisfy { $0.contains("phase=test.success") }, "phase name is included")
        assert(messages.allSatisfy { $0.contains("thread=main") }, "thread class is included")
        assert(messages.allSatisfy { $0.contains("recording=meta_folder") }, "only sanitized basename is included")
        assert(messages.allSatisfy { !$0.contains("/private/user/recordings") }, "full recording path is not logged")
        assert(messages.allSatisfy { $0.contains("duration_ms=") || $0.contains("begin ") }, "completed markers include monotonic duration")
        assert(messages[1].contains("outcome=success"), "successful body outcome is recorded")

        let phaseIDs = Set(messages.compactMap { fieldValue("phase_id", in: $0) })
        assert(phaseIDs.count == 1, "one phase id is shared by all markers")
    }

    private static func testThrownBodyStillClosesPhase() {
        do {
            _ = try RuntimeDiagnostics.withPhase("test.throw") {
                throw ExpectedError()
            }
            assertionFailure("throwing body must rethrow")
        } catch is ExpectedError {
            // Expected: diagnostics must preserve the body's original error.
        } catch {
            assertionFailure("unexpected error type: \(error)")
        }

        let messages = RuntimeDiagnosticsLogCapture.takeMessages()
        assert(messages.count == 3, "throw emits all three markers")
        assert(messages[1].contains("outcome=throw"), "throw outcome is recorded before pool drain")
        assert(messages[2].contains("outcome=throw"), "throw outcome is recorded after pool drain")
    }

    private static func testBackgroundMarker() {
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            RuntimeDiagnostics.withPhase("test.background") {}
            finished.signal()
        }
        assert(finished.wait(timeout: .now() + 5) == .success, "background phase finishes")

        let messages = RuntimeDiagnosticsLogCapture.takeMessages()
        assert(messages.count == 3, "background phase emits three markers")
        assert(messages.allSatisfy { $0.contains("thread=background") }, "background thread is labeled")
    }

    private static func fieldValue(_ field: String, in message: String) -> String? {
        for component in message.split(separator: " ") {
            let parts = component.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == Substring(field) {
                return String(parts[1])
            }
        }
        return nil
    }
}
