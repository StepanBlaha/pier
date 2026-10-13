import Foundation

// Shared data contracts. Every module reads/writes these, so change only with care.

public enum IPFamily: String, Codable, Sendable { case v4, v6 }

/// One listening TCP socket as seen by the kernel.
public struct ListeningSocket: Hashable, Codable, Sendable {
    public var port: UInt16
    public var pid: Int32
    /// Bound local address, e.g. "127.0.0.1", "::1", "0.0.0.0", "::", "192.168.1.5".
    public var address: String
    public var family: IPFamily

    public init(port: UInt16, pid: Int32, address: String, family: IPFamily) {
        self.port = port; self.pid = pid; self.address = address; self.family = family
    }
}

/// Snapshot of a process. Fields are nil when unreadable (other user / root without privileges).
public struct ProcInfo: Hashable, Codable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    /// Short name (p_comm / executable basename), e.g. "node".
    public var name: String
    public var executablePath: String?
    /// argv including argv[0].
    public var arguments: [String]
    public var cwd: String?
    public var startTime: Date?
    /// Instantaneous-ish CPU % (may be nil on first sample).
    public var cpuPercent: Double?
    public var rssBytes: UInt64?
    /// false when we could not read cwd/args (different uid, root).
    public var isAccessible: Bool

    public init(pid: Int32, ppid: Int32, uid: UInt32, name: String, executablePath: String? = nil,
                arguments: [String] = [], cwd: String? = nil, startTime: Date? = nil,
                cpuPercent: Double? = nil, rssBytes: UInt64? = nil, isAccessible: Bool = true) {
        self.pid = pid; self.ppid = ppid; self.uid = uid; self.name = name
        self.executablePath = executablePath; self.arguments = arguments; self.cwd = cwd
        self.startTime = startTime; self.cpuPercent = cpuPercent; self.rssBytes = rssBytes
        self.isAccessible = isAccessible
    }
}

public enum BindScope: String, Codable, Sendable {
    /// 127.0.0.1 / ::1 only.
    case loopback
    /// 0.0.0.0 / ::, reachable from LAN.
    case all
    /// Bound to a specific non-loopback interface address.
    case specific
}

public enum ServiceKind: String, Codable, Sendable {
    case devServer   // has a project cwd + recognizable dev runtime
    case infra       // database, cache, local AI, etc.
    case docker      // docker-proxied port
    case system      // macOS noise (ControlCenter, rapportd, ...)
    case other
}

public struct Framework: Hashable, Codable, Sendable {
    /// Stable id, lowercase: "next", "vite", "astro", "remix", "nuxt", "sveltekit", "rails", "django", "flask", "fastapi", "express", ...
    public var id: String
    /// Display name: "Next.js".
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public enum ProtocolKind: String, Codable, Sendable { case http, https, websocket, grpc, tcp, unknown }

public enum Health: String, Codable, Sendable {
    case ok        // 2xx/3xx/4xx (server answered sanely)
    case error     // 5xx
    case timeout   // no answer within timeout
    case unknown   // not probed / non-HTTP
}

public enum OwnerKind: String, Codable, Sendable {
    case vscode, cursor, zed, xcode, iterm, terminal, ghostty, warp, wezterm, kitty, alacritty, tmux, claudeCode, launchd, docker, other
}

public struct OwnerLink: Hashable, Codable, Sendable {
    public var pid: Int32
    public var name: String
    public var kind: OwnerKind
    public init(pid: Int32, name: String, kind: OwnerKind) { self.pid = pid; self.name = name; self.kind = kind }
}

public struct ProbeResult: Hashable, Codable, Sendable {
    public var protocolKind: ProtocolKind
    public var health: Health
    public var httpStatus: Int?
    /// <title> of the root page, trimmed.
    public var title: String?
    /// Absolute favicon URL (from <link rel=icon> or /favicon.ico if it exists).
    public var faviconURL: String?
    /// Server header, if any (helps identification, e.g. "Werkzeug").
    public var serverHeader: String?
    public init(protocolKind: ProtocolKind = .unknown, health: Health = .unknown, httpStatus: Int? = nil,
                title: String? = nil, faviconURL: String? = nil, serverHeader: String? = nil) {
        self.protocolKind = protocolKind; self.health = health; self.httpStatus = httpStatus
        self.title = title; self.faviconURL = faviconURL; self.serverHeader = serverHeader
    }
}

/// Docker container behind a published host port.
public struct DockerInfo: Hashable, Codable, Sendable {
    public var containerID: String
    public var containerName: String
    public var image: String
    public var containerPort: UInt16
    public var composeProject: String?
    public var composeService: String?
    public init(containerID: String, containerName: String, image: String, containerPort: UInt16,
                composeProject: String? = nil, composeService: String? = nil) {
        self.containerID = containerID; self.containerName = containerName; self.image = image
        self.containerPort = containerPort; self.composeProject = composeProject; self.composeService = composeService
    }
}

/// One row = one (port, pid). IPv4+IPv6 binds of the same pid/port are merged.
public struct Service: Identifiable, Hashable, Codable, Sendable {
    /// "\(port)-\(pid)"
    public var id: String { "\(port)-\(process.pid)" }
    public var port: UInt16
    public var process: ProcInfo
    /// All bound addresses for this (port, pid).
    public var addresses: [String]
    public var bindScope: BindScope
    /// e.g. "http://192.168.1.23:3000" when bindScope != .loopback.
    public var lanURL: String?

