import Foundation
import Darwin

public enum TunnelError: Error, LocalizedError, CustomStringConvertible {
    case cloudflaredMissing
    case spawnFailed(String)
    case noURL(String)
    case notExposed(UInt16)

    public var description: String {
        switch self {
        case .cloudflaredMissing: return "cloudflared not installed — brew install cloudflared"
        case .spawnFailed(let s): return "could not start cloudflared: \(s)"
        case .noURL(let s): return s
        case .notExposed(let p): return "no pier tunnel for :\(p)"
        }
    }
    public var errorDescription: String? { description }
}

public enum TunnelLauncher {
    /// cloudflared binary: env PIER_CLOUDFLARED, else PATH plus the usual Homebrew locations.
    public static func cloudflaredPath() -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        if let o = env["PIER_CLOUDFLARED"], !o.isEmpty { return fm.isExecutableFile(atPath: o) ? o : nil }
        var dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"] where !dirs.contains(extra) { dirs.append(extra) }
        for d in dirs {
            let p = "\(d)/cloudflared"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Start `cloudflared tunnel --url http://localhost:<port>` detached, wait for the trycloudflare URL, record it.
    public static func expose(port: UInt16) async throws -> String {
        try await expose(port: port, timeout: 25)
    }

    public static func expose(port: UInt16, timeout: TimeInterval) async throws -> String {
        if let existing = TunnelRegistry.record(port: port) { return existing.url }
        guard let bin = cloudflaredPath() else { throw TunnelError.cloudflaredMissing }

        let metricsPort = freeLoopbackPort()
        let logURL = TunnelRegistry.logURL(port: port)
        try? FileManager.default.createDirectory(at: TunnelRegistry.logDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let args = [bin, "tunnel", "--no-autoupdate", "--url", "http://localhost:\(port)", "--metrics", "127.0.0.1:\(metricsPort)"]
        let pid = try spawnDetached(args, log: logURL.path)

        let deadline = Date().addingTimeInterval(timeout)
        var lastMetricsCheck = Date()
        while Date() < deadline {
            if let url = urlFromLog(logURL) { return register(port: port, pid: pid, url: url) }
            if Date().timeIntervalSince(lastMetricsCheck) > 1 {
                lastMetricsCheck = Date()
                if let url = TunnelSources.quickTunnelURL(metrics: "127.0.0.1:\(metricsPort)", budget: 0.2),
                   isQuickTunnelHost(url) { return register(port: port, pid: pid, url: url) }
            }
            if exited(pid) {
                if let url = urlFromLog(logURL) { return register(port: port, pid: pid, url: url) }
                throw TunnelError.noURL("cloudflared exited before a tunnel was ready\n" + logTail(logURL))
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        terminate(pid: pid)
        throw TunnelError.noURL("timed out after \(Int(timeout))s waiting for a trycloudflare.com URL (log: \(logURL.path))\n" + logTail(logURL))
    }

    /// Stop a tunnel started by `expose`.
    public static func unexpose(port: UInt16) throws {
        guard let rec = TunnelRegistry.load(prune: false).first(where: { $0.port == port }) else {
            TunnelRegistry.remove(port: port)
            throw TunnelError.notExposed(port)
        }
        terminate(pid: rec.pid)
        TunnelRegistry.remove(port: port)
        try? FileManager.default.removeItem(at: TunnelRegistry.logURL(port: port))
    }

    // MARK: Internals

    private static func register(port: UInt16, pid: pid_t, url: String) -> String {
        TunnelRegistry.add(TunnelRecord(port: port, pid: pid, url: url, startedAt: Date()))
        return url
    }

    private static func isQuickTunnelHost(_ url: String) -> Bool { url.hasSuffix(".trycloudflare.com") && !url.hasPrefix("https://api.") }

    /// First `https://<name>.trycloudflare.com` in the log, ignoring the API endpoint cloudflared mentions in errors.
    static func extractTunnelURL(_ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "https://[a-zA-Z0-9-]+\\.trycloudflare\\.com") else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range)
            if s != "https://api.trycloudflare.com" { return s }
        }
        return nil
    }

    private static func urlFromLog(_ url: URL) -> String? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return extractTunnelURL(String(decoding: d, as: UTF8.self))
    }

    private static func logTail(_ url: URL, lines: Int = 6) -> String {
        guard let d = try? Data(contentsOf: url) else { return "" }
        return String(decoding: d, as: UTF8.self).split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    private static func freeLoopbackPort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 20241 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { return 20241 }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return UInt16(bigEndian: addr.sin_port)
    }

    /// posix_spawn into a new session (setsid) so the tunnel outlives pier and the terminal; stdio → log file.
    private static func spawnDetached(_ argv: [String], log: String) throws -> pid_t {
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&fa, 1, 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var none = sigset_t(); sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
        var all = sigset_t(); sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)

        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        let envStrings = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        let cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer { cEnv.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &fa, &attr, cArgs, cEnv)
        guard rc == 0 else { throw TunnelError.spawnFailed(String(cString: strerror(rc))) }
        return pid
    }

    /// Our own child that already exited (reaps it); false for non-children (their liveness is kill(0)-based).
    private static func exited(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid { return true }
        if r == -1 && errno == ECHILD { return !Killer.isAlive(pid) }
        return false
    }

    /// TERM then KILL (whole process group when we created it via setsid).
    private static func terminate(pid: pid_t) {
        guard pid > 1, pid != getpid() else { return }
        let group = getpgid(pid) == pid
        func send(_ sig: Int32) { _ = group ? killpg(pid, sig) : kill(pid, sig) }
        send(SIGTERM)
        for _ in 0..<30 where Killer.isAlive(pid) { _ = waitpid(pid, nil, WNOHANG); usleep(100_000) }
        _ = waitpid(pid, nil, WNOHANG)
        if Killer.isAlive(pid) {
            send(SIGKILL)
            for _ in 0..<20 where Killer.isAlive(pid) { _ = waitpid(pid, nil, WNOHANG); usleep(50_000) }
        }
    }
}
