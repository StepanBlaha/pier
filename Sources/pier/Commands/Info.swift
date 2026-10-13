import ArgumentParser
import Foundation
import PierCore

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show everything pier knows about a service.")

    @Argument(help: "Port number or (fuzzy) name.", completion: TargetCompletion.kind) var target: String
    @Flag(help: "Output JSON.") var json = false

    func run() async throws {
        let s = try await Resolver.resolveOne(target)
        let config = ConfigStore.load()
        if json { Term.out(try Output.json(ServiceEntry(s, config: config))); return }

        let p = s.process
        var rows: [(String, String?)] = [
            ("Name", ConfigDisplay.name(s, config: config)),
            ("Auto name", ConfigDisplay.customName(s, config: config) == nil ? nil : s.displayName),
            ("Pinned", ConfigDisplay.isPinned(s, config: config) ? "yes" : nil),
            ("Port", String(s.port)),
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
        ]
        if let probe = s.probe {
            rows.append(("Health", Output.paintHealth(Output.healthText(s), probe.health)
                         + (probe.httpStatus.map { " (\($0))" } ?? "")))
            rows += [("Title", probe.title), ("Favicon", probe.faviconURL), ("Server", probe.serverHeader)]
        }
        rows += [
            ("Owners", s.owners.isEmpty ? nil : Format.ownerChain(s, unicode: Term.glyphs == .unicode)),
            ("Uptime", Format.uptime(p)),
            ("CPU", p.cpuPercent.map { String(format: "%.1f%%", $0) }),
            ("Memory", p.rssBytes.map(Format.bytes)),
            ("PID", "\(p.pid)  (parent \(p.ppid))"),
            ("Executable", p.executablePath),
            ("Command", p.arguments.isEmpty ? nil : p.arguments.joined(separator: " ")),
            ("Note", p.isAccessible ? nil : "limited info (process belongs to another user or root)"),
        ]
        let shown = rows.compactMap { k, v in v.map { (k, $0) } }
        let pad = (shown.map { DisplayWidth.of($0.0) }.max() ?? 0) + 2
        // On a terminal, wrap long values under their own column; piped output is never wrapped.
        let avail = Term.caps.stdoutTTY ? Term.width - pad : Int.max / 4
        for (k, v) in shown {
            let lines = k == "Health" ? [v] : Self.wrap(Term.clean(v), width: max(10, avail))   // Health holds our own color escapes
            for (i, line) in lines.enumerated() {
                let label = i == 0 ? Term.paint(DisplayWidth.pad(k, to: pad), .bold) : String(repeating: " ", count: pad)
                Term.out(label + line)
            }
        }
    }

    /// Hard wrap by display width (breaking at a space when one is close), keeping grapheme clusters whole.
    /// Values may contain color escapes only in the health cell, which is short; measure ignoring them.
    static func wrap(_ s: String, width: Int) -> [String] {
        guard AnsiText.width(s) > width else { return [s] }
        var lines: [String] = [], cur = "", n = 0
        for c in s {
            let w = DisplayWidth.of(c)
            if n + w > width {
                if let sp = cur.lastIndex(of: " "), AnsiText.width(String(cur[sp...])) < width / 2, AnsiText.width(String(cur[..<sp])) > 0 {
                    let tail = String(cur[cur.index(after: sp)...])
                    lines.append(String(cur[..<sp]))
                    cur = tail; n = DisplayWidth.of(tail)
                } else {
                    lines.append(cur); cur = ""; n = 0
                }
            }
            cur.append(c); n += w
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }
}
