import Foundation

enum ActionType {
    case insert
    case url
    case shortcut
    case shell
    case appleScript
}

final class ConfigChangeWatcher {
    init(filePath: String, onChanged: @escaping () -> Void) {}
    func start() {}
    func stop() {}
}

final class UserDefaultsManager {
    static let shared = UserDefaultsManager()

    private init() {}

    func setConfigPath(_ path: String) {}
    func getConfigPath() -> String? { nil }
    func removeConfigPath() {}
}

enum SchemaManager {
    static func getSchemaReference() -> String? {
        "https://example.invalid/macrowhisper-schema.json"
    }
}

func logDebug(_ message: String) {}
func logInfo(_ message: String) {}
func logWarning(_ message: String) {}
func logError(_ message: String) {}
func notify(title: String, message: String) {}
