import ArgumentParser
import Foundation
import PierCore

// MARK: - pier run

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command in managed mode (logs + exact restart).",
        discussion: """
        No command: runs the "dev" script of ./package.json with the package manager its lockfile implies.
        Attached (default) the command runs on a pseudo-terminal, so colors and prompts work, and
        its output is also kept in a ring buffer for `pier logs`. --detach runs it in the background.

          pier run                      # npm/pnpm/yarn/bun run dev
          pier run -- python app.py
          pier run --detach --name api -- node server.js
        """)

    @Option(help: "Display name (default: the project folder).") var name: String?
    @Flag(help: "Run in the background; print the id and return.") var detach = false
    @Option(help: "Working directory (default: current).") var cwd: String?
    @Option(name: .customLong("env"), help: "Extra environment variable, KEY=VALUE (repeatable).") var env: [String] = []
    @Flag(help: "With --detach: print the manifest as JSON.") var json = false
    @Option(help: .hidden) var stack: String?
    @Option(name: .customLong("env-file"), help: .hidden) var envFile: String?
    @Option(name: .customLong("daemon-id"), help: .hidden) var daemonID: String?
    @Argument(parsing: .captureForPassthrough, help: "Command to run, after `--`.") var command: [String] = []

    func run() async throws {
        var cmd = command
        // The command is captured verbatim, so options only count before `--` / the first non-option word.
        if let f = cmd.first, f.hasPrefix("-"), f != "--" {
            if f == "-h" || f == "--help" { throw CleanExit.helpRequest(Self.self) }
            Term.fail("unknown option '\(f)'; put the command after `--`, e.g. pier run -- \(f) \(Term.glyphs.ellipsis)")
            throw ExitCode(64)
        }
        if cmd.first == "--" { cmd.removeFirst() }

        var dir = cwd ?? FileManager.default.currentDirectoryPath
        if !dir.hasPrefix("/") { dir = FileManager.default.currentDirectoryPath + "/" + dir }
        dir = URL(fileURLWithPath: dir).standardizedFileURL.path

        var envMap: [String: String] = [:]
        if let f = envFile { envMap = ManagedEnvFile.consume(path: f) }
        for pair in env {
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else {
                Term.fail("--env expects KEY=VALUE, got '\(pair)'"); throw ExitCode(64)
            }
            envMap[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }

        if cmd.isEmpty {
            switch ManagedDefaults.defaultCommand(cwd: dir) {
            case .success(let c): cmd = c
            case .failure(let e):
                Term.fail("\(e.message)\n  pass a command: pier run -- <cmd>")
                throw ExitCode(1)
            }
        }

        let displayName = name ?? ManagedDefaults.projectName(cwd: dir)
        let opts = ManagedWrapperOptions(id: ManagedCoding.newID(), name: displayName, command: cmd, cwd: dir,
                                         env: envMap.isEmpty ? nil : envMap, detached: detach || daemonID != nil, stack: stack)

        // Daemon half of --detach: a re-exec of ourselves in a fresh session with stdio on /dev/null.
        if let id = daemonID {
            setsid()
            var o = opts; o.id = id
            Foundation.exit(ManagedWrapper.run(o))
        }

        if detach {
            guard let exe = ManagedWrapper.currentExecutable() ?? ManagedLauncher.pierExecutable() else {
                Term.fail("cannot locate the pier executable"); throw ExitCode(1)
            }
            do {
                let m = try ManagedWrapper.startDetached(executable: exe, options: opts)
                if json {
                    print(String(decoding: try ManagedCoding.encoder().encode(m), as: UTF8.self))
                } else {
                    print("\(m.name) running in the background (id \(m.id), pid \(m.childPid.map(String.init) ?? "?")). Logs: pier logs \(m.name)")
                }
            } catch {
                Term.fail("\(error)")
                throw ExitCode(1)
            }
            return
        }

        let code = ManagedWrapper.run(opts)
        if code != 0 { throw ExitCode(code) }
    }
}

// MARK: - Target resolution shared by logs / restart

enum ManagedTargets {
    /// Managed service by id / name (works for crashed ones that aren't listening). nil = not found among managed.
    static func findManaged(_ target: String) throws -> ManagedManifest? {
        if UInt16(target) != nil { return nil }   // a port goes through the normal resolver
        let hits = ManagedRegistry.find(target, in: ManagedRegistry.all())
        if hits.count == 1 { return hits[0] }
        if hits.count > 1 {
            Term.fail("'\(target)' matches \(hits.count) managed services; use the id:")
            for m in hits { Term.err("  \(m.id)  \(m.name)  (\(m.state.rawValue))  \(m.cwd)") }
            throw ExitCode(2)
        }
        return nil
    }

    static func manifest(forManagedID id: String?) -> ManagedManifest? {
        guard let id else { return nil }
        return ManagedRegistry.all().first { $0.id == id }
    }
}

