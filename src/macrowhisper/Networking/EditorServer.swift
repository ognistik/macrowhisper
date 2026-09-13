import Foundation
import Dispatch
import Darwin

/// The resource root used by the installed editor.  The editor is deliberately
/// resolved from the executable's Homebrew-style share directory or from the
/// repository's build output; it is never resolved relative to an arbitrary
/// daemon working directory.
final class EditorResourceResolver {
    struct Resource {
        let data: Data
        let contentType: String
    }

    private let roots: [URL]

    /// Initializer used by focused server tests and by callers that have an
    /// explicitly validated installation root.
    init(roots: [URL]) {
        self.roots = roots.map { $0.standardizedFileURL }
    }

    /// Resolve only the two supported production locations:
    /// `<prefix>/share/macrowhisper/editor` and the repository's
    /// `.build/editor` directory.  In particular, do not add the current
    /// working directory here: a foreign CWD must not be able to replace the
    /// installed editor bundle.
    convenience init(executablePath: String? = nil) {
        var roots: [URL] = []

        let candidateExecutablePath = executablePath
            ?? Bundle.main.executableURL?.path
            ?? CommandLine.arguments.first
        if let candidateExecutablePath, candidateExecutablePath.hasPrefix("/") {
            let originalExecutable = URL(fileURLWithPath: candidateExecutablePath)
            let resolvedExecutable = originalExecutable.resolvingSymlinksInPath()
            // Keep both paths: Homebrew may link the executable into `bin`
            // while retaining shared resources in either the linked prefix or
            // the resolved keg prefix, depending on how the formula was
            // installed.
            for executable in [originalExecutable, resolvedExecutable] {
                let prefix = executable.deletingLastPathComponent().deletingLastPathComponent()
                roots.append(prefix.appendingPathComponent("share/macrowhisper/editor", isDirectory: true))
            }
            // Xcode's command-line product is a development artifact rather
            // than a Homebrew prefix. Its build phase copies matching assets
            // next to the executable; accept that explicit .build location
            // without ever falling back to the process CWD.
            let executableDirectory = resolvedExecutable.deletingLastPathComponent()
            if executableDirectory.path.contains("/.build/") {
                roots.append(executableDirectory.appendingPathComponent("editor", isDirectory: true))
            }
        }

        // `#filePath` is an explicit repository source location.  This path
        // is used only for developer builds whose generated Vite output lives
        // at the documented repository `.build/editor` location.
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = sourceFile
            .deletingLastPathComponent() // Networking
            .deletingLastPathComponent() // macrowhisper
            .deletingLastPathComponent() // src
        roots.append(repositoryRoot.appendingPathComponent(".build/editor", isDirectory: true))

        self.init(roots: roots)
    }

    func resource(for requestPath: String) -> Resource? {
        guard let decodedPath = requestPath.removingPercentEncoding,
              !decodedPath.contains("\0"),
              decodedPath.hasPrefix("/") else {
            return nil
        }

        let relativePath: String
        if decodedPath == "/" {
            relativePath = "index.html"
        } else if decodedPath.hasPrefix("/assets/") {
            relativePath = String(decodedPath.dropFirst())
            guard relativePath != "assets/" else { return nil }
        } else {
            return nil
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }

        for root in roots {
            guard let fileURL = safeFileURL(relativePath: relativePath, under: root),
                  let data = try? Data(contentsOf: fileURL),
                  !data.isEmpty || isRegularFile(fileURL) else {
                continue
            }
            return Resource(data: data, contentType: Self.contentType(for: fileURL.pathExtension))
        }
        return nil
    }

