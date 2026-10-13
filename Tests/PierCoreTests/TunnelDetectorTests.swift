import XCTest
import Darwin
@testable import PierCore

final class TunnelDetectorTests: XCTestCase {
    override class func setUp() { super.setUp(); signal(SIGPIPE, SIG_IGN) }  // fake servers may write to closed peers

    // MARK: Parsers

    func testParseLocalPort() {
        for (input, want): (String, UInt16?) in [
            ("http://localhost:3000", 3000), ("localhost:3000", 3000), ("3000", 3000), ("https://127.0.0.1:8443/x", 8443),
            ("http://[::1]:5173", 5173), ("http://localhost", nil), ("tcp://host:99999", nil), ("", nil),
        ] { XCTAssertEqual(TunnelSources.parseLocalPort(input), want, input) }
    }

    func testParseNgrokPrefersHTTPS() {
        let json = """
        {"tunnels":[
          {"name":"a (http)","public_url":"http://abc.ngrok-free.app","config":{"addr":"http://localhost:3000"}},
          {"name":"a","public_url":"https://abc.ngrok-free.app","config":{"addr":"http://localhost:3000"}},
          {"name":"b","public_url":"https://def.ngrok.io","config":{"addr":"localhost:8080"}},
          {"name":"c","public_url":"https://ghi.ngrok.io","config":{"addr":"5173"}},
          {"name":"d","public_url":"tcp://0.tcp.ngrok.io:1234","config":{"addr":"localhost:5432"}}
        ],"uri":"/api/tunnels"}
        """
        let m = TunnelSources.parseNgrok(Data(json.utf8))
        XCTAssertEqual(m[3000], "https://abc.ngrok-free.app")
        XCTAssertEqual(m[8080], "https://def.ngrok.io")
        XCTAssertEqual(m[5173], "https://ghi.ngrok.io")
        XCTAssertEqual(m[5432], "tcp://0.tcp.ngrok.io:1234")
    }

    func testParseCloudflaredArgs() {
        XCTAssertEqual(TunnelSources.parseCloudflaredArgs(["cloudflared", "tunnel", "--url", "http://localhost:3100", "--metrics", "127.0.0.1:20241"]),
                       .init(port: 3100, metrics: "127.0.0.1:20241"))
        XCTAssertEqual(TunnelSources.parseCloudflaredArgs(["cloudflared", "tunnel", "--url=localhost:4000"]), .init(port: 4000, metrics: nil))
        XCTAssertNil(TunnelSources.parseCloudflaredArgs(["cloudflared", "tunnel", "run", "mytunnel"]))
    }

