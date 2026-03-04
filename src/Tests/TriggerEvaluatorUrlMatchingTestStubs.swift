import Foundation
import Cocoa

// Minimal stubs for compiling TriggerEvaluator.swift in isolation.

final class Logger {}

var redactedLogsEnabled = false

func logInfo(_ message: String) {}
func logDebug(_ message: String) {}
func logWarning(_ message: String) {}
func logError(_ message: String) {}

func isVerboseLogDetailEnabled() -> Bool { false }

func summarizeForLogs(_ value: String?, maxPreview: Int = 120) -> String {
    guard let value else { return "nil" }
    return summarizeForLogs(value, maxPreview: maxPreview)
}

func summarizeForLogs(_ value: String, maxPreview: Int = 120) -> String {
    if value.count <= maxPreview {
        return value
    }
    let end = value.index(value.startIndex, offsetBy: maxPreview)
    return String(value[..<end]) + "…"
}

struct AppConfiguration {
    struct Insert {
        var triggerVoice: String?
        var triggerApps: String?
        var triggerModes: String?
        var triggerUrls: String?
        var triggerLogic: String?
    }

    struct Url {
        var triggerVoice: String?
        var triggerApps: String?
        var triggerModes: String?
        var triggerUrls: String?
        var triggerLogic: String?
    }

    struct Shortcut {
        var triggerVoice: String?
        var triggerApps: String?
        var triggerModes: String?
        var triggerUrls: String?
        var triggerLogic: String?
    }

    struct ScriptShell {
        var triggerVoice: String?
        var triggerApps: String?
        var triggerModes: String?
        var triggerUrls: String?
        var triggerLogic: String?
    }

    struct ScriptAppleScript {
        var triggerVoice: String?
        var triggerApps: String?
        var triggerModes: String?
        var triggerUrls: String?
        var triggerLogic: String?
    }

    var inserts: [String: Insert]
    var urls: [String: Url]
    var shortcuts: [String: Shortcut]
    var scriptsShell: [String: ScriptShell]
    var scriptsAS: [String: ScriptAppleScript]

    init(
        inserts: [String: Insert] = [:],
        urls: [String: Url] = [:],
        shortcuts: [String: Shortcut] = [:],
        scriptsShell: [String: ScriptShell] = [:],
        scriptsAS: [String: ScriptAppleScript] = [:]
    ) {
        self.inserts = inserts
        self.urls = urls
        self.shortcuts = shortcuts
        self.scriptsShell = scriptsShell
        self.scriptsAS = scriptsAS
    }
}

final class ConfigurationManager {
    var config: AppConfiguration

    init(config: AppConfiguration) {
        self.config = config
    }
}
