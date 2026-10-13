import Foundation
import Darwin

// Building blocks for managed mode: coding, ring buffer, ANSI stripping, unix sockets, env capture.

// MARK: - Coding

/// JSON coding shared by the manifest file and the socket protocol (ISO-8601 dates with fractional seconds).
public enum ManagedCoding {
    private static func format(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
    private static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(format(date))
        }
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = parse(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
            }
            return date
        }
        return d
    }

    /// Fresh 8-char [a-z0-9] id that collides with no manifest in runDir.
    public static func newID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        while true {
            let id = String((0..<8).map { _ in alphabet.randomElement()! })
            if !FileManager.default.fileExists(atPath: ManagedPaths.manifestURL(id: id).path) { return id }
        }
    }
}

enum ManagedFiles {
    static func ensureRunDir() {
        try? FileManager.default.createDirectory(at: ManagedPaths.runDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// Atomic write (tmp + rename), mode 0600.
    static func writeAtomic(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ManagedError.spawnFailed("cannot write \(tmp.path)")
        }
        if rename(tmp.path, url.path) != 0 {
            let e = errno
            unlink(tmp.path)
            throw ManagedError.spawnFailed("cannot rename manifest: \(String(cString: strerror(e)))")
        }
    }

    static func writeManifest(_ m: ManagedManifest) {
        ensureRunDir()
        if let data = try? ManagedCoding.encoder().encode(m) {
            try? writeAtomic(data, to: ManagedPaths.manifestURL(id: m.id))
        }
    }

    static func readManifest(_ url: URL) -> ManagedManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? ManagedCoding.decoder().decode(ManagedManifest.self, from: data)
    }

    static func logURL(id: String) -> URL { ManagedPaths.runDir.appendingPathComponent("\(id).log") }
}

// MARK: - Env files (env overrides travel via a 0600 file, never argv, so secrets don't show in `ps`)

public enum ManagedEnvFile {
    public static func write(_ env: [String: String], id: String) throws -> String {
        ManagedFiles.ensureRunDir()
        let url = ManagedPaths.runDir.appendingPathComponent("\(id).env")
        try ManagedFiles.writeAtomic(try JSONEncoder().encode(env), to: url)
        return url.path
    }

    /// Reads and deletes the file.
    public static func consume(path: String) -> [String: String] {
        defer { unlink(path) }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let env = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return env
    }
}

// MARK: - Ring buffer

/// Last N lines / M bytes of output. ANSI preserved. Thread-safe.
public final class LogRingBuffer: @unchecked Sendable {
    public let maxLines: Int
    public let maxBytes: Int
    private let lock = NSLock()
    private var lines: [Data] = []     // completed lines, each including its trailing "\n"
    private var head = 0
    private var bytes = 0
    private var partial = Data()        // current unterminated line
    private let maxPartial = 64 * 1024

    public init(maxLines: Int = 10_000, maxBytes: Int = 2 * 1024 * 1024) {
        self.maxLines = maxLines; self.maxBytes = maxBytes
    }

    public var lineCount: Int { lock.lock(); defer { lock.unlock() }; return (lines.count - head) + (partial.isEmpty ? 0 : 1) }
    public var byteCount: Int { lock.lock(); defer { lock.unlock() }; return bytes + partial.count }
    /// True when the last line has no trailing newline yet.
    public var hasPartialLine: Bool { lock.lock(); defer { lock.unlock() }; return !partial.isEmpty }

