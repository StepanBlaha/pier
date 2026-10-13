import ArgumentParser
import Darwin
import Foundation
import PierCore

struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Live, top-like view of services with keyboard actions.",
        discussion: """
        KEYS
          up/down, j   move       g G   top / bottom        enter   toggle detail pane
          o         open in browser          c   copy local URL
          k         kill (asks first)        /   filter (esc clears)
          a         show / hide system noise r   refresh now        q   quit
          ctrl-l    redraw                   ctrl-z   suspend
        """)

    @Flag(name: .shortAndLong, help: "Include system noise (AirPlay, rapportd, ...).") var all = false
    @Option(name: .shortAndLong, help: "Seconds between refreshes.") var interval: Double = 2

    func validate() throws {
        guard interval >= 0.5 else { throw ValidationError("--interval must be at least 0.5 seconds.") }
    }

    func run() async throws {
        let caps = Term.caps
        guard caps.stdinTTY, caps.stdoutTTY else {
            Term.err("pier watch needs an interactive terminal (stdin and stdout must be a TTY); try `pier ls`")
            throw ExitCode(1)
        }
        guard caps.cursorControl else {
            let term = ProcessInfo.processInfo.environment["TERM"] ?? ""
            Term.err("pier watch needs an interactive terminal (TERM is \(term.isEmpty ? "not set" : "\"\(term)\"")); try `pier ls`")
            throw ExitCode(1)
        }
        let term = RawTerminal()
        do { try term.enter() } catch {
            Term.fail(error.localizedDescription)
            throw ExitCode(1)
        }
        defer { term.leave() }
        try await WatchLoop(term: term, interval: interval, includeNoise: all).run()
    }
}

/// Results handed from background tasks to the (blocking, input-driven) main loop.
private final class Mailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: (includeNoise: Bool, services: [Service])?
    private var statuses: [(String, Bool)] = []
    private var refresh = false

    func post(snapshot: (Bool, [Service])) { lock.withLock { self.snapshot = snapshot } }
    func post(status: String, isError: Bool, refresh: Bool = false) {
        lock.withLock { statuses.append((status, isError)); if refresh { self.refresh = true } }
    }
    func drain() -> (snapshot: (includeNoise: Bool, services: [Service])?, statuses: [(String, Bool)], refresh: Bool) {
        lock.withLock {
            defer { snapshot = nil; statuses = []; refresh = false }
            return (snapshot, statuses, refresh)
        }
    }
}

private struct WatchLoop {
    let term: RawTerminal
    let interval: TimeInterval
    let includeNoise: Bool

