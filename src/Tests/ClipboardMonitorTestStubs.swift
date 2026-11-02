import Foundation
import Cocoa

final class Logger {}

private let clipboardMonitorWarningLock = NSLock()
private var clipboardMonitorWarningMessages: [String] = []

func takeClipboardMonitorWarningMessages() -> [String] {
    clipboardMonitorWarningLock.lock()
    defer { clipboardMonitorWarningLock.unlock() }
    let messages = clipboardMonitorWarningMessages
    clipboardMonitorWarningMessages.removeAll()
    return messages
}

enum PasteDiagnostics {
    static func recordClipboardFinalization(stage: String, changeCount: Int, delay: TimeInterval? = nil) {}
}

func getSelectedText() -> String { "" }
func sanitizeContextPlaceholderValue(_ value: String) -> String { value }
func resolveFrontAppIdentity() -> NSRunningApplication? { nil }
func requestAccessibilityPermission() -> Bool { false }
func checkAccessibilityPermission() -> Bool { false }
func isInInputField() -> Bool { false }
func simulateKeyDown(key: Int) {}
func shouldEmitRateLimitedLog(key: String, cooldown: TimeInterval) -> Bool { false }
func logDebug(_ message: String) {}
func logInfo(_ message: String) {}
func logWarning(_ message: String) {
    clipboardMonitorWarningLock.lock()
    clipboardMonitorWarningMessages.append(message)
    clipboardMonitorWarningLock.unlock()
}
func logError(_ message: String) {}
