import Foundation
import Darwin

/// Minimal blocking HTTP/1.1 GET client over a unix socket or loopback TCP, with a hard wall-clock budget.
/// Used for the Docker Engine API, the ngrok local API and cloudflared's metrics server.
enum LocalHTTP {
    enum Endpoint {
        case unix(String)
        case tcp(host: String, port: UInt16)
    }

    struct Response {
        var status: Int
        var headers: [String: String]   // lowercased names
        var body: Data
        /// True once the whole body has arrived (content-length satisfied / last chunk seen).
        var complete: Bool
    }

    /// GET `path`; nil on connect failure, timeout or a response that is not HTTP.
    static func get(_ endpoint: Endpoint, path: String, budget: TimeInterval) -> Response? {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(budget, 0) * 1_000_000_000)
        guard let fd = connectSocket(endpoint, deadline: deadline) else { return nil }
        defer { close(fd) }

        let host: String
        switch endpoint {
        case .unix: host = "localhost"
        case .tcp(let h, let p): host = "\(h):\(p)"
        }
        let request = Data("GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: pier\r\nAccept: application/json\r\nConnection: close\r\n\r\n".utf8)
        guard writeAll(fd, request, deadline: deadline) else { return nil }

        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if let r = parse(raw), r.complete { return r }
            guard wait(fd, events: Int16(POLLIN), deadline: deadline) else { break }
            let n = read(fd, &buf, buf.count)
            if n > 0 { raw.append(buf, count: n); continue }
            if n == 0 { break }                       // EOF
            if errno == EAGAIN || errno == EINTR { continue }
            break
        }
        // EOF without an explicit end marker still counts if headers parsed (Connection: close semantics).
        guard var r = parse(raw) else { return nil }
        if r.headers["content-length"] == nil && r.headers["transfer-encoding"]?.lowercased().contains("chunked") != true {
            r.complete = true
        }
        return r
    }

    // MARK: Parsing

    static func parse(_ data: Data) -> Response? {
        let bytes = [UInt8](data)
        guard bytes.starts(with: Array("HTTP/".utf8)) else { return nil }
        guard let headEnd = find(bytes, [13, 10, 13, 10], from: 0) else { return nil }
        let head = String(decoding: bytes[..<headEnd], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let statusParts = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = Array(bytes[(headEnd + 4)...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            let (decoded, done) = dechunk(body)
            return Response(status: status, headers: headers, body: Data(decoded), complete: done)
        }
        if let cl = headers["content-length"].flatMap({ Int($0) }) {
            return Response(status: status, headers: headers, body: Data(body.prefix(cl)), complete: body.count >= cl)
        }
        return Response(status: status, headers: headers, body: Data(body), complete: false)
    }

    /// Decodes chunked transfer encoding. `done` is true once the terminating zero chunk was seen.
    static func dechunk(_ bytes: [UInt8]) -> ([UInt8], Bool) {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            guard let eol = find(bytes, [13, 10], from: i) else { return (out, false) }
            var sizeText = String(decoding: bytes[i..<eol], as: UTF8.self)
            if let semi = sizeText.firstIndex(of: ";") { sizeText = String(sizeText[..<semi]) }
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return (out, false) }
            i = eol + 2
            if size == 0 { return (out, true) }
            guard i + size <= bytes.count else {
                out.append(contentsOf: bytes[i...])
                return (out, false)
            }
            out.append(contentsOf: bytes[i..<(i + size)])
            i += size + 2   // trailing CRLF
        }
        return (out, false)
    }

    private static func find(_ hay: [UInt8], _ needle: [UInt8], from: Int) -> Int? {
        guard needle.count > 0, hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
        var i = from
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == needle[0] && hay[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }

    // MARK: Sockets

    private static func remainingMillis(_ deadline: UInt64) -> Int32? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return nil }
        return Int32(min((deadline - now + 999_999) / 1_000_000, 60_000))
    }

    /// poll() until `events` or the deadline.
    private static func wait(_ fd: Int32, events: Int16, deadline: UInt64) -> Bool {
        while true {
            guard let ms = remainingMillis(deadline) else { return false }
            var p = pollfd(fd: fd, events: events, revents: 0)
            let r = poll(&p, 1, ms)
            if r > 0 { return true }   // ready, or error/hangup: the next read/write/SO_ERROR reports it
            if r == 0 { return false }
            if errno != EINTR { return false }
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data, deadline: UInt64) -> Bool {
        var sent = 0
        let bytes = [UInt8](data)
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            if n > 0 { sent += n; continue }
            if n < 0 && (errno == EAGAIN || errno == EINTR) {
                if !wait(fd, events: Int16(POLLOUT), deadline: deadline) { return false }
                continue
            }
            return false
        }
        return true
    }

    private static func connectSocket(_ endpoint: Endpoint, deadline: UInt64) -> Int32? {
        switch endpoint {
        case .unix(let path):
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                for (i, b) in bytes.enumerated() { buf[i] = UInt8(bitPattern: b) }
            }
            addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connectNonBlocking(AF_UNIX, $0, socklen_t(MemoryLayout<sockaddr_un>.size), deadline: deadline)
                }
            }
        case .tcp(let host, let port):
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            let h = host == "localhost" ? "127.0.0.1" : host
            guard inet_pton(AF_INET, h, &addr.sin_addr) == 1 else { return nil }
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connectNonBlocking(AF_INET, $0, socklen_t(MemoryLayout<sockaddr_in>.size), deadline: deadline)
                }
            }
        }
    }

    private static func connectNonBlocking(_ family: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t, deadline: UInt64) -> Int32? {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        if connect(fd, addr, len) == 0 { return fd }
        if errno == EINPROGRESS || errno == EAGAIN {
            if wait(fd, events: Int16(POLLOUT), deadline: deadline) {
                var err: Int32 = 0
                var errLen = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errLen) == 0, err == 0 { return fd }
            }
        }
        close(fd)
        return nil
    }
}