    public func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        appendLocked(data)
    }

    public func append(_ string: String) { append(Data(string.utf8)) }

    private func appendLocked(_ data: Data) {
        var start = data.startIndex
        while let nl = data[start...].firstIndex(of: 0x0A) {
            partial.append(data[start...nl])
            commit(partial)
            partial = Data()
            start = data.index(after: nl)
        }
        if start < data.endIndex { partial.append(data[start...]) }
        if partial.count > maxPartial {            // endless line (progress bars): flush it as a line
            commit(partial)
            partial = Data()
        }
        trim()
    }

    private func commit(_ line: Data) {
        lines.append(line)
        bytes += line.count
    }

    private func trim() {
        while (lines.count - head > maxLines || bytes + partial.count > maxBytes) && head < lines.count {
            bytes -= lines[head].count
            head += 1
        }
        if head > 2048, head * 2 > lines.count {
            lines.removeFirst(head)
            head = 0
        }
    }

    /// Last `n` lines (a trailing unterminated line counts as one). n <= 0 → "".
    public func tail(_ n: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return tailLocked(n)
    }

    func tailLocked(_ n: Int) -> String {
        guard n > 0 else { return "" }
        var out = Data()
        let hasPartial = !partial.isEmpty
        let fromCompleted = max(0, n - (hasPartial ? 1 : 0))
        let first = max(head, lines.count - fromCompleted)
        for i in first..<lines.count { out.append(lines[i]) }
        if hasPartial { out.append(partial) }
        return String(decoding: out, as: UTF8.self)
    }

    public func all() -> String { tail(maxLines + 1) }
}

// MARK: - ANSI stripping

/// Streaming escape-sequence remover (CSI, OSC, DCS/APC/PM/SOS strings, 2-char escapes), bell and NUL.
/// Lone carriage returns (progress bars / spinners) become newlines; CRLF becomes LF.
public struct ANSIStripper: Sendable {
    private enum State { case normal, esc, csi, str, strEsc, escInter }
    private var state = State.normal
    private var pendingCR = false

    public init() {}

    public static func strip(_ s: String) -> String {
        var st = ANSIStripper()
        return st.feed(s)
    }

    public mutating func feed(_ input: String) -> String {
        var out = String.UnicodeScalarView()
        for u in input.unicodeScalars {
            let v = u.value
            switch state {
            case .normal:
                if pendingCR {
                    pendingCR = false
                    out.append("\n")
                    if v == 0x0A { continue }
                }
                switch v {
                case 0x1B: state = .esc
                case 0x0D: pendingCR = true
                case 0x07, 0x00: break
                default: out.append(u)
                }
            case .esc:
                switch v {
                case 0x5B: state = .csi                                   // [
                case 0x5D, 0x50, 0x58, 0x5E, 0x5F: state = .str           // ] P X ^ _
                case 0x20...0x2F: state = .escInter
                default: state = .normal                                  // 2-char escape
                }
            case .csi:
                if (0x40...0x7E).contains(v) { state = .normal }
            case .escInter:
                if (0x30...0x7E).contains(v) { state = .normal }
            case .str:
                if v == 0x07 { state = .normal } else if v == 0x1B { state = .strEsc }
            case .strEsc:
                state = (v == 0x5C) ? .normal : .str                     // ESC \ terminates
            }
        }
        return String(out)
    }
}

/// Decodes a byte stream into Strings without splitting multi-byte UTF-8 sequences across chunks.
public struct UTF8Chunker: Sendable {
    private var pending = [UInt8]()
    public init() {}

    public mutating func decode(_ data: Data) -> String {
        pending.append(contentsOf: data)
        var cut = pending.count
        // Look at the last up-to-3 bytes for an incomplete sequence.
        var i = pending.count - 1
        var back = 0
        while i >= 0, back < 4 {
            let b = pending[i]
            if b & 0xC0 == 0x80 { i -= 1; back += 1; continue }          // continuation byte
            let need = b >= 0xF0 ? 4 : (b >= 0xE0 ? 3 : (b >= 0xC0 ? 2 : 1))
            if need > back + 1 { cut = i }                                // lead byte lacking continuations
            break
        }
        let head = Array(pending[0..<cut])
        pending = Array(pending[cut...])
        return String(decoding: head, as: UTF8.self)
    }
}

// MARK: - Unix sockets

enum UnixSocket {
    static func address(_ path: String) -> (sockaddr_un, socklen_t)? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return (addr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }

