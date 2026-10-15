import Foundation
import Cocoa

// Minimal runtime stubs for compiling the production placeholder pipeline in regression tests.

enum ActionType {
    case insert
    case url
    case shortcut
    case shell
    case appleScript
}

final class ConfigurationManager {
    var config = AppConfiguration.defaultConfig()
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
var stubSelectedText = ""
var stubAppContext = ""
var stubAppVocabulary = ""
var stubActiveURL: String?

func logDebug(_ message: String) {}
func logWarning(_ message: String) {}
func logError(_ message: String) {}

func redactForLogs(_ text: String) -> String { text }
func summarizeForLogs(_ text: String, maxPreview: Int) -> String { text }
func isVerboseLogDetailEnabled() -> Bool { false }

func getSelectedText() -> String { stubSelectedText }
func resolveFrontAppIdentity() -> NSRunningApplication? { globalState.lastDetectedFrontApp }
func getAppContext(targetPid: Int32?, fallbackAppName: String?) -> String { stubAppContext }
func getAppVocabulary(targetPid: Int32?, fallbackAppName: String?, fallbackBundleId: String?) -> String { stubAppVocabulary }
func getActiveURL(targetPid: Int32? = nil, fallbackBundleId: String? = nil) -> String? { stubActiveURL }

func resolveRecordingFolderPath(
    configManager: ConfigurationManager?,
    recordingsWatcher: RecordingsFolderWatcher?,
    index: Int
) -> String? {
    nil
}