    private func safeFileURL(relativePath: String, under root: URL) -> URL? {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let candidate = canonicalRoot
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL

        let rootPath = canonicalRoot.path.hasSuffix("/")
            ? canonicalRoot.path
            : canonicalRoot.path + "/"
        guard candidate.path == canonicalRoot.path || candidate.path.hasPrefix(rootPath) else {
            return nil
        }
        guard isRegularFile(candidate) else { return nil }
        return candidate
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return false
        }
        return true
    }

    private static func contentType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html":
            return "text/html; charset=utf-8"
        case "css":
            return "text/css; charset=utf-8"
        case "js", "mjs":
            return "text/javascript; charset=utf-8"
        case "json":
            return "application/json; charset=utf-8"
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "woff":
            return "font/woff"
        case "woff2":
            return "font/woff2"
        default:
            return "application/octet-stream"
        }
    }
}

/// A small, bounded HTTP server for the local editor.  Swifter remains the
/// daemon's HTTP dependency, but its parser allocates a declared request body
/// before dispatching to a route.  The editor therefore owns this deliberately
/// narrow parser so Content-Length can be rejected before body allocation.
final class EditorServer {
    static let defaultPort: UInt16 = 49172
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 256 * 1024
    static let requestTimeout: TimeInterval = 5
    static let bootstrapLifetime: TimeInterval = 30
    static let sessionLifetime: TimeInterval = 8 * 60 * 60

    private let configManager: ConfigurationManager
    private let resourceResolver: EditorResourceResolver
    private let preferredPort: UInt16
    private let bootstrapLifetime: TimeInterval
    private let sessionLifetime: TimeInterval
    private let acceptQueue = DispatchQueue(label: "com.macrowhisper.editor.accept", qos: .utility)
    // A single bounded connection worker keeps request ordering predictable
    // for the revision-based editor contract and avoids unbounded work when a
    // browser opens several tabs at once. Each connection is short-lived.
    private let connectionQueue = DispatchQueue(
        label: "com.macrowhisper.editor.connections",
        qos: .utility
    )
    private let stateLock = NSLock()
    private var acceptSource: DispatchSourceRead?
    private var serverSocket: Int32 = -1
    private var running = false
    private var boundPort: UInt16?
    private var bootstrapTokens: [String: Date] = [:]
    private var sessions: [String: Date] = [:]

    init(
        configManager: ConfigurationManager,
        resourceResolver: EditorResourceResolver = EditorResourceResolver(),
        preferredPort: UInt16 = EditorServer.defaultPort,
        bootstrapLifetime: TimeInterval = EditorServer.bootstrapLifetime,
        sessionLifetime: TimeInterval = EditorServer.sessionLifetime
    ) {
        self.configManager = configManager
        self.resourceResolver = resourceResolver
        self.preferredPort = preferredPort
        self.bootstrapLifetime = max(0.01, bootstrapLifetime)
        self.sessionLifetime = max(0.01, sessionLifetime)
    }

    var isRunning: Bool {
        stateLock.withLock { running }
    }

    var port: UInt16? {
        stateLock.withLock { boundPort }
    }

    /// The clean address contains no credential and is safe to display in a
    /// status message.  Bootstrap credentials are returned separately by the
    /// Unix-socket command and are placed in a URL fragment.
    var cleanAddress: String? {
        stateLock.withLock {
            guard let boundPort else { return nil }
            return "http://127.0.0.1:\(boundPort)/"
        }
    }

    /// Starts an IPv4 loopback listener.  The documented port is attempted
    /// first; if it is occupied or otherwise unavailable, port zero lets the
    /// OS choose another loopback port.  No exception escapes the daemon's
    /// startup path unless the fallback itself also fails.
    func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard !running else { return }
        let listening = try makeListeningSocket()
        let source = DispatchSource.makeReadSource(fileDescriptor: listening.fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        source.setCancelHandler {
            close(listening.fd)
        }

        serverSocket = listening.fd
        boundPort = listening.port
        bootstrapTokens.removeAll(keepingCapacity: false)
        sessions.removeAll(keepingCapacity: false)
        acceptSource = source
        running = true
        source.resume()

        logInfo("Editor server listening on 127.0.0.1:\(listening.port)")
    }

