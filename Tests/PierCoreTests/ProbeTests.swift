import XCTest
import Darwin
@testable import PierCore

/// Tiny blocking TCP server on an ephemeral 127.0.0.1 port. `handler` runs once per accepted connection.
final class TestServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var clients: [Int32] = []

    init(handler: @escaping @Sendable (Int32) -> Void) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else { throw NSError(domain: "TestServer", code: Int(errno)) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &len) } }
        listenFD = fd
        port = UInt16(bigEndian: addr.sin_port)
        let listener = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(listener, nil, nil)
                if c < 0 { return }
                var one: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                self?.lock.withLock { self?.clients.append(c) }
                Thread.detachNewThread { handler(c) }
            }
        }
    }

    func stop() {
        shutdown(listenFD, SHUT_RDWR); close(listenFD)
        lock.withLock { clients.forEach { shutdown($0, SHUT_RDWR); close($0) } }
    }

    /// Serves a fixed raw response to every request, then closes.
    static func responding(_ raw: @escaping @Sendable (String) -> String) throws -> TestServer {
        try TestServer { fd in
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buf, buf.count)
            let req = n > 0 ? String(decoding: buf[..<n], as: UTF8.self) : ""
            let out = Array(raw(req).utf8)
            _ = write(fd, out, out.count)
            close(fd)
        }
    }

    static func http(status: String = "200 OK", headers: String = "Content-Type: text/html\r\n", body: String) throws -> TestServer {
        try responding { _ in "HTTP/1.1 \(status)\r\n\(headers)Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)" }
    }
}

final class ProbeTests: XCTestCase {
    override class func setUp() { super.setUp(); signal(SIGPIPE, SIG_IGN) }  // fake servers may write to closed peers

    func testHTMLTitleAndFavicon() async throws {
        let s = try TestServer.http(headers: "Content-Type: text/html; charset=utf-8\r\nServer: TestSrv/1\r\n",
                                    body: "<!doctype html><html><head>\n<TITLE data-x=1>  Haf &amp;\n Pet &#39;&#x41; </TITLE>\n<link rel=\"icon\" href=\"/static/fav.png\"></head><body></body></html>")
        defer { s.stop() }
        let r = await Prober.probe(port: s.port)
        XCTAssertEqual(r.protocolKind, .http)
        XCTAssertEqual(r.health, .ok)
        XCTAssertEqual(r.httpStatus, 200)
        XCTAssertEqual(r.title, "Haf & Pet 'A")
        XCTAssertEqual(r.faviconURL, "http://localhost:\(s.port)/static/fav.png")
        XCTAssertEqual(r.serverHeader, "TestSrv/1")
    }

    func testDefaultFaviconWhenNoLink() async throws {
        let s = try TestServer.http(body: "<html><head><title>x</title></head></html>")
        defer { s.stop() }
        let r = await Prober.probe(port: s.port)
        XCTAssertEqual(r.faviconURL, "http://localhost:\(s.port)/favicon.ico")
    }

    func testServerError() async throws {
        let s = try TestServer.http(status: "503 Service Unavailable", body: "nope")
        defer { s.stop() }
        let r = await Prober.probe(port: s.port)
        XCTAssertEqual(r.protocolKind, .http)
        XCTAssertEqual(r.health, .error)
        XCTAssertEqual(r.httpStatus, 503)
    }

    func test404IsOK() async throws {
        let s = try TestServer.http(status: "404 Not Found", body: "{}")
        defer { s.stop() }
        let r = await Prober.probe(port: s.port)
        XCTAssertEqual(r.health, .ok)
    }

    func testAcceptButNeverRespond() async throws {
        let s = try TestServer { fd in sleep(5); close(fd) }
        defer { s.stop() }
        let t0 = Date()
        let r = await Prober.probe(port: s.port, timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.3 * 2 + 0.2)
        XCTAssertEqual(r.protocolKind, .tcp)
        XCTAssertEqual(r.health, .timeout)
    }

    func testServerFirstBanner() async throws {
        let s = try TestServer { fd in
            let b = Array("SSH-2.0-test\r\n".utf8); _ = write(fd, b, b.count); sleep(1); close(fd)
        }
        defer { s.stop() }
        let r = await Prober.probe(port: s.port)
        XCTAssertEqual(r.protocolKind, .tcp)
        XCTAssertEqual(r.health, .unknown)
    }

    func testNonHTTPReplyIsTCP() async throws {
        let s = try TestServer.responding { _ in "-ERR unknown command\r\n" }
        defer { s.stop() }
        let r = await Prober.probe(port: s.port)
        XCTAssertEqual(r.protocolKind, .tcp)
        XCTAssertEqual(r.health, .unknown)
    }

