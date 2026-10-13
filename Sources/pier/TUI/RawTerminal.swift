import Foundation
import Darwin

// Signal flags: handlers only set these; the main loop acts on them (async-signal-safe).
private var gQuitSignal: sig_atomic_t = 0
private var gStopSignal: sig_atomic_t = 0
private var gContSignal: sig_atomic_t = 0
private var gWinchSignal: sig_atomic_t = 0
private var gOriginalTermios = termios()
private var gRawActive = false
private var gHooksInstalled = false

private func onQuitSignal(_ sig: Int32) { gQuitSignal = 1 }
private func onStopSignal(_ sig: Int32) { gStopSignal = 1 }
private func onContSignal(_ sig: Int32) { gContSignal = 1 }
private func onWinch(_ sig: Int32) { gWinchSignal = 1 }      // also interrupts poll()

/// Crash / abort: put the terminal back (async-signal-safe), then die with the original signal.
private func onFatalSignal(_ sig: Int32) {
    RawTerminal.restoreNow()
    signal(sig, SIG_DFL)
    raise(sig)
}

// Alternate screen on, cursor hidden, autowrap off (a wide glyph or last-column write can never scroll
// or wrap the frame), clear. Only sequences understood by xterm, tmux, screen, the Linux console and friends.
private let enterSequence: StaticString = "\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7l\u{1B}[2J\u{1B}[H"
// Reset attributes, clear the (alternate) screen so nothing is left behind where there is no alternate
// screen (Linux console, GNU screen with altscreen off), autowrap + cursor back, leave the alternate screen.
private let leaveSequence: StaticString = "\u{1B}[0m\u{1B}[2J\u{1B}[H\u{1B}[?7h\u{1B}[?25h\u{1B}[?1049l"

/// Raw-mode terminal on the alternate screen. `leave()` is idempotent and also runs from `atexit`
/// and from fatal-signal handlers, so the user's terminal is restored on every exit path.
final class RawTerminal {
    enum Read { case bytes([UInt8]), timeout, eof }

    struct Events { var winch = false, resumed = false, stop = false }

    var quitRequested: Bool { gQuitSignal != 0 }

    func enter() throws {
        guard tcgetattr(STDIN_FILENO, &gOriginalTermios) == 0 else {
            throw NSError(domain: "pier.tty", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "cannot read terminal attributes"])
        }
        try applyRaw()
        if !gHooksInstalled {
            gHooksInstalled = true
            atexit { RawTerminal.restoreNow() }
            Self.install(SIGINT, onQuitSignal)
            Self.install(SIGTERM, onQuitSignal)
            Self.install(SIGHUP, onQuitSignal)
            Self.install(SIGTSTP, onStopSignal)
            Self.install(SIGCONT, onContSignal)
            Self.install(SIGWINCH, onWinch)
            for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP, SIGQUIT] {
                Self.install(sig, onFatalSignal, resetHand: true)
            }
            signal(SIGPIPE, SIG_IGN)
        }
        Self.writeStatic(enterSequence)
    }

    private func applyRaw() throws {
        var raw = gOriginalTermios
        raw.c_iflag &= ~tcflag_t(ICRNL | INLCR | IXON | BRKINT | ISTRIP | INPCK)
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else {
            throw NSError(domain: "pier.tty", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "cannot enter raw mode"])
        }
        gRawActive = true
    }

    private static func install(_ sig: Int32, _ handler: @convention(c) (Int32) -> Void, resetHand: Bool = false) {
        var sa = sigaction()
        sa.__sigaction_u.__sa_handler = handler
        sigemptyset(&sa.sa_mask)
        sa.sa_flags = resetHand ? Int32(SA_RESETHAND | SA_NODEFER) : 0       // no SA_RESTART: poll() must see EINTR
        sigaction(sig, &sa, nil)
    }

    func leave() { Self.restoreNow() }

    /// Leaves the alternate screen, shows the cursor and restores the original termios. Async-signal-safe.
    static func restoreNow() {
        guard gRawActive else { return }
        gRawActive = false
        writeStatic(leaveSequence)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &gOriginalTermios)
    }

    /// Ctrl-Z / SIGTSTP: hand the terminal back, stop, and take it again after SIGCONT (the caller redraws).
    func suspend() {
        Self.restoreNow()
        gStopSignal = 0
        signal(SIGTSTP, SIG_DFL)
        raise(SIGTSTP)                       // stops here until the shell continues us
        Self.install(SIGTSTP, onStopSignal)
        resume()
    }

    /// Re-enter raw mode + alternate screen (after SIGCONT; also fixes up modes a shell may have changed).
    func resume() {
        gContSignal = 0
        if tcgetattr(STDIN_FILENO, &gOriginalTermios) == 0, (try? applyRaw()) != nil {
            Self.writeStatic(enterSequence)
        }
    }

    /// Pending asynchronous events since the last call.
    func takeEvents() -> Events {
        var e = Events()
        if gWinchSignal != 0 { gWinchSignal = 0; e.winch = true }
        if gContSignal != 0 { e.resumed = true }
        if gStopSignal != 0 { gStopSignal = 0; e.stop = true }
        return e
    }

    /// Wait up to `timeoutMs` for input.
    func read(timeoutMs: Int32) -> Read {
        var fd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let n = poll(&fd, 1, timeoutMs)
        if n <= 0 { return .timeout }                       // timeout or EINTR (signal)
        if fd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 && fd.revents & Int16(POLLIN) == 0 { return .eof }
        var buf = [UInt8](repeating: 0, count: 1024)
        let got = Darwin.read(STDIN_FILENO, &buf, buf.count)
        if got > 0 { return .bytes(Array(buf[0..<got])) }
        if got < 0, errno == EINTR || errno == EAGAIN { return .timeout }
        return .eof                                         // EOF or EIO (terminal went away)
    }

    /// TIOCGWINSZ on stdout / stderr / stdin, then $COLUMNS / $LINES, then 80x24 (some ttys report 0x0).
    static func size() -> (cols: Int, rows: Int) {
        var w = winsize()
        for fd in [STDOUT_FILENO, STDERR_FILENO, STDIN_FILENO] where isatty(fd) != 0 {
            if ioctl(fd, TIOCGWINSZ, &w) == 0, w.ws_col > 0, w.ws_row > 0 { return (Int(w.ws_col), Int(w.ws_row)) }
        }
        let env = ProcessInfo.processInfo.environment
        let cols = env["COLUMNS"].flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil } ?? 80
        let rows = env["LINES"].flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil } ?? 24
        return (cols, rows)
    }

    private static func writeStatic(_ s: StaticString) {
        var off = 0
        let total = s.utf8CodeUnitCount
        while off < total {
            let n = Darwin.write(STDOUT_FILENO, s.utf8Start + off, total - off)
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
            off += n
        }
    }

    /// One blocking write of the whole string (handles partial writes). A dead terminal requests quit.
    static func write(_ s: String) {
        let bytes = Array(s.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                gQuitSignal = 1                              // EIO / EPIPE: nobody is listening any more
                return
            }
            off += n
        }
    }
}
