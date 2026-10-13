import Foundation
import Darwin

public struct StaleVerdict: Equatable, Codable, Sendable {
    /// Human reasons, e.g. ["up 11d", "idle 0.0% CPU", "no open connections"].
    public var reasons: [String]
    /// ESTABLISHED client connections to the service port right now; nil = unknown.
    public var activeConnections: Int?
    public init(reasons: [String], activeConnections: Int? = nil) {
        self.reasons = reasons; self.activeConnections = activeConnections
    }
}

public struct StaleEntry: Equatable, Codable, Sendable {
    public var service: Service
    public var verdict: StaleVerdict
    public var uptimeSeconds: Double
    public init(service: Service, verdict: StaleVerdict, uptimeSeconds: Double) {
        self.service = service; self.verdict = verdict; self.uptimeSeconds = uptimeSeconds
    }
}

/// Finds forgotten dev servers: old, idle, nobody connected.
public enum Staleness {
    public static let defaultMinAge: TimeInterval = 3 * 86_400
    public static let defaultMaxCPU: Double = 1.0

    /// Pure age + idle + kind check. nil = not stale.
    /// - Only `.devServer` and `.other` with a project path qualify; `.infra`/`.docker` only with `includeInfra`;
    ///   system / noise / unreadable processes never.
    /// - Connections are NOT considered here (see `find`); a nil `activeConnections` adds no connection reason.
    public static func evaluate(_ s: Service, now: Date, minAge: TimeInterval = defaultMinAge,
                                maxCPU: Double = defaultMaxCPU, includeInfra: Bool = false,
                                activeConnections: Int? = nil) -> StaleVerdict? {
        guard !s.isNoise, s.process.isAccessible else { return nil }
        switch s.kind {
        case .devServer: break
        case .other: guard s.projectPath != nil else { return nil }
        case .infra, .docker: guard includeInfra else { return nil }
        case .system: return nil
        }
        guard let start = s.process.startTime else { return nil }
        let age = now.timeIntervalSince(start)
        guard age >= minAge else { return nil }
        let cpu = s.process.cpuPercent ?? 0   // unknown counts as idle
        guard cpu <= maxCPU else { return nil }

        var reasons = ["up \(Format.duration(age))", String(format: "idle %.1f%% CPU", cpu)]
        if let n = activeConnections {
            reasons.append(n == 0 ? "no open connections" : "\(n) open connection\(n == 1 ? "" : "s")")
        }
        return StaleVerdict(reasons: reasons, activeConnections: activeConnections)
    }

    /// Evaluates all services (connection counting injectable for tests), drops ones that look in use
    /// (established connections) unless `includeActive`, sorted by uptime desc then port.
    public static func find(in services: [Service], now: Date = Date(),
                            minAge: TimeInterval = defaultMinAge, maxCPU: Double = defaultMaxCPU,
                            includeInfra: Bool = false, includeActive: Bool = false,
                            ports: Set<UInt16> = [],
                            connectionCount: (Service) -> Int? = { Connections.established(pid: $0.process.pid, port: $0.port) })
        -> [StaleEntry] {
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [StaleEntry] = []
        for s in services {
            guard s.process.pid > 1, s.process.pid != me else { continue }
            if !ports.isEmpty, !ports.contains(s.port) { continue }
            // Cheap checks first; only count connections for candidates.
            guard evaluate(s, now: now, minAge: minAge, maxCPU: maxCPU, includeInfra: includeInfra) != nil else { continue }
            let conns = connectionCount(s)
            if let c = conns, c > 0, !includeActive { continue }
            guard let verdict = evaluate(s, now: now, minAge: minAge, maxCPU: maxCPU, includeInfra: includeInfra,
                                         activeConnections: conns),
                  let start = s.process.startTime else { continue }
            out.append(StaleEntry(service: s, verdict: verdict, uptimeSeconds: now.timeIntervalSince(start)))
        }
        return out.sorted { ($1.uptimeSeconds, $0.service.port) < ($0.uptimeSeconds, $1.service.port) }
    }

    /// Total RSS across distinct pids (a pid listening on two ports counts once).
    public static func totalMemory(_ entries: [StaleEntry]) -> UInt64 {
        var seen = Set<Int32>(), total: UInt64 = 0
        for e in entries where seen.insert(e.service.process.pid).inserted { total += e.service.process.rssBytes ?? 0 }
        return total
    }
}
