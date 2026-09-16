import Foundation
import Darwin

private struct EditorBootstrapResponse: Decodable {
    let address: String
    let bootstrapURL: String
    let expiresAt: TimeInterval
}

private struct EditorSessionResponse: Decodable {
    let sessionToken: String
    let expiresAt: TimeInterval
}

private struct EditorEditRequest: Encodable {
    let expectedRevision: ConfigurationRevision
    let edits: [ConfigurationEdit]
}

private struct EditorFolderPickerResponse: Decodable {
    let operationID: String
    let status: String
    let path: String?
}

private struct EditorConfigurationRevealResponse: Decodable {
    let success: Bool
}

private struct EditorAPIErrorResponse: Decodable {
    let code: String
    let message: String
}

private final class ControlledDirectoryPicker: EditorDirectoryPicking {
    private let lock = NSLock()
    private var completion: ((Result<String?, Error>) -> Void)?
    private(set) var purposes: [EditorFolderPickerPurpose] = []

    func chooseDirectory(
        purpose: EditorFolderPickerPurpose,
        completion: @escaping (Result<String?, Error>) -> Void
    ) {
        lock.lock()
        purposes.append(purpose)
        self.completion = completion
        lock.unlock()
    }

    func complete(path: String?) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(.success(path))
    }
}

private final class ControlledConfigurationRevealer: EditorConfigurationRevealing {
    private let lock = NSLock()
    private(set) var paths: [String] = []
    private var shouldFail = false

    func revealConfiguration(at path: String) throws {
        lock.lock()
        paths.append(path)
        let fail = shouldFail
        lock.unlock()
        if fail {
            throw NSError(domain: "EditorServerRegression", code: 14)
        }
    }

    func setFailure(_ enabled: Bool) {
        lock.lock()
        shouldFail = enabled
        lock.unlock()
    }
}

private struct HTTPTestResponse {
    let status: Int
    let body: Data
}

private func fail(_ label: String, details: String = "") -> Never {
    let suffix = details.isEmpty ? "" : "\n\(details)"
    fputs("FAIL: \(label)\(suffix)\n", stderr)
    exit(1)
}

private func assertTrue(_ condition: Bool, _ label: String, details: String = "") {
    guard condition else { fail(label, details: details) }
    print("PASS: \(label)")
}

private func makeTemporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("macrowhisper-editor-server-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func write(_ contents: String, to url: URL) throws {
    try Data(contents.utf8).write(to: url)
}

private func sendAll(_ data: Data, to socket: Int32) throws {
    try data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let written = Darwin.send(socket, baseAddress.advanced(by: offset), data.count - offset, 0)
            guard written > 0 else { throw NSError(domain: "EditorServerRegression", code: 1) }
            offset += written
        }
    }
}

private func request(
    port: UInt16,
    method: String,
    path: String,
    headers: [String: String] = [:],
    body: Data = Data(),
    declaredContentLength: Int? = nil
) throws -> HTTPTestResponse {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socket >= 0 else { throw NSError(domain: "EditorServerRegression", code: 2) }
    defer { close(socket) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = withUnsafePointer(to: &timeout) {
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    var loopback = in_addr()
    guard inet_pton(AF_INET, "127.0.0.1", &loopback) == 1 else {
        throw NSError(domain: "EditorServerRegression", code: 3)
    }
    address.sin_addr = loopback
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { throw NSError(domain: "EditorServerRegression", code: 4) }

    let suppliesHost = headers.keys.contains { $0.caseInsensitiveCompare("Host") == .orderedSame }
    var requestText = "\(method) \(path) HTTP/1.1\r\n"
    if !suppliesHost {
        requestText += "Host: 127.0.0.1:\(port)\r\n"
    }
    requestText += "Connection: close\r\n"
    for (name, value) in headers {
        requestText += "\(name): \(value)\r\n"
    }
    requestText += "Content-Length: \(declaredContentLength ?? body.count)\r\n\r\n"
    var requestData = Data(requestText.utf8)
    requestData.append(body)
    try sendAll(requestData, to: socket)

    var responseData = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.recv(socket, &chunk, chunk.count, 0)
        if count == 0 { break }
        guard count > 0 else {
            throw NSError(domain: "EditorServerRegression", code: 5, userInfo: [NSLocalizedDescriptionKey: "recv failed with errno \(errno)"])
        }
        responseData.append(contentsOf: chunk.prefix(count))
    }
    guard let separator = responseData.range(of: Data([13, 10, 13, 10])),
          let headerText = String(data: responseData.prefix(upTo: separator.lowerBound), encoding: .utf8) else {
        throw NSError(domain: "EditorServerRegression", code: 6)
    }
    let statusLine = headerText.components(separatedBy: "\r\n").first ?? ""
    guard let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") else {
        throw NSError(domain: "EditorServerRegression", code: 7)
    }
    return HTTPTestResponse(status: status, body: Data(responseData.suffix(from: separator.upperBound)))
}

