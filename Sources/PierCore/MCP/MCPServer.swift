import Foundation
import Darwin

/// MCP server over newline-delimited JSON-RPC 2.0 (stdio transport).
///
/// Everything written goes through the `write` callback, one complete line per message and never anything
/// else, so stdout stays a clean protocol channel. Requests run concurrently; `notifications/cancelled`
/// cancels the matching in-flight request (which then sends no response).
public final class MCPServer: @unchecked Sendable {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let serverName = "pier"
    public static let serverVersion = PierVersion.current

    public static let instructions = """
    pier shows and controls services listening on this Mac's localhost ports (dev servers, databases, Docker, local AI). \
    Call list_services first to see what is running and which project each port belongs to. \
    Tools that take a `target` accept a port number (exact) or a fuzzy name (project, page title, framework, process); \
    ambiguous names are rejected, so pass the port. To run a dev server yourself, use run_service, then wait_for_port, \
    then read_logs with the managed id. kill_service refuses databases/Docker/system services unless confirm=true, which you \
    should only set after the user agreed.
    """

    private enum Code {
        static let parse = -32700, invalidRequest = -32600, methodNotFound = -32601, invalidParams = -32602, internalError = -32603
    }

    private let context: MCPContext
    private let lock = NSLock()
    private var inflight: [String: Task<Void, Never>] = [:]

    public init(context: MCPContext = .live) {
        self.context = context
    }

    // MARK: Serving

    /// Process lines until the stream ends, then wait for in-flight requests (cancelling stragglers after `drainGrace`).
    public func serve(lines: AsyncStream<String>, drainGrace: TimeInterval = 10,
                      write: @escaping @Sendable (String) -> Void) async {
        var tasks: [Task<Void, Never>] = []
        for await raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let message = JSON.parse(line)

            // Cancellation is handled inline so it cannot queue behind the request it cancels.
            if let msg = message, msg["method"]?.stringValue == "notifications/cancelled" {
                if let rid = msg["params"]?["requestId"] { cancel(requestID: rid) }
                continue
            }

            let key = message.flatMap { $0["id"] }.map { $0.compact }
            let task = spawn(key: key) { [self] in
                let response = await handle(message: message)
                if let key { self.finish(key) }
                if !Task.isCancelled, let response { write(response.compact) }
            }
            tasks.append(task)
        }

        // EOF: let running requests answer, but never hang forever on a long wait_for_port.
        let watchdog = Task { [self] in
            try? await Task.sleep(nanoseconds: UInt64(drainGrace * 1_000_000_000))
            if !Task.isCancelled { self.cancelAll() }
        }
        for t in tasks { await t.value }
        watchdog.cancel()
    }

    /// Starts the task and registers it under `key` atomically (the body's `finish` cannot run before registration).
    private func spawn(key: String?, _ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.lock(); defer { lock.unlock() }
        let task = Task { await body() }
        if let key { inflight[key] = task }
        return task
    }

    private func finish(_ key: String) {
        lock.lock(); inflight[key] = nil; lock.unlock()
    }

    private func cancel(requestID: JSON) {
        lock.lock(); let t = inflight[requestID.compact]; lock.unlock()
        t?.cancel()
    }

    private func cancelAll() {
        lock.lock(); let all = Array(inflight.values); lock.unlock()
        all.forEach { $0.cancel() }
    }

    /// Handle one raw JSON line (used by tests and by `serve`). Returns the response line, or nil for notifications.
    public func handle(line: String) async -> String? {
        await handle(message: JSON.parse(line))?.compact
    }

    // MARK: Dispatch

    func handle(message: JSON?) async -> JSON? {
        guard let message else { return Self.error(id: .null, code: Code.parse, message: "Parse error") }
        guard case .object = message else {
            return Self.error(id: .null, code: Code.invalidRequest, message: "Invalid Request: expected a JSON object")
        }
        // Responses to server-initiated requests: we send none, so ignore.
        guard let method = message["method"]?.stringValue else {
            if message["result"] != nil || message["error"] != nil { return nil }
            return Self.error(id: message["id"] ?? .null, code: Code.invalidRequest, message: "Invalid Request: missing method")
        }
        let id = message["id"]
        let isNotification = id == nil
        let params = message["params"]

        switch method {
        case "notifications/initialized", "notifications/cancelled", "notifications/roots/list_changed":
            return nil
        case _ where isNotification:
            return nil   // unknown notifications are silently ignored
        default:
            break
        }
        guard let id else { return nil }

        switch method {
        case "initialize":
            return Self.ok(id: id, result: initializeResult(params))
        case "ping":
            return Self.ok(id: id, result: [:])
        case "tools/list":
            return Self.ok(id: id, result: ["tools": .array(MCPTools.all.map(\.listing))])
        case "tools/call":
            return await callTool(id: id, params: params)
        default:
            return Self.error(id: id, code: Code.methodNotFound, message: "Method not found: \(method)")
        }
    }

    private func initializeResult(_ params: JSON?) -> JSON {
        let requested = params?["protocolVersion"]?.stringValue
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil } ?? Self.supportedProtocolVersions[0]
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": .string(Self.serverName), "version": .string(Self.serverVersion)],
            "instructions": .string(Self.instructions),
        ]
    }

    private func callTool(id: JSON, params: JSON?) async -> JSON? {
        guard let params, case .object = params else {
            return Self.error(id: id, code: Code.invalidParams, message: "Invalid params: expected an object with 'name'")
        }
        guard let name = params["name"]?.stringValue, !name.isEmpty else {
            return Self.error(id: id, code: Code.invalidParams, message: "Invalid params: 'name' (string) is required")
        }
        guard let tool = MCPTools.tool(named: name) else {
            return Self.error(id: id, code: Code.invalidParams, message: "Unknown tool: \(name)")
        }
        if let a = params["arguments"], !a.isNull, a.objectValue == nil {
            return Self.error(id: id, code: Code.invalidParams, message: "Invalid params: 'arguments' must be an object")
        }

        let result: MCPToolResult
        do {
            result = try await tool.handler(context, MCPArgs(params["arguments"]))
        } catch let e as MCPArgError {
            result = .error("Invalid arguments for \(name): \(e.message)")
        } catch is CancellationError {
            return nil
        } catch {
            result = .error("\(name) failed: \(error)")
        }
        if Task.isCancelled { return nil }
        return Self.ok(id: id, result: result.rpcValue)
    }

    // MARK: Envelopes

    static func ok(id: JSON, result: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSON, code: Int, message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }

    // MARK: stdio

    /// Lines from stdin on a dedicated thread (blocking reads), finishing at EOF.
    public static func stdinLines() -> AsyncStream<String> {
        AsyncStream { continuation in
            let thread = Thread {
                while let line = readLine(strippingNewline: true) { continuation.yield(line) }
                continuation.finish()
            }
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    /// Runs the server on stdin/stdout. The protocol channel is a private dup of the original stdout and fd 1 is
    /// redirected to stderr, so stray `print`s anywhere in the process can never corrupt the stream.
    public static func runStdio(context: MCPContext = .live) async {
        signal(SIGPIPE, SIG_IGN)
        let protocolFD = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let writer = LineWriter(fd: protocolFD)
        await MCPServer(context: context).serve(lines: stdinLines()) { writer.write($0) }
        close(protocolFD)
    }
}

/// Serializes whole-line writes to a file descriptor.
final class LineWriter: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    init(fd: Int32) { self.fd = fd }

    func write(_ line: String) {
        var bytes = Array(line.utf8)
        bytes.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n < 0 { if errno == EINTR { continue }; return }
            offset += n
        }
    }
}
