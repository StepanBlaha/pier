import Foundation
import Darwin

/// A tunnel started by `pier expose`, persisted in `tunnels.json`.
public struct TunnelRecord: Codable, Hashable, Sendable {
    public var port: UInt16
    public var pid: Int32
    public var url: String
    public var startedAt: Date
    public init(port: UInt16, pid: Int32, url: String, startedAt: Date = Date()) {
        self.port = port; self.pid = pid; self.url = url; self.startedAt = startedAt
    }
}

/// Registry of tunnels pier started. File: `<root>/tunnels.json`; logs in `<root>/tunnels/<port>.log`.
/// `<root>` is ManagedPaths.root unless env PIER_TUNNEL_DIR is set (tests).
public enum TunnelRegistry {
    public static var directory: URL {
        if let d = ProcessInfo.processInfo.environment["PIER_TUNNEL_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d, isDirectory: true)
        }
        return ManagedPaths.root
    }
    public static var fileURL: URL { directory.appendingPathComponent("tunnels.json") }
    public static var logDirectory: URL { directory.appendingPathComponent("tunnels", isDirectory: true) }
    public static func logURL(port: UInt16) -> URL { logDirectory.appendingPathComponent("\(port).log") }

    /// Records whose process is still alive. With `prune`, dead ones are removed from the file.
    public static func load(prune: Bool = true) -> [TunnelRecord] {
        let all = read()
        let alive = all.filter(isAlive)
        if prune && alive.count != all.count { withLock { write(read().filter(isAlive)) } }
        return alive
    }

    public static func record(port: UInt16) -> TunnelRecord? { load().first { $0.port == port } }

    public static func add(_ record: TunnelRecord) {
        withLock {
            var all = read().filter { $0.port != record.port && isAlive($0) }
            all.append(record)
            write(all)
        }
    }

    public static func remove(port: UInt16) {
        withLock { write(read().filter { $0.port != port && isAlive($0) }) }
    }

    /// pid alive (not a zombie) and not a recycled pid (process started after the tunnel was registered).
    static func isAlive(_ r: TunnelRecord) -> Bool {
        guard r.pid > 1, Killer.isAlive(r.pid) else { return false }
        if let start = ProcScanner.processInfo(pid: r.pid)?.startTime, start > r.startedAt.addingTimeInterval(2) { return false }
        return true
    }

    // MARK: File IO

    private static func read() -> [TunnelRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([TunnelRecord].self, from: data)) ?? []
    }

    private static func write(_ records: [TunnelRecord]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(records) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func withLock<T>(_ body: () -> T) -> T {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("tunnels.lock").path, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return body()
    }
}
