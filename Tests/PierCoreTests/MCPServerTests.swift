import XCTest
import Darwin
@testable import PierCore

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ l: String) { lock.lock(); lines.append(l); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

final class MCPServerTests: XCTestCase {
    // MARK: helpers

    private func fakeService(port: UInt16, pid: Int32, name: String = "node", kind: ServiceKind, project: String? = nil,
                             infra: String? = nil, noise: Bool = false) -> Service {
        var s = Service(port: port, process: ProcInfo(pid: pid, ppid: 1, uid: 501, name: name, cwd: project.map { "/tmp/\($0)" },
                                                      startTime: Date().addingTimeInterval(-3600)),
                        addresses: ["127.0.0.1"], bindScope: .loopback)
        s.kind = kind
        s.projectName = project
        s.projectPath = project.map { "/tmp/\($0)" }
        s.infraName = infra
        s.isNoise = noise
        s.probe = ProbeResult(protocolKind: .http, health: .ok, httpStatus: 200, title: nil)
        return s
    }

    private func fakeServer(_ services: [Service], managed: [ManagedManifest] = []) -> MCPServer {
        MCPServer(context: MCPContext(snapshot: { noise, _ in services.filter { noise || !$0.isNoise } }, managed: { managed }))
    }

    private func rpc(_ server: MCPServer, _ request: JSON) async throws -> JSON {
        let maybe = await server.handle(line: request.compact)
        let line = try XCTUnwrap(maybe, "expected a response")
        XCTAssertFalse(line.contains("\n"))
        return try XCTUnwrap(JSON.parse(line))
    }

    private func call(_ server: MCPServer, _ tool: String, _ args: JSON = [:], id: Int = 1) async throws -> JSON {
        try await rpc(server, ["jsonrpc": "2.0", "id": .int(id), "method": "tools/call",
                               "params": ["name": .string(tool), "arguments": args]])
    }

    private func isError(_ r: JSON) -> Bool { r["result"]?["isError"]?.boolValue == true }
    private func text(_ r: JSON) -> String { r["result"]?["content"]?[0]?["text"]?.stringValue ?? "" }

    // MARK: lifecycle

    func testInitializeEchoesSupportedVersion() async throws {
        let s = MCPServer()
        let r = try await rpc(s, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                  "params": ["protocolVersion": "2025-03-26", "capabilities": [:],
                                             "clientInfo": ["name": "t", "version": "1"]]])
        XCTAssertEqual(r["id"], 1)
        XCTAssertEqual(r["result"]?["protocolVersion"], "2025-03-26")
        XCTAssertEqual(r["result"]?["serverInfo"]?["name"], "pier")
        XCTAssertEqual(r["result"]?["serverInfo"]?["version"], "0.1.0")
        XCTAssertEqual(r["result"]?["capabilities"]?["tools"]?["listChanged"], false)
        XCTAssertTrue((r["result"]?["instructions"]?.stringValue ?? "").contains("list_services"))
    }

    func testInitializeFallsBackToLatestVersion() async throws {
        let r = try await rpc(MCPServer(), ["jsonrpc": "2.0", "id": "a", "method": "initialize",
                                            "params": ["protocolVersion": "1999-01-01"]])
        XCTAssertEqual(r["id"], "a")   // string ids are echoed unchanged
        XCTAssertEqual(r["result"]?["protocolVersion"], "2025-06-18")
    }

    func testNotificationsGetNoResponse() async {
        let s = MCPServer()
        let a = await s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        let b = await s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/whatever"}"#)
        XCTAssertNil(a)
        XCTAssertNil(b)
    }

    func testPing() async throws {
        let r = try await rpc(MCPServer(), ["jsonrpc": "2.0", "id": 7, "method": "ping"])
        XCTAssertEqual(r["id"], 7)
        XCTAssertEqual(r["result"], [:])
    }

    func testUnknownMethod() async throws {
        let r = try await rpc(MCPServer(), ["jsonrpc": "2.0", "id": 2, "method": "resources/list"])
        XCTAssertEqual(r["error"]?["code"], -32601)
        XCTAssertEqual(r["id"], 2)
    }

    func testParseError() async throws {
        let maybe = await MCPServer().handle(line: "{not json")
        let line = try XCTUnwrap(maybe)
        let r = try XCTUnwrap(JSON.parse(line))
        XCTAssertEqual(r["error"]?["code"], -32700)
        XCTAssertEqual(r["id"], .null)
    }

    func testBadParams() async throws {
        let s = MCPServer()
        let noName = try await rpc(s, ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [:]])
        XCTAssertEqual(noName["error"]?["code"], -32602)
        let noParams = try await rpc(s, ["jsonrpc": "2.0", "id": 2, "method": "tools/call"])
        XCTAssertEqual(noParams["error"]?["code"], -32602)
        let unknown = try await rpc(s, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "nope"]])
        XCTAssertEqual(unknown["error"]?["code"], -32602)
        let badArgs = try await rpc(s, ["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                        "params": ["name": "find_free_port", "arguments": "x"]])
        XCTAssertEqual(badArgs["error"]?["code"], -32602)
    }

    // MARK: tools/list

    func testToolsListHasAllToolsWithValidSchemas() async throws {
        let r = try await rpc(MCPServer(), ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let tools = try XCTUnwrap(r["result"]?["tools"]?.arrayValue)
        let names = Set(tools.compactMap { $0["name"]?.stringValue })
        XCTAssertEqual(names, ["list_services", "service_info", "read_logs", "kill_service", "restart_service",
                               "find_free_port", "wait_for_port", "stale_services", "run_service"])
        for t in tools {
            let name = t["name"]?.stringValue ?? "?"
            XCTAssertFalse((t["description"]?.stringValue ?? "").isEmpty, name)
            let schema = try XCTUnwrap(t["inputSchema"], name)
            XCTAssertEqual(schema["type"], "object", name)
            let props = try XCTUnwrap(schema["properties"]?.objectValue, name)
            for req in schema["required"]?.arrayValue ?? [] {
                XCTAssertNotNil(props[req.stringValue ?? ""], "\(name): required \(req) missing from properties")
            }
            for (k, p) in props { XCTAssertNotNil(p["type"] ?? p["oneOf"], "\(name).\(k) has no type") }
            XCTAssertNotNil(t["annotations"]?["readOnlyHint"]?.boolValue, name)
        }
        let kill = try XCTUnwrap(tools.first { $0["name"] == "kill_service" })
        XCTAssertEqual(kill["annotations"]?["destructiveHint"], true)
        XCTAssertEqual(kill["annotations"]?["readOnlyHint"], false)
        let list = try XCTUnwrap(tools.first { $0["name"] == "list_services" })
        XCTAssertEqual(list["annotations"]?["readOnlyHint"], true)
    }

    // MARK: tools

    func testFindFreePort() async throws {
        let r = try await call(MCPServer(), "find_free_port", ["from": 41000])
        XCTAssertFalse(isError(r))
        let port = try XCTUnwrap(r["result"]?["structuredContent"]?["port"]?.intValue)
        XCTAssertGreaterThanOrEqual(port, 41000)
        XCTAssertTrue(PortFinder.isFree(UInt16(port)))
        XCTAssertEqual(JSON.parse(text(r))?["port"]?.intValue, port)
    }

    func testFindFreePortBadArgIsToolError() async throws {
        let r = try await call(MCPServer(), "find_free_port", ["from": "abc"])
        XCTAssertTrue(isError(r))
        XCTAssertNil(r["error"])
        let r2 = try await call(MCPServer(), "find_free_port", ["from": 70000])
        XCTAssertTrue(isError(r2))
    }

    func testListServicesLiveReturnsArray() async throws {
        let r = try await call(MCPServer(), "list_services", ["probe": false])
        XCTAssertFalse(isError(r))
        XCTAssertNotNil(r["result"]?["structuredContent"]?["services"]?.arrayValue)
        XCTAssertNotNil(JSON.parse(text(r))?.arrayValue)
    }

    func testListServicesCompactFields() async throws {
        var s = fakeService(port: 3123, pid: 4242, kind: .devServer, project: "relay")
        s.framework = Framework(id: "next", name: "Next.js")
        s.gitBranch = "main"
        s.owners = [OwnerLink(pid: 10, name: "claude", kind: .claudeCode), OwnerLink(pid: 11, name: "node", kind: .other)]
        s.tunnelURL = "https://x.trycloudflare.com"
        let noise = fakeService(port: 5000, pid: 300, name: "ControlCenter", kind: .system, noise: true)
        let server = fakeServer([s, noise])

        let r = try await call(server, "list_services")
        let rows = try XCTUnwrap(r["result"]?["structuredContent"]?["services"]?.arrayValue)
        XCTAssertEqual(rows.count, 1)   // noise hidden by default
        let row = rows[0]
        XCTAssertEqual(row["port"], 3123)
        XCTAssertEqual(row["name"], "relay")
        XCTAssertEqual(row["project"], "relay")
        XCTAssertEqual(row["project_path"], "/tmp/relay")
        XCTAssertEqual(row["framework"], "Next.js")
        XCTAssertEqual(row["kind"], "devServer")
        XCTAssertEqual(row["health"], "ok")
        XCTAssertEqual(row["http_status"], 200)
        XCTAssertEqual(row["url"], "http://localhost:3123")
        XCTAssertEqual(row["tunnel_url"], "https://x.trycloudflare.com")
        XCTAssertEqual(row["managed"], false)
        XCTAssertEqual(row["pid"], 4242)
        XCTAssertEqual(row["git_branch"], "main")
        XCTAssertEqual(row["owners"], ["claudeCode", "other"])
        XCTAssertGreaterThan(row["uptime_s"]?.intValue ?? 0, 3000)

        let all = try await call(server, "list_services", ["include_noise": true])
        XCTAssertEqual(all["result"]?["structuredContent"]?["services"]?.arrayValue?.count, 2)
    }

    func testServiceInfoAndTargetErrors() async throws {
        let a = fakeService(port: 3001, pid: 4001, kind: .devServer, project: "alpha")
        let b = fakeService(port: 3002, pid: 4002, kind: .devServer, project: "alpha-two")
        let server = fakeServer([a, b])

        let info = try await call(server, "service_info", ["target": "3001"])
        XCTAssertFalse(isError(info))
        XCTAssertEqual(info["result"]?["structuredContent"]?["port"], 3001)
        XCTAssertEqual(info["result"]?["structuredContent"]?["projectName"], "alpha")

        let numeric = try await call(server, "service_info", ["target": 3002])   // number instead of string
        XCTAssertFalse(isError(numeric))

        let ambiguous = try await call(server, "service_info", ["target": "alp"])
        XCTAssertTrue(isError(ambiguous))
        XCTAssertTrue(text(ambiguous).contains(":3001"))
        XCTAssertTrue(text(ambiguous).contains(":3002"))

        let none = try await call(server, "service_info", ["target": "zzzz"])
        XCTAssertTrue(isError(none))
        XCTAssertTrue(text(none).contains("list_services"))

        let missing = try await call(server, "service_info", [:])
        XCTAssertTrue(isError(missing))
    }

    func testKillRefusesInfraWithoutConfirmAndProtectsPid1() async throws {
        let pg = fakeService(port: 5432, pid: 99_991, name: "postgres", kind: .infra, infra: "PostgreSQL")
        let init1 = fakeService(port: 8081, pid: 1, name: "launchd", kind: .devServer, project: "weird")
        let me = fakeService(port: 8082, pid: ProcessInfo.processInfo.processIdentifier, kind: .devServer, project: "self")
        let server = fakeServer([pg, init1, me])

        let r = try await call(server, "kill_service", ["target": "5432"])
        XCTAssertTrue(isError(r))
        XCTAssertTrue(text(r).contains("confirm"))
        XCTAssertTrue(Killer.isAlive(ProcessInfo.processInfo.processIdentifier))

        let p1 = try await call(server, "kill_service", ["target": "8081", "confirm": true])
        XCTAssertTrue(isError(p1))
        XCTAssertTrue(text(p1).contains("refusing"))

        let selfKill = try await call(server, "kill_service", ["target": "8082", "confirm": true])
        XCTAssertTrue(isError(selfKill))
        XCTAssertTrue(text(selfKill).contains("pier itself"))
    }

    func testRestartRefusesInfra() async throws {
        let pg = fakeService(port: 5432, pid: 99_991, name: "postgres", kind: .infra, infra: "PostgreSQL")
        let r = try await call(fakeServer([pg]), "restart_service", ["target": "postgres"])
        XCTAssertTrue(isError(r))
        XCTAssertTrue(text(r).contains("Refusing"))
    }

    func testReadLogsOnUnmanagedExplainsAdoption() async throws {
        let s = fakeService(port: 3001, pid: 4001, kind: .devServer, project: "alpha")
        let r = try await call(fakeServer([s]), "read_logs", ["target": "alpha"])
        XCTAssertTrue(isError(r))
        XCTAssertTrue(text(r).contains("restart_service"))
        let none = try await call(fakeServer([]), "read_logs", ["target": "ghost"])
        XCTAssertTrue(isError(none))
    }

    func testStaleServicesShape() async throws {
        let r = try await call(fakeServer([]), "stale_services", ["days": 1])
        XCTAssertFalse(isError(r))
        XCTAssertEqual(r["result"]?["structuredContent"]?["count"], 0)
    }

    func testRunServiceValidatesInput() async throws {
        let server = MCPServer()
        let noCwd = try await call(server, "run_service", ["command": ["echo", "hi"]])
        XCTAssertTrue(isError(noCwd))
        let badDir = try await call(server, "run_service", ["command": "echo hi", "cwd": "/definitely/not/here"])
        XCTAssertTrue(isError(badDir))
        XCTAssertTrue(text(badDir).contains("cwd"))
        let noCmd = try await call(server, "run_service", ["cwd": "/tmp"])
        XCTAssertTrue(isError(noCmd))
    }

    // MARK: wait_for_port

    func testWaitForPortTimesOut() async throws {
        let port = try XCTUnwrap(PortFinder.nextFree(from: 42_000))
        let start = Date()
        let r = try await call(MCPServer(), "wait_for_port", ["port": .int(Int(port)), "timeout_s": 0.6])
        XCTAssertTrue(isError(r))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertTrue(text(r).contains("nothing listened"))
    }

    func testWaitForPortSeesListener() async throws {
        let (fd, port) = try listen()
        defer { close(fd) }
        let r = try await call(MCPServer(), "wait_for_port", ["port": .int(Int(port)), "timeout_s": 5])
        XCTAssertFalse(isError(r), text(r))
        XCTAssertEqual(r["result"]?["structuredContent"]?["listening"], true)
        XCTAssertNotNil(r["result"]?["structuredContent"]?["elapsed_s"]?.doubleValue)
    }

    private func listen() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &a.sin_addr)
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(rc, 0)
        XCTAssertEqual(Darwin.listen(fd, 4), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return (fd, UInt16(bigEndian: a.sin_port))
    }

    // MARK: serve loop

    func testServeLoopWritesOneJSONLinePerResponse() async throws {
        let out = Collector()
        let input = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            "",
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"find_free_port","arguments":{}}}"#,
            "garbage",
        ]
        let stream = AsyncStream<String> { c in input.forEach { c.yield($0) }; c.finish() }
        await MCPServer().serve(lines: stream) { out.add($0) }

        let lines = out.all
        XCTAssertEqual(lines.count, 4)   // 3 responses + parse error; notification and blank line produce nothing
        let parsed = lines.compactMap { JSON.parse($0) }
        XCTAssertEqual(parsed.count, 4)
        XCTAssertEqual(Set(parsed.compactMap { $0["id"]?.intValue }), [1, 2, 3])
        XCTAssertTrue(parsed.contains { $0["error"]?["code"] == -32700 })
    }

    func testCancellingWaitForPort() async throws {
        let port = try XCTUnwrap(PortFinder.nextFree(from: 43_000))
        let out = Collector()
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        let c = cont!

        let start = Date()
        let serving = Task { await MCPServer().serve(lines: stream) { out.add($0) } }
        c.yield(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"wait_for_port","arguments":{"port":\#(port),"timeout_s":60}}}"#)
        try await Task.sleep(nanoseconds: 600_000_000)
        c.yield(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9,"reason":"test"}}"#)
        c.yield(#"{"jsonrpc":"2.0","id":10,"method":"ping"}"#)
        c.finish()
        await serving.value

        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "cancelled request must not run to its 60s timeout")
        let parsed = out.all.compactMap { JSON.parse($0) }
        XCTAssertTrue(parsed.contains { $0["id"] == 10 })
        XCTAssertFalse(parsed.contains { $0["id"] == 9 }, "cancelled requests get no response")
    }

    func testEOFCancelsStragglersAfterGrace() async throws {
        let port = try XCTUnwrap(PortFinder.nextFree(from: 43_500))
        let stream = AsyncStream<String> { c in
            c.yield(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"wait_for_port","arguments":{"port":\#(port),"timeout_s":60}}}"#)
            c.finish()
        }
        let start = Date()
        await MCPServer().serve(lines: stream, drainGrace: 0.5) { _ in }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    // MARK: helpers

    func testANSIStripping() {
        let raw = "\u{1B}[32mready\u{1B}[0m - started on \u{1B}[1;4mhttp://x\u{1B}[0m\u{1B}]0;title\u{07}ok\n"
        XCTAssertEqual(MCPText.stripANSI(raw), "ready - started on http://xok\n")
        XCTAssertEqual(MCPText.lastLines("a\nb\nc\n", 2), "b\nc")
    }

    func testJSONRoundTripKeepsIntVsString() {
        let v = JSON.parse(#"{"a":1,"b":"1","c":[true,null,1.5]}"#)
        XCTAssertEqual(v?["a"], 1)
        XCTAssertEqual(v?["b"], "1")
        XCTAssertEqual(v?["c"]?[2], 1.5)
        XCTAssertFalse(v!.compact.contains("\n"))
    }

    func testLogsToolReadsManagedByNameWhenNoLiveService() async throws {
        // Crashed managed service: manifest exists, no listening service. Log fetch fails (no socket) with a useful error.
        let m = ManagedManifest(id: "ab12cd34", name: "crashy", wrapperPid: 1, childPid: nil, command: ["x"], cwd: "/tmp", state: .crashed, lastExitCode: 1)
        let r = try await call(fakeServer([], managed: [m]), "read_logs", ["target": "crashy"])
        XCTAssertTrue(isError(r))
        XCTAssertTrue(text(r).contains("crashy"))
        XCTAssertFalse(text(r).contains("no service or managed service"))
    }
}