    /// Documented behaviour: a port nobody listens on yields protocol .unknown, health .timeout, and returns fast.
    func testClosedPort() async throws {
        let s = try TestServer { close($0) }
        let port = s.port
        s.stop()
        let t0 = Date()
        let r = await Prober.probe(port: port)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.6)
        XCTAssertEqual(r.protocolKind, .unknown)
        XCTAssertEqual(r.health, .timeout)
    }

    func testRedirectFollowed() async throws {
        let s = try TestServer.responding { req in
            if req.hasPrefix("GET /home") {
                let body = "<html><head><title>Home</title><link rel='shortcut icon' href='img/i.ico'></head></html>"
                return "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            }
            return "HTTP/1.1 302 Found\r\nLocation: /home\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
        defer { s.stop() }
        let r = await Prober.probe(port: s.port)
        XCTAssertEqual(r.protocolKind, .http)
        XCTAssertEqual(r.httpStatus, 200)
        XCTAssertEqual(r.title, "Home")
        XCTAssertEqual(r.faviconURL, "http://localhost:\(s.port)/img/i.ico")
    }

    func testForeignRedirectNotFollowed() async throws {
        let s = try TestServer.responding { _ in "HTTP/1.1 301 Moved\r\nLocation: http://example.com/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
        defer { s.stop() }
        let r = await Prober.probe(port: s.port)
        XCTAssertEqual(r.httpStatus, 301)
        XCTAssertEqual(r.health, .ok)
        XCTAssertNil(r.title)
    }

    func testWebSocketUpgradeRequired() async throws {
        let s = try TestServer.http(status: "426 Upgrade Required", headers: "Upgrade: websocket\r\nContent-Type: text/plain\r\n", body: "upgrade")
        defer { s.stop() }
        let r = await Prober.probe(port: s.port)
        XCTAssertEqual(r.protocolKind, .websocket)
        XCTAssertEqual(r.health, .ok)
    }

    func testKeepAliveServerReturnsPromptly() async throws {
        // Server ignores Connection: close and keeps the socket open; completion must come from Content-Length.
        let s = try TestServer { fd in
            var buf = [UInt8](repeating: 0, count: 4096); _ = read(fd, &buf, buf.count)
            let body = "<title>KA</title>"
            let out = Array("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
            _ = write(fd, out, out.count); sleep(5); close(fd)
        }
        defer { s.stop() }
        let t0 = Date()
        let r = await Prober.probe(port: s.port, timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
        XCTAssertEqual(r.title, "KA")
    }

    func testChunkedBody() async throws {
        let s = try TestServer.responding { _ in
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n10\r\n<html><head><tit\r\n12\r\nle>Chunky</title></\r\n5\r\nhead>\r\n0\r\n\r\n"
        }
        defer { s.stop() }
        let r = await Prober.probe(port: s.port)
        XCTAssertEqual(r.title, "Chunky")
    }

    func testConcurrentProbes() async throws {
        let s = try TestServer.http(body: "<title>C</title>")
        defer { s.stop() }
        let port = s.port
        let results = await withTaskGroup(of: ProbeResult.self) { g in
            for _ in 0..<30 { g.addTask { await Prober.probe(port: port) } }
            return await g.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(results.filter { $0.title == "C" && $0.protocolKind == .http }.count, 30)
    }

    func testTitleParsing() {
        XCTAssertEqual(HTTPResponse.title(in: "<title>a&lt;b&gt; &quot;q&quot; &amp;lt;</title>"), "a<b> \"q\" &lt;")
        XCTAssertEqual(HTTPResponse.title(in: "<titlefoo><title>ok</title>"), "ok")
        XCTAssertEqual(HTTPResponse.title(in: "<title>" + String(repeating: "x", count: 300) + "</title>")?.count, 120)
        XCTAssertNil(HTTPResponse.title(in: "<title>  </title>"))
    }

    func testIconParsing() {
        XCTAssertEqual(HTTPResponse.iconHref(in: "<link rel=apple-touch-icon href=/a.png><link href='/i.svg' rel='icon' type=image/svg+xml>"), "/i.svg")
        XCTAssertEqual(HTTPResponse.iconHref(in: "<link rel=\"apple-touch-icon\" href=\"/a.png\">"), "/a.png")
        XCTAssertNil(HTTPResponse.iconHref(in: "<link rel=stylesheet href=/s.css><link rel=mask-icon href=/m.svg>"))
    }
}
