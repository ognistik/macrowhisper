import Foundation
import Darwin

@main
struct LoggerConcurrencyRegression {
    private static let workerCount = 8
    private static let threadRecordsPerWorker = 500
    private static let processRecordsPerWorker = 1_000
    private static let logLevel = Logger.LogLevel.info

    static func main() {
        if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "--process-child" {
            runProcessChild(
                directory: CommandLine.arguments[2],
                worker: Int(CommandLine.arguments[3])!,
                recordCount: Int(CommandLine.arguments[4])!,
                readyDirectory: CommandLine.arguments[5]
            )
            return
        }

        let concurrencyOnly = CommandLine.arguments.contains("--concurrency-only")
        let processOnly = CommandLine.arguments.contains("--process-only")
        suppressConsoleLogging = true
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrowhisper-logger-regression-\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryRoot) }

            if !processOnly {
                testThreadWriters(in: temporaryRoot.appendingPathComponent("threads"), prepareFile: concurrencyOnly)
            }
            testProcessWriters(
                in: temporaryRoot.appendingPathComponent("processes"),
                prepareFile: concurrencyOnly || processOnly
            )

            if !concurrencyOnly && !processOnly {
                testConcurrentInitialCreation(in: temporaryRoot.appendingPathComponent("initial-creation"))
                testRotationAndRetention(in: temporaryRoot.appendingPathComponent("rotation"))
                testProcessWritersAcrossRotation(in: temporaryRoot.appendingPathComponent("process-rotation"))
            }
            print("Logger concurrency regression passed")
        } catch {
            fail("Regression setup failed: \(error)")
        }
    }

    private static func testThreadWriters(in directoryURL: URL, prepareFile: Bool) {
        createDirectory(directoryURL)
        let logPath = directoryURL.appendingPathComponent("macrowhisper.log").path
        if prepareFile { createEmptyLog(at: logPath) }

        let startGate = DispatchSemaphore(value: 0)
        let readyGate = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let sharedLogger = Logger(logDirectory: directoryURL.path)

        for worker in 0..<workerCount {
            finished.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let logger = worker < workerCount / 2
                    ? sharedLogger
                    : Logger(logDirectory: directoryURL.path)
                readyGate.signal()
                startGate.wait()
                for sequence in 0..<threadRecordsPerWorker {
                    logger.log(threadMessage(worker: worker, sequence: sequence), level: logLevel)
                }
                finished.leave()
            }
        }

        waitForSignals(readyGate, count: workerCount, description: "thread writers to initialize")
        for _ in 0..<workerCount { startGate.signal() }
        finished.wait()

        if !FileManager.default.fileExists(atPath: logPath) {
            fail("Thread writers did not create the active log")
        }
        let expected = (0..<workerCount).flatMap { worker in
            (0..<threadRecordsPerWorker).map { threadMessage(worker: worker, sequence: $0) }
        }
        verifyMessages(at: [URL(fileURLWithPath: logPath)], expected: expected, context: "concurrent logger instances on threads")
    }

    private static func testProcessWriters(in directoryURL: URL, prepareFile: Bool) {
        createDirectory(directoryURL)
        let logPath = directoryURL.appendingPathComponent("macrowhisper.log").path
        if prepareFile { createEmptyLog(at: logPath) }
        runProcessWriters(in: directoryURL, logPath: logPath)

        let expected = (0..<workerCount).flatMap { worker in
            (0..<processRecordsPerWorker).map { processMessage(worker: worker, sequence: $0) }
        }
        verifyMessages(at: [URL(fileURLWithPath: logPath)], expected: expected, context: "simultaneous subprocess writers")
    }

    private static func runProcessWriters(in directoryURL: URL, logPath: String) {
        let readyDirectory = directoryURL.appendingPathComponent("ready")
        createDirectory(readyDirectory)
        let gatePath = directoryURL.appendingPathComponent("go").path
        let executablePath = resolvedExecutablePath()
        var processes: [Process] = []

        for worker in 0..<workerCount {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = [
                "--process-child",
                directoryURL.path,
                String(worker),
                String(processRecordsPerWorker),
                readyDirectory.path
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                for running in processes where running.isRunning { running.terminate() }
                fail("Could not launch process writer \(worker): \(error)")
            }
            processes.append(process)
        }

        let readyDeadline = Date().addingTimeInterval(60)
        while !allReady(in: readyDirectory, count: workerCount) {
            if Date() >= readyDeadline {
                for process in processes where process.isRunning { process.terminate() }
                fail("Subprocess writers did not reach the shared start barrier")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        if !FileManager.default.fileExists(atPath: logPath) {
            for process in processes where process.isRunning { process.terminate() }
            fail("Concurrent Logger initialization did not create the active log")
        }

        do {
            try Data("go".utf8).write(to: URL(fileURLWithPath: gatePath), options: .atomic)
        } catch {
            for process in processes where process.isRunning { process.terminate() }
            fail("Could not release subprocess writers: \(error)")
        }

        let completionDeadline = Date().addingTimeInterval(90)
        while processes.contains(where: { $0.isRunning }) {
            if Date() >= completionDeadline {
                for process in processes where process.isRunning { process.terminate() }
                fail("Subprocess writers timed out; logger coordination may be deadlocked")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        for (worker, process) in processes.enumerated() {
            if process.terminationStatus != 0 {
                fail("Subprocess writer \(worker) exited with status \(process.terminationStatus)")
            }
        }

    }

    private static func testProcessWritersAcrossRotation(in directoryURL: URL) {
        createDirectory(directoryURL)
        let logPath = directoryURL.appendingPathComponent("macrowhisper.log").path
        let rotationHeadroom = 450_000
        createNewlineLog(at: logPath, size: (5 * 1024 * 1024) - rotationHeadroom)
        runProcessWriters(in: directoryURL, logPath: logPath)

        let backups = backupLogURLs(in: directoryURL)
        if backups.count != 1 {
            fail("Concurrent writes across the size threshold should create exactly one backup")
        }
        let expected = (0..<workerCount).flatMap { worker in
            (0..<processRecordsPerWorker).map { processMessage(worker: worker, sequence: $0) }
        }
        verifyMessages(
            at: backups + [URL(fileURLWithPath: logPath)],
            expected: expected,
            context: "simultaneous subprocess writers crossing the rotation threshold",
            expectedRotationNotices: 1
        )
    }

    private static func runProcessChild(directory: String, worker: Int, recordCount: Int, readyDirectory: String) {
        let logger = Logger(logDirectory: directory)
        let readyPath = URL(fileURLWithPath: readyDirectory)
            .appendingPathComponent("ready-\(worker)")
        do {
            try Data("ready".utf8).write(to: readyPath, options: .atomic)
        } catch {
            fail("Subprocess \(worker) could not publish readiness: \(error)")
        }

        let gatePath = URL(fileURLWithPath: directory).appendingPathComponent("go").path
        let gateDeadline = Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: gatePath) {
            if Date() >= gateDeadline { fail("Subprocess \(worker) timed out at start barrier") }
            Thread.sleep(forTimeInterval: 0.005)
        }

        for sequence in 0..<recordCount {
            logger.log(processMessage(worker: worker, sequence: sequence), level: logLevel)
        }
    }

    private static func testConcurrentInitialCreation(in directoryURL: URL) {
        createDirectory(directoryURL)
        let readyGate = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        for _ in 0..<workerCount {
            finished.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Logger(logDirectory: directoryURL.path)
                readyGate.signal()
                finished.leave()
            }
        }
        waitForSignals(readyGate, count: workerCount, description: "concurrent initializers")
        finished.wait()

        let logPath = directoryURL.appendingPathComponent("macrowhisper.log").path
        if !FileManager.default.fileExists(atPath: logPath) {
            fail("Logger initialization did not create the active log")
        }
    }

    private static func testRotationAndRetention(in baseURL: URL) {
        createDirectory(baseURL)
        let logPath = baseURL.appendingPathComponent("macrowhisper.log").path
        createSparseLog(at: logPath, marker: "INITIAL_ROTATION_PAYLOAD")
        seedTimestampCollisions(in: baseURL)

        _ = Logger(logDirectory: baseURL.path)
        let backups = backupLogURLs(in: baseURL)
        if backups.count != 1 || !backups[0].lastPathComponent.hasSuffix(".2") {
            fail("Same-second rotation collision did not choose a unique suffix and retain one backup")
        }
        let backupData = try! Data(contentsOf: backups[0])
        if backupData.range(of: Data("INITIAL_ROTATION_PAYLOAD".utf8)) == nil {
            fail("The rotated backup is missing the original log contents")
        }
        let activeLog = try! String(contentsOfFile: logPath, encoding: .utf8)
        if !activeLog.contains("Log file rotated due to size limit") {
            fail("The active log is missing its rotation notice")
        }

        let generatedName = backups[0].lastPathComponent
        let backupPrefix = "macrowhisper.log."
        let generatedStem = String(generatedName.dropFirst(backupPrefix.count))
        guard let suffixSeparator = generatedStem.lastIndex(of: "."),
              Int(generatedStem[generatedStem.index(after: suffixSeparator)...]) == 2 else {
            fail("Could not identify the same-second rotation suffix for retention test")
        }
        let timestamp = String(generatedStem[..<suffixSeparator])
        let tiedModificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        let tiedBackups = ["\(backupPrefix)\(timestamp).9", "\(backupPrefix)\(timestamp).10"]
        for name in [generatedName] + tiedBackups {
            let url = baseURL.appendingPathComponent(name)
            do {
                if name != generatedName { try Data("tied backup".utf8).write(to: url) }
                try FileManager.default.setAttributes(
                    [.modificationDate: tiedModificationDate],
                    ofItemAtPath: url.path
                )
            } catch {
                fail("Could not create tied-mtime retention fixture: \(error)")
            }
        }

        _ = Logger(logDirectory: baseURL.path)
        let retainedAfterTie = backupLogURLs(in: baseURL)
        if retainedAfterTie.count != 1 || retainedAfterTie[0].lastPathComponent != tiedBackups[1] {
            fail("Tied-mtime retention did not keep the numerically newest collision suffix")
        }
    }

    private static func seedTimestampCollisions(in directoryURL: URL) {
        let fileManager = FileManager.default
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let logPath = directoryURL.appendingPathComponent("macrowhisper.log").path
        let oldModificationDate = Date(timeIntervalSince1970: 1)

        for offset in -5...30 {
            let timestamp = formatter.string(from: Date(timeIntervalSinceNow: TimeInterval(offset)))
                .replacingOccurrences(of: ":", with: "-")
            for suffix in ["", ".1"] {
                let candidate = URL(fileURLWithPath: "\(logPath).\(timestamp)\(suffix)")
                do {
                    try Data("old backup".utf8).write(to: candidate)
                    try fileManager.setAttributes([.modificationDate: oldModificationDate], ofItemAtPath: candidate.path)
                } catch {
                    fail("Could not seed timestamp collision: \(error)")
                }
            }
        }
    }

    private static func backupLogURLs(in directoryURL: URL) -> [URL] {
        let logPrefix = "macrowhisper.log."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        return names
            .filter { $0.hasPrefix(logPrefix) }
            .map { directoryURL.appendingPathComponent($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func createSparseLog(at path: String, marker: String) {
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o644))
        if descriptor < 0 { fail("Could not create oversized rotation fixture") }
        defer { _ = Darwin.close(descriptor) }

        guard ftruncate(descriptor, off_t((5 * 1024 * 1024) + 1)) == 0 else {
            fail("Could not size rotation fixture")
        }
        let bytes = Array(marker.utf8)
        let written = bytes.withUnsafeBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return Darwin.pwrite(descriptor, baseAddress, buffer.count, 0)
        }
        if written != bytes.count { fail("Could not mark rotation fixture") }
    }

    private static func createNewlineLog(at path: String, size: Int) {
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o644))
        if descriptor < 0 { fail("Could not create threshold-crossing log fixture") }
        defer { _ = Darwin.close(descriptor) }

        let chunk = [UInt8](repeating: 0x0A, count: 64 * 1024)
        var remaining = size
        while remaining > 0 {
            let length = min(remaining, chunk.count)
            let written = chunk.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.write(descriptor, baseAddress, length)
            }
            if written <= 0 {
                if errno == EINTR { continue }
                fail("Could not fill threshold-crossing log fixture")
            }
            remaining -= written
        }
    }

    private static func verifyMessages(
        at paths: [URL],
        expected: [String],
        context: String,
        expectedRotationNotices: Int = 0
    ) {
        var actual: [String] = []
        for url in paths {
            let contents: String
            do {
                contents = try String(contentsOf: url, encoding: .utf8)
            } catch {
                fail("Could not read log for \(context): \(error)")
            }
            for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let delimiter = line.range(of: "] [INFO] ") else {
                    fail("Found a malformed or partial record during \(context)")
                }
                actual.append(String(line[delimiter.upperBound...]))
            }
        }

        let rotationNotice = "Log file rotated due to size limit"
        let actualRotationNotices = actual.filter { $0 == rotationNotice }.count
        actual.removeAll { $0 == rotationNotice }
        if actualRotationNotices != expectedRotationNotices {
            fail("\(context) found \(actualRotationNotices) rotation notices; expected \(expectedRotationNotices)")
        }

        let expectedSet = Set(expected)
        let actualCounts = Dictionary(grouping: actual, by: { $0 }).mapValues(\.count)
        let missing = expected.filter { actualCounts[$0, default: 0] == 0 }
        let duplicated = actualCounts.filter { $0.value > 1 }
        if actual.count != expected.count || expectedSet.count != expected.count || !missing.isEmpty || !duplicated.isEmpty {
            let missingExample = missing.first ?? "none"
            let duplicateExample = duplicated.first?.key ?? "none"
            fail("\(context) lost, duplicated, or corrupted records (expected \(expected.count), found \(actual.count); missing example: \(missingExample); duplicate example: \(duplicateExample))")
        }
    }

    private static func threadMessage(worker: Int, sequence: Int) -> String {
        uniqueMessage(kind: "THREAD", worker: worker, sequence: sequence)
    }

    private static func processMessage(worker: Int, sequence: Int) -> String {
        uniqueMessage(kind: "PROCESS", worker: worker, sequence: sequence)
    }

    private static func uniqueMessage(kind: String, worker: Int, sequence: Int) -> String {
        let width = 48 + ((worker * 29 + sequence * 17) % 144)
        let fill = Character(UnicodeScalar(65 + ((worker + sequence) % 26))!)
        let payload = String(repeating: fill, count: width)
        return "\(kind)|worker=\(worker)|sequence=\(sequence)|payload=\(payload)"
    }

    private static func resolvedExecutablePath() -> String {
        let suppliedPath = CommandLine.arguments[0]
        if suppliedPath.hasPrefix("/") { return suppliedPath }
        return URL(fileURLWithPath: suppliedPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL.path
    }

    private static func allReady(in directoryURL: URL, count: Int) -> Bool {
        (0..<count).allSatisfy { FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("ready-\($0)").path) }
    }

    private static func waitForSignals(_ semaphore: DispatchSemaphore, count: Int, description: String) {
        for _ in 0..<count {
            if semaphore.wait(timeout: .now() + 60) == .timedOut {
                fail("Timed out waiting for \(description)")
            }
        }
    }

    private static func createDirectory(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            fail("Could not create temporary test directory: \(error)")
        }
    }

    private static func createEmptyLog(at path: String) {
        do {
            try Data().write(to: URL(fileURLWithPath: path))
        } catch {
            fail("Could not prepare empty log: \(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("Logger concurrency regression failed: \(message)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
