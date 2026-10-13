import Foundation
import Darwin
import PierCore

/// TTY detection, colors, prompts. Everything terminal-specific lives here; the decisions themselves
/// are pure functions in PierCore (`TermCaps`) so they are unit-tested.
enum Term {
    /// Detected once at startup from the real environment.
    static let caps: TermCaps = detect()

    static func detect() -> TermCaps {
        var w = winsize()
        var cols: Int?
        for fd in [STDOUT_FILENO, STDERR_FILENO, STDIN_FILENO] where isatty(fd) != 0 {
            if ioctl(fd, TIOCGWINSZ, &w) == 0, w.ws_col > 0 { cols = Int(w.ws_col); break }
        }
        return TermCaps.detect(env: ProcessInfo.processInfo.environment,
                               stdinTTY: isatty(STDIN_FILENO) != 0, stdoutTTY: isatty(STDOUT_FILENO) != 0,
                               stderrTTY: isatty(STDERR_FILENO) != 0, measuredColumns: cols)
    }

    static var stdoutIsTTY: Bool { caps.stdoutTTY }
    /// stdin and stdout are a terminal that can do cursor control (not dumb / unset TERM).
    static var interactive: Bool { caps.interactive }
    /// Plain "can prompt": stdin and stdout are TTYs (works even on a dumb terminal).
    static var canPrompt: Bool { caps.stdinTTY && caps.stdoutTTY }
    static var color: Bool { caps.color != .none }
    static var colorLevel: ColorLevel { caps.color }
    static var unicode: Bool { caps.unicode }
    static var glyphs: Glyphs { caps.glyphs }
    /// Replace non-ASCII data with "?" (only when writing to a terminal that is not UTF-8).
    static var asciiOnly: Bool { !caps.unicode && caps.stdoutTTY }

    /// Terminal width: TIOCGWINSZ, then $COLUMNS, then 80.
    static var width: Int { caps.width }
    /// Width tables may use: the terminal width, or unbounded when stdout is piped (never truncate data).
    static var tableWidth: Int { caps.tableWidth }

    /// The 16 basic colors plus bold / dim only; grey is dim (bright-black is invisible on some themes).
    enum Style: String {
        case bold = "1", dim = "2", red = "31", green = "32", yellow = "33"
        static let grey = Style.dim
    }

    static func paint(_ s: String, _ style: Style, enabled: Bool = Term.color) -> String {
        enabled ? "\u{1B}[\(style.rawValue)m\(s)\u{1B}[0m" : s
    }

    /// Untrusted text (page titles, argv, container names, ...) made safe for a terminal; single line.
    static func clean(_ s: String) -> String { Sanitize.line(s, asciiOnly: asciiOnly) }

    // MARK: Output

    /// Write to stdout through stdio (same buffer as `print`, so ordering is preserved). A closed pipe
    /// (`pier ls | head -1`) ends the process quietly with status 0.
    static func out(_ s: String, terminator: String = "\n") {
        fputs(s + terminator, stdout)
        if ferror(stdout) != 0 { brokenPipeExit() }
    }

    static func flush() {
        fflush(stdout)
        if ferror(stdout) != 0 { brokenPipeExit() }
    }

    private static func brokenPipeExit() -> Never {
        _exit(0)
    }

    /// Call first thing in `main`: ignore SIGPIPE (writes then fail with EPIPE instead of killing us).
    static func bootstrap() {
        signal(SIGPIPE, SIG_IGN)
        // Make sure buffered output is pushed out (and EPIPE handled) when we exit normally.
        atexit { if fflush(stdout) != 0 || ferror(stdout) != 0 { _exit(0) } }
    }

    static func err(_ message: String) {
        FileHandle.standardError.write(Data((Sanitize.text(message, asciiOnly: false) + "\n").utf8))
    }

    /// Prints "pier: message" to stderr.
    static func fail(_ message: String) {
        err("pier: " + message)
    }

    /// y/N prompt (on stdout, or stderr when stdout is redirected so it stays visible); default no.
    static func confirm(_ question: String) -> Bool {
        let prompt = Sanitize.text(question) + " [y/N] "
        if caps.stdoutTTY {
            fputs(prompt, stdout); fflush(stdout)
        } else {
            fputs(prompt, stderr); fflush(stderr)
        }
        guard let line = readLine() else { return false }
        return ["y", "yes"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
