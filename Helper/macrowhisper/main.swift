#!/usr/bin/env swift

import Foundation
import Swifter
import Dispatch

// MARK: - Helpers

@preconcurrency
final class ProxyStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let writer: HttpResponseBodyWriter
    let semaphore: DispatchSemaphore

    init(writer: HttpResponseBodyWriter, semaphore: DispatchSemaphore) {
        self.writer = writer
        self.semaphore = semaphore
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Write each chunk as soon as it arrives
        try? writer.write(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Done streaming
        semaphore.signal()
    }
}

func exitWithError(_ message: String) -> Never {
    print("Error: \(message)")
    exit(1)
}

func loadProxies(from path: String) -> [String: [String: Any]] {
    let proxiesFile = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: proxiesFile.path) else {
        print("Warning: proxies.json not found.")
        return [:]
    }
    
    do {
        let data = try Data(contentsOf: proxiesFile)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            print("Warning: Malformed proxies.json")
            return [:]
        }
        print("Successfully loaded proxies configuration")
        return dict
    } catch {
        print("Error reading proxies.json: \(error.localizedDescription)")
        return [:]
    }
}

func buildRequest(url: String, headers: [String: String], json: [String: Any]) -> URLRequest {
    guard let urlObj = URL(string: url) else { exitWithError("Bad URL: \(url)") }
    var req = URLRequest(url: urlObj)
    req.httpMethod = "POST"
    for (k, v) in headers { req.addValue(v, forHTTPHeaderField: k) }
    req.httpBody = try? JSONSerialization.data(withJSONObject: json)
    return req
}

func mergeBody(original: [String: Any], modifications: [String: Any]) -> [String: Any] {
    var out = original
    for (k, v) in modifications { out[k] = v }
    return out
}

final class FileChangeWatcher {
    private let filePath: String
    private let callback: () -> Void
    private let queue = DispatchQueue(label: "com.macrowhisper.filewatcher", qos: .utility)

    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var rewatchTimer: DispatchSourceTimer?

    init(filePath: String, callback: @escaping () -> Void) {
        self.filePath = filePath
        self.callback = callback
        startWatching()
    }

    private func startWatching() {
        guard FileManager.default.fileExists(atPath: filePath) else {
            scheduleRewatch()
            return
        }

        fileDescriptor = open(filePath, O_EVTONLY)
        if fileDescriptor < 0 {
            print("FileChangeWatcher: Failed to open file descriptor for \(filePath)")
            scheduleRewatch()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            // If file is deleted or renamed, stop watcher and schedule rewatch
            if !FileManager.default.fileExists(atPath: self.filePath) {
                self.stopWatching()
                self.scheduleRewatch()
            } else {
                self.callback()
            }
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
            }
        }

        source.resume()
        self.dispatchSource = source
    }

    private func stopWatching() {
        dispatchSource?.cancel()
        dispatchSource = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func scheduleRewatch() {
        // Cancel existing timer if any
        rewatchTimer?.cancel()
        rewatchTimer = nil

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1) // Check every 1 second
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if FileManager.default.fileExists(atPath: self.filePath) {
                self.rewatchTimer?.cancel()
                self.rewatchTimer = nil
                self.startWatching()
            }
        }
        timer.resume()
        self.rewatchTimer = timer
    }

    deinit {
        stopWatching()
        rewatchTimer?.cancel()
        rewatchTimer = nil
    }
}

class RecordingsFolderWatcher: @unchecked Sendable {
    private let basePath: String
    private let recordingsPath: String
    private var currentWatchedFolder: String?
    private var folderDispatchSource: DispatchSourceFileSystemObject?
    private var fileDispatchSource: DispatchSourceFileSystemObject?
    private var processedMetaJsons = Set<String>()
    private let fileDescriptorQueue = DispatchQueue(label: "com.macrowhisper.filedescriptor", qos: .userInteractive)
    private var metaJsonFileDescriptor: Int32 = -1
    
    deinit {
        closeFileDescriptor()
    }
    