    func testParseQuickTunnel() {
        XCTAssertEqual(TunnelSources.parseQuickTunnel(Data(#"{"hostname":"foo-bar.trycloudflare.com"}"#.utf8)), "https://foo-bar.trycloudflare.com")
        XCTAssertNil(TunnelSources.parseQuickTunnel(Data(#"{"hostname":""}"#.utf8)))
    }

    func testParseTailscaleFunnel() {
        let json = """
        {"TCP":{"443":{"HTTPS":true},"8443":{"HTTPS":true}},
         "Web":{
           "mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"},"/api":{"Proxy":"http://127.0.0.1:4000"}}},
           "mac.tail1234.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:5000"}}},
           "private.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:6000"}}}},
         "AllowFunnel":{"mac.tail1234.ts.net:443":true,"mac.tail1234.ts.net:8443":true}}
        """
        let m = TunnelSources.parseTailscaleFunnel(Data(json.utf8))
        XCTAssertEqual(m[3000], "https://mac.tail1234.ts.net")
        XCTAssertEqual(m[4000], "https://mac.tail1234.ts.net/api")
        XCTAssertEqual(m[5000], "https://mac.tail1234.ts.net:8443")
        XCTAssertNil(m[6000], "not funnelled")
        XCTAssertTrue(TunnelSources.parseTailscaleFunnel(Data("{}".utf8)).isEmpty)
    }

    func testExtractTunnelURLIgnoresAPIEndpoint() {
        let log = """
        ERR failed to request quick Tunnel: Post "https://api.trycloudflare.com/tunnel": EOF
        INF |  https://quiet-river-1234.trycloudflare.com                |
        """
        XCTAssertEqual(TunnelLauncher.extractTunnelURL(log), "https://quiet-river-1234.trycloudflare.com")
        XCTAssertNil(TunnelLauncher.extractTunnelURL("https://api.trycloudflare.com only"))
    }

    // MARK: Sources against fake servers

    func testNgrokAgainstFakeAPI() async throws {
        let body = #"{"tunnels":[{"public_url":"https://x.ngrok.io","config":{"addr":"http://localhost:3000"}}]}"#
        let server = try DockerFakeServer.tcp { _ in DockerFakeServer.ok(body) }
        defer { server.stop() }
        var o = TunnelDetector.Options()
        o.ngrokPorts = [server.port, 1]   // port 1 refuses instantly
        o.includeRegistry = false; o.includeCloudflaredProcesses = false; o.includeTailscale = false
        let t0 = Date()
        let m = await TunnelDetector.activeTunnels(options: o)
        XCTAssertEqual(m[3000], "https://x.ngrok.io")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.3)
    }

    func testBudgetIsHardCapWhenSourceHangs() async throws {
        let server = try DockerFakeServer.tcp { _ in nil }
        defer { server.stop() }
        var o = TunnelDetector.Options()
        o.ngrokPorts = [server.port]
        o.includeRegistry = false; o.includeCloudflaredProcesses = false; o.includeTailscale = false
        let t0 = Date()
        let m = await TunnelDetector.activeTunnels(options: o)
        XCTAssertTrue(m.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.45)
    }

    func testQuickTunnelMetricsAgainstFakeServer() throws {
        let server = try DockerFakeServer.tcp { req in
            req.hasPrefix("GET /quicktunnel") ? DockerFakeServer.ok(#"{"hostname":"abc-def.trycloudflare.com"}"#) : nil
        }
        defer { server.stop() }
        XCTAssertEqual(TunnelSources.quickTunnelURL(metrics: "127.0.0.1:\(server.port)", budget: 0.3), "https://abc-def.trycloudflare.com")
        XCTAssertEqual(TunnelSources.quickTunnelURL(metrics: "localhost:\(server.port)", budget: 0.3), "https://abc-def.trycloudflare.com")
    }

    func testTailscaleWithFakeCLIAndTimeout() throws {
        let dir = try makeTempDir()
        let good = dir.appendingPathComponent("ts-good")
        try writeScript(good, """
        #!/bin/sh
        cat <<'EOF'
        {"Web":{"h.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7777"}}}},"AllowFunnel":{"h.ts.net:443":true}}
        EOF
        """)
        setenv("PIER_TAILSCALE", good.path, 1)
        defer { unsetenv("PIER_TAILSCALE") }
        XCTAssertEqual(TunnelSources.tailscaleFunnel(timeout: 2)[7777], "https://h.ts.net")

        let slow = dir.appendingPathComponent("ts-slow")
        try writeScript(slow, "#!/bin/sh\nexec sleep 30\n")
        setenv("PIER_TAILSCALE", slow.path, 1)
        let t0 = Date()
        XCTAssertTrue(TunnelSources.tailscaleFunnel(timeout: 0.25).isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.6)
    }

    // MARK: Registry

    func testRegistryPrunesDeadPids() throws {
        let dir = try makeTempDir()
        setenv("PIER_TUNNEL_DIR", dir.path, 1)
        defer { unsetenv("PIER_TUNNEL_DIR") }
        // A pid that is certainly dead: spawn + reap a short-lived child.
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try p.run(); p.waitUntilExit()
        let dead = p.processIdentifier
        TunnelRegistry.add(TunnelRecord(port: 41001, pid: getpid(), url: "https://live.trycloudflare.com", startedAt: Date()))
        let raw = try Data(contentsOf: TunnelRegistry.fileURL)
        var text = String(decoding: raw, as: UTF8.self)
        XCTAssertTrue(text.contains("41001"))
        // inject a dead record by hand
        text = text.replacingOccurrences(of: "]", with: #",{"port":41002,"pid":\#(dead),"url":"https://dead.trycloudflare.com","startedAt":"2020-01-01T00:00:00Z"}]"#)
        try text.write(to: TunnelRegistry.fileURL, atomically: true, encoding: .utf8)
        let loaded = TunnelRegistry.load()
        XCTAssertEqual(loaded.map(\.port), [41001])
        XCTAssertFalse(String(decoding: try Data(contentsOf: TunnelRegistry.fileURL), as: UTF8.self).contains("41002"))
    }

    // MARK: Full expose flow with a fake cloudflared

    func testExposeFlowWithFakeCloudflared() async throws {
        let dir = try makeTempDir()
        let fake = dir.appendingPathComponent("cloudflared")
        try writeScript(fake, """
        #!/bin/sh
        echo "args: $@" >&2
        echo "2026-10-13T10:00:00Z INF Requesting new quick Tunnel on trycloudflare.com..." >&2
        echo "2026-10-13T10:00:01Z INF |  https://fake-flow-test.trycloudflare.com  |" >&2
        exec sleep 300
        """)
        setenv("PIER_CLOUDFLARED", fake.path, 1)
        setenv("PIER_TUNNEL_DIR", dir.path, 1)
        defer { unsetenv("PIER_CLOUDFLARED"); unsetenv("PIER_TUNNEL_DIR") }
        let port: UInt16 = 59123

        let url = try await TunnelLauncher.expose(port: port, timeout: 10)
        XCTAssertEqual(url, "https://fake-flow-test.trycloudflare.com")

        let rec = try XCTUnwrap(TunnelRegistry.record(port: port))
        XCTAssertEqual(rec.url, url)
        XCTAssertTrue(Killer.isAlive(rec.pid))
        XCTAssertEqual(getsid(rec.pid), rec.pid, "detached into its own session")

        let log = try String(contentsOf: TunnelRegistry.logURL(port: port), encoding: .utf8)
        XCTAssertTrue(log.contains("tunnel --no-autoupdate --url http://localhost:59123 --metrics 127.0.0.1:"), log)

        // Idempotent.
        let again = try await TunnelLauncher.expose(port: port, timeout: 10)
        XCTAssertEqual(again, url)
        XCTAssertEqual(TunnelRegistry.load().count, 1)

        // Detector finds it.
        var o = TunnelDetector.Options()
        o.ngrokPorts = []; o.includeCloudflaredProcesses = false; o.includeTailscale = false
        let found = await TunnelDetector.activeTunnels(options: o)
        XCTAssertEqual(found[port], url)

        // Stop.
        try TunnelLauncher.unexpose(port: port)
        XCTAssertFalse(Killer.isAlive(rec.pid))
        XCTAssertTrue(TunnelRegistry.load().isEmpty)
        let afterStop = await TunnelDetector.activeTunnels(options: o)
        XCTAssertNil(afterStop[port])
        XCTAssertThrowsError(try TunnelLauncher.unexpose(port: port))
    }

    func testExposeTimesOutAndCleansUp() async throws {
        let dir = try makeTempDir()
        let fake = dir.appendingPathComponent("cloudflared")
        try writeScript(fake, "#!/bin/sh\necho 'nothing useful' >&2\nexec sleep 300\n")
        setenv("PIER_CLOUDFLARED", fake.path, 1)
        setenv("PIER_TUNNEL_DIR", dir.path, 1)
        defer { unsetenv("PIER_CLOUDFLARED"); unsetenv("PIER_TUNNEL_DIR") }
        do {
            _ = try await TunnelLauncher.expose(port: 59124, timeout: 1)
            XCTFail("expected timeout")
        } catch let e as TunnelError {
            XCTAssertTrue(e.description.contains("timed out"), e.description)
        }
        XCTAssertTrue(TunnelRegistry.load().isEmpty)
    }

    func testExposeWithoutCloudflaredThrowsInstallHint() async {
        setenv("PIER_CLOUDFLARED", "/nonexistent/cloudflared", 1)
        setenv("PIER_TUNNEL_DIR", NSTemporaryDirectory() + "pier-t-empty-\(UUID().uuidString)", 1)
        defer { unsetenv("PIER_CLOUDFLARED"); unsetenv("PIER_TUNNEL_DIR") }
        do {
            _ = try await TunnelLauncher.expose(port: 59125)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual("\(error)", "cloudflared not installed (brew install cloudflared)")
        }
    }

    // MARK: Helpers

    private func makeTempDir() throws -> URL {
        let d = URL(fileURLWithPath: "/tmp/pier-t-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func writeScript(_ url: URL, _ body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
    }
}