    public var kind: ServiceKind = .other
    /// Folder name of the project root (nearest ancestor of cwd with package.json / .git / pyproject / Gemfile ...).
    public var projectName: String?
    public var projectPath: String?
    public var framework: Framework?
    /// e.g. "PostgreSQL", "Redis", "Ollama".
    public var infraName: String?
    public var gitBranch: String?
    /// e.g. "node 20.11.1", "python 3.12.2".
    public var runtime: String?
    /// Parent chain, nearest first, already classified. Empty if unknown.
    public var owners: [OwnerLink] = []
    public var isNoise: Bool = false
    public var isManaged: Bool = false
    /// ManagedManifest.id when isManaged.
    public var managedID: String?
    public var docker: DockerInfo?
    /// Public URL if a tunnel (cloudflared / ngrok / tailscale funnel) points at this port.
    public var tunnelURL: String?
    public var probe: ProbeResult?

    public init(port: UInt16, process: ProcInfo, addresses: [String], bindScope: BindScope) {
        self.port = port; self.process = process; self.addresses = addresses; self.bindScope = bindScope
    }

    public var localURL: String {
        let scheme = probe?.protocolKind == .https ? "https" : "http"
        return "\(scheme)://localhost:\(port)"
    }

    /// Identity that survives restarts (pins, renames): project path, else docker container, else "name:port".
    public var stableKey: String {
        if let p = projectPath { return "project:\(p)" }
        if let d = docker { return "docker:\(d.containerName)" }
        return "\(infraName ?? process.name):\(port)"
    }

    /// Best human label: page title > infra name > project name > process name.
    public var displayName: String {
        if let t = probe?.title, !t.isEmpty { return t }
        if let i = infraName { return i }
        if let p = projectName { return p }
        return process.name
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, localURL, stableKey
        case managedID, docker, tunnelURL
        case port, process, addresses, bindScope, lanURL, kind, projectName, projectPath, framework,
             infraName, gitBranch, runtime, owners, isNoise, isManaged, probe
    }

    // Custom encode so JSON consumers (CLI --json, MCP) also get the computed fields.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(localURL, forKey: .localURL)
        try c.encode(stableKey, forKey: .stableKey)
        try c.encodeIfPresent(managedID, forKey: .managedID)
        try c.encodeIfPresent(docker, forKey: .docker)
        try c.encodeIfPresent(tunnelURL, forKey: .tunnelURL)
        try c.encode(port, forKey: .port)
        try c.encode(process, forKey: .process)
        try c.encode(addresses, forKey: .addresses)
        try c.encode(bindScope, forKey: .bindScope)
        try c.encodeIfPresent(lanURL, forKey: .lanURL)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(projectName, forKey: .projectName)
        try c.encodeIfPresent(projectPath, forKey: .projectPath)
        try c.encodeIfPresent(framework, forKey: .framework)
        try c.encodeIfPresent(infraName, forKey: .infraName)
        try c.encodeIfPresent(gitBranch, forKey: .gitBranch)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encode(owners, forKey: .owners)
        try c.encode(isNoise, forKey: .isNoise)
        try c.encode(isManaged, forKey: .isManaged)
        try c.encodeIfPresent(probe, forKey: .probe)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decode(UInt16.self, forKey: .port)
        process = try c.decode(ProcInfo.self, forKey: .process)
        addresses = try c.decode([String].self, forKey: .addresses)
        bindScope = try c.decode(BindScope.self, forKey: .bindScope)
        lanURL = try c.decodeIfPresent(String.self, forKey: .lanURL)
        kind = try c.decodeIfPresent(ServiceKind.self, forKey: .kind) ?? .other
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        framework = try c.decodeIfPresent(Framework.self, forKey: .framework)
        infraName = try c.decodeIfPresent(String.self, forKey: .infraName)
        gitBranch = try c.decodeIfPresent(String.self, forKey: .gitBranch)
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime)
        owners = try c.decodeIfPresent([OwnerLink].self, forKey: .owners) ?? []
        isNoise = try c.decodeIfPresent(Bool.self, forKey: .isNoise) ?? false
        isManaged = try c.decodeIfPresent(Bool.self, forKey: .isManaged) ?? false
        probe = try c.decodeIfPresent(ProbeResult.self, forKey: .probe)
        managedID = try c.decodeIfPresent(String.self, forKey: .managedID)
        docker = try c.decodeIfPresent(DockerInfo.self, forKey: .docker)
        tunnelURL = try c.decodeIfPresent(String.self, forKey: .tunnelURL)
    }
}