    init?(basePath: String) {
        self.basePath = basePath
        self.recordingsPath = basePath + "/recordings"
        
        // Verify recordings folder exists
        guard FileManager.default.fileExists(atPath: recordingsPath) else {
            print("Error: recordings folder not found at \(recordingsPath)")
            return nil
        }
        
        // Mark current newest folder as "already processed"
        if let newestFolder = findNewestFolder() {
            currentWatchedFolder = newestFolder
            print("Initial run: Marking current newest folder as already processed: \(newestFolder)")
            
            // Also mark existing meta.json as processed if it exists
            let metaJsonPath = newestFolder + "/meta.json"
            if FileManager.default.fileExists(atPath: metaJsonPath) {
                processedMetaJsons.insert(metaJsonPath)
                print("Initial run: Marking existing meta.json as already processed")
            }
        }
        
        // Start watching recordings folder using FSEvents for better performance
        startWatchingRecordingsFolder()
    }
    
    private func startWatchingRecordingsFolder() {
        // Use low-level file descriptor and GCD to watch for changes
        fileDescriptorQueue.async { [weak self] in
            guard let self = self else { return }
            
            let fileDescriptor = open(self.recordingsPath, O_EVTONLY)
            if fileDescriptor < 0 {
                print("Error: Unable to open file descriptor for recordings folder")
                return
            }
            
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileDescriptor,
                eventMask: [.write, .link, .rename],
                queue: self.fileDescriptorQueue
            )
            
            source.setEventHandler { [weak self] in
                self?.checkForNewFolder()
            }
            
            source.setCancelHandler {
                close(fileDescriptor)
            }
            
            source.resume()
            self.folderDispatchSource = source
            
            // Do initial check
            self.checkForNewFolder()
        }
    }
    
    private func findNewestFolder() -> String? {
        // Get all subdirectories in recordings folder
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: recordingsPath),
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            print("Error: Failed to read contents of recordings folder")
            return nil
        }
        
        // Filter for directories only
        let directories = contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
        
        // Sort by creation date (newest first)
        let sortedDirs = directories.sorted { dir1, dir2 in
            let date1 = try? dir1.resourceValues(forKeys: [.creationDateKey]).creationDate
            let date2 = try? dir2.resourceValues(forKeys: [.creationDateKey]).creationDate
            return (date1 ?? Date.distantPast) > (date2 ?? Date.distantPast)
        }
        
        // Get newest directory
        return sortedDirs.first?.path
    }
    
    private func checkForNewFolder() {
        guard let newestFolder = findNewestFolder() else {
            print("No subdirectories found in recordings folder")
            return
        }
        
        // If we're already watching this folder, do nothing
        if newestFolder == currentWatchedFolder {
            return
        }
        
        print("New folder detected: \(newestFolder)")
        currentWatchedFolder = newestFolder
        
        // Stop watching old folder
        cancelFileWatcher()
        
        // Watch for meta.json in the new folder
        watchForMetaJson(in: newestFolder)
    }
    
    private func cancelFileWatcher() {
        fileDispatchSource?.cancel()
        fileDispatchSource = nil
        closeFileDescriptor()
    }
    
    private func closeFileDescriptor() {
        if metaJsonFileDescriptor >= 0 {
            close(metaJsonFileDescriptor)
            metaJsonFileDescriptor = -1
        }
    }
    
    private func watchForMetaJson(in folderPath: String) {
        // Use low-level file descriptor and GCD to watch for changes
        fileDescriptorQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Cancel any existing watcher
            self.cancelFileWatcher()
            
            let fileDescriptor = open(folderPath, O_EVTONLY)
            if fileDescriptor < 0 {
                print("Error: Unable to open file descriptor for folder")
                return
            }
            
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileDescriptor,
                eventMask: [.write, .link, .rename],
                queue: self.fileDescriptorQueue
            )
            
            source.setEventHandler { [weak self] in
                guard let self = self else { return }
                
                let metaJsonPath = folderPath + "/meta.json"
                if FileManager.default.fileExists(atPath: metaJsonPath) && !self.processedMetaJsons.contains(metaJsonPath) {
                    self.checkMetaJson(at: metaJsonPath)
                }
            }
            
            source.setCancelHandler {
                close(fileDescriptor)
            }
            
            source.resume()
            self.fileDispatchSource = source
            
            // Check immediately if meta.json already exists
            let metaJsonPath = folderPath + "/meta.json"
            if FileManager.default.fileExists(atPath: metaJsonPath) && !self.processedMetaJsons.contains(metaJsonPath) {
                self.checkMetaJson(at: metaJsonPath)
            }
        }
    }
    
    private func checkMetaJson(at path: String) {
        // Directly monitor the meta.json file for changes
        if metaJsonFileDescriptor < 0 {
            metaJsonFileDescriptor = open(path, O_EVTONLY)
            if metaJsonFileDescriptor >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: metaJsonFileDescriptor,
                    eventMask: [.write, .delete],
                    queue: fileDescriptorQueue
                )
                
                source.setEventHandler { [weak self] in
                    self?.readAndProcessMetaJson(at: path)
                }
                
                source.setCancelHandler { [weak self] in
                    self?.closeFileDescriptor()
                }
                
                source.resume()
                self.fileDispatchSource = source
            }
        }
        
        // Also check immediately
        readAndProcessMetaJson(at: path)
    }
    
    private func readAndProcessMetaJson(at path: String) {
        // Don't process if already handled
        if processedMetaJsons.contains(path) {
            return
        }
        
        // Check if file still exists
        if !FileManager.default.fileExists(atPath: path) {
            print("meta.json was deleted")
            return
        }
        
        // Read file with low-level APIs for speed
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .uncached),
              let json = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any] else {
            print("Error: Failed to read meta.json or invalid JSON format")
            return
        }
        
        // Check if result key exists and has a non-null, non-empty value
        if let result = json["result"],
           !(result is NSNull),
           !String(describing: result).isEmpty {
            print("Found valid result in meta.json: \(result)")
            
            // Mark this file as processed so we don't trigger again
            processedMetaJsons.insert(path)
            
            // Cancel file watcher since we're done with this file
            cancelFileWatcher()
            
            // Trigger Keyboard Maestro on main thread for UI interaction
            // Store the method reference
            let triggerMethod = self.triggerKeyboardMaestro
            // Use it in the closure without capturing self
            DispatchQueue.main.async {
                triggerMethod()
            }
        }
    }
    
    private func triggerKeyboardMaestro() {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = [
            "-e",
            "tell application \"Keyboard Maestro Engine\" to do script \"Trigger - Meta\""
        ]
        // Discard all output, fully async
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            print("Failed to launch Keyboard Maestro trigger: \(error)")
        }
    }
}

