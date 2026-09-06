import Foundation

enum ActionType {
    case insert
    case url
    case shortcut
    case shell
    case appleScript
}

/// The transaction runner drives watcher callbacks explicitly. This keeps the
/// production manager and its callback queue in the test while avoiding a
/// live filesystem watcher or service process.
final class ConfigChangeWatcher {
    private let onChanged: () -> Void
    private(set) var isStarted = false
    static var latest: ConfigChangeWatcher?

    init(filePath: String, onChanged: @escaping () -> Void) {
        _ = filePath
        self.onChanged = onChanged
        Self.latest = self
    }

    func start() { isStarted = true }
    func stop() { isStarted = false }

    static func triggerLatest() {
        latest?.onChanged()
    }
}

final class UserDefaultsManager {
    static let shared = UserDefaultsManager()
    private init() {}

    func setConfigPath(_ path: String) { _ = path }
    func getConfigPath() -> String? { nil }
    func removeConfigPath() {}
}

enum SchemaManager {
    static func getSchemaReference() -> String? { nil }
}

func logDebug(_ message: String) { _ = message }
func logInfo(_ message: String) { _ = message }
func logWarning(_ message: String) { _ = message }
func logError(_ message: String) { _ = message }

var testNotifications: [(title: String, message: String)] = []

func notify(title: String, message: String) {
    testNotifications.append((title: title, message: message))
}
