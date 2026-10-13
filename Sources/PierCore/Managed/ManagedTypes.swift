import Foundation

// CONTRACT: shared by `pier run` (wrapper), logs/restart, MCP, stacks and the app.
// Owner of implementations: Managed agent. Types here are final; change only with care.

/// Written by each `pier run` wrapper to ManagedPaths.runDir/<id>.json; removed on clean exit.
public struct ManagedManifest: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case starting, running, restarting, exited, crashed }

    /// Short random id (8 chars, [a-z0-9]), which keeps unix socket paths under the 104-byte limit.
    public var id: String
    /// Display name; defaults to the cwd's project folder name.
    public var name: String
    public var wrapperPid: Int32
    /// Current child pid (changes on restart). nil while (re)starting.
    public var childPid: Int32?
    public var command: [String]
    public var cwd: String
    /// Extra env vars applied on top of the wrapper's own env (used by adoption/restart and stacks).
    public var env: [String: String]?
    public var startedAt: Date
    public var restartedAt: Date?
    public var restartCount: Int
    public var state: State
    public var lastExitCode: Int32?
    /// true = no controlling terminal (spawned by app, adoption, stacks).
    public var detached: Bool
    /// pier.yml stack name, if started by `pier up`.
    public var stack: String?

    public init(id: String, name: String, wrapperPid: Int32, childPid: Int32?, command: [String], cwd: String,
                env: [String: String]? = nil, startedAt: Date = Date(), restartedAt: Date? = nil, restartCount: Int = 0,
                state: State = .starting, lastExitCode: Int32? = nil, detached: Bool = false, stack: String? = nil) {
        self.id = id; self.name = name; self.wrapperPid = wrapperPid; self.childPid = childPid; self.command = command
        self.cwd = cwd; self.env = env; self.startedAt = startedAt; self.restartedAt = restartedAt
        self.restartCount = restartCount; self.state = state; self.lastExitCode = lastExitCode
        self.detached = detached; self.stack = stack
    }

    public var socketPath: String { ManagedPaths.socketURL(id: id).path }
}

public enum ManagedPaths {
    /// ~/Library/Application Support/pier
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/pier", isDirectory: true)
    }
    public static var runDir: URL { root.appendingPathComponent("run", isDirectory: true) }
    public static func manifestURL(id: String) -> URL { runDir.appendingPathComponent("\(id).json") }
    public static func socketURL(id: String) -> URL { runDir.appendingPathComponent("\(id).sock") }
}

/// Wire protocol over the unix socket: client sends ONE JSON line (ManagedRequest),
/// server answers with ONE JSON line (ManagedResponse); for `.logs(follow: true)` it then keeps
/// streaming raw UTF-8 log bytes until the client disconnects.
public enum ManagedRequest: Codable, Sendable, Equatable {
    case status
    case logs(tail: Int, follow: Bool)
    case restart
    case stop
}

public struct ManagedResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var manifest: ManagedManifest?
    /// For `.logs`: the last `tail` lines (ANSI preserved).
    public var logs: String?
    public init(ok: Bool, error: String? = nil, manifest: ManagedManifest? = nil, logs: String? = nil) {
        self.ok = ok; self.error = error; self.manifest = manifest; self.logs = logs
    }
}

public enum ManagedError: Error, CustomStringConvertible {
    case notRunning(String), protocolError(String), spawnFailed(String)
    public var description: String {
        switch self {
        case .notRunning(let s): return "managed service not running: \(s)"
        case .protocolError(let s): return "protocol error: \(s)"
        case .spawnFailed(let s): return "spawn failed: \(s)"
        }
    }
}
