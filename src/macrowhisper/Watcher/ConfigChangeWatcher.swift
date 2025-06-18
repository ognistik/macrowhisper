import Foundation
import Dispatch

class ConfigChangeWatcher {
    private let filePath: String
    private var source: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.macrowhisper.configwatcher")
    private let onChanged: () -> Void

    init(filePath: String, onChanged: @escaping () -> Void) {
        self.filePath = filePath
        self.onChanged = onChanged
    }

    func start() {
        // Ensure we don't start multiple watchers
        guard source == nil else { return }

        let fileDescriptor = open(filePath, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            logError("ConfigChangeWatcher: Failed to open file descriptor for path: \(filePath)")
            return
        }

        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .write, queue: queue)

        source?.setEventHandler { [weak self] in
            self?.onChanged()
        }

        source?.setCancelHandler {
            close(fileDescriptor)
        }

        source?.resume()
        logDebug("Started watching for configuration changes at: \(filePath)")
    }

    func stop() {
        source?.cancel()
        source = nil
    }
} 