private func decode<T: Decodable>(_ type: T.Type, _ response: HTTPTestResponse) throws -> T {
    try JSONDecoder().decode(type, from: response.body)
}

private func bootstrapToken(from url: String) -> String? {
    guard let fragment = URL(string: url)?.fragment,
          fragment.hasPrefix("bootstrap=") else { return nil }
    return String(fragment.dropFirst("bootstrap=".count))
}

private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

private func runEditorServerRegression() throws {
    let developmentEditorRoot = EditorResourceResolver.developmentEditorRoot(
        sourceFilePath: "/workspace/macrowhisper-editor/src/macrowhisper/Networking/EditorServer.swift"
    )
    assertTrue(
        developmentEditorRoot.path == "/workspace/macrowhisper-editor/.build/editor",
        "development editor resources resolve from the repository root"
    )

    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let configPath = root.appendingPathComponent("config.json")
    try write(
        """
        {
          "configVersion": 2,
          "defaults": { "watch": "/tmp/macrowhisper-editor-server-watch" },
          "inserts": { "paste": { "action": ".autoPaste" } }
        }
        """,
        to: configPath
    )
    let resourceRoot = root.appendingPathComponent("editor", isDirectory: true)
    let assetsRoot = resourceRoot.appendingPathComponent("assets", isDirectory: true)
    try FileManager.default.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
    try write("<!doctype html><title>editor</title>", to: resourceRoot.appendingPathComponent("index.html"))
    try write("console.log('editor')", to: assetsRoot.appendingPathComponent("app.js"))
    let outside = root.appendingPathComponent("outside.txt")
    try write("outside", to: outside)
    try FileManager.default.createSymbolicLink(
        at: assetsRoot.appendingPathComponent("leak.js"),
        withDestinationURL: outside
    )

    let manager = ConfigurationManager(configPath: configPath.path)
    let directoryPicker = ControlledDirectoryPicker()
    let configurationRevealer = ControlledConfigurationRevealer()
    let server = EditorServer(
        configManager: manager,
        resourceResolver: EditorResourceResolver(roots: [resourceRoot]),
        preferredPort: 0,
        directoryPicker: directoryPicker,
        configurationRevealer: configurationRevealer
    )
    try server.start()
    defer { server.stop() }
    guard let port = server.port else { throw NSError(domain: "EditorServerRegression", code: 8) }
    assertTrue(server.cleanAddress == "http://127.0.0.1:\(port)/", "server binds explicit loopback address")

    guard let bootstrapJSON = server.issueBootstrapPayloadJSON(),
          let bootstrapData = bootstrapJSON.data(using: .utf8) else {
        throw NSError(domain: "EditorServerRegression", code: 9)
    }
    let bootstrap = try JSONDecoder().decode(EditorBootstrapResponse.self, from: bootstrapData)
    guard let token = bootstrapToken(from: bootstrap.bootstrapURL) else {
        throw NSError(domain: "EditorServerRegression", code: 10)
    }
    assertTrue(bootstrap.address == "http://127.0.0.1:\(port)/", "bootstrap keeps credential URL separate from clean address")
    assertTrue(bootstrap.expiresAt > Date().timeIntervalSince1970, "bootstrap has an expiry")

    let sessionResponse = try request(
        port: port,
        method: "POST",
        path: "/api/session",
        headers: ["X-Macrowhisper-Bootstrap": token]
    )
    assertTrue(sessionResponse.status == 200, "valid bootstrap token creates a session")
    let session = try decode(EditorSessionResponse.self, sessionResponse)
    assertTrue(session.expiresAt > Date().timeIntervalSince1970, "session has an expiry")

    let replayResponse = try request(
        port: port,
        method: "POST",
        path: "/api/session",
        headers: ["X-Macrowhisper-Bootstrap": token]
    )
    assertTrue(replayResponse.status == 401, "bootstrap token is single-use")

    let unauthenticated = try request(port: port, method: "GET", path: "/api/config")
    assertTrue(unauthenticated.status == 401, "configuration reads require bearer authentication")

    let authorization = "Bearer \(session.sessionToken)"
    let snapshotResponse = try request(
        port: port,
        method: "GET",
        path: "/api/config",
        headers: ["Authorization": authorization]
    )
    assertTrue(snapshotResponse.status == 200, "authenticated snapshot succeeds")
    let snapshot = try decode(ConfigurationSnapshot.self, snapshotResponse)
    assertTrue(snapshot.diskIsValid, "snapshot carries valid disk state")

    let revealHeaders = [
        "Authorization": authorization,
        "Origin": "http://127.0.0.1:\(port)"
    ]
    let unauthenticatedReveal = try request(
        port: port,
        method: "POST",
        path: "/api/config/reveal",
        headers: ["Origin": "http://127.0.0.1:\(port)"]
    )
    assertTrue(unauthenticatedReveal.status == 401, "configuration reveal requires bearer authentication")
    let foreignReveal = try request(
        port: port,
        method: "POST",
        path: "/api/config/reveal",
        headers: ["Authorization": authorization, "Origin": "http://example.invalid"]
    )
    assertTrue(foreignReveal.status == 403, "configuration reveal rejects a foreign origin")
    let clientPathReveal = try request(
        port: port,
        method: "POST",
        path: "/api/config/reveal",
        headers: revealHeaders,
        body: Data("{\"path\":\"/tmp/client-supplied-path\"}".utf8)
    )
    assertTrue(clientPathReveal.status == 400, "configuration reveal rejects client-supplied paths")
    assertTrue(configurationRevealer.paths.isEmpty, "rejected reveal does not invoke Finder")
    let revealResponse = try request(
        port: port,
        method: "POST",
        path: "/api/config/reveal",
        headers: revealHeaders
    )
    assertTrue(revealResponse.status == 200, "authenticated same-origin configuration reveal succeeds")
    let revealPayload = try decode(EditorConfigurationRevealResponse.self, revealResponse)
    assertTrue(revealPayload.success, "configuration reveal returns a stable success payload")
    assertTrue(configurationRevealer.paths == [configPath.path], "configuration reveal uses the manager's current selected path")
    configurationRevealer.setFailure(true)
    let failedReveal = try request(
        port: port,
        method: "POST",
        path: "/api/config/reveal",
        headers: revealHeaders
    )
    assertTrue(failedReveal.status == 500, "Finder failure returns an internal error")
    let revealError = try decode(EditorAPIErrorResponse.self, failedReveal)
    assertTrue(revealError.code == "revealFailed", "Finder failure uses a stable error code")
    assertTrue(!revealError.message.isEmpty, "Finder failure returns an error message")

    let pickerHeaders = [
        "Authorization": authorization,
        "Origin": "http://127.0.0.1:\(port)",
        "Content-Type": "application/json"
    ]
    let pickerBody = Data("{\"purpose\":\"watch\"}".utf8)
    let unauthenticatedPicker = try request(
        port: port,
        method: "POST",
        path: "/api/folder-picker",
        headers: ["Origin": "http://127.0.0.1:\(port)", "Content-Type": "application/json"],
        body: pickerBody
    )
    assertTrue(unauthenticatedPicker.status == 401, "folder picker requires bearer authentication")
    let foreignPicker = try request(
        port: port,
        method: "POST",
        path: "/api/folder-picker",
        headers: ["Authorization": authorization, "Origin": "http://example.invalid", "Content-Type": "application/json"],
        body: pickerBody
    )
    assertTrue(foreignPicker.status == 403, "folder picker rejects a foreign origin")
    let malformedPicker = try request(
        port: port,
        method: "POST",
        path: "/api/folder-picker",
        headers: pickerHeaders,
        body: Data("{\"purpose\":\"file\"}".utf8)
    )
    assertTrue(malformedPicker.status == 400, "folder picker rejects unsupported purposes")

    let pickerStart = try request(
        port: port,
        method: "POST",
        path: "/api/folder-picker",
        headers: pickerHeaders,
        body: pickerBody
    )
    assertTrue(pickerStart.status == 202, "folder picker starts without blocking the HTTP worker")
    let pendingPicker = try decode(EditorFolderPickerResponse.self, pickerStart)
    assertTrue(pendingPicker.status == "pending", "folder picker start returns a pending operation")
    assertTrue(directoryPicker.purposes == [.watch], "folder picker receives the requested purpose")
    let busyPicker = try request(
        port: port,
        method: "POST",
        path: "/api/folder-picker",
        headers: pickerHeaders,
        body: Data("{\"purpose\":\"moveTo\"}".utf8)
    )
    assertTrue(busyPicker.status == 409, "only one native folder picker can be active")
    let pendingStatus = try request(
        port: port,
        method: "GET",
        path: "/api/folder-picker/\(pendingPicker.operationID)",
        headers: ["Authorization": authorization]
    )
    assertTrue(try decode(EditorFolderPickerResponse.self, pendingStatus).status == "pending", "folder picker status can be polled")

    directoryPicker.complete(path: "~/Documents/superwhisper")
    let selectedStatus = try request(
        port: port,
        method: "GET",
        path: "/api/folder-picker/\(pendingPicker.operationID)",
        headers: ["Authorization": authorization]
    )
    let selectedPicker = try decode(EditorFolderPickerResponse.self, selectedStatus)
    assertTrue(selectedPicker.status == "selected" && selectedPicker.path == "~/Documents/superwhisper", "selected folder path is returned without filesystem access")

    let cancelledStart = try request(
        port: port,
        method: "POST",
        path: "/api/folder-picker",
        headers: pickerHeaders,
        body: Data("{\"purpose\":\"moveTo\"}".utf8)
    )
    let cancelledPicker = try decode(EditorFolderPickerResponse.self, cancelledStart)
    directoryPicker.complete(path: nil)
    let cancelledStatus = try request(
        port: port,
        method: "GET",
        path: "/api/folder-picker/\(cancelledPicker.operationID)",
        headers: ["Authorization": authorization]
    )
    assertTrue(try decode(EditorFolderPickerResponse.self, cancelledStatus).status == "cancelled", "cancelling the native picker is not an error")

    let editRequest = try encoded(EditorEditRequest(
        expectedRevision: snapshot.revision,
        edits: [ConfigurationEdit(
            path: ["defaults", "actionDelay"],
            operation: .set,
            value: .number(1.25)
        )]
    ))
    let commitResponse = try request(
        port: port,
        method: "POST",
        path: "/api/config/edits",
        headers: [
            "Authorization": authorization,
            "Origin": "http://127.0.0.1:\(port)",
            "Content-Type": "application/json"
        ],
        body: editRequest
    )
    assertTrue(commitResponse.status == 200, "authenticated JSON edit commits")
    let committed = try decode(ConfigurationSnapshot.self, commitResponse)
    assertTrue(committed.config.defaults.actionDelay == 1.25, "edit response contains committed configuration")

    let staleResponse = try request(
        port: port,
        method: "POST",
        path: "/api/config/edits",
        headers: [
            "Authorization": authorization,
            "Origin": "http://127.0.0.1:\(port)",
            "Content-Type": "application/json"
        ],
        body: editRequest
    )
    assertTrue(staleResponse.status == 409, "stale revision returns conflict")
    let staleError = try decode(ConfigurationTransactionError.self, staleResponse)
    assertTrue(staleError.code == .staleRevision, "stale response preserves transaction error code")

    let foreignOriginResponse = try request(
        port: port,
        method: "POST",
        path: "/api/config/edits",
        headers: [
            "Authorization": authorization,
            "Origin": "http://example.invalid",
            "Content-Type": "application/json"
        ],
        body: editRequest
    )
    assertTrue(foreignOriginResponse.status == 403, "foreign mutation origin is rejected")

    let missingOriginResponse = try request(
        port: port,
        method: "POST",
        path: "/api/config/edits",
        headers: [
            "Authorization": authorization,
            "Content-Type": "application/json"
        ],
        body: editRequest
    )
    assertTrue(missingOriginResponse.status == 403, "mutation without an Origin is rejected")

    let badContentTypeResponse = try request(
        port: port,
        method: "POST",
        path: "/api/config/edits",
        headers: [
            "Authorization": authorization,
            "Origin": "http://127.0.0.1:\(port)",
            "Content-Type": "application/x-www-form-urlencoded"
        ],
        body: editRequest
    )
    assertTrue(badContentTypeResponse.status == 415, "non-JSON mutation content type is rejected")

    let badHostResponse = try request(
        port: port,
        method: "GET",
        path: "/api/config",
        headers: ["Host": "127.0.0.1:1", "Authorization": authorization]
    )
    assertTrue(badHostResponse.status == 400, "unexpected Host is rejected")

    let preflightResponse = try request(port: port, method: "OPTIONS", path: "/api/config")
    assertTrue(preflightResponse.status == 405, "cross-origin preflight is not enabled")

    let oversizedResponse = try request(
        port: port,
        method: "POST",
        path: "/api/session",
        headers: ["Content-Type": "application/json"],
        declaredContentLength: EditorServer.maxBodyBytes + 1
    )
    assertTrue(oversizedResponse.status == 413, "oversized request bodies are rejected before decoding")

    let traversalResponse = try request(
        port: port,
        method: "GET",
        path: "/assets/../outside.txt"
    )
    assertTrue(traversalResponse.status == 404, "path traversal cannot read outside resources")
    let symlinkResponse = try request(port: port, method: "GET", path: "/assets/leak.js")
    assertTrue(symlinkResponse.status == 404, "resource symlink escape is rejected")
    let indexResponse = try request(port: port, method: "GET", path: "/")
    assertTrue(indexResponse.status == 200, "static index resource is served")
    let assetResponse = try request(port: port, method: "GET", path: "/assets/app.js")
    assertTrue(assetResponse.status == 200, "static asset is served from the packaged assets directory")
    assertTrue(
        String(data: assetResponse.body, encoding: .utf8) == "console.log('editor')",
        "static asset response preserves its contents"
    )
    let missingAssetResponse = try request(port: port, method: "GET", path: "/assets/missing.js")
    assertTrue(missingAssetResponse.status == 404, "missing static resources fail clearly")

    server.stop()
    Thread.sleep(forTimeInterval: 0.05)
    try server.start()
    guard let restartedPort = server.port else { throw NSError(domain: "EditorServerRegression", code: 11) }
    let invalidatedSession = try request(
        port: restartedPort,
        method: "GET",
        path: "/api/config",
        headers: ["Authorization": authorization]
    )
    assertTrue(invalidatedSession.status == 401, "server restart invalidates bearer sessions")

    let shortLivedServer = EditorServer(
        configManager: manager,
        resourceResolver: EditorResourceResolver(roots: [resourceRoot]),
        preferredPort: 0,
        bootstrapLifetime: 0.01,
        sessionLifetime: 0.01
    )
    try shortLivedServer.start()
    defer { shortLivedServer.stop() }
    guard let shortPort = shortLivedServer.port,
          let shortBootstrapJSON = shortLivedServer.issueBootstrapPayloadJSON(),
          let shortBootstrapData = shortBootstrapJSON.data(using: .utf8) else {
        throw NSError(domain: "EditorServerRegression", code: 12)
    }
    let shortBootstrap = try JSONDecoder().decode(EditorBootstrapResponse.self, from: shortBootstrapData)
    guard let shortToken = bootstrapToken(from: shortBootstrap.bootstrapURL) else {
        throw NSError(domain: "EditorServerRegression", code: 13)
    }
    Thread.sleep(forTimeInterval: 0.03)
    let expiredResponse = try request(
        port: shortPort,
        method: "POST",
        path: "/api/session",
        headers: ["X-Macrowhisper-Bootstrap": shortToken]
    )
    assertTrue(expiredResponse.status == 401, "expired bootstrap token is rejected")
}

@main
struct EditorServerRegressionRunner {
    static func main() {
        do {
            try runEditorServerRegression()
        } catch {
            fail("editor server regression", details: error.localizedDescription)
        }
    }
}