    static func listen(path: String) throws -> Int32 {
        guard let (addr0, len) = address(path) else {
            throw ManagedError.spawnFailed("socket path too long (\(path.utf8.count) bytes)")
        }
        var addr = addr0
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ManagedError.spawnFailed("socket(): \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        unlink(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard rc == 0 else {
            let e = errno; close(fd)
            throw ManagedError.spawnFailed("bind \(path): \(String(cString: strerror(e)))")
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 32) == 0 else {
            let e = errno; close(fd); unlink(path)
            throw ManagedError.spawnFailed("listen: \(String(cString: strerror(e)))")
        }
        return fd
    }

    /// Connected blocking socket (with CLOEXEC / NOSIGPIPE), or nil.
    static func connect(path: String, timeout: TimeInterval) -> Int32? {
        guard let (addr0, len) = address(path) else { return nil }
        var addr = addr0
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) }
        }
        if rc != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { close(fd); return nil }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&p, 1, Int32(timeout * 1000)) > 0 else { close(fd); return nil }
            var err: Int32 = 0
            var elen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen)
            guard err == 0 else { close(fd); return nil }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    static func setTimeouts(_ fd: Int32, recv: TimeInterval?, send: TimeInterval?) {
        func tv(_ t: TimeInterval) -> timeval {
            timeval(tv_sec: Int(t), tv_usec: Int32((t - floor(t)) * 1_000_000))
        }
        var r = tv(recv ?? 0), s = tv(send ?? 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &r, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &s, socklen_t(MemoryLayout<timeval>.size))
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN {
                        var pf = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&pf, 1, 1000); continue
                    }
                    return false
                }
                if n == 0 { return false }
                p += n; left -= n
            }
            return true
        }
    }

    /// Reads up to and excluding the first "\n" (any bytes after it are discarded). nil on EOF-before-newline / timeout / overflow.
    static func readLine(_ fd: Int32, max: Int = 1 << 20) -> Data? {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while out.count <= max {
            let n = read(fd, &buf, buf.count)
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { return out.isEmpty ? nil : out }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                out.append(contentsOf: buf[0..<nl])
                return out
            }
            out.append(contentsOf: buf[0..<n])
        }
        return nil
    }
}

// MARK: - Process environment

public enum ProcEnvironment {
    /// Terminal-session variables that must not follow a process into a different terminal/session.
    public static let sessionVariables: Set<String> = [
        "TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE", "TMUX", "TMUX_PANE", "WINDOWID", "SHLVL", "_", "OLDPWD",
        "STY", "WT_SESSION", "KITTY_WINDOW_ID", "WEZTERM_PANE", "TERM_PROGRAM_SESSION_ID",
    ]

    /// Environment of `pid` via KERN_PROCARGS2 (same uid only; nil otherwise). Session variables are dropped.
    public static func read(pid: Int32, dropping: Set<String> = sessionVariables) -> [String: String]? {
        guard let raw = rawArgsAndEnv(pid: pid) else { return nil }
        var env: [String: String] = [:]
        for entry in raw.env {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<eq])
            guard !key.isEmpty, !dropping.contains(key) else { continue }
            env[key] = String(entry[entry.index(after: eq)...])
        }
        return env
    }

    /// argv + env strings out of a KERN_PROCARGS2 buffer: [argc:int32][exec_path\0][\0 padding][argv…][env…]
    static func parse(buffer buf: [UInt8]) -> (argv: [String], env: [String])? {
        guard buf.count > MemoryLayout<Int32>.size else { return nil }
        let argc = buf.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        while i < buf.count, buf[i] != 0 { i += 1 }
        while i < buf.count, buf[i] == 0 { i += 1 }
        func next() -> String? {
            guard i < buf.count else { return nil }
            var j = i
            while j < buf.count, buf[j] != 0 { j += 1 }
            let s = String(decoding: buf[i..<j], as: UTF8.self)
            i = j + 1
            return s
        }
        var argv: [String] = []
        while argv.count < argc, let a = next() { argv.append(a) }
        var env: [String] = []
        while let e = next(), !e.isEmpty { env.append(e) }   // an empty string ends the env block
        return (argv, env)
    }

    static func rawArgsAndEnv(pid: Int32) -> (argv: [String], env: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        buf.removeLast(buf.count - size)
        return parse(buffer: buf)
    }
}
