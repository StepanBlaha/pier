import ArgumentParser
import Foundation
import PierCore

// MARK: - shared helpers

private enum StackCLI {
    static func resolveFile(_ explicit: String?) throws -> URL {
        if let f = explicit {
            let u = URL(fileURLWithPath: (f as NSString).expandingTildeInPath)
            return u
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let u = StackLoader.find(from: cwd) else {
            Term.fail("no pier.yml found in \(cwd.path) or any parent directory (up to ~). Use -f FILE, or see docs/pier-yml.md.")
            throw ExitCode(1)
        }
        return u
    }

    static func load(_ explicit: String?) throws -> StackFile {
        let url = try resolveFile(explicit)
        do {
            let file = try StackLoader.load(url: url)
            for w in file.warnings { Term.err(Term.paint("warning: ", .yellow, enabled: Term.caps.stderrColor != .none) + w) }
            return file
        } catch let e as StackError {
            for line in e.description.split(separator: "\n") { Term.err("pier: \(line)") }
            throw ExitCode(1)
        }
    }

    static func json<T: Encodable>(_ v: T) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let d = try? enc.encode(v), let s = String(data: d, encoding: .utf8) { Term.out(s) }
    }

    static func stateLabel(_ s: StackServiceResult.State) -> String {
        switch s {
        case .ready: return "ready"
        case .started: return "started"
        case .alreadyRunning: return "already running"
        case .failed: return "FAILED"
        case .skipped: return "skipped"
        case .stopped: return "stopped"
        case .notRunning: return "not running"
        }
    }

    static func stateStyle(_ s: StackServiceResult.State) -> Term.Style {
        switch s {
        case .ready, .started, .alreadyRunning, .stopped: return .green
        case .failed: return .red
        case .skipped: return .yellow
        case .notRunning: return .grey
        }
    }

    static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

    static func table(_ results: [StackServiceResult]) {
        let nameW = max(7, results.map(\.name.count).max() ?? 0)
        let portW = 5
        let stateW = max(5, results.map { stateLabel($0.state).count }.max() ?? 0)
        Term.out(Term.paint(pad("SERVICE", nameW) + "  " + pad("PORT", portW) + "  " + pad("STATE", stateW) + "  URL", .bold))
        for r in results {
            let state = pad(stateLabel(r.state), stateW)
            Term.out(pad(r.name, nameW) + "  " + pad(r.port.map(String.init) ?? "-", portW) + "  "
                  + Term.paint(state, stateStyle(r.state)) + "  " + (r.url ?? "-"))
        }
        for r in results where r.detail != nil && (r.state.isFailure || r.state == .failed) {
            Term.out(Term.paint("  \(Term.clean(r.name)): \(Term.clean(r.detail!))", stateStyle(r.state)))
        }
    }
}

