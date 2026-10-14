import XCTest
import Darwin
@testable import PierCore

/// Blocking one-shot-per-connection server on a unix socket or an ephemeral loopback TCP port.
/// `respond` receives the raw request and returns the bytes to send (chunks are written with small pauses);
/// returning nil means "accept but never answer".
final class DockerFakeServer: @unchecked Sendable {
    let socketPath: String?
    let port: UInt16
    private let listenFD: Int32
    private let respond: @Sendable (String) -> [Data]?
    private let lock = NSLock()
    private var clients: [Int32] = []
    private(set) var requests: [String] = []

    static func unix(_ respond: @escaping @Sendable (String) -> [Data]?) throws -> DockerFakeServer {
        let path = "/tmp/pier-t-\(UInt32.random(in: 0..<UInt32.max)).sock"
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { b in for (i, c) in bytes.enumerated() { b[i] = UInt8(bitPattern: c) } }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0, listen(fd, 8) == 0 else { throw NSError(domain: "fake", code: Int(errno)) }
        return DockerFakeServer(fd: fd, path: path, port: 0, respond: respond)
    }

    static func tcp(_ respond: @escaping @Sendable (String) -> [Data]?) throws -> DockerFakeServer {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0, listen(fd, 8) == 0 else { throw NSError(domain: "fake", code: Int(errno)) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return DockerFakeServer(fd: fd, path: nil, port: UInt16(bigEndian: addr.sin_port), respond: respond)
    }

    private init(fd: Int32, path: String?, port: UInt16, respond: @escaping @Sendable (String) -> [Data]?) {
        listenFD = fd; socketPath = path; self.port = port; self.respond = respond
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let c = accept(listenFD, nil, nil)
            var nosig: Int32 = 1; setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
            if c < 0 { return }
            lock.lock(); clients.append(c); lock.unlock()
            Thread.detachNewThread { [self] in serve(c) }
        }
    }

    private func serve(_ c: Int32) {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while !data.suffix(4).elementsEqual([13, 10, 13, 10]) {
            let n = read(c, &buf, buf.count)
            if n <= 0 {
                lock.lock(); clients.removeAll { $0 == c }; lock.unlock()
                close(c); return
            }
            data.append(buf, count: n)
        }
        let req = String(decoding: data, as: UTF8.self)
        lock.lock(); requests.append(req); lock.unlock()
        guard let chunks = respond(req) else { return }   // hang: keep the fd open until stop()
        for ch in chunks {
            _ = ch.withUnsafeBytes { write(c, $0.baseAddress, ch.count) }
            usleep(5_000)
        }
        lock.lock(); clients.removeAll { $0 == c }; lock.unlock()
        close(c)
    }

    func stop() {
        // shutdown() first wakes the accept loop with an error, so it never re-enters accept() on a reused fd.
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        lock.lock(); clients.forEach { shutdown($0, SHUT_RDWR) }; lock.unlock()
        if let p = socketPath { unlink(p) }
    }

    static func ok(_ body: String, contentType: String = "application/json") -> [Data] {
        let b = Data(body.utf8)
        return [Data("HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(b.count)\r\nConnection: close\r\n\r\n".utf8), b]
    }

    /// Body split into odd-sized chunks, headers and chunk framing split across writes.
    static func chunked(_ body: String, size: Int = 37) -> [Data] {
        var out = [Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8)]
        let bytes = Array(body.utf8)
        var i = 0
        while i < bytes.count {
            let part = Array(bytes[i..<min(i + size, bytes.count)])
            out.append(Data("\(String(part.count, radix: 16))\r\n".utf8))
            out.append(Data(part))
            out.append(Data("\r\n".utf8))
            i += size
        }
        out.append(Data("0\r\n\r\n".utf8))
        return out
    }
}

final class DockerMapperTests: XCTestCase {
    override class func setUp() { super.setUp(); signal(SIGPIPE, SIG_IGN) }  // fake servers may write to closed peers

    static let fixture = """
    [
      {"Id":"abc123def4567890","Names":["/relay-db"],"Image":"postgres:16","Ports":[
         {"IP":"0.0.0.0","PrivatePort":5432,"PublicPort":15432,"Type":"tcp"},
         {"IP":"::","PrivatePort":5432,"PublicPort":15432,"Type":"tcp"},
         {"PrivatePort":9999,"Type":"tcp"},
         {"IP":"0.0.0.0","PrivatePort":53,"PublicPort":5353,"Type":"udp"}],
       "Labels":{"com.docker.compose.project":"relay","com.docker.compose.service":"db"}},
      {"Id":"ffff0000aaaa1111","Names":["/standalone","/alias"],"Image":"nginx:alpine","Ports":[
         {"IP":"127.0.0.1","PrivatePort":80,"PublicPort":8080,"Type":"tcp"}],"Labels":{}},
      {"Id":"no-ports","Names":["/idle"],"Image":"busybox","Ports":[],"Labels":null}
    ]
    """

