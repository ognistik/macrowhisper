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
    func getActiveSessionSelectedText() -> String { "" }
    func getActiveSessionClipboardContentWithStacking(enableStacking: Bool) -> String { "" }
    func getRecentClipboardContent() -> String { "" }
    func getRecentClipboardContentWithStacking(enableStacking: Bool) -> String { "" }
}

final class RecordingsFolderWatcher {
    func hasActiveRecordingSessions() -> Bool { false }
    func getClipboardMonitor() -> ClipboardMonitor { ClipboardMonitor() }
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
