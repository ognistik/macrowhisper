import Cocoa
import Dispatch
import Foundation

private struct NativePasteboardSnapshot {
    let changeCount: Int
    let typeNames: [String]
    let text: String?
    let marker: String?
    let usesSamePasteboard: Bool
}

private struct ClipboardTransactionObservation {
    let startingCount: Int
    let writeCount: Int
    let textWriteSucceeded: Bool
    let markerWriteSucceeded: Bool
    let snapshot: NativePasteboardSnapshot
    let expectedText: String
    let expectedMarker: String
    let expectedMarkerType: String
}

private func expectedMarkerTypeName(for token: String) -> String? {
    let components = token.components(separatedBy: "-")
    guard components.count >= 4,
          components[0] == "worker",
          let worker = Int(components[1]),
          components[2] == "iteration",
          let iteration = Int(components[3]) else {
        return nil
    }
    return "com.macrowhisper.clipboard-access-regression.\(worker).\(iteration)"
}

private func productionSnapshotIncoherence(
    _ snapshot: ClipboardPasteboardSnapshot,
    writeCountsByToken: [String: Int]
) -> String? {
    guard let content = snapshot.content else { return "content is missing" }
    guard snapshot.payload.semanticText == content else { return "payload text differs from snapshot content" }
    guard let expectedMarkerType = expectedMarkerTypeName(for: content) else {
        return "content does not identify a write transaction"
    }

    let observedTypes = Set(snapshot.types.map(\.rawValue))
    let allowedTextTypes = Set([
        NSPasteboard.PasteboardType.string.rawValue,
        NSPasteboard.PasteboardType("NSStringPboardType").rawValue
    ])
    guard observedTypes.contains(NSPasteboard.PasteboardType.string.rawValue) else {
        return "text flavor is missing"
    }
    guard observedTypes.contains(expectedMarkerType) else {
        return "marker flavor does not match snapshot content"
    }
    guard observedTypes.isSubset(of: allowedTextTypes.union([expectedMarkerType])) else {
        return "snapshot contains a stale or unrelated flavor"
    }
    guard let expectedChangeCount = writeCountsByToken[content] else {
        return "snapshot content has no matching write transaction"
    }
    guard snapshot.changeCount == expectedChangeCount else {
        return "snapshot change count does not match its text and type transaction"
    }
    return nil
}

private final class AutoreleaseDrainProbe: NSObject {
    private let onDeinit: () -> Void

    init(onDeinit: @escaping () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit()
    }
}

private final class LockedFlag {
    private let lock = NSLock()
    private var storedValue = false