func isPortAvailable(_ port: UInt16) -> Bool {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    if sock < 0 { return false }
    defer { close(sock) }
    
    var addr = sockaddr_in(
        sin_len: UInt8(MemoryLayout<sockaddr_in>.stride),
        sin_family: sa_family_t(AF_INET),
        sin_port: port.bigEndian,
        sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
        sin_zero: (0,0,0,0,0,0,0,0)
    )
    let bind_result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
        }
    }
    return bind_result == 0
}

func mergeAnnotationsIntoContent(_ data: Data) -> Data {
    guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var choices = root["choices"] as? [[String: Any]] else {
        print("Couldn't parse completion JSON, returning original data.")
        return data
    }
    for i in choices.indices {
        guard var message = choices[i]["message"] as? [String: Any] else { continue }
        if let annotations = message["annotations"] as? [[String: Any]], !annotations.isEmpty {
            print("Found \(annotations.count) annotations, merging into content for choice[\(i)].")
            var content = message["content"] as? String ?? ""
            content += "\n\n---\n"
            for ann in annotations {
                if let urlCitation = ann["url_citation"] as? [String: Any] {
                    let title = urlCitation["title"] as? String ?? "Link"
                    let url = urlCitation["url"] as? String ?? ""
                    content += "- [\(title)](\(url))\n"
                }
            }
            message["content"] = content
            message.removeValue(forKey: "annotations")
            choices[i]["message"] = message
        }
    }
    root["choices"] = choices
    return (try? JSONSerialization.data(withJSONObject: root)) ?? data
}

// MARK: - Main

// Parse CLI arguments
var jsonPath: String? = nil
var watchPath: String? = nil

let args = CommandLine.arguments
var i = 1
while i < args.count {
    switch args[i] {
    case "-j", "--json":
        if i + 1 < args.count {
            jsonPath = args[i + 1]
            i += 2
        } else {
            exitWithError("Missing path after -j/--json")
        }
    case "-w", "--watch":
        if i + 1 < args.count {
            watchPath = args[i + 1]
            i += 2
        } else {
            exitWithError("Missing path after -w/--watch")
        }
    default:
        // For backward compatibility, treat lone argument as json path
        if jsonPath == nil && !args[i].hasPrefix("-") {
            jsonPath = args[i]
            i += 1
        } else {
            exitWithError("Unknown argument: \(args[i])")
        }
    }
}

