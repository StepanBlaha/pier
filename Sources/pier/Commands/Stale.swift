import ArgumentParser
import Foundation
import PierCore

/// Filters shared by `pier stale` and `pier prune`.
struct StaleFilters: ParsableArguments {
    @Option(help: "Minimum uptime in days.") var days: Double = 3
    @Option(name: .customLong("max-cpu"), help: "Maximum CPU % to count as idle.") var maxCPU: Double = 1
    @Flag(name: .customLong("include-infra"), help: "Also consider databases, Docker and other infra.") var includeInfra = false
    @Flag(name: .customLong("include-active"), help: "Also list servers that currently have open client connections.") var includeActive = false
    @Option(name: .customLong("port"), help: "Only consider this port (repeatable).") var ports: [UInt16] = []

    func validate() throws {
        if days < 0 { throw ValidationError("--days must be >= 0.") }
        if maxCPU < 0 { throw ValidationError("--max-cpu must be >= 0.") }
    }

    func find() async -> [StaleEntry] {
        let services = await ServiceCatalog.snapshot(.init(includeNoise: false, probe: false))
        return Staleness.find(in: services, minAge: days * 86_400, maxCPU: maxCPU,
                              includeInfra: includeInfra, includeActive: includeActive, ports: Set(ports))
    }
}

enum StaleOutput {
    static func table(_ entries: [StaleEntry], width: Int = Term.tableWidth, color: Bool = Term.color,
                      glyphs: Glyphs = Term.glyphs, asciiOnly: Bool = Term.asciiOnly) -> [String] {
        let rows = entries.map { e -> [String] in
            let s = e.service, p = s.process
            return [String(s.port), s.displayName, s.projectName ?? "-", Format.uptime(p) ?? "-",
                    p.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "-", p.rssBytes.map(Format.bytes) ?? "-",
                    e.verdict.reasons.joined(separator: ", ")]
        }
        var table = TextTable(headers: ["PORT", "NAME", "PROJECT", "UPTIME", "CPU", "MEM", "WHY"], rows: rows,
                              shrinkable: [1, 2, 6], dropOrder: [5, 4, 2, 3])
        table.ellipsis = glyphs.ellipsis
        table.asciiOnly = asciiOnly
        return table.render(maxWidth: width) { row, col, text in
            guard color else { return text }
            guard row != nil else { return Term.paint(text, .bold) }
            switch col {
            case 0: return Term.paint(text, .bold)
            default: return text
            }
        }
    }

    static func summary(_ entries: [StaleEntry]) -> (count: Int, memory: String) {
        (Set(entries.map(\.service.process.pid)).count, Format.bytes(Staleness.totalMemory(entries)))
    }
}

struct Stale: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List forgotten dev servers (long uptime, idle).",
        discussion: """
        A dev server is stale when it has been up at least --days, uses at most --max-cpu % CPU and
        has no established client connections (a browser tab with HMR open means it's in use).
        Infra, Docker and system services are skipped unless --include-infra.
        """)

    @OptionGroup var filters: StaleFilters
    @Flag(help: "Output JSON.") var json = false

    func run() async throws {
        let entries = await filters.find()
        if json { Term.out(try Output.json(entries)); return }
        guard !entries.isEmpty else {
            if !MascotUI.show(.coffee, text: ["No stale dev servers.", MascotUI.hint("nothing forgotten, time for a coffee")]) {
                Term.out("No stale dev servers.")
            }
            return
        }
        Term.out(StaleOutput.table(entries).joined(separator: "\n"))
        let (n, mem) = StaleOutput.summary(entries)
        Term.out("\n\(n) stale server\(n == 1 ? "" : "s") using \(mem). Run `pier prune` to stop \(n == 1 ? "it" : "them").")
    }
}

struct Prune: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Kill forgotten dev servers (see `pier stale`).",
        discussion: "Shows the same list as `pier stale`, asks once, then stops each (SIGTERM, then SIGKILL after 3s).")

    @OptionGroup var filters: StaleFilters
    @Flag(name: [.short, .long], help: "Don't ask for confirmation.") var yes = false
    @Flag(name: .customLong("dry-run"), help: "Show what would be stopped; stop nothing.") var dryRun = false

    func run() async throws {
        let entries = await filters.find()
        guard !entries.isEmpty else { print("No stale dev servers."); return }
        print(StaleOutput.table(entries).joined(separator: "\n"))

        // One kill per pid, even if it listens on several ports.
        var targets: [(pid: Int32, entries: [StaleEntry])] = []
        for e in entries {
            if let i = targets.firstIndex(where: { $0.pid == e.service.process.pid }) { targets[i].entries.append(e) }
            else { targets.append((e.service.process.pid, [e])) }
        }
        let n = targets.count, mem = StaleOutput.summary(entries).memory
        if dryRun {
            print("\nDry run: would stop \(n) server\(n == 1 ? "" : "s") using \(mem). Nothing was stopped.")
            return
        }
        print()
        if !yes {
            guard Term.canPrompt else {
                Term.fail("refusing to stop \(n) server\(n == 1 ? "" : "s") without confirmation; pass --yes (or --dry-run to preview)")
                throw ExitCode(1)
            }
            guard Term.confirm("Stop \(n) server\(n == 1 ? "" : "s")?") else {
                print("Aborted.")
                throw ExitCode(1)
            }
        }

        var failed = false
        var stopped = 0
        for t in targets {
            let s = t.entries[0].service
            let label = "\(Term.clean(s.displayName)) (pid \(t.pid)) on " + t.entries.map { ":\($0.service.port)" }.joined(separator: ", ")
            do {
                try Killer.validate(pid: t.pid)
                switch try await Killer.terminate(pid: t.pid) {
                case .terminated: print("Stopped \(label)"); stopped += 1
                case .killed: print("Force killed \(label)"); stopped += 1
                case .alreadyGone: print("\(label) already exited")
                case .permissionDenied: Term.fail("permission denied stopping \(label)"); failed = true
                case .stillRunning: Term.fail("\(label) is still running after SIGKILL"); failed = true
                case .failed(let e): Term.fail("failed to stop \(label): \(String(cString: strerror(e)))"); failed = true
                }
            } catch {
                Term.fail("\(error.localizedDescription) (\(label))")
                failed = true
            }
        }
        if failed { throw ExitCode(1) }
        if stopped > 0 {
            MascotUI.show(.celebrating, text: ["Stopped \(stopped) stale server\(stopped == 1 ? "" : "s").",
                                               MascotUI.hint("freeing up to \(mem)")], blankBefore: true)
        }
    }
}
