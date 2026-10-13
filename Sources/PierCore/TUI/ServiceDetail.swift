import Foundation

/// Label/value fields describing one service, in display order; nil/empty values are dropped.
/// Plain text (no styling) so any front end (CLI info, TUI detail pane, menu bar app) can render it.
public enum ServiceDetail {
    public static func healthText(_ s: Service) -> String {
        guard let probe = s.probe else { return "unknown" }
        let word: String
        switch probe.health {
        case .ok: word = "ok"
        case .error: word = "error"
        case .timeout: word = "timeout"
        case .unknown: word = "unknown"
        }
        return word + (probe.httpStatus.map { " (\($0))" } ?? "")
    }

    public static func fields(_ s: Service, now: Date = Date(), unicode: Bool = true) -> [(label: String, value: String)] {
        let p = s.process
        var rows: [(String, String?)] = [
            ("Name", s.displayName),
            ("URL", s.localURL),
            ("LAN URL", s.lanURL),
            ("Kind", s.kind.rawValue + (s.isManaged ? " (managed)" : "") + (s.isNoise ? " (noise)" : "")),
            ("Project", s.projectName),
            ("Path", s.projectPath),
            ("Git branch", s.gitBranch),
            ("Framework", s.framework?.name),
            ("Infra", s.infraName),
            ("Runtime", s.runtime),
            ("Bind", "\(Format.bindLabel(s.bindScope)) (\(s.addresses.joined(separator: ", ")))"),
            ("Protocol", s.probe.map { $0.protocolKind.rawValue }),
            ("Health", s.probe == nil ? nil : healthText(s)),
            ("Title", s.probe?.title),
            ("Server", s.probe?.serverHeader),
            ("Owners", s.owners.isEmpty ? nil : Format.ownerChain(s, unicode: unicode)),
            ("Uptime", Format.uptime(p, now: now)),
            ("CPU", p.cpuPercent.map { String(format: "%.1f%%", $0) }),
            ("Memory", p.rssBytes.map(Format.bytes)),
            ("PID", "\(p.pid)  (parent \(p.ppid))"),
            ("Executable", p.executablePath),
            ("Command", p.arguments.isEmpty ? nil : p.arguments.joined(separator: " ")),
            ("Note", p.isAccessible ? nil : "limited info (process belongs to another user or root)"),
        ]
        rows.removeAll { ($0.1 ?? "").isEmpty }
        return rows.map { ($0.0, $0.1 ?? "") }
    }
}