// Check that at least one feature is enabled
if jsonPath == nil && watchPath == nil {
    exitWithError("At least one feature must be enabled. Use -j for server or -w for folder watching.")
}

// Server setup - only if jsonPath is provided
var server: HttpServer? = nil
var proxies: [String: [String: Any]] = [:]
var fileWatcher: FileChangeWatcher? = nil

if let jsonPath = jsonPath {
    // Validate JSON configuration file exists
    guard FileManager.default.fileExists(atPath: jsonPath) else {
        exitWithError("Configuration file not found: \(jsonPath)")
    }
    
    // Load proxies from the JSON path
    proxies = loadProxies(from: jsonPath)
    
    // Create file watcher to reload configuration when it changes
    fileWatcher = FileChangeWatcher(filePath: jsonPath) {
        print("proxies.json changed, reloading configuration...")
        proxies = loadProxies(from: jsonPath)
        print("Configuration reloaded successfully - changes will apply to new requests")
    }
    
    // Start HTTP server
    server = HttpServer()
    let port: in_port_t = 11434
    guard isPortAvailable(port) else {
        exitWithError("Port \(port) is already in use.")
    }
    
    // Set up server routes
    setupServerRoutes(server: server!)
    
    print("Proxy server running on http://localhost:\(port)")
    try! server!.start(port, forceIPv4: true)
}

// Initialize the recordings folder watcher if path provided
var recordingsWatcher: RecordingsFolderWatcher? = nil
if let watchPath = watchPath {
    // Validate the watch folder exists
    guard FileManager.default.fileExists(atPath: watchPath) else {
        exitWithError("Watch folder not found: \(watchPath)")
    }
    
    recordingsWatcher = RecordingsFolderWatcher(basePath: watchPath)
    if recordingsWatcher == nil {
        print("Warning: Failed to initialize recordings folder watcher")
    } else {
        print("Watching recordings folder at \(watchPath)/recordings")
    }
}