    func set(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

private func failClipboardAccessRegression(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

private func assertClipboardAccess(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { failClipboardAccessRegression(message) }
    print("PASS: \(message)")
}

private func testConcurrentNativeTransactions(on pasteboard: NSPasteboard) {
    let workerCount = 8
    let iterationsPerWorker = 35
    let workerQueue = DispatchQueue(
        label: "macrowhisper.clipboard-access-regression.workers.\(UUID().uuidString)",
        attributes: .concurrent
    )
    let ready = DispatchGroup()
    let completed = DispatchGroup()
    let writersCompleted = DispatchGroup()
    let startGate = DispatchSemaphore(value: 0)
    let firstPartialWriteReached = DispatchSemaphore(value: 0)
    let readerAttemptingCapture = DispatchSemaphore(value: 0)
    let resultLock = NSLock()
    var observations: [ClipboardTransactionObservation] = []
    var productionSnapshots: [ClipboardPasteboardSnapshot] = []
    var writeCountsByToken: [String: Int] = [:]
    var failures: [String] = []
    var productionSnapshotFailures: [String] = []

    let baselineToken = "worker-99-iteration-99-\(UUID().uuidString)"
    let baselineMarkerType = NSPasteboard.PasteboardType(
        "com.macrowhisper.clipboard-access-regression.99.99"
    )
    let baselineWrite = ClipboardAccess.withPasteboard(pasteboard) { board in
        board.clearContents()
        let textSucceeded = board.setString(baselineToken, forType: .string)
        let markerSucceeded = board.setString(baselineToken, forType: baselineMarkerType)
        return (textSucceeded, markerSucceeded, board.changeCount)
    }
    guard baselineWrite.0 && baselineWrite.1 else {
        failClipboardAccessRegression("could not initialize the private pasteboard baseline")
    }
    writeCountsByToken[baselineToken] = baselineWrite.2

    for worker in 0..<workerCount {
        ready.enter()
        completed.enter()
        writersCompleted.enter()
        workerQueue.async {
            ready.leave()
            guard startGate.wait(timeout: .now() + 10) == .success else {
                resultLock.lock()
                failures.append("worker \(worker) did not receive the start signal")
                resultLock.unlock()
                writersCompleted.leave()
                completed.leave()
                return
            }

            var workerObservations: [ClipboardTransactionObservation] = []
            var workerWriteCounts: [String: Int] = [:]
            workerObservations.reserveCapacity(iterationsPerWorker)

            for iteration in 0..<iterationsPerWorker {
                let token = "worker-\(worker)-iteration-\(iteration)-\(UUID().uuidString)"
                let marker = "flavor-\(token)"
                let markerType = NSPasteboard.PasteboardType(
                    "com.macrowhisper.clipboard-access-regression.\(worker).\(iteration)"
                )

                let observation = ClipboardAccess.withPasteboard(pasteboard) { board in
                    let startingCount = board.changeCount
                    board.clearContents()
                    if worker == 0 && iteration == 0 {
                        firstPartialWriteReached.signal()
                        if readerAttemptingCapture.wait(timeout: .now() + 3) != .success {
                            resultLock.lock()
                            failures.append("production snapshot reader did not reach the partial-write handshake")
                            resultLock.unlock()
                        }
                        // If the production snapshot path drops its lock, the
                        // reader gets a deterministic chance to observe this
                        // intentionally incomplete board state.
                        Thread.sleep(forTimeInterval: 0.025)
                    }
                    Thread.sleep(forTimeInterval: 0.0005)
                    let textWriteSucceeded = board.setString(token, forType: .string)
                    Thread.sleep(forTimeInterval: 0.0005)
                    let markerWriteSucceeded = board.setString(marker, forType: markerType)
                    let writeCount = board.changeCount

                    // Give competing workers time to attempt entry while the
                    // transaction still owns the process-wide clipboard lock.
                    Thread.sleep(forTimeInterval: 0.0005)

                    let snapshot = ClipboardAccess.withPasteboard(board) { nestedBoard in
                        NativePasteboardSnapshot(
                            changeCount: nestedBoard.changeCount,
                            typeNames: (nestedBoard.types ?? []).map(\.rawValue),
                            text: nestedBoard.string(forType: .string),
                            marker: nestedBoard.string(forType: markerType),
                            usesSamePasteboard: ObjectIdentifier(nestedBoard) == ObjectIdentifier(board)
                        )
                    }

                    return ClipboardTransactionObservation(
                        startingCount: startingCount,
                        writeCount: writeCount,
                        textWriteSucceeded: textWriteSucceeded,
                        markerWriteSucceeded: markerWriteSucceeded,
                        snapshot: snapshot,
                        expectedText: token,
                        expectedMarker: marker,
                        expectedMarkerType: markerType.rawValue
                    )
                }

                workerObservations.append(observation)
                workerWriteCounts[token] = observation.writeCount
            }

            resultLock.lock()
            observations.append(contentsOf: workerObservations)
            writeCountsByToken.merge(workerWriteCounts) { _, latest in latest }
            resultLock.unlock()
            writersCompleted.leave()
            completed.leave()
        }
    }

    ready.enter()
    completed.enter()
    workerQueue.async {
        ready.leave()
        guard startGate.wait(timeout: .now() + 10) == .success else {
            resultLock.lock()
            productionSnapshotFailures.append("production snapshot reader did not receive the start signal")
            resultLock.unlock()
            completed.leave()
            return
        }

        var readerSnapshots: [ClipboardPasteboardSnapshot] = []
        if firstPartialWriteReached.wait(timeout: .now() + 5) == .success {
            readerAttemptingCapture.signal()
        } else {
            resultLock.lock()
            productionSnapshotFailures.append("no writer exposed the partial-transaction handshake")
            resultLock.unlock()
        }

        while writersCompleted.wait(timeout: .now()) == .timedOut {
            if let snapshot = captureClipboardPasteboardSnapshot(
                from: pasteboard,
                source: "clipboard-access-concurrency-regression"
            ) {
                readerSnapshots.append(snapshot)
            } else {
                resultLock.lock()
                productionSnapshotFailures.append("production snapshot returned nil during concurrent writes")
                resultLock.unlock()
            }
            Thread.sleep(forTimeInterval: 0.00025)
        }

        if let finalSnapshot = captureClipboardPasteboardSnapshot(
            from: pasteboard,
            source: "clipboard-access-concurrency-regression-final"
        ) {
            readerSnapshots.append(finalSnapshot)
        } else {
            resultLock.lock()
            productionSnapshotFailures.append("production snapshot returned nil after concurrent writes")
            resultLock.unlock()
        }

        resultLock.lock()
        productionSnapshots.append(contentsOf: readerSnapshots)
        resultLock.unlock()
        completed.leave()
    }

    guard ready.wait(timeout: .now() + 5) == .success else {
        failClipboardAccessRegression("concurrent workers did not become ready within 5 seconds")
    }
    for _ in 0...workerCount { startGate.signal() }

    guard completed.wait(timeout: .now() + 20) == .success else {
        failClipboardAccessRegression("native clipboard transactions exceeded the 20-second timeout")
    }

    resultLock.lock()
    let transactionFailures = failures
    let transactionObservations = observations
    let snapshotFailures = productionSnapshotFailures
    let snapshots = productionSnapshots
    let transactionWriteCounts = writeCountsByToken
    resultLock.unlock()

    assertClipboardAccess(
        transactionFailures.isEmpty,
        "all concurrent workers entered the bounded transaction runner"
    )
    assertClipboardAccess(
        transactionObservations.count == workerCount * iterationsPerWorker,
        "all native clipboard transactions completed"
    )
    assertClipboardAccess(
        snapshotFailures.isEmpty && !snapshots.isEmpty,
        "production clipboard snapshots complete during and after concurrent writes"
    )

    let invalidObservation = transactionObservations.first { observation in
        let actualTypes = Set(observation.snapshot.typeNames)
        let allowedTextTypes = Set([
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType("NSStringPboardType").rawValue
        ])
        return !observation.textWriteSucceeded
            || !observation.markerWriteSucceeded
            || observation.writeCount <= observation.startingCount
            || observation.snapshot.changeCount != observation.writeCount
            || observation.snapshot.text != observation.expectedText
            || observation.snapshot.marker != observation.expectedMarker
            || !actualTypes.contains(observation.expectedMarkerType)
            || !actualTypes.contains(NSPasteboard.PasteboardType.string.rawValue)
            || !actualTypes.isSubset(of: allowedTextTypes.union([observation.expectedMarkerType]))
            || !observation.snapshot.usesSamePasteboard
    }
    assertClipboardAccess(
        invalidObservation == nil,
        "each transaction snapshots its own text, type set, and stable change count"
    )

    let distinctWriteCounts = Set(transactionObservations.map(\.writeCount))
    assertClipboardAccess(
        distinctWriteCounts.count == transactionObservations.count,
        "each serialized write transaction advances to a distinct pasteboard change count"
    )

    let firstInvalidProductionSnapshot = snapshots.first { snapshot in
        productionSnapshotIncoherence(snapshot, writeCountsByToken: transactionWriteCounts) != nil
    }
    if let firstInvalidProductionSnapshot,
       let reason = productionSnapshotIncoherence(
           firstInvalidProductionSnapshot,
           writeCountsByToken: transactionWriteCounts
       ) {
        fputs(
            "FAIL: production clipboard snapshot is incoherent: \(reason) " +
                "changeCount=\(firstInvalidProductionSnapshot.changeCount) " +
                "types=\(firstInvalidProductionSnapshot.types.map(\.rawValue))\n",
            stderr
        )
        exit(1)
    }
    assertClipboardAccess(
        firstInvalidProductionSnapshot == nil,
        "production snapshots keep payload, text, marker type, and change count coherent"
    )
}

private func testAutoreleaseDrainStaysInsideLock(on pasteboard: NSPasteboard) {
    let competitorQueue = DispatchQueue(
        label: "macrowhisper.clipboard-access-regression.cleanup-competitor.\(UUID().uuidString)"
    )
    let competitorStarted = DispatchSemaphore(value: 0)
    let competitorEntered = DispatchSemaphore(value: 0)
    let probeDrained = DispatchSemaphore(value: 0)
    let competitorEnteredDuringDrain = LockedFlag()

    let probeWasDrainedByWrapper = autoreleasepool { () -> Bool in
        ClipboardAccess.withPasteboard(pasteboard) { _ in
            competitorQueue.async {
                competitorStarted.signal()
                _ = ClipboardAccess.withPasteboard(pasteboard) { _ in
                    competitorEntered.signal()
                }
            }

            guard competitorStarted.wait(timeout: .now() + 3) == .success else {
                failClipboardAccessRegression("cleanup competitor did not start within 3 seconds")
            }

            // Let the competitor reach the wrapper while this thread still
            // holds its outer transaction lock.
            Thread.sleep(forTimeInterval: 0.02)

            _ = Unmanaged.passRetained(AutoreleaseDrainProbe {
                let enteredBeforePoolDrainCompleted =
                    competitorEntered.wait(timeout: .now() + 0.2) == .success
                competitorEnteredDuringDrain.set(enteredBeforePoolDrainCompleted)
                probeDrained.signal()
            }).autorelease()
        }

        return probeDrained.wait(timeout: .now() + 1) == .success
    }

    assertClipboardAccess(
        probeWasDrainedByWrapper,
        "temporary Objective-C objects drain before the pasteboard transaction returns"
    )
    assertClipboardAccess(
        !competitorEnteredDuringDrain.value,
        "the process-wide lock remains held while the local autorelease pool drains"
    )
    assertClipboardAccess(
        competitorEntered.wait(timeout: .now() + 2) == .success,
        "a competing clipboard transaction proceeds after cleanup releases the lock"
    )
}

@main
private struct ClipboardAccessConcurrencyRegression {
    static func main() {
        let transactionPasteboard = NSPasteboard(
            name: NSPasteboard.Name("com.macrowhisper.clipboard-access-regression.transactions.\(UUID().uuidString)")
        )
        let cleanupPasteboard = NSPasteboard(
            name: NSPasteboard.Name("com.macrowhisper.clipboard-access-regression.cleanup.\(UUID().uuidString)")
        )

        testConcurrentNativeTransactions(on: transactionPasteboard)
        testAutoreleaseDrainStaysInsideLock(on: cleanupPasteboard)
    }
}