    func testParseFixture() {
        let map = DockerMapper.parseContainers(Data(Self.fixture.utf8))
        XCTAssertEqual(Set(map.keys), [15432, 8080])
        let db = map[15432]
        XCTAssertEqual(db?.containerName, "relay-db")
        XCTAssertEqual(db?.containerID, "abc123def4567890")
        XCTAssertEqual(db?.image, "postgres:16")
        XCTAssertEqual(db?.containerPort, 5432)
        XCTAssertEqual(db?.composeProject, "relay")
        XCTAssertEqual(db?.composeService, "db")
        XCTAssertEqual(map[8080]?.containerName, "standalone")
        XCTAssertNil(map[8080]?.composeProject)
    }

    func testParseGarbage() {
        XCTAssertTrue(DockerMapper.parseContainers(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(DockerMapper.parseContainers(Data("{}".utf8)).isEmpty)
    }

    func testCandidateOrder() {
        let c = DockerMapper.candidateSockets(environment: ["DOCKER_HOST": "unix:///x/d.sock", "XDG_RUNTIME_DIR": "/run/user/1"], home: "/h")
        XCTAssertEqual(c, ["/x/d.sock", "/h/.docker/run/docker.sock", "/var/run/docker.sock", "/h/.orbstack/run/docker.sock",
                           "/h/.colima/default/docker.sock", "/h/.rd/docker.sock", "/run/user/1/podman/podman.sock"])
        // tcp:// DOCKER_HOST is ignored
        XCTAssertFalse(DockerMapper.candidateSockets(environment: ["DOCKER_HOST": "tcp://1.2.3.4:2375"], home: "/h").contains { $0.contains("2375") })
    }

    func testFakeServerContentLength() throws {
        let server = try DockerFakeServer.unix { _ in DockerFakeServer.ok(Self.fixture) }
        defer { server.stop() }
        let map = DockerMapper.publishedPorts(environment: ["DOCKER_HOST": "unix://" + server.socketPath!], home: "/nonexistent")
        XCTAssertEqual(map[15432]?.composeService, "db")
        XCTAssertEqual(map.count, 2)
        XCTAssertTrue(server.requests.first?.hasPrefix("GET /containers/json HTTP/1.1") == true)
    }

    func testFakeServerChunked() throws {
        let server = try DockerFakeServer.unix { _ in DockerFakeServer.chunked(Self.fixture) }
        defer { server.stop() }
        let map = DockerMapper.publishedPorts(sockets: [server.socketPath!], budget: 3)
        XCTAssertEqual(map[8080]?.image, "nginx:alpine")
        XCTAssertEqual(map.count, 2)
    }

    func testStaleSocketFallsThroughToNext() throws {
        let server = try DockerFakeServer.unix { _ in DockerFakeServer.ok(Self.fixture) }
        defer { server.stop() }
        // First candidate is a path that is not connectable; second works.
        let map = DockerMapper.publishedPorts(sockets: ["/tmp/pier-no-such.sock", server.socketPath!], budget: 3)
        XCTAssertEqual(map.count, 2)
    }

    func testHangingServerHonoursBudget() throws {
        let server = try DockerFakeServer.unix { _ in nil }
        defer { server.stop() }
        let t0 = Date()
        let map = DockerMapper.publishedPorts(sockets: [server.socketPath!], budget: DockerMapper.budget)
        let dt = Date().timeIntervalSince(t0)
        XCTAssertTrue(map.isEmpty)
        XCTAssertLessThan(dt, 0.4)
        XCTAssertGreaterThan(dt, 0.1)
    }

    func testNon200IsIgnored() throws {
        let server = try DockerFakeServer.unix { _ in [Data("HTTP/1.1 500 Oops\r\nContent-Length: 2\r\n\r\n[]".utf8)] }
        defer { server.stop() }
        XCTAssertTrue(DockerMapper.publishedPorts(sockets: [server.socketPath!], budget: 0.3).isEmpty)
    }

    func testMissingSocketFastPath() {
        let t0 = Date()
        let map = DockerMapper.publishedPorts(environment: [:], home: "/nonexistent-home-\(UUID().uuidString)")
        XCTAssertTrue(map.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.02)
    }

    func testDechunk() {
        let (body, done) = LocalHTTP.dechunk(Array("4\r\nWiki\r\n5;ext=1\r\npedia\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "Wikipedia")
        XCTAssertTrue(done)
        let (partial, d2) = LocalHTTP.dechunk(Array("4\r\nWiki\r\n5\r\npe".utf8))
        XCTAssertEqual(String(decoding: partial, as: UTF8.self), "Wikipe")
        XCTAssertFalse(d2)
    }
}
