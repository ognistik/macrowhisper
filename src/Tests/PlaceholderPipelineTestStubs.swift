import Foundation
import Cocoa

// Minimal stubs for compiling Placeholders.swift in isolation for regression tests.

func decodeMacrowhisperInsertEscapes(_ value: String) -> String {
    let characters = Array(value)
    var result = String()
    var index = 0
    while index < characters.count {
        guard characters[index] == "\\" else {
            result.append(characters[index])
            index += 1
            continue
        }
        var slashCount = 0
        while index < characters.count, characters[index] == "\\" {
            slashCount += 1
            index += 1
        }
        guard index < characters.count, characters[index] == "n" else {
            result.append(String(repeating: "\\", count: slashCount))
            continue
        }
        result.append(String(repeating: "\\", count: slashCount / 2))
        result.append(slashCount.isMultiple(of: 2) ? "n" : "\n")
        index += 1
    }
    return result
}

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

func escapeJsonString(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: "\\t")
        .replacingOccurrences(of: "\u{08}", with: "\\b")
        .replacingOccurrences(of: "\u{0C}", with: "\\f")
}

func escapeAppleScriptString(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

func escapeShellCharacters(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "`", with: "\\`")
        .replacingOccurrences(of: "$", with: "\\$")
}

func escapeUrlPlaceholder(_ value: String) -> String {
    let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    return value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
}

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