// MARK: - pier logs

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show logs of a managed service.",
        discussion: "Only services started by `pier run` (or adopted via `pier restart`) have logs. ANSI colors are stripped unless stdout is a color terminal or --raw is given.")

    @Argument(help: "Port, name or managed id.", completion: TargetCompletion.kind) var target: String
    @Flag(name: .shortAndLong, help: "Keep streaming new output until Ctrl-C.") var follow = false
    @Option(name: [.customShort("n"), .customLong("lines")], help: "Lines of history to show.") var lines: Int = 200
    @Flag(help: "Keep ANSI escape sequences.") var raw = false

    func run() async throws {
        let m: ManagedManifest
        if let found = try ManagedTargets.findManaged(target) {
            m = found
        } else {
            let s = try await Resolver.resolveOne(target, probe: false)
            guard let found = ManagedTargets.manifest(forManagedID: s.managedID) else {
                let n = s.projectName ?? s.displayName
                Term.fail("\(n) wasn't started by pier \(Term.glyphs.dash) `pier restart \(target)` adopts it so logs are captured")
                throw ExitCode(1)
            }
            m = found
        }

        let keepANSI = raw || (Term.color && ProcessInfo.processInfo.environment["TERM"] != "dumb")
        var stripper = ANSIStripper()
        func emit(_ s: String) {
            let out = keepANSI ? s : stripper.feed(s)
            if !out.isEmpty { Term.out(out, terminator: ""); Term.flush() }
        }

        if !follow {
            do {
                var text = try await ManagedClient.logs(m, tail: lines)
                if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
                emit(text)
            } catch {
                Term.fail("cannot read logs of \(m.name): \(error)")
                throw ExitCode(1)
            }
            return
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sigint.setEventHandler { Foundation.exit(0) }
        sigint.resume()
        do {
            for try await chunk in ManagedClient.followLogs(m, tail: lines) { emit(chunk) }
        } catch {
            Term.fail("lost connection to \(m.name): \(error)")
            throw ExitCode(1)
        }
        if !keepANSI { /* stream ended: service stopped */ }
        Term.err("pier: \(m.name) stopped")
    }
}

// MARK: - pier restart

struct Restart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restart a service (adopts discovered ones into managed mode).",
        discussion: """
        Managed services restart exactly (same command, cwd and env). Other dev servers are adopted: pier
        captures their command line, cwd and environment, stops them and starts them again in the
        background under a pier wrapper, so `pier logs` works from then on. Databases, Docker and
        system services are never restarted this way.
        """)

    @Argument(help: "Port, name or managed id.", completion: TargetCompletion.kind) var target: String
    @Flag(name: [.short, .long], help: "Don't ask before adopting.") var yes = false

    func run() async throws {
        if let m = try ManagedTargets.findManaged(target) {
            try await restartManaged(m)
            return
        }
        let s = try await Resolver.resolveOne(target, probe: false)
        let label = s.projectName ?? s.process.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? s.displayName

        if let m = ManagedTargets.manifest(forManagedID: s.managedID) {
            try await restartManaged(m)
            return
        }
        if let d = s.docker {
            refuse("\(label) runs in Docker. Use: docker restart \(d.containerName)")
        }
        if s.isNoise || s.kind == .system {
            refuse("\(label) is a macOS system service; pier doesn't restart those.")
        }
        if s.kind == .infra {
            refuse("\(label) is infrastructure. Restart it with its own tooling, e.g.: brew services restart \(Self.brewFormula(for: s))")
        }
        guard s.process.isAccessible, s.process.uid == getuid() else {
            refuse("\(label) belongs to another user (or its details are unreadable), so pier can't capture and respawn it.")
        }

        if !yes {
            let question = "Adopt and restart \(label)? It will keep running in the background under pier (`pier logs \(label)` for output)."
            guard Term.interactive else {
                Term.fail("\(question) Confirmation required; pass --yes to proceed non-interactively.")
                throw ExitCode(1)
            }
            guard Term.confirm(question) else { print("Aborted."); throw ExitCode(1) }
        }

        do {
            let r = try await ManagedLauncher.adoptWithReport(s)
            print("Adopted \(r.manifest.name) (id \(r.manifest.id)): \(r.command.joined(separator: " "))")
            if r.portListening {
                print("Listening on :\(s.port) again. Logs: pier logs \(r.manifest.name) -f")
            } else {
                print("Started, but :\(s.port) isn't accepting connections yet. Check: pier logs \(r.manifest.name) -f")
            }
        } catch {
            Term.fail("\(error)")
            throw ExitCode(1)
        }
    }

    private func restartManaged(_ m: ManagedManifest) async throws {
        do {
            try await ManagedClient.restart(m)
            let fresh = (try? await ManagedClient.status(m)) ?? m
            print("Restarted \(fresh.name) (restart #\(fresh.restartCount), pid \(fresh.childPid.map(String.init) ?? "?"))")
        } catch {
            Term.fail("couldn't restart \(m.name): \(error)")
            throw ExitCode(1)
        }
    }

    private func refuse(_ message: String) -> Never {
        Term.fail(message)
        Foundation.exit(1)
    }

    static func brewFormula(for s: Service) -> String {
        let n = (s.infraName ?? s.process.name).lowercased()
        let map: [(String, String)] = [
            ("postgres", "postgresql@16"), ("redis", "redis"), ("mongo", "mongodb-community"), ("mysql", "mysql"),
            ("mariadb", "mariadb"), ("memcache", "memcached"), ("rabbit", "rabbitmq"), ("elastic", "elasticsearch"),
            ("ollama", "ollama"), ("nginx", "nginx"), ("meilisearch", "meilisearch"),
        ]
        for (k, v) in map where n.contains(k) { return v }
        return n.split(separator: " ").first.map(String.init) ?? n
    }
}