    /// Stops the listener and invalidates both bootstrap and bearer sessions.
    /// The latter is intentional even for an in-process restart: a token must
    /// never survive a server lifecycle boundary.
    func stop() {
        let source: DispatchSourceRead? = stateLock.withLock {
            running = false
            boundPort = nil
            bootstrapTokens.removeAll(keepingCapacity: false)
            sessions.removeAll(keepingCapacity: false)
            let source = acceptSource
            acceptSource = nil
            serverSocket = -1
            return source
        }
        source?.cancel()
    }

    /// Called only by the authenticated same-user Unix-socket command.  The
    /// returned object has a clean address and a separate fragment URL; the
    /// raw bootstrap token is never logged by this class.
    func issueBootstrapPayloadJSON() -> String? {
        let payload: BootstrapPayload? = stateLock.withLock {
            guard running, let boundPort else { return nil }
            let token = Self.randomToken()
            let expiresAt = Date().addingTimeInterval(bootstrapLifetime)
            bootstrapTokens[token] = expiresAt
            let address = "http://127.0.0.1:\(boundPort)/"
            return BootstrapPayload(
                address: address,
                bootstrapURL: "\(address)#bootstrap=\(token)",
                expiresAt: expiresAt.timeIntervalSince1970
            )
        }
        guard let payload else { return nil }
        do {
            return String(decoding: try Self.encodeJSON(payload), as: UTF8.self)
        } catch {
            return nil
        }
    }

    private struct BootstrapPayload: Codable {
        let address: String
        let bootstrapURL: String
        let expiresAt: TimeInterval
    }

    private struct SessionPayload: Codable {
        let sessionToken: String
        let expiresAt: TimeInterval
    }

    private struct EditRequest: Codable {
        let expectedRevision: ConfigurationRevision
        let edits: [ConfigurationEdit]
    }

    private struct APIErrorPayload: Codable {
        let code: String
        let message: String
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private struct HTTPResponse {
        let status: Int
        let reason: String
        let body: Data
        let contentType: String
    }

    private struct HTTPFailure: Error {
        let status: Int
        let reason: String
        let code: String
        let message: String
    }

    private struct ListeningSocket {
        let fd: Int32
        let port: UInt16
    }

    private func makeListeningSocket() throws -> ListeningSocket {
        do {
            return try makeListeningSocket(on: preferredPort)
        } catch {
            // Port fallback is deliberately explicit rather than silently
            // listening on all interfaces through a library default.
            return try makeListeningSocket(on: 0)
        }
    }

