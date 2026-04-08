import Foundation
import Cocoa

final class Logger {}

func getSelectedText() -> String { "" }
func sanitizeContextPlaceholderValue(_ value: String) -> String { value }
func resolveFrontAppIdentity() -> NSRunningApplication? { nil }
func requestAccessibilityPermission() -> Bool { false }
func isInInputField() -> Bool { false }
func simulateKeyDown(key: Int) {}
func shouldEmitRateLimitedLog(key: String, cooldown: TimeInterval) -> Bool { false }
func logDebug(_ message: String) {}
func logInfo(_ message: String) {}
func logWarning(_ message: String) {}
func logError(_ message: String) {}