    func run() async throws {
        var state = WatchState(interval: interval, includeNoise: includeNoise)
        var decoder = KeyDecoder()
        let mailbox = Mailbox()
        let caps = Term.caps
        // Color only if allowed; bold / reverse are fine on any terminal with cursor control (even under NO_COLOR).
        let style = WatchRenderer.Style(color: caps.color != .none, attributes: caps.cursorControl, unicode: caps.fancyGlyphs,
                                        mascot: Mascot.disabled(env: ProcessInfo.processInfo.environment) ? nil : MascotStyle(caps: caps))
        // A lone ESC is told apart from a sequence by timeout; slower links (ssh) get more time.
        let env = ProcessInfo.processInfo.environment
        let escapeWaitMs: Int32 = (env["SSH_CONNECTION"] != nil || env["SSH_TTY"] != nil) ? 150 : 40

        var size = RawTerminal.size()
        state.resize(cols: size.cols, rows: size.rows)

        var inFlight = false
        var queued = false
        var lastStart = Date.distantPast
        var dirty = true
        var fullRedraw = false
        var statusShown = false
        var pendingSince: Date?

        func startSnapshot(_ now: Date) {
            inFlight = true; lastStart = now
            let noise = state.includeNoise
            Task.detached {
                let services = await ServiceCatalog.snapshot(.init(includeNoise: noise))
                mailbox.post(snapshot: (noise, services))
            }
        }

        // First frame immediately ("scanning..."), then fill in.
        RawTerminal.write(WatchRenderer.frame(state, now: Date(), style: style))
        startSnapshot(Date())

        loop: while !term.quitRequested {
            let now = Date()

            let events = term.takeEvents()
            if events.resumed { term.resume(); fullRedraw = true; dirty = true }     // after SIGCONT
            if events.stop { term.suspend(); fullRedraw = true; dirty = true }       // external SIGTSTP
            let newSize = RawTerminal.size()
            if newSize != size || events.winch {
                if newSize != size { size = newSize; state.resize(cols: size.cols, rows: size.rows) }
                fullRedraw = true; dirty = true
            }

            let mail = mailbox.drain()
            if let snap = mail.snapshot {
                inFlight = false
                if snap.includeNoise == state.includeNoise {
                    state.update(services: snap.services, now: now)
                    dirty = true
                } else {
                    queued = true     // noise toggled while scanning: result is stale
                }
            }
            for (text, isError) in mail.statuses { state.setStatus(text, isError: isError, now: now); dirty = true }
            if mail.refresh { queued = true }

            if !inFlight, queued || now.timeIntervalSince(lastStart) >= interval {
                queued = false
                startSnapshot(now)
            }

            let showing = state.activeStatus(now: now) != nil
            if showing != statusShown { statusShown = showing; dirty = true }

            if dirty {
                dirty = false
                RawTerminal.write(WatchRenderer.frame(state, now: now, style: style, clear: fullRedraw))
                fullRedraw = false
            }

            var keys: [Key] = []
            switch term.read(timeoutMs: decoder.hasPending ? escapeWaitMs : 100) {
            case .bytes(let b): keys = decoder.feed(b)
            case .timeout: if decoder.hasPending && !decoder.isPasting { keys = decoder.flush() }
            case .eof: break loop
            }
            // A paste whose end marker never arrives must not swallow the keyboard forever.
            if decoder.isPasting {
                pendingSince = pendingSince ?? Date()
                if Date().timeIntervalSince(pendingSince!) > 3 { decoder.reset(); pendingSince = nil }
            } else { pendingSince = nil }

            for key in keys {
                dirty = true
                if key == .ctrl("z") {                      // raw mode: Ctrl-Z is a byte, not a signal
                    term.suspend()
                    fullRedraw = true
                    continue
                }
                guard let effect = state.handle(key, now: Date()) else { continue }
                switch effect {
                case .quit: break loop
                case .refresh: queued = true
                case .redraw: fullRedraw = true
                case .open(let s): Self.open(s, mailbox)
                case .copyURL(let s): Self.copy(s, mailbox)
                case .kill(let s): Self.kill(s, mailbox)
                }
            }
        }
    }

    // MARK: Effects (all off the main loop; output silenced so the TUI is never corrupted)

    private static func open(_ s: Service, _ mailbox: Mailbox) {
        let url = s.localURL
        Task.detached {
            let ok = run("/usr/bin/open", [url], input: nil)
            mailbox.post(status: ok ? "opened \(url)" : "open failed for \(url)", isError: !ok)
        }
    }

    private static func copy(_ s: Service, _ mailbox: Mailbox) {
        let url = s.localURL
        Task.detached {
            let ok = run("/usr/bin/pbcopy", [], input: Data(url.utf8))
            mailbox.post(status: ok ? "copied \(url)" : "copy failed (pbcopy)", isError: !ok)
        }
    }

    private static func kill(_ s: Service, _ mailbox: Mailbox) {
        Task.detached {
            do {
                // No elevation in the TUI: EPERM is reported, never prompted.
                let outcome = try await Killer.terminate(pid: s.process.pid)
                let (text, isError) = WatchState.killMessage(outcome, for: s)
                mailbox.post(status: text, isError: isError, refresh: true)
            } catch {
                mailbox.post(status: error.localizedDescription, isError: true)
            }
        }
    }

    private static func run(_ path: String, _ args: [String], input: Data?) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let pipe = input == nil ? nil : Pipe()
        if let pipe { p.standardInput = pipe } else { p.standardInput = FileHandle.nullDevice }
        do { try p.run() } catch { return false }
        if let pipe, let input {
            pipe.fileHandleForWriting.write(input)
            try? pipe.fileHandleForWriting.close()
        }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