    private func makeListeningSocket(on requestedPort: UInt16) throws -> ListeningSocket {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw EditorServerError.socketCreation(errno)
        }
        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requestedPort.bigEndian
        var loopback = in_addr()
        guard inet_pton(AF_INET, "127.0.0.1", &loopback) == 1 else {
            close(fd)
            throw EditorServerError.invalidAddress
        }
        address.sin_addr = loopback

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let bindError = errno
            close(fd)
            throw EditorServerError.bindFailed(bindError)
        }
        guard Darwin.listen(fd, 16) == 0 else {
            let listenError = errno
            close(fd)
            throw EditorServerError.listenFailed(listenError)
        }
        // The accept source may receive one event for several queued clients.
        // Non-blocking mode lets the handler drain that queue and return to
        // Dispatch instead of blocking shutdown on a second accept call.
        let currentFlags = fcntl(fd, F_GETFL, 0)
        guard currentFlags >= 0,
              fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            let flagsError = errno
            close(fd)
            throw EditorServerError.listenFailed(flagsError)
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getsocknameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &boundLength)
            }
        }
        guard getsocknameResult == 0 else {
            let nameError = errno
            close(fd)
            throw EditorServerError.addressLookupFailed(nameError)
        }
        return ListeningSocket(fd: fd, port: UInt16(bigEndian: boundAddress.sin_port))
    }

    private func acceptConnections() {
        let fd: Int32? = stateLock.withLock {
            running ? serverSocket : nil
        }
        guard let fd else { return }

        while isRunning {
            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            // The listening socket is non-blocking so the accept loop can
            // drain Dispatch events. Ensure each accepted connection uses
            // blocking reads with SO_RCVTIMEO; otherwise a connection whose
            // first bytes have not arrived yet can spuriously fail with
            // EAGAIN instead of waiting for the bounded timeout.
            let clientFlags = fcntl(client, F_GETFL, 0)
            if clientFlags < 0 || fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK) != 0 {
                close(client)
                continue
            }
            connectionQueue.async { [weak self] in
                self?.handleConnection(client)
            }
        }
    }

    private func handleConnection(_ client: Int32) {
        defer { close(client) }
        configureTimeouts(for: client)

        do {
            let request = try readRequest(from: client)
            let response = handle(request)
            try write(response, to: client)
        } catch let failure as HTTPFailure {
            let response = makeAPIErrorResponse(
                status: failure.status,
                reason: failure.reason,
                code: failure.code,
                message: failure.message
            )
            try? write(response, to: client)
        } catch {
            let response = makeAPIErrorResponse(
                status: 500,
                reason: "Internal Server Error",
                code: "internalError",
                message: "The editor request could not be completed"
            )
            try? write(response, to: client)
        }
    }

    private func configureTimeouts(for socket: Int32) {
        var timeout = timeval(
            tv_sec: Int(EditorServer.requestTimeout),
            tv_usec: 0
        )
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    private func readRequest(from socket: Int32) throws -> HTTPRequest {
        let delimiter = Data([13, 10, 13, 10])
        var headerAndBody = Data()
        var headerEnd: Range<Data.Index>?

        while headerEnd == nil {
            guard headerAndBody.count < Self.maxHeaderBytes else {
                throw HTTPFailure(
                    status: 431,
                    reason: "Request Header Fields Too Large",
                    code: "headersTooLarge",
                    message: "Request headers exceed the editor limit"
                )
            }
            var chunk = [UInt8](repeating: 0, count: min(2048, Self.maxHeaderBytes - headerAndBody.count))
            let readCount = chunk.withUnsafeMutableBytes { buffer in
                Darwin.recv(socket, buffer.baseAddress, buffer.count, 0)
            }
            if readCount == 0 {
                throw HTTPFailure(status: 400, reason: "Bad Request", code: "connectionClosed", message: "Request ended before headers were complete")
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw HTTPFailure(status: 408, reason: "Request Timeout", code: "timeout", message: "The editor request timed out")
            }
            headerAndBody.append(contentsOf: chunk.prefix(readCount))
            headerEnd = headerAndBody.range(of: delimiter)
        }

        guard let headerEnd else {
            throw HTTPFailure(status: 400, reason: "Bad Request", code: "malformedRequest", message: "Malformed HTTP request")
        }
        let headerData = headerAndBody.prefix(upTo: headerEnd.lowerBound)
        let remainderStart = headerEnd.upperBound
        let remainder = Data(headerAndBody.suffix(from: remainderStart))
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPFailure(status: 400, reason: "Bad Request", code: "invalidHeaders", message: "Request headers must be UTF-8")
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HTTPFailure(status: 400, reason: "Bad Request", code: "malformedRequest", message: "Request line is missing")
        }
        lines.removeFirst()
        let requestTokens = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestTokens.count == 3,
              requestTokens[2] == "HTTP/1.0" || requestTokens[2] == "HTTP/1.1" else {
            throw HTTPFailure(status: 400, reason: "Bad Request", code: "malformedRequest", message: "Only HTTP/1.0 and HTTP/1.1 are supported")
        }
        let target = String(requestTokens[1])
        guard target.hasPrefix("/"), !target.contains("#") else {
            throw HTTPFailure(status: 400, reason: "Bad Request", code: "invalidTarget", message: "Only origin-form request targets are supported")
        }
        let rawPath = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "/"
        guard let path = rawPath.removingPercentEncoding, !path.contains("\0"), !path.isEmpty else {
            throw HTTPFailure(status: 400, reason: "Bad Request", code: "invalidTarget", message: "Request path is not valid UTF-8")
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard !line.isEmpty,
                  let separator = line.firstIndex(of: ":") else {
                throw HTTPFailure(status: 400, reason: "Bad Request", code: "invalidHeaders", message: "Malformed request header")
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" ) }) else {
                throw HTTPFailure(status: 400, reason: "Bad Request", code: "invalidHeaders", message: "Invalid request header name")
            }
            guard headers[name] == nil else {
                throw HTTPFailure(status: 400, reason: "Bad Request", code: "duplicateHeader", message: "Duplicate request headers are not accepted")
            }
            headers[name] = value
        }

        guard headers["host"] != nil else {
            throw HTTPFailure(status: 400, reason: "Bad Request", code: "missingHost", message: "Host is required")
        }
        if headers["transfer-encoding"] != nil {
            throw HTTPFailure(status: 400, reason: "Bad Request", code: "unsupportedEncoding", message: "Chunked request bodies are not supported")
        }

        let bodyLength: Int
        if let rawLength = headers["content-length"] {
            guard !rawLength.isEmpty,
                  rawLength.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let parsedLength = Int(rawLength) else {
                throw HTTPFailure(status: 400, reason: "Bad Request", code: "invalidContentLength", message: "Content-Length must be a non-negative decimal integer")
            }
            bodyLength = parsedLength
        } else {
            bodyLength = 0
        }
        guard bodyLength <= Self.maxBodyBytes else {
            throw HTTPFailure(status: 413, reason: "Payload Too Large", code: "bodyTooLarge", message: "Request body exceeds the editor limit")
        }

        var body = Data(remainder.prefix(bodyLength))
        while body.count < bodyLength {
            var chunk = [UInt8](repeating: 0, count: min(2048, bodyLength - body.count))
            let readCount = chunk.withUnsafeMutableBytes { buffer in
                Darwin.recv(socket, buffer.baseAddress, buffer.count, 0)
            }
            if readCount == 0 {
                throw HTTPFailure(status: 400, reason: "Bad Request", code: "truncatedBody", message: "Request body ended before Content-Length")
            }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw HTTPFailure(status: 408, reason: "Request Timeout", code: "timeout", message: "The editor request timed out")
            }
            body.append(contentsOf: chunk.prefix(readCount))
        }

        return HTTPRequest(
            method: String(requestTokens[0]),
            path: path,
            headers: headers,
            body: body
        )
    }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        guard let port, request.headers["host"] == "127.0.0.1:\(port)" else {
            return makeAPIErrorResponse(
                status: 400,
                reason: "Bad Request",
                code: "invalidHost",
                message: "Host must match the loopback editor address"
            )
        }

        if request.path.hasPrefix("/api/") {
            return handleAPI(request)
        }
        guard request.method == "GET" else {
            return makeAPIErrorResponse(status: 405, reason: "Method Not Allowed", code: "methodNotAllowed", message: "Only GET is supported for editor resources")
        }
        guard let resource = resourceResolver.resource(for: request.path) else {
            return makeAPIErrorResponse(status: 404, reason: "Not Found", code: "notFound", message: "Editor resource was not found")
        }
        return HTTPResponse(status: 200, reason: "OK", body: resource.data, contentType: resource.contentType)
    }

    private func handleAPI(_ request: HTTPRequest) -> HTTPResponse {
        switch request.path {
        case "/api/session":
            guard request.method == "POST" else {
                return makeAPIErrorResponse(status: 405, reason: "Method Not Allowed", code: "methodNotAllowed", message: "Session bootstrap requires POST")
            }
            if !request.body.isEmpty {
                guard mediaType(request.headers["content-type"]) == "application/json" else {
                    return makeAPIErrorResponse(status: 415, reason: "Unsupported Media Type", code: "contentType", message: "Session requests with a body must use application/json")
                }
                guard (try? JSONSerialization.jsonObject(with: request.body, options: [])) != nil else {
                    return makeAPIErrorResponse(status: 400, reason: "Bad Request", code: "invalidJSON", message: "Session request body is not valid JSON")
                }
            }
            if let origin = request.headers["origin"], origin != editorOrigin {
                return makeAPIErrorResponse(status: 403, reason: "Forbidden", code: "origin", message: "Origin is not the editor origin")
            }
            guard let bootstrap = request.headers["x-macrowhisper-bootstrap"],
                  let session = consumeBootstrap(bootstrap) else {
                return makeAPIErrorResponse(status: 401, reason: "Unauthorized", code: "bootstrapExpired", message: "The editor bootstrap token is invalid or expired")
            }
            guard let data = try? Self.encodeJSON(session) else {
                return makeAPIErrorResponse(status: 500, reason: "Internal Server Error", code: "encoding", message: "Session response could not be encoded")
            }
            return HTTPResponse(status: 200, reason: "OK", body: data, contentType: "application/json; charset=utf-8")

        case "/api/config":
            guard request.method == "GET" else {
                return makeAPIErrorResponse(status: 405, reason: "Method Not Allowed", code: "methodNotAllowed", message: "Configuration snapshots require GET")
            }
            guard hasValidSession(request) else {
                return makeAPIErrorResponse(status: 401, reason: "Unauthorized", code: "unauthorized", message: "A valid editor session is required")
            }
            let snapshot = configManager.configurationSnapshot()
            guard let data = try? Self.encodeJSON(snapshot) else {
                return makeAPIErrorResponse(status: 500, reason: "Internal Server Error", code: "encoding", message: "Configuration snapshot could not be encoded")
            }
            return HTTPResponse(status: 200, reason: "OK", body: data, contentType: "application/json; charset=utf-8")

        case "/api/config/edits":
            guard request.method == "POST" else {
                return makeAPIErrorResponse(status: 405, reason: "Method Not Allowed", code: "methodNotAllowed", message: "Configuration edits require POST")
            }
            guard hasValidSession(request) else {
                return makeAPIErrorResponse(status: 401, reason: "Unauthorized", code: "unauthorized", message: "A valid editor session is required")
            }
            guard mediaType(request.headers["content-type"]) == "application/json" else {
                return makeAPIErrorResponse(status: 415, reason: "Unsupported Media Type", code: "contentType", message: "Configuration edits require application/json")
            }
            guard let origin = request.headers["origin"], origin == editorOrigin else {
                return makeAPIErrorResponse(status: 403, reason: "Forbidden", code: "origin", message: "Mutations require the editor origin")
            }
            let decoded: EditRequest
            do {
                decoded = try JSONDecoder().decode(EditRequest.self, from: request.body)
            } catch {
                return makeAPIErrorResponse(status: 400, reason: "Bad Request", code: "malformedEdit", message: "Edit request must contain expectedRevision and edits")
            }
            switch configManager.applyConfigurationEdits(
                decoded.edits,
                expectedRevision: decoded.expectedRevision,
                reason: "editor"
            ) {
            case .committed(let snapshot):
                guard let data = try? Self.encodeJSON(snapshot) else {
                    return makeAPIErrorResponse(status: 500, reason: "Internal Server Error", code: "encoding", message: "Committed snapshot could not be encoded")
                }
                return HTTPResponse(status: 200, reason: "OK", body: data, contentType: "application/json; charset=utf-8")
            case .rejected(let error):
                guard let data = try? Self.encodeJSON(error) else {
                    return makeAPIErrorResponse(status: 500, reason: "Internal Server Error", code: "encoding", message: "Transaction error could not be encoded")
                }
                let status = Self.httpStatus(for: error.code)
                return HTTPResponse(status: status, reason: Self.reasonPhrase(for: status), body: data, contentType: "application/json; charset=utf-8")
            }

        default:
            return makeAPIErrorResponse(status: 404, reason: "Not Found", code: "notFound", message: "Editor API endpoint was not found")
        }
    }

    private func consumeBootstrap(_ token: String) -> SessionPayload? {
        stateLock.withLock {
            let now = Date()
            guard let expiration = bootstrapTokens.removeValue(forKey: token), expiration > now,
                  running else {
                return nil
            }
            let sessionToken = Self.randomToken()
            let sessionExpiration = now.addingTimeInterval(sessionLifetime)
            sessions[sessionToken] = sessionExpiration
            return SessionPayload(sessionToken: sessionToken, expiresAt: sessionExpiration.timeIntervalSince1970)
        }
    }

    private func hasValidSession(_ request: HTTPRequest) -> Bool {
        guard let authorization = request.headers["authorization"],
              authorization.hasPrefix("Bearer ") else {
            return false
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else { return false }
        return stateLock.withLock {
            guard let expiration = sessions[token] else { return false }
            if expiration <= Date() {
                sessions.removeValue(forKey: token)
                return false
            }
            return running
        }
    }

    private func mediaType(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private var editorOrigin: String? {
        guard let address = cleanAddress else { return nil }
        return address.hasSuffix("/") ? String(address.dropLast()) : address
    }

    private func makeAPIErrorResponse(
        status: Int,
        reason: String,
        code: String,
        message: String
    ) -> HTTPResponse {
        let payload = APIErrorPayload(code: code, message: message)
        let body = (try? Self.encodeJSON(payload)) ?? Data("{\"code\":\"internalError\",\"message\":\"Request failed\"}".utf8)
        return HTTPResponse(status: status, reason: reason, body: body, contentType: "application/json; charset=utf-8")
    }

    private func write(_ response: HTTPResponse, to socket: Int32) throws {
        let header = "HTTP/1.1 \(response.status) \(response.reason)\r\n" +
            "Content-Type: \(response.contentType)\r\n" +
            "Content-Length: \(response.body.count)\r\n" +
            "Cache-Control: no-store\r\n" +
            "Content-Security-Policy: default-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'\r\n" +
            "X-Content-Type-Options: nosniff\r\n" +
            "Referrer-Policy: no-referrer\r\n" +
            "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(response.body)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let result = Darwin.send(
                    socket,
                    baseAddress.advanced(by: offset),
                    data.count - offset,
                    0
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw EditorServerError.writeFailed(errno)
                }
                guard result > 0 else { throw EditorServerError.writeFailed(EPIPE) }
                offset += result
            }
        }
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func httpStatus(for code: ConfigurationTransactionErrorCode) -> Int {
        switch code {
        case .staleRevision, .invalidDiskState, .resourceMismatch:
            return 409
        case .persistenceFailed, .encodingFailed:
            return 500
        case .malformedEdit, .invalidPath, .typeMismatch, .outOfRange,
             .validationFailed, .legacyConfiguration, .unknownKey, .unsupportedVersion:
            return 422
        }
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 422: return "Unprocessable Entity"
        case 431: return "Request Header Fields Too Large"
        default: return "Internal Server Error"
        }
    }
}

private enum EditorServerError: Error, LocalizedError {
    case socketCreation(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case addressLookupFailed(Int32)
    case invalidAddress
    case writeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .socketCreation(let code): return "could not create editor socket (errno \(code))"
        case .bindFailed(let code): return "could not bind editor socket (errno \(code))"
        case .listenFailed(let code): return "could not listen on editor socket (errno \(code))"
        case .addressLookupFailed(let code): return "could not discover editor port (errno \(code))"
        case .invalidAddress: return "could not configure loopback editor address"
        case .writeFailed(let code): return "could not write editor response (errno \(code))"
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