/// Progress output: plain lines when piped / dumb terminals, a one-line spinner on real TTYs.
private final class StackPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: String] = [:]     // service -> message (spinner)
    private var order: [String] = []
    private var lastPlainPing: [String: TimeInterval] = [:]
    private var spinner: Task<Void, Never>?
    private let nameWidth: Int
    private let fancy: Bool
    private var frame = 0
    private var spinnerShown = false

    init(nameWidth: Int) {
        self.nameWidth = nameWidth
        fancy = Term.stdoutIsTTY && Term.caps.cursorControl
    }

    func start() {
        guard fancy else { return }
        spinner = Task.detached { [self] in
            while !Task.isCancelled {
                self.tick()
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    func stop() {
        spinner?.cancel()
        lock.lock(); clearSpinner(); lock.unlock()
    }

    private func clearSpinner() {
        guard spinnerShown else { return }
        Term.out("\r" + String(repeating: " ", count: max(0, Term.width - 1)) + "\r", terminator: "")
        spinnerShown = false
    }

    private func tick() {
        lock.lock(); defer { lock.unlock() }
        guard !order.isEmpty else { clearSpinner(); Term.flush(); return }
        let frames = ["-", "\\", "|", "/"]
        frame += 1
        let items = order.map { "\($0): \(pending[$0] ?? "")" }.joined(separator: "  ")
        var line = "\(frames[frame % frames.count]) \(items)"
        let w = max(20, Term.width - 1)
        if line.count > w { line = String(line.prefix(w - 3)) + "..." }
        Term.out("\r" + line + String(repeating: " ", count: max(0, w - line.count)), terminator: "")
        Term.flush()
        spinnerShown = true
    }

    private func emit(_ text: String) {
        clearSpinner()
        Term.out(text)
        Term.flush()
    }

    private func label(_ name: String) -> String { "  " + StackCLI.pad(name, nameWidth) + "  " }

    func handle(_ e: StackEvent) {
        lock.lock(); defer { lock.unlock() }
        switch e {
        case .starting(let s, let m):
            if !order.contains(s) { order.append(s) }
            pending[s] = m
            emit(label(s) + "starting: " + Term.clean(m))
        case .waiting(let s, let m, let elapsed):
            pending[s] = "\(m) (\(Int(elapsed))s)"
            if !fancy {
                let last = lastPlainPing[s] ?? 0
                if elapsed - last >= 5 { lastPlainPing[s] = elapsed; emit(label(s) + "\(m) (\(Int(elapsed))s)") }
            }
        case .stopping(let s):
            if !order.contains(s) { order.append(s) }
            pending[s] = "stopping"
            emit(label(s) + "stopping")
        case .finished(let r):
            order.removeAll { $0 == r.name }
            pending[r.name] = nil
            var text = label(r.name) + Term.paint(StackCLI.stateLabel(r.state), StackCLI.stateStyle(r.state))
            if let p = r.port, r.state == .ready || r.state == .started || r.state == .alreadyRunning { text += " :\(p)" }
            if let d = r.detail { text += "  " + Term.clean(d) }
            emit(text)
        }
    }
}

// MARK: - pier up

struct Up: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start a stack from pier.yml (all services, managed).",
        discussion: """
        Starts the services of the nearest pier.yml (searched upward from the current directory, up to ~) \
        as managed services, dependencies first, waiting for each readiness check. \
        Pass service names to start only those (plus their dependencies). See docs/pier-yml.md.
        """)

    @Argument(help: "Services to start (default: all). Dependencies are started too.") var services: [String] = []
    @Option(name: [.short, .customLong("file")], help: "Path to pier.yml (or a directory containing it).") var file: String?
    @Flag(name: .customLong("dry-run"), help: "Print the start plan (waves) without starting anything.") var dryRun = false
    @Flag(help: "Output JSON.") var json = false

    private struct PlanService: Encodable {
        var name: String, command: [String], cwd: String, port: UInt16?, ready: String, dependsOn: [String]
        var env: [String: String]
    }
    private struct PlanOut: Encodable { var stack: String, file: String, waves: [[PlanService]] }
    private struct RunOut: Encodable {
        var stack: String, file: String, ok: Bool, waves: [[String]], services: [StackServiceResult]
    }

    func run() async throws {
        let stack = try StackCLI.load(file)
        let waves: [[ServiceName]]
        do { waves = try StackPlanner.plan(stack, selection: services) }
        catch let e as StackError { Term.fail("\(e)"); throw ExitCode(1) }

        if dryRun { printPlan(stack, waves); return }

        StackRegistry.record(name: stack.name, file: stack.path)
        let count = waves.reduce(0) { $0 + $1.count }
        let nameW = waves.flatMap { $0 }.map(\.count).max() ?? 8
        let printer = StackPrinter(nameWidth: nameW)
        var runner = StackRunner(onEvent: { _ in })
        if !json {
            Term.out("\(stack.name): starting \(count) service\(count == 1 ? "" : "s")" + (waves.count > 1 ? " in \(waves.count) waves" : ""))
            runner.onEvent = { printer.handle($0) }
            printer.start()
        }
        let result: StackRunResult
        do { result = try await runner.up(stack, selection: services) }
        catch { printer.stop(); Term.fail("\(error)"); throw ExitCode(1) }
        printer.stop()

        if json {
            StackCLI.json(RunOut(stack: stack.name, file: stack.path, ok: result.ok, waves: result.waves, services: result.services))
        } else {
            Term.out("")
            StackCLI.table(result.services)
        }
        if !result.ok { throw ExitCode(1) }
    }

    private func printPlan(_ stack: StackFile, _ waves: [[ServiceName]]) {
        if json {
            let out = PlanOut(stack: stack.name, file: stack.path, waves: waves.map { w in
                w.compactMap { stack.service($0) }.map {
                    PlanService(name: $0.name, command: $0.command, cwd: $0.cwd, port: $0.port, ready: $0.ready.label,
                                dependsOn: $0.dependsOn, env: $0.env)
                }
            })
            StackCLI.json(out)
            return
        }
        Term.out("\(stack.name)  (\(stack.path))")
        let nameW = waves.flatMap { $0 }.map(\.count).max() ?? 8
        for (i, wave) in waves.enumerated() {
            Term.out("wave \(i + 1)" + (wave.count > 1 ? "  (parallel)" : ""))
            for n in wave {
                guard let s = stack.service(n) else { continue }
                var line = "  " + StackCLI.pad(n, nameW) + "  " + Term.clean(s.display)
                var meta: [String] = []
                if let p = s.port { meta.append(":\(p)") }
                meta.append("ready: \(s.ready.label)")
                if !s.dependsOn.isEmpty { meta.append("after: \(s.dependsOn.joined(separator: ", "))") }
                if s.cwd != stack.directory { meta.append("cwd: \(Self.rel(s.cwd, to: stack.directory))") }
                line += "   " + Term.paint("[" + meta.joined(separator: "; ") + "]", .dim)
                Term.out(line)
            }
        }
    }

    static func rel(_ path: String, to base: String) -> String {
        path.hasPrefix(base + "/") ? "./" + path.dropFirst(base.count + 1) : path
    }
}

