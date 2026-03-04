import Foundation
import Cocoa

// Minimal stubs for compiling Placeholders.swift in isolation for regression tests.

enum ActionType {
    case insert
    case url
    case shortcut
    case shell
    case appleScript
}

final class DummyDefaults {
    var clipboardStacking: Bool = false
}

final class DummyConfig {
    var defaults = DummyDefaults()
}

final class ConfigurationManager {
    var config = DummyConfig()
}

final class ClipboardMonitor {
    var activeSessionSelectedText: String = ""
    var activeSessionClipboardContentWithStacking: String = ""
    var recentClipboardContent: String = ""
    var recentClipboardContentWithStacking: String = ""

    func getActiveSessionSelectedText() -> String { activeSessionSelectedText }
    func getActiveSessionClipboardContentWithStacking(enableStacking: Bool) -> String { activeSessionClipboardContentWithStacking }
    func getRecentClipboardContent() -> String { recentClipboardContent }
    func getRecentClipboardContentWithStacking(enableStacking: Bool) -> String { recentClipboardContentWithStacking }
}

final class RecordingsFolderWatcher {
    var activeRecordingSessions = false
    var clipboardMonitor = ClipboardMonitor()

    func hasActiveRecordingSessions() -> Bool { activeRecordingSessions }
    func getClipboardMonitor() -> ClipboardMonitor { clipboardMonitor }
}

final class GlobalStateManager {
    var lastDetectedFrontApp: NSRunningApplication?
}

let globalState = GlobalStateManager()
var globalConfigManager: ConfigurationManager?
var recordingsWatcher: RecordingsFolderWatcher?
var redactedLogsEnabled = false

func logDebug(_ message: String) {}
func logWarning(_ message: String) {}
func logError(_ message: String) {}

func redactForLogs(_ text: String) -> String { text }
func summarizeForLogs(_ text: String, maxPreview: Int) -> String { text }
func isVerboseLogDetailEnabled() -> Bool { false }

func escapeJsonString(_ value: String) -> String { value }
func escapeAppleScriptString(_ value: String) -> String { value }
func escapeShellCharacters(_ value: String) -> String { value }
func escapeUrlPlaceholder(_ value: String) -> String { value }

func getSelectedText() -> String { "" }
func getAppContext(targetPid: Int32?, fallbackAppName: String?) -> String { "" }
func getAppVocabulary(targetPid: Int32?, fallbackAppName: String?, fallbackBundleId: String?) -> String { "" }

func resolveRecordingFolderPath(
    configManager: ConfigurationManager?,
    recordingsWatcher: RecordingsFolderWatcher?,
    index: Int
) -> String? {
    nil
}
