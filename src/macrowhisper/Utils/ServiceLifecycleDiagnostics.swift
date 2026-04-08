import Foundation
import Dispatch
import Darwin

private struct ServiceSessionState: Codable {
    let pid: Int32
    let startedAt: TimeInterval
    let startupSource: String
    let startupContext: String
    let isActive: Bool
    let shutdownReason: String?
    let shutdownAt: TimeInterval?
}

private struct ServiceLaunchIntent: Codable {
    let reason: String
    let requestedAt: TimeInterval
    let requestedByPid: Int32
}

final class ServiceLifecycleDiagnostics {
    static let shared = ServiceLifecycleDiagnostics()

    private let queue = DispatchQueue(label: "com.macrowhisper.servicelifecycle")
    private let fileManager = FileManager.default
    private let sessionStatePath: String
    private let launchIntentPath: String
    private let dateFormatter = ISO8601DateFormatter()
    private var signalSources: [DispatchSourceSignal] = []
    private var shutdownRecorded = false

    private init() {
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let macrowhisperDir = appSupportDir?.appendingPathComponent("Macrowhisper")
            ?? URL(fileURLWithPath: "/tmp/Macrowhisper")

        self.sessionStatePath = macrowhisperDir.appendingPathComponent("service_session_state.json").path
        self.launchIntentPath = macrowhisperDir.appendingPathComponent("pending_launch_intent.json").path
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func recordLaunchIntent(_ reason: String) {
        queue.sync {
            ensureParentDirectoryExists()

            let intent = ServiceLaunchIntent(
                reason: reason,
                requestedAt: Date().timeIntervalSince1970,
                requestedByPid: getpid()
            )

            save(intent, to: launchIntentPath)
            logInfo("[Lifecycle] Recorded pending daemon launch intent: \(reason)")
        }
    }

    func clearPendingLaunchIntent() {
        queue.sync {
            guard fileManager.fileExists(atPath: launchIntentPath) else { return }
            try? fileManager.removeItem(atPath: launchIntentPath)
        }
    }

    func beginDaemonSession(startupSource: String, startupContext: String) {
        queue.sync {
            ensureParentDirectoryExists()

            let previousState: ServiceSessionState? = load(from: sessionStatePath)
            let launchIntent: ServiceLaunchIntent? = load(from: launchIntentPath)
            if launchIntent != nil {
                try? fileManager.removeItem(atPath: launchIntentPath)
            }

            if let launchIntent {
                logInfo(
                    "[Lifecycle] Startup follows explicit daemon launch intent: \(launchIntent.reason) " +
                    "(requestedAt: \(format(timestamp: launchIntent.requestedAt)), requestedByPid: \(launchIntent.requestedByPid))"
                )
            }

            if let previousState, previousState.isActive {
                logWarning(
                    "[Lifecycle] Previous daemon session ended without a recorded clean shutdown " +
                    "(pid: \(previousState.pid), startedAt: \(format(timestamp: previousState.startedAt)), " +
                    "source: \(previousState.startupSource)). This launch likely followed a crash, SIGKILL, force quit, or launchd recovery."
                )
            } else if let previousState,
                      let shutdownReason = previousState.shutdownReason,
                      let shutdownAt = previousState.shutdownAt {
                logDebug(
                    "[Lifecycle] Previous daemon shutdown was recorded as '\(shutdownReason)' " +
                    "at \(format(timestamp: shutdownAt))."
                )
            }

            let newState = ServiceSessionState(
                pid: getpid(),
                startedAt: Date().timeIntervalSince1970,
                startupSource: startupSource,
                startupContext: startupContext,
                isActive: true,
                shutdownReason: nil,
                shutdownAt: nil
            )

            save(newState, to: sessionStatePath)
            shutdownRecorded = false
            installTerminationSignalHandlersIfNeeded()
        }
    }

    func recordCleanShutdown(reason: String) {
        queue.sync {
            guard !shutdownRecorded else { return }

            let existingState: ServiceSessionState? = load(from: sessionStatePath)
            let shutdownAt = Date().timeIntervalSince1970
            let updatedState = ServiceSessionState(
                pid: existingState?.pid ?? getpid(),
                startedAt: existingState?.startedAt ?? shutdownAt,
                startupSource: existingState?.startupSource ?? "unknown",
                startupContext: existingState?.startupContext ?? "",
                isActive: false,
                shutdownReason: reason,
                shutdownAt: shutdownAt
            )

            save(updatedState, to: sessionStatePath)
            shutdownRecorded = true
            logInfo("[Lifecycle] Recorded clean daemon shutdown: \(reason)")
        }
    }

    private func installTerminationSignalHandlersIfNeeded() {
        guard signalSources.isEmpty else { return }

        let handledSignals = [SIGTERM, SIGINT, SIGHUP, SIGQUIT]
        for handledSignal in handledSignals {
            signal(handledSignal, SIG_IGN)

            let source = DispatchSource.makeSignalSource(signal: handledSignal, queue: DispatchQueue.main)
            source.setEventHandler { [weak self] in
                let signalName = Self.signalName(for: handledSignal)
                logInfo("[Lifecycle] Received \(signalName); recording shutdown state before exiting.")
                self?.recordCleanShutdown(reason: "received \(signalName)")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func ensureParentDirectoryExists() {
        let parentPath = (sessionStatePath as NSString).deletingLastPathComponent
        if !fileManager.fileExists(atPath: parentPath) {
            try? fileManager.createDirectory(atPath: parentPath, withIntermediateDirectories: true)
        }
    }

    private func load<T: Decodable>(from path: String) -> T? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }

        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to path: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func format(timestamp: TimeInterval) -> String {
        dateFormatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    private static func signalName(for signalNumber: Int32) -> String {
        switch signalNumber {
        case SIGTERM: return "SIGTERM"
        case SIGINT: return "SIGINT"
        case SIGHUP: return "SIGHUP"
        case SIGQUIT: return "SIGQUIT"
        default: return "signal \(signalNumber)"
        }
    }
}
