import ApplicationServices
import Foundation

enum AccessibilityActivationKind: Equatable {
    case electron
    case chromiumBrowser
    case none

    private static let chromiumBrowserBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.operasoftware.OperaGX",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "ai.perplexity.comet",
        "company.thebrowser.dia",
        "company.thebrowser.Browser",
        "com.openai.atlas",
        "org.chromium.Chromium",
        "org.chromium.Thorium",
        "net.imput.helium",
        "io.wavebox.wavebox"
    ]

    static func resolve(bundleIdentifier: String?, hasElectronFramework: Bool) -> Self {
        if hasElectronFramework {
            return .electron
        }

        guard let bundleIdentifier,
              chromiumBrowserBundleIdentifiers.contains(bundleIdentifier) else {
            return .none
        }
        return .chromiumBrowser
    }
}

struct AccessibilityAppIdentity: Hashable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
}

enum AccessibilityActivationOutcome: Equatable {
    case succeeded
    case retryable
    case unavailable

    static func classify(_ error: AXError) -> Self {
        switch error {
        case .success:
            return .succeeded
        case .failure, .cannotComplete:
            return .retryable
        default:
            return .unavailable
        }
    }
}

struct AccessibilityActivationAttemptBudget {
    private struct Entry {
        var attempts: Int
        var lastAttemptAt: TimeInterval
        var outcome: AccessibilityActivationOutcome?
    }

    private var entries: [AccessibilityAppIdentity: Entry] = [:]

    mutating func shouldAttempt(
        for identity: AccessibilityAppIdentity,
        kind: AccessibilityActivationKind,
        now: TimeInterval,
        cooldown: TimeInterval = 1.0,
        maximumAttempts: Int = 2
    ) -> Bool {
        guard kind != .none, identity.processIdentifier > 0, maximumAttempts > 0 else {
            return false
        }

        guard var entry = entries[identity] else {
            entries[identity] = Entry(attempts: 1, lastAttemptAt: now, outcome: nil)
            return true
        }

        guard entry.outcome == .retryable,
              entry.attempts < maximumAttempts,
              now >= entry.lastAttemptAt,
              now - entry.lastAttemptAt >= cooldown else {
            return false
        }

        entry.attempts += 1
        entry.lastAttemptAt = now
        entry.outcome = nil
        entries[identity] = entry
        return true
    }

    mutating func record(
        _ outcome: AccessibilityActivationOutcome,
        for identity: AccessibilityAppIdentity
    ) {
        guard var entry = entries[identity] else { return }
        entry.outcome = outcome
        entries[identity] = entry
    }
}

struct AccessibilityFocusFailureMemo {
    private struct Entry {
        let identity: AccessibilityAppIdentity
        let timestamp: TimeInterval
    }

    private var entry: Entry?

    mutating func recordMiss(for identity: AccessibilityAppIdentity, at timestamp: TimeInterval) {
        entry = Entry(identity: identity, timestamp: timestamp)
    }

    mutating func clear() {
        entry = nil
    }

    mutating func shouldReuseMiss(
        for identity: AccessibilityAppIdentity,
        now: TimeInterval,
        validity: TimeInterval = 0.15
    ) -> Bool {
        guard let entry else { return false }
        guard entry.identity == identity else {
            self.entry = nil
            return false
        }
        guard now >= entry.timestamp,
              now - entry.timestamp < validity else {
            self.entry = nil
            return false
        }
        return true
    }
}