// MARK: - pier down

struct Down: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop a stack started with `pier up`.",
        discussion: "Stops the managed services of the nearest pier.yml's stack, dependents first. Pass service names to stop only those.")

    @Argument(help: "Services to stop (default: all of the stack).") var services: [String] = []
    @Option(name: [.short, .customLong("file")], help: "Path to pier.yml (or a directory containing it).") var file: String?
    @Flag(name: .customLong("all-stacks"), help: "Stop every stack started with `pier up`, regardless of directory.") var allStacks = false
    @Flag(help: "Output JSON.") var json = false

    private struct Out: Encodable { var stack: String?, ok: Bool, services: [StackServiceResult] }

    func run() async throws {
        let printer = StackPrinter(nameWidth: 8)
        var runner = StackRunner(onEvent: { _ in })
        let results: [StackServiceResult]
        var stackName: String?
        if allStacks {
            if !services.isEmpty { Term.fail("--all-stacks cannot be combined with service names"); throw ExitCode(2) }
            if !json { runner.onEvent = { printer.handle($0) }; printer.start() }
            results = await runner.downAll()
        } else {
            let stack = try StackCLI.load(file)
            stackName = stack.name
            if !json { runner.onEvent = { printer.handle($0) }; printer.start() }
            do { results = try await runner.down(stack, selection: services) }
            catch { printer.stop(); Term.fail("\(error)"); throw ExitCode(1) }
        }
        printer.stop()

        let ok = !results.contains { $0.state == .failed }
        if json { StackCLI.json(Out(stack: stackName, ok: ok, services: results)) }
        else if results.allSatisfy({ $0.state == .notRunning }) {
            Term.out(allStacks ? "no stacks running" : "\(stackName ?? "stack"): nothing running")
        } else {
            Term.out("\n\(stackName ?? "all stacks"): stopped \(results.filter { $0.state == .stopped }.count) service(s)")
        }
        if !ok { throw ExitCode(1) }
    }
}