// Function to set up server routes
func setupServerRoutes(server: HttpServer) {
    server["/v1/chat/completions"] = { req in
        // Access the proxies through a function call to ensure it's always up-to-date
        let currentProxies = getProxies()
        
        guard req.method == "POST" else { return .notFound }
        let rawBody = req.body
        
        guard !rawBody.isEmpty else { return .badRequest(.text("Missing body")) }
        guard let jsonBody = try? JSONSerialization.jsonObject(with: Data(rawBody), options: []) as? [String: Any] else {
            return .badRequest(.text("Malformed JSON"))
        }
        guard var model = jsonBody["model"] as? String else {
            return .badRequest(.text("Missing model"))
        }
        
        // If doesn't start with mw|, forward unchanged to original endpoint (Ollama)
        if !model.hasPrefix("mw|") {
            // Forward request to original endpoint (e.g., Ollama)
            let ollamaURL = "http://localhost:11435/v1/chat/completions"
            
            // I don't want to strip all the original header
            var headers = req.headers
            
            if let ua = req.headers["user-agent"] { headers["User-Agent"] = ua }
            let outgoingReq = buildRequest(url: ollamaURL, headers: headers, json: jsonBody)
            
            return HttpResponse.raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                let semaphore = DispatchSemaphore(value: 0)
                let delegate = ProxyStreamDelegate(writer: writer, semaphore: semaphore)
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                let task = session.dataTask(with: outgoingReq)
                task.resume()
                semaphore.wait() // Wait until the streaming is finished
            }
        }
        
        // If starts with mw|, strip and process
        model.removeFirst("mw|".count)
        guard let proxyRule = currentProxies[model] else {
            return .badRequest(.text("No proxy rule for model \(model)"))
        }
        guard let targetURL = proxyRule["url"] as? String else {
            return .badRequest(.text("No url in proxies.json for \(model)"))
        }

        // Prepare headers and body (as already done above)
        var headers = req.headers
        headers.removeValue(forKey: "Content-Length")
        headers.removeValue(forKey: "content-length")
        headers.removeValue(forKey: "Host")
        headers.removeValue(forKey: "host")
        headers.removeValue(forKey: "connection")
        headers.removeValue(forKey: "Connection")
        headers.removeValue(forKey: "User-Agent")
        headers.removeValue(forKey: "user-agent")

        var bodyMods = [String: Any]()
        var newBody = jsonBody
        newBody["model"] = model

        for (k, v) in proxyRule {
            if k == "url" { continue }
            if k == "key", let token = v as? String {
                headers["Authorization"] = "Bearer \(token)"
            } else if k == "model" {
                newBody["model"] = v
            } else if k.hasPrefix("-H "), let val = v as? String {
                let hk = String(k.dropFirst(3))
                headers[hk] = val
            } else if k.hasPrefix("-d ") {
                let bk = String(k.dropFirst(3))
                bodyMods[bk] = v
            }
        }

        newBody = mergeBody(original: newBody, modifications: bodyMods)

        // Special handling for OpenRouter
        if targetURL.contains("openrouter.ai/api/v1/chat/completions") {
            // Force set these headers for OpenRouter, overriding any user settings
            headers["HTTP-Referer"] = "https://by.afadingthought.com/macrowhisper"
            headers["X-Title"] = "Macrowhisper"
        }
        
        let streamDisabled = (proxyRule["-d stream"] as? Bool == false)
        let outgoingReq = buildRequest(url: targetURL, headers: headers, json: newBody)

        if streamDisabled {
            return HttpResponse.raw(200, "OK", ["Content-Type": "text/event-stream"]) { writer in
                let session = URLSession(configuration: .default)
                let semaphore = DispatchSemaphore(value: 0)
                session.dataTask(with: outgoingReq) { data, _, _ in
                    if let data = data {
                        let processed = mergeAnnotationsIntoContent(data)
                        // Parse response
                        if let root = try? JSONSerialization.jsonObject(with: processed) as? [String: Any],
                           let choices = root["choices"] as? [[String: Any]],
                           let message = choices.first?["message"] as? [String: Any],
                           let content = message["content"] as? String {
                            // Stream word by word as OpenAI delta-style
                            var _ = ""
                            // Assume 'content' is your string to stream
                            let deltaChunk: [String: Any] = [
                                "id": root["id"] ?? "chatcmpl-xxx",
                                "object": "chat.completion.chunk",
                                "choices": [[
                                    "delta": ["content": content],
                                    "index": 0,
                                    "finish_reason": nil
                                ]],
                                "model": root["model"] ?? "unknown"
                            ]

                            if let chunkData = try? JSONSerialization.data(withJSONObject: deltaChunk),
                               let chunkString = String(data: chunkData, encoding: .utf8) {
                                let sse = "data: \(chunkString)\n\n"
                                try? writer.write(sse.data(using: .utf8)!)
                                // No sleep, just send it all at once
                            }

                            let done = "data: [DONE]\n\n"
                            try? writer.write(done.data(using: .utf8)!)
                        } else {
                            // If can't parse, fallback, but this may crash some clients
                            let chunk = "data: \(String(data: processed, encoding: .utf8) ?? "")\n\n"
                            let done = "data: [DONE]\n\n"
                            try? writer.write(chunk.data(using: .utf8)!)
                            try? writer.write(done.data(using: .utf8)!)
                        }
                    }
                    semaphore.signal()
                }.resume()
                semaphore.wait()
            }
        } else {
            // Usual streaming passthrough
            return HttpResponse.raw(200, "OK", ["Content-Type": "application/json"]) { writer in
                let semaphore = DispatchSemaphore(value: 0)
                let delegate = ProxyStreamDelegate(writer: writer, semaphore: semaphore)
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                let task = session.dataTask(with: outgoingReq)
                task.resume()
                semaphore.wait()
            }
        }
    }

    server["/api/tags"] = { req in
        // First try to get the actual tags from Ollama
        var tagsList: [[String: Any]] = []
        
        // Try to fetch from Ollama
        let ollamaURL = "http://localhost:11435/api/tags"
        var request = URLRequest(url: URL(string: ollamaURL)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 0.5 // Short timeout of 0.5 seconds
        
        // Create a special version that doesn't crash on network errors
        func safeNetworkRequest(_ request: URLRequest) -> (Data?, URLResponse?, Error?) {
            let semaphore = DispatchSemaphore(value: 0)
            var resultData: Data? = nil
            var resultResponse: URLResponse? = nil
            var resultError: Error? = nil
            
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = request.timeoutInterval
            let session = URLSession(configuration: config)
            
            session.dataTask(with: request) { data, response, error in
                resultData = data
                resultResponse = response
                resultError = error
                semaphore.signal()
            }.resume()
            
            _ = semaphore.wait(timeout: .now() + request.timeoutInterval + 0.1)
            return (resultData, resultResponse, resultError)
        }
        
        // Use our safe network request function
        let (data, response, error) = safeNetworkRequest(request)
        
        if let error = error {
            print("Error connecting to Ollama: \(error.localizedDescription)")
            // Continue with empty tagsList - Ollama is probably not running
        } else if let data = data,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 {
            // Parse the response as before
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["models"] as? [[String: Any]] {
                    tagsList = models
                    print("Successfully retrieved \(models.count) models from Ollama")
                }
            } catch {
                print("Error parsing Ollama response: \(error)")
            }
        } else {
            print("Failed to get models from Ollama: status code \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        
        // Add a default placeholder model if Ollama/LMStudio is running but returned no models
        if tagsList.isEmpty && error == nil && (response as? HTTPURLResponse)?.statusCode == 200 {
            let defaultModel: [String: Any] = [
                "name": "-",
                "modified_at": ISO8601DateFormatter().string(from: Date()),
                "size": 0,
                "digest": "default-model",
                "details": [
                    "format": "unknown",
                    "family": "default",
                    "parameter_size": "N/A",
                    "quantization_level": "none"
                ]
            ]
            tagsList.append(defaultModel)
        }
        
        // For each proxy in your proxies dictionary, add an entry
        for (proxyName, _) in getProxies() {
            let customProxyModel: [String: Any] = [
                "name": "mw|\(proxyName)",
                "modified_at": ISO8601DateFormatter().string(from: Date()),
                "size": 0,
                "digest": "mw-\(proxyName)",
                "details": [
                    "format": "proxy",
                    "family": "proxy",
                    "parameter_size": "N/A",
                    "quantization_level": "none"
                ]
            ]
            tagsList.append(customProxyModel)
        }
        
        // Return the combined list
        let modelResponse: [String: Any] = ["models": tagsList]
        let jsonData = try! JSONSerialization.data(withJSONObject: modelResponse)
        
        return .raw(200, "OK", ["Content-Type": "application/json"]) { writer in
            try? writer.write(jsonData)
        }
    }


    server.notFoundHandler = { req in
        // Forward everything to Ollama, preserving path and method
        let targetURL = "http://localhost:11435\(req.path)"
        let headers = req.headers
        var request = URLRequest(url: URL(string: targetURL)!)
        request.httpMethod = req.method
        for (k, v) in headers { request.addValue(v, forHTTPHeaderField: k) }
        if !req.body.isEmpty {
            request.httpBody = Data(req.body)
        }

        return HttpResponse.raw(200, "OK", headers) { writer in
            let semaphore = DispatchSemaphore(value: 0)
            let delegate = ProxyStreamDelegate(writer: writer, semaphore: semaphore)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: request)
            task.resume()
            semaphore.wait()
        }
    }
}

// Add a helper function to access the proxies
func getProxies() -> [String: [String: Any]] {
    return proxies
}

// Keep the main thread running
RunLoop.main.run()

// MARK: - URLSession sync helper
// Change the URLSession extension to:
extension URLSession {
    func synchronousDataTask(with request: URLRequest) -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        
        // Use an array for thread safety
        var resultData: Data? = nil
        var resultResponse: URLResponse? = nil
        var resultError: Error? = nil
        
        dataTask(with: request) { data, response, error in
            // Capture on the main thread to avoid concurrency issues
            DispatchQueue.main.async {
                resultData = data
                resultResponse = response
                resultError = error
                semaphore.signal()
            }
        }.resume()
        
        semaphore.wait()
        
        if let e = resultError { exitWithError("Network error: \(e.localizedDescription)") }
        return (resultData ?? Data(), resultResponse!)
    }
}
