import Foundation
import Darwin

/// Who currently holds a port (for conflict messages).
public struct StackPortHolder: Equatable, Sendable {
    public var pid: Int32?
    public var description: String
    public init(pid: Int32? = nil, description: String) { self.pid = pid; self.description = description }
}

/// Everything the runner needs from the outside world. Injected so tests can fake processes and ports.
public protocol StackBackend: Sendable {
    /// Live managed services (all stacks).
    func runningManifests() -> [ManagedManifest]
    func spawn(command: [String], cwd: String, env: [String: String]?, name: String, stack: String) async throws -> ManagedManifest
    func status(_ m: ManagedManifest) async throws -> ManagedManifest
    func logs(_ m: ManagedManifest, tail: Int) async throws -> String
    func stop(_ m: ManagedManifest) async throws
    /// Non-nil when something is already listening on `port`.
    func portHolder(_ port: UInt16) -> StackPortHolder?
    /// TCP connect succeeds on localhost:port.
    func isListening(_ port: UInt16) async -> Bool
    /// HTTP request to localhost:port gets a sane (< 500) answer.
    func httpHealthy(_ port: UInt16) async -> Bool
}

/// Production backend: ManagedLauncher / ManagedClient / ManagedRegistry + libproc + sockets.
public struct LiveStackBackend: StackBackend {
    public init() {}

    public func runningManifests() -> [ManagedManifest] { ManagedRegistry.all() }

    public func spawn(command: [String], cwd: String, env: [String: String]?, name: String, stack: String) async throws -> ManagedManifest {
        try await ManagedLauncher.spawnDetached(command: command, cwd: cwd, env: env, name: name, stack: stack)
    }
    public func status(_ m: ManagedManifest) async throws -> ManagedManifest { try await ManagedClient.status(m) }
    public func logs(_ m: ManagedManifest, tail: Int) async throws -> String { try await ManagedClient.logs(m, tail: tail) }
    public func stop(_ m: ManagedManifest) async throws { try await ManagedClient.stop(m) }

    public func portHolder(_ port: UInt16) -> StackPortHolder? {
        // Listening-socket scan only: a bind() probe would false-positive on TIME_WAIT right after `pier down`.
        guard let s = ServiceCatalog.quickSnapshot(includeNoise: true).first(where: { $0.port == port }) else { return nil }
        var d = "\(s.process.name) (pid \(s.process.pid)"
        if let p = s.projectName { d += ", project \(p)" }
        if let id = s.managedID, let m = ManagedRegistry.all().first(where: { $0.id == id }) { d += ", managed as \(m.name)" }
        d += ")"
        return StackPortHolder(pid: s.process.pid, description: d)
    }

    public func isListening(_ port: UInt16) async -> Bool { Self.canConnect(port) }

    public func httpHealthy(_ port: UInt16) async -> Bool {
        let r = await Prober.probe(port: port, timeout: 1.0)
        return r.health == .ok
    }

    /// Non-blocking connect to 127.0.0.1 then ::1 with a short timeout.
    static func canConnect(_ port: UInt16, timeout: Int32 = 300) -> Bool {
        for family in [AF_INET, AF_INET6] {
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var rc: Int32
            if family == AF_INET {
                var a = sockaddr_in()
                a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                a.sin_family = sa_family_t(AF_INET)
                a.sin_port = port.bigEndian
                inet_pton(AF_INET, "127.0.0.1", &a.sin_addr)
                rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            } else {
                var a = sockaddr_in6()
                a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                a.sin6_family = sa_family_t(AF_INET6)
                a.sin6_port = port.bigEndian
                inet_pton(AF_INET6, "::1", &a.sin6_addr)
                rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            }
            if rc == 0 { return true }
            guard errno == EINPROGRESS else { continue }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&p, 1, timeout) > 0 else { continue }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err == 0 { return true }
        }
        return false
    }
}
