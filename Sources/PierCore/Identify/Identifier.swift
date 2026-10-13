import Foundation

public enum Identifier {
    /// Fill: kind, projectName/projectPath, framework, infraName, gitBranch, runtime, owners, isNoise, lanURL.
    /// `parents` = ProcScanner.parentChain(of: s.process.pid).
    public static func enrich(_ s: inout Service, parents: [ProcInfo]) {
        let p = s.process
        let f = ProcFacets(p)

        s.isNoise = NoiseRules.isNoise(f, cwd: p.cwd)

        if let root = ProjectLocator.projectRoot(cwd: p.cwd) {
            s.projectPath = root
            s.projectName = (root as NSString).lastPathComponent
            s.gitBranch = ProjectLocator.gitBranch(from: root)
        }

        let runtimeKey = RuntimeDetector.key(f)
        s.runtime = RuntimeDetector.runtime(f, process: p)
        s.framework = FrameworkDetector.detect(f, projectPath: s.projectPath, isJS: runtimeKey.map(RuntimeDetector.jsRuntimes.contains) ?? false)

        let isDocker = InfraDetector.isDockerProxy(f)
        let hasDevContext = s.projectPath != nil || s.framework != nil || runtimeKey != nil
        s.infraName = InfraDetector.match(f, port: s.port, isDocker: isDocker, hasDevContext: hasDevContext, isAccessible: p.isAccessible)?.name

        if s.isNoise { s.kind = .system }
        else if isDocker { s.kind = .docker }
        else if s.infraName != nil { s.kind = .infra }
        else if s.projectPath != nil && (s.framework != nil || runtimeKey != nil) { s.kind = .devServer }
        else { s.kind = .other }

        s.owners = OwnerClassifier.owners(from: parents)
        s.lanURL = lanURL(for: s)
    }

    /// Post-probe refinement (e.g. Server: Werkzeug → Flask when framework unknown).
    public static func refine(_ s: inout Service) {
        if isAppInternal(s) { s.isNoise = true; return }
        guard s.framework == nil, let probe = s.probe else { return }
        let server = probe.serverHeader?.lowercased() ?? ""
        let title = probe.title?.lowercased() ?? ""
        guard let hit = probeHints.first(where: { h in
            h.server.contains(where: server.contains) || h.title.contains(where: title.contains)
        }) else { return }
        s.framework = hit.framework
        if s.kind == .other && s.projectPath != nil { s.kind = .devServer }
    }

    /// Desktop-app helper ports (VS Code "Code Helper", Notion, Slack…): binary inside a .app bundle,
    /// no project, no infra match, and no page title to show. Apps that serve a real page (title) stay visible.
    static func isAppInternal(_ s: Service) -> Bool {
        guard s.projectPath == nil, s.infraName == nil, s.framework == nil,
              let exe = s.process.executablePath, exe.contains(".app/") else { return false }
        return (s.probe?.title ?? "").isEmpty
    }

    private struct ProbeHint {
        let framework: Framework
        var server: [String] = []
        var title: [String] = []
    }

    /// Server-header / <title> fingerprints, used only when argv + package.json found nothing.
    private static let probeHints: [ProbeHint] = [
        ProbeHint(framework: Framework(id: "flask", name: "Flask"), server: ["werkzeug"]),
        ProbeHint(framework: Framework(id: "fastapi", name: "FastAPI"), server: ["uvicorn", "hypercorn"]),
        ProbeHint(framework: Framework(id: "rails", name: "Rails"), server: ["webrick", "puma"]),
        ProbeHint(framework: Framework(id: "python-http", name: "Python http.server"), server: ["simplehttp"]),
        ProbeHint(framework: Framework(id: "vite", name: "Vite"), title: ["vite app", "vite +"]),
        ProbeHint(framework: Framework(id: "next", name: "Next.js"), title: ["create next app"]),
        ProbeHint(framework: Framework(id: "cra", name: "Create React App"), title: ["react app"]),
        ProbeHint(framework: Framework(id: "django", name: "Django"), title: ["the install worked successfully"]),
        ProbeHint(framework: Framework(id: "storybook", name: "Storybook"), title: ["storybook"]),
    ]

    // MARK: - Network

    private static let wildcards: Set<String> = ["0.0.0.0", "::", "*", "0:0:0:0:0:0:0:0"]

    /// Strips brackets, zone id and the IPv4-mapped prefix: "[::ffff:127.0.0.1]%lo0" → "127.0.0.1".
    static func normalize(address: String) -> String {
        var a = address.lowercased()
        if a.hasPrefix("["), let close = a.firstIndex(of: "]") { a = String(a[a.index(after: a.startIndex)..<close]) }
        if let pct = a.firstIndex(of: "%") { a = String(a[..<pct]) }
        if a.hasPrefix("::ffff:") { a.removeFirst("::ffff:".count) }
        return a
    }

    static func isLoopback(_ a: String) -> Bool { a.hasPrefix("127.") || a == "::1" || a == "localhost" }

    /// Merge addresses → scope. Any wildcard ("0.0.0.0", "::", "*") → .all; all loopback → .loopback; else .specific.
    public static func bindScope(for addresses: [String]) -> BindScope {
        let norm = addresses.map(normalize(address:))
        if norm.contains(where: wildcards.contains) { return .all }
        if norm.allSatisfy(isLoopback) { return .loopback }
        return .specific
    }

    static func lanURL(for s: Service) -> String? {
        let ip: String?
        switch s.bindScope {
        case .loopback: return nil
        case .all: ip = lanIPv4()
        case .specific:
            ip = s.addresses.map(normalize(address:)).first { !isLoopback($0) && isIPv4($0) }
        }
        return ip.map { "http://\($0):\(s.port)" }
    }

    private static func isIPv4(_ a: String) -> Bool {
        let parts = a.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    private static let skippedInterfacePrefixes = ["lo", "utun", "bridge", "awdl", "llw", "gif", "stf", "anpi", "ap", "vmenet", "vnic", "ppp"]

    /// Best LAN IPv4 among (interface, address) candidates: en0, en1, … first, then anything not skipped.
    /// Link-local (169.254.x.x) addresses are ignored.
    static func pickLAN(from candidates: [(name: String, ip: String)]) -> String? {
        let usable = candidates.filter { c in
            !c.ip.hasPrefix("169.254.") && !skippedInterfacePrefixes.contains { c.name.hasPrefix($0) }
        }
        func enIndex(_ name: String) -> Int? { name.hasPrefix("en") ? Int(name.dropFirst(2)) : nil }
        let ens = usable.compactMap { c in enIndex(c.name).map { ($0, c.ip) } }.sorted { $0.0 < $1.0 }
        return ens.first?.1 ?? usable.first?.ip
    }

    /// Primary LAN IPv4 (en0/en1...), nil if offline.
    public static func lanIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [(name: String, ip: String)] = []
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            candidates.append((String(cString: ifa.pointee.ifa_name), String(cString: buf)))
        }
        return pickLAN(from: candidates)
    }

    /// True if the service is known not to speak HTTP (Postgres, Redis, Mongo, MySQL...) — skip probing.
    public static func isKnownNonHTTP(_ s: Service) -> Bool {
        let rule = s.infraName.flatMap(InfraDetector.rule(named:))
        guard let rule else { return false }
        return rule.nonHTTP && !rule.httpPorts.contains(s.port)
    }
}
