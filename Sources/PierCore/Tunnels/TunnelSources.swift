import Foundation
import Darwin

/// Individual tunnel sources + their pure parsers. Everything here is blocking and budgeted;
/// `TunnelDetector` runs them concurrently.
enum TunnelSources {
    // MARK: Shared parsing

    /// "http://localhost:3000", "localhost:3000", "127.0.0.1:3000/path", "3000", "[::1]:3000" → 3000.
    static func parseLocalPort(_ addr: String) -> UInt16? {
        var s = addr.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        if let colon = s.lastIndex(of: ":") { s = String(s[s.index(after: colon)...]) }
        return UInt16(s)
    }

    private static func rank(_ url: String) -> Int {
        if url.hasPrefix("https://") { return 0 }
        if url.hasPrefix("http://") { return 1 }
        return 2
    }

    // MARK: ngrok

    /// `/api/tunnels` body → port → public URL (https preferred).
    static func parseNgrok(_ data: Data) -> [UInt16: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tunnels = root["tunnels"] as? [[String: Any]] else { return [:] }
        var out: [UInt16: String] = [:]
        for t in tunnels {
            guard let url = t["public_url"] as? String,
                  let addr = (t["config"] as? [String: Any])?["addr"] as? String,
                  let port = parseLocalPort(addr) else { continue }
            if let existing = out[port], rank(existing) <= rank(url) { continue }
            out[port] = url
        }
        return out
    }

    static func ngrok(ports: [UInt16], budget: TimeInterval) -> [UInt16: String] {
        var out: [UInt16: String] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: ports.count) { i in
            guard let r = LocalHTTP.get(.tcp(host: "127.0.0.1", port: ports[i]), path: "/api/tunnels", budget: budget),
                  r.status == 200 else { return }
            let found = parseNgrok(r.body)
            lock.lock(); defer { lock.unlock() }
            for (p, u) in found where out[p] == nil || rank(u) < rank(out[p]!) { out[p] = u }
        }
        return out
    }

    // MARK: cloudflared processes

    struct CloudflaredArgs: Equatable {
        var port: UInt16
        var metrics: String?   // "host:port"
    }

    /// Extracts `--url <addr>` and `--metrics <host:port>` (also `--flag=value`). Nil without a usable --url.
    static func parseCloudflaredArgs(_ args: [String]) -> CloudflaredArgs? {
        func value(of flag: String) -> String? {
            for (i, a) in args.enumerated() {
                if a == flag, i + 1 < args.count { return args[i + 1] }
                if a.hasPrefix(flag + "=") { return String(a.dropFirst(flag.count + 1)) }
            }
            return nil
        }
        guard let url = value(of: "--url"), let port = parseLocalPort(url) else { return nil }
        return CloudflaredArgs(port: port, metrics: value(of: "--metrics"))
    }

    /// `/quicktunnel` body → https URL.
    static func parseQuickTunnel(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = obj["hostname"] as? String, !host.isEmpty else { return nil }
        return host.hasPrefix("http") ? host : "https://\(host)"
    }

    static func metricsEndpoint(_ metrics: String) -> LocalHTTP.Endpoint? {
        guard let colon = metrics.lastIndex(of: ":"), let port = UInt16(metrics[metrics.index(after: colon)...]) else { return nil }
        var host = String(metrics[..<colon])
        if host.isEmpty || host == "0.0.0.0" || host == "localhost" { host = "127.0.0.1" }
        guard host.split(separator: ".").count == 4 else { return nil }   // IPv4 only
        return .tcp(host: host, port: port)
    }

    /// Public URL of a cloudflared quick tunnel via its metrics server.
    static func quickTunnelURL(metrics: String, budget: TimeInterval) -> String? {
        guard let ep = metricsEndpoint(metrics),
              let r = LocalHTTP.get(ep, path: "/quicktunnel", budget: budget), r.status == 200 else { return nil }
        return parseQuickTunnel(r.body)
    }

    /// pids whose process name mentions cloudflared (cheap proc_name filter before reading argv).
    static func cloudflaredPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard n > 0 else { return [] }
        var out: [Int32] = []
        var name = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(n)) where pid > 0 {
            if proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name).lowercased().contains("cloudflared") { out.append(pid) }
        }
        return out
    }

    /// Port → URL for cloudflared processes started elsewhere that expose a `--metrics` server.
    static func cloudflaredProcesses(budget: TimeInterval) -> [UInt16: String] {
        let infos = cloudflaredPids().compactMap { ProcScanner.processInfo(pid: $0) }
        var targets: [(UInt16, String)] = []
        for info in infos {
            guard let parsed = parseCloudflaredArgs(info.arguments), let m = parsed.metrics else { continue }
            targets.append((parsed.port, m))
        }
        var out: [UInt16: String] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: targets.count) { i in
            guard let url = quickTunnelURL(metrics: targets[i].1, budget: budget) else { return }
            lock.lock(); defer { lock.unlock() }
            if out[targets[i].0] == nil { out[targets[i].0] = url }
        }
        return out
    }

    // MARK: Tailscale Funnel

    static let tailscaleCandidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]

    static func tailscaleBinary() -> String? {
        let fm = FileManager.default
        if let o = ProcessInfo.processInfo.environment["PIER_TAILSCALE"], !o.isEmpty {
            return fm.isExecutableFile(atPath: o) ? o : nil
        }
        for c in tailscaleCandidates where fm.isExecutableFile(atPath: c) { return c }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/tailscale"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// `tailscale funnel status --json` → port → https URL, only for hosts listed in AllowFunnel.
    static func parseTailscaleFunnel(_ data: Data) -> [UInt16: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = root["Web"] as? [String: Any] else { return [:] }
        let allow = root["AllowFunnel"] as? [String: Any] ?? [:]
        var out: [UInt16: String] = [:]
        for hostPort in web.keys.sorted() {
            guard (allow[hostPort] as? Bool) == true,
                  let handlers = (web[hostPort] as? [String: Any])?["Handlers"] as? [String: Any] else { continue }
            var host = hostPort
            var suffix = ""
            if let colon = hostPort.lastIndex(of: ":") {
                host = String(hostPort[..<colon])
                let p = String(hostPort[hostPort.index(after: colon)...])
                if p != "443" { suffix = ":\(p)" }
            }
            for path in handlers.keys.sorted() {
                guard let proxy = (handlers[path] as? [String: Any])?["Proxy"] as? String,
                      let port = parseLocalPort(proxy), out[port] == nil else { continue }
                out[port] = "https://\(host)\(suffix)\(path == "/" ? "" : path)"
            }
        }
        return out
    }

    static func tailscaleFunnel(timeout: TimeInterval) -> [UInt16: String] {
        guard let bin = tailscaleBinary(),
              let out = runCapture(bin, ["funnel", "status", "--json"], timeout: timeout) else { return [:] }
        return parseTailscaleFunnel(out)
    }

    /// Runs a process, returning stdout, or nil on failure/timeout (the process is killed on timeout).
    static func runCapture(_ exe: String, _ args: [String], timeout: TimeInterval) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + 0.05) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }
}
