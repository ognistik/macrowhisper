import Cocoa

/// The process-wide boundary for synchronous native pasteboard transactions.
///
/// NSPasteboard.general is shared by watcher bootstrap, main-thread polling,
/// and socket commands. Protect the complete read or clear/write transaction,
/// including AppKit's temporary-object cleanup, rather than individual getters.
/// Only value snapshots may leave this boundary. Never wait on a monitor state
/// queue, dispatch to the main queue, or invoke caller callbacks inside it.
enum ClipboardAccess {
    private static let lock = NSRecursiveLock()

    static func withPasteboard<T>(
        _ pasteboard: NSPasteboard? = nil,
        _ body: (NSPasteboard) throws -> T
    ) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        // Drain native temporaries before another thread can use the shared
        // pasteboard. Recursive entry permits snapshot/writer composition.
        return try autoreleasepool {
            try body(pasteboard ?? .general)
        }
    }

    static var changeCount: Int {
        withPasteboard { $0.changeCount }
    }

    static func readText() -> String? {
        withPasteboard { $0.string(forType: .string) }
    }

    struct TextWriteResult {
        let succeeded: Bool
        let changeCount: Int
        let confirmedText: String?
    }

    @discardableResult
    static func writeText(_ text: String, confirm: Bool = false) -> TextWriteResult {
        withPasteboard { pasteboard in
            pasteboard.clearContents()
            let succeeded = pasteboard.setString(text, forType: .string)
            return TextWriteResult(
                succeeded: succeeded,
                changeCount: pasteboard.changeCount,
                confirmedText: confirm ? pasteboard.string(forType: .string) : nil
            )
        }
    }
}
