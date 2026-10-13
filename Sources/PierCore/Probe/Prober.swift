import Foundation

public enum Prober {
    /// Connect to 127.0.0.1:port (fallback ::1), sniff protocol, GET / for status+title+favicon.
    /// Never exceeds ~timeout*2 total. Closed / unreachable ports yield `.unknown` protocol with `.timeout` health.
    public static func probe(port: UInt16, timeout: TimeInterval = 0.3) async -> ProbeResult {
        let t = max(timeout, 0.05)
        return await Session(port: port, timeout: t, deadline: Date().addingTimeInterval(t * 2)).run()
    }
}

private struct Session {
    let port: UInt16
    let timeout: TimeInterval
    let deadline: Date

    private var budget: TimeInterval { max(0, min(timeout, deadline.timeIntervalSinceNow)) }

    func run() async -> ProbeResult {
        guard let (wire, host) = await connect(tls: false, preferred: nil) else {
            return ProbeResult(protocolKind: .unknown, health: .timeout)
        }
        defer { wire.close() }

        // 1. Server-first protocols (SSH, SMTP, MySQL, ...).
        let first = await wire.read(timeout: min(0.08, timeout / 3)) { !$0.isEmpty }
        if !first.data.isEmpty, !HTTPResponse.looksLikeHTTP(first.data) { return nonHTTP(first.data) }

        // 2. Plain HTTP request.
        if first.data.isEmpty, !first.closed {
            _ = await wire.send(HTTPResponse.request(path: "/", port: port))
        }
        let resp = await wire.read(timeout: budget) { HTTPResponse.isComplete($0) }

        if let r = HTTPResponse.parse(resp.data) { return await finish(r, tls: false, host: host) }
        if resp.data.isEmpty {
            // Silent close on plaintext: maybe TLS. Silence without close: accepted but mute.
            guard resp.closed else { return ProbeResult(protocolKind: .tcp, health: .timeout) }
            wire.close()
            return await runTLS(host: host)
        }
        if HTTPResponse.isTLSRecord(resp.data) {
            wire.close()
            return await runTLS(host: host)
        }
        return nonHTTP(resp.data)
    }

    // MARK: Branches

    private func nonHTTP(_ data: Data) -> ProbeResult {
        let isH2 = HTTPResponse.isH2Frame(data) || String(decoding: data.prefix(64), as: UTF8.self).contains("PRI *")
        return ProbeResult(protocolKind: isH2 ? .grpc : .tcp, health: .unknown)
    }

    private func runTLS(host: ProbeWire.Host) async -> ProbeResult {
        guard budget > 0.01, let (wire, _) = await connect(tls: true, preferred: host) else {
            return ProbeResult(protocolKind: .tcp, health: .unknown)
        }
        defer { wire.close() }
        _ = await wire.send(HTTPResponse.request(path: "/", port: port))
        let resp = await wire.read(timeout: budget) { HTTPResponse.isComplete($0) }
        if let r = HTTPResponse.parse(resp.data) { return await finish(r, tls: true, host: host) }
        if resp.data.isEmpty { return ProbeResult(protocolKind: .https, health: .timeout) }
        return nonHTTP(resp.data)
    }

    private func finish(_ first: HTTPResponse, tls: Bool, host: ProbeWire.Host) async -> ProbeResult {
        var final = first
        var scheme = tls ? "https" : "http"
        var path = "/"
        var kind: ProtocolKind = tls ? .https : .http
        if first.status == 426 || first.headers["upgrade"]?.lowercased().contains("websocket") == true { kind = .websocket }

        // Follow one same-host redirect.
        if first.status / 100 == 3, let loc = first.headers["location"], let t = redirectTarget(loc, scheme: scheme, path: path),
           budget > 0.05, let r2 = await fetch(path: t.path, tls: t.scheme == "https", host: host) {
            final = r2; scheme = t.scheme; path = t.path
        }

        var result = ProbeResult(protocolKind: kind, health: final.status / 100 == 5 ? .error : .ok, httpStatus: final.status)
        result.serverHeader = first.headers["server"] ?? final.headers["server"]
        if final.looksLikeHTML {
            let html = final.html
            result.title = HTTPResponse.title(in: html)
            result.faviconURL = HTTPResponse.iconHref(in: html).flatMap { resolve($0, scheme: scheme, path: path) }
        }
        result.faviconURL = result.faviconURL ?? "\(scheme)://localhost:\(port)/favicon.ico"
        return result
    }

    // MARK: Helpers

    private func fetch(path: String, tls: Bool, host: ProbeWire.Host) async -> HTTPResponse? {
        guard let (wire, _) = await connect(tls: tls, preferred: host) else { return nil }
        defer { wire.close() }
        _ = await wire.send(HTTPResponse.request(path: path, port: port))
        return HTTPResponse.parse(await wire.read(timeout: budget) { HTTPResponse.isComplete($0) }.data)
    }

    /// 127.0.0.1 first, then ::1 (or the reverse when a family is already known to work).
    private func connect(tls: Bool, preferred: ProbeWire.Host?) async -> (ProbeWire, ProbeWire.Host)? {
        let order: [ProbeWire.Host] = preferred == .v6 ? [.v6, .v4] : [.v4, .v6]
        for host in order {
            guard budget > 0.01 else { return nil }
            let wire = ProbeWire(port: port, host: host, tls: tls)
            if await wire.open(timeout: budget) { return (wire, host) }
            wire.close()
            if preferred != nil { break }   // family already known: no point retrying the other
        }
        return nil
    }

    private func base(scheme: String, path: String) -> URL? { URL(string: "\(scheme)://localhost:\(port)\(path)") }

    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// Same-host, same-port redirect target, or nil.
    private func redirectTarget(_ location: String, scheme: String, path: String) -> (scheme: String, path: String)? {
        guard let b = base(scheme: scheme, path: path), let url = URL(string: location, relativeTo: b)?.absoluteURL,
              let s = url.scheme, s == "http" || s == "https",
              let h = url.host?.lowercased(), Self.localHosts.contains(h),
              (url.port ?? (s == "https" ? 443 : 80)) == Int(port),
              let c = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        let p = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath + (c.percentEncodedQuery.map { "?" + $0 } ?? "")
        return (s == scheme && p == path) ? nil : (s, p)
    }

    /// Absolute favicon URL; only local hosts are accepted (pier never reaches out to CDNs).
    private func resolve(_ href: String, scheme: String, path: String) -> String? {
        guard let b = base(scheme: scheme, path: path), let url = URL(string: href, relativeTo: b)?.absoluteURL,
              let s = url.scheme, s == "http" || s == "https",
              let h = url.host?.lowercased(), Self.localHosts.contains(h) else { return nil }
        return url.absoluteString
    }
}
