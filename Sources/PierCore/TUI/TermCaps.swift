import Foundation

// Terminal capability detection. Pure logic (environment + isatty answers in, decisions out) so every
// combination of TERM / locale / NO_COLOR / piping can be unit-tested without a terminal.

public enum ColorLevel: Int, Comparable, Sendable {
    case none = 0, basic16, ansi256, truecolor
    public static func < (a: ColorLevel, b: ColorLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Decorative glyphs; the ASCII set is used when the locale / terminal can't be trusted with Unicode.
public struct Glyphs: Equatable, Sendable {
    public var bullet: String        // health dot
    public var ellipsis: String
    public var chevron: String       // owner chain separator
    public var sep: String           // inline field separator
    public var dash: String
    public var selector: String      // selected row marker
    public var cursor: String        // text cursor in the filter prompt
    public var refresh: String
    public var enter: String
    public var arrows: String
    public var rule: String          // horizontal rule
    public var openQuote: String
    public var closeQuote: String

    public static let unicode = Glyphs(bullet: "●", ellipsis: "…", chevron: "›", sep: "·", dash: "-", selector: "▸",
                                       cursor: "█", refresh: "⟳", enter: "⏎", arrows: "↑↓", rule: "─",
                                       openQuote: "“", closeQuote: "”")
    public static let ascii = Glyphs(bullet: "*", ellipsis: "...", chevron: ">", sep: "|", dash: "-", selector: ">",
                                     cursor: "_", refresh: "~", enter: "enter", arrows: "up/down", rule: "-",
                                     openQuote: "\"", closeQuote: "\"")
}

public struct TermCaps: Equatable, Sendable {
    public var stdinTTY: Bool
    public var stdoutTTY: Bool
    public var stderrTTY: Bool
    /// Color level for stdout / stderr (only the 16 basic colors are ever emitted; the level is informational).
    public var color: ColorLevel
    public var stderrColor: ColorLevel
    /// Terminal can be sent UTF-8 text.
    public var unicode: Bool
    /// Decorative symbols are safe (Unicode, and not a CJK locale where ambiguous-width glyphs often take 2 cells).
    public var fancyGlyphs: Bool
    /// Cursor addressing / alternate screen / bold / reverse are usable (false for dumb, unset or unknown TERM).
    public var cursorControl: Bool
    /// Measured by TIOCGWINSZ (nil when unavailable).
    public var measuredColumns: Int?
    public var columnsEnv: Int?

    public var glyphs: Glyphs { fancyGlyphs ? .unicode : .ascii }

    /// Full-screen interactive use (`pier watch`).
    public var interactive: Bool { stdinTTY && stdoutTTY && cursorControl }

    /// Terminal width for layout: TIOCGWINSZ, then $COLUMNS, then 80.
    public var width: Int { measuredColumns ?? columnsEnv ?? 80 }

    /// Width available to tables. Piped output is never truncated (it is data, not a display).
    public var tableWidth: Int { stdoutTTY ? width : Int.max / 4 }

    public static func detect(env: [String: String], stdinTTY: Bool, stdoutTTY: Bool, stderrTTY: Bool,
                              measuredColumns: Int? = nil) -> TermCaps {
        let unicode = unicodeSupported(env: env)
        return TermCaps(
            stdinTTY: stdinTTY, stdoutTTY: stdoutTTY, stderrTTY: stderrTTY,
            color: colorLevel(env: env, isTTY: stdoutTTY),
            stderrColor: colorLevel(env: env, isTTY: stderrTTY),
            unicode: unicode,
            fancyGlyphs: unicode && !cjkLocale(env: env),
            cursorControl: terminalIsCapable(env: env),
            measuredColumns: measuredColumns.flatMap { $0 > 0 ? $0 : nil },
            columnsEnv: env["COLUMNS"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil })
    }

    // MARK: Decisions

    private static func value(_ env: [String: String], _ key: String) -> String? {
        guard let v = env[key], !v.isEmpty else { return nil }
        return v
    }

    /// TERM is set to something that can take cursor addressing.
    public static func terminalIsCapable(env: [String: String]) -> Bool {
        guard let term = value(env, "TERM")?.lowercased() else { return false }
        return term != "dumb" && term != "unknown"
    }

    /// NO_COLOR (non-empty, any value) -> none; CLICOLOR_FORCE / FORCE_COLOR -> on even when piped;
    /// CLICOLOR=0 -> none; dumb / unset TERM -> none; otherwise a TTY gets color.
    public static func colorLevel(env: [String: String], isTTY: Bool) -> ColorLevel {
        if value(env, "NO_COLOR") != nil { return .none }

        var forced = false
        if let f = value(env, "CLICOLOR_FORCE"), f != "0" { forced = true }
        if let f = env["FORCE_COLOR"] {
            let t = f.lowercased()
            if t != "0" && t != "false" { forced = true }          // "" counts as on (chalk convention)
            else { return .none }
        }
        if !forced {
            if value(env, "CLICOLOR") == "0" { return .none }
            guard isTTY, terminalIsCapable(env: env) else { return .none }
        }
        let term = value(env, "TERM")?.lowercased() ?? ""
        let colorterm = value(env, "COLORTERM")?.lowercased() ?? ""
        if colorterm == "truecolor" || colorterm == "24bit" { return .truecolor }
        if term.contains("256color") || term.contains("direct") { return .ansi256 }
        return .basic16
    }

    /// LC_ALL > LC_CTYPE > LANG decides. With no locale at all (common for GUI-launched / ssh-without-SendEnv
    /// sessions) a terminal that announces itself via TERM_PROGRAM / WT_SESSION is trusted to be UTF-8.
    public static func unicodeSupported(env: [String: String]) -> Bool {
        let term = value(env, "TERM")?.lowercased()
        if term == "linux" || term == "dumb" { return false }
        for key in ["LC_ALL", "LC_CTYPE", "LANG"] {
            if let v = value(env, key) {
                let l = v.lowercased()
                return l.contains("utf-8") || l.contains("utf8")
            }
        }
        return value(env, "TERM_PROGRAM") != nil || value(env, "WT_SESSION") != nil
    }

    /// ja / zh / ko locales: terminals commonly render East Asian Ambiguous glyphs (● ─ … ·) two cells wide.
    public static func cjkLocale(env: [String: String]) -> Bool {
        for key in ["LC_ALL", "LC_CTYPE", "LANG"] {
            if let v = value(env, key) {
                let lang = v.lowercased().prefix { $0 != "_" && $0 != "." && $0 != "@" }
                return ["ja", "zh", "ko"].contains(String(lang))
            }
        }
        return false
    }

    /// SGR parameters for the QR code's explicit black-on-white (works on dark and light themes).
    public static func qrSGR(level: ColorLevel, term: String?) -> String {
        switch level {
        case .truecolor: return "38;2;0;0;0;48;2;255;255;255"
        case .ansi256: return "38;5;16;48;5;231"
        default:
            // Bright white background (107) is missing on the Linux console; plain white (47) there.
            return (term?.lowercased() == "linux") ? "30;47" : "30;107"
        }
    }
}

// MARK: - Display width

/// wcwidth-like cell widths: East Asian Wide / Fullwidth and emoji presentation = 2; combining marks,
/// ZWJ, variation selectors and controls = 0.
public enum DisplayWidth {
    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0xA4CF, 0xA960...0xA97F,
        0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
        0x16FE0...0x16FE4, 0x17000...0x18AFF, 0x1B000...0x1B2FF, 0x1F200...0x1F2FF, 0x20000...0x2FFFD, 0x30000...0x3FFFD,
        0x2329...0x232A,
    ]

    private static func isWide(_ v: UInt32) -> Bool {
        if v < 0x1100 { return false }
        return wideRanges.contains { $0.contains(v) }
    }

    private static func scalarWidth(_ s: Unicode.Scalar) -> Int {
        let v = s.value
        if v < 0x20 || (0x7F...0x9F).contains(v) { return 0 }
        if v < 0x300 { return 1 }
        switch s.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format, .control: return 0
        default: break
        }
        if (0xFE00...0xFE0F).contains(v) || v == 0x200B { return 0 }
        if isWide(v) { return 2 }
        if s.properties.isEmojiPresentation { return 2 }
        return 1
    }

    /// Cells taken by one grapheme cluster: the width of its first visible scalar, forced to 2 by an emoji
    /// presentation selector / ZWJ sequence unless a text selector says otherwise.
    public static func of(_ c: Character) -> Int {
        var first = 0
        var emojiSequence = false, textSelector = false
        for s in c.unicodeScalars {
            if first == 0 { first = scalarWidth(s) }
            if s.value == 0xFE0F || s.value == 0x200D { emojiSequence = true }
            if s.value == 0xFE0E { textSelector = true }
        }
        if first == 0 { return 0 }
        return emojiSequence && !textSelector ? 2 : first
    }

    public static func of(_ s: String) -> Int {
        var n = 0
        for c in s { n += of(c) }
        return n
    }

    /// Longest prefix that fits in `width` cells (never splits a grapheme cluster).
    public static func prefix(_ s: String, width: Int) -> String {
        guard width > 0 else { return "" }
        var out = "", n = 0
        for c in s {
            let w = of(c)
            if n + w > width { break }
            out.append(c); n += w
        }
        return out
    }

    /// Truncate to `width` cells, ending in `ellipsis` when something was cut.
    public static func truncate(_ s: String, to width: Int, ellipsis: String = "…") -> String {
        guard width > 0 else { return "" }
        if of(s) <= width { return s }
        let e = of(ellipsis)
        if e >= width { return prefix(ellipsis, width: width) }
        return prefix(s, width: width - e) + ellipsis
    }

    /// Right-pad with spaces to `width` cells.
    public static func pad(_ s: String, to width: Int) -> String {
        let n = of(s)
        return n >= width ? s : s + String(repeating: " ", count: width - n)
    }
}

// MARK: - Untrusted text

/// Everything that can come from the network or other processes (page titles, argv, container names, ...)
/// must pass through here before reaching a terminal: an embedded ESC / OSC / C1 control could otherwise
/// move the cursor, rewrite the title, change colors or even type into the shell on some terminals.
public enum Sanitize {
    /// Single-line text: escape sequences removed, every control character (including \n \t) becomes a space
    /// or is dropped, bidi overrides dropped. With `asciiOnly`, each non-ASCII character becomes "?".
    public static func line(_ s: String, asciiOnly: Bool = false) -> String {
        clean(s, keepNewlines: false, asciiOnly: asciiOnly)
    }

    /// Multi-line text: like `line` but "\n" is kept.
    public static func text(_ s: String, asciiOnly: Bool = false) -> String {
        clean(s, keepNewlines: true, asciiOnly: asciiOnly)
    }

    /// Fast path: nothing to do for plain printable ASCII.
    private static func isPlain(_ s: String) -> Bool {
        for b in s.utf8 where b < 0x20 || b >= 0x7F { return false }
        return true
    }

    private static func isBidi(_ v: UInt32) -> Bool {
        (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) || v == 0x200E || v == 0x200F || v == 0x061C
    }

    private static func clean(_ s: String, keepNewlines: Bool, asciiOnly: Bool) -> String {
        if isPlain(s) { return s }
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        let n = scalars.count

        func skipString(from start: Int) -> Int {
            // OSC / DCS / PM / APC / SOS body: up to BEL or ST (ESC \); unterminated swallows the rest.
            var j = start
            while j < n {
                if scalars[j].value == 0x07 { return j + 1 }
                if scalars[j].value == 0x1B, j + 1 < n, scalars[j + 1] == "\\" { return j + 2 }
                if scalars[j].value == 0x9C { return j + 1 }
                j += 1
            }
            return n
        }
        func skipCSI(from start: Int) -> Int {
            var j = start
            while j < n, (0x20...0x3F).contains(scalars[j].value) { j += 1 }      // parameters + intermediates
            if j < n, (0x40...0x7E).contains(scalars[j].value) { return j + 1 }
            return j                                                              // malformed: stop at the offender
        }

        while i < n {
            let sc = scalars[i], v = sc.value
            if v == 0x1B {
                guard i + 1 < n else { i += 1; continue }
                let next = scalars[i + 1]
                switch next {
                case "[": i = skipCSI(from: i + 2)
                case "]", "P", "X", "^", "_": i = skipString(from: i + 2)
                default:
                    // ESC + intermediates + final (charset selection, RIS, ...): drop the lot.
                    var j = i + 1
                    while j < n, (0x20...0x2F).contains(scalars[j].value) { j += 1 }
                    i = min(n, j + 1)
                }
                continue
            }
            if v == 0x9B { i = skipCSI(from: i + 1); continue }
            if v == 0x9D || v == 0x90 || v == 0x98 || v == 0x9E || v == 0x9F { i = skipString(from: i + 1); continue }
            i += 1
            switch v {
            case 0x0A:
                if keepNewlines { out.append(sc) } else { out.append(" ") }
            case 0x09, 0x2028, 0x2029:
                out.append(" ")
            case 0x0D:
                if !keepNewlines { out.append(" ") }
            case 0x00...0x1F, 0x7F...0x9F: break
            case _ where isBidi(v) || v == 0xFEFF: break
            default:
                out.append(sc)
            }
        }
        let result = String(out)
        // One "?" per grapheme cluster that isn't plain ASCII.
        return asciiOnly ? String(result.map { $0.isASCII ? $0 : "?" }) : result
    }
}

// MARK: - ANSI-aware helpers (for strings the renderer has already styled)

public enum AnsiText {
    private enum Token { case escape(String), char(Character) }

    private static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        let scalars = Array(s.unicodeScalars)
        var i = 0
        var run = String.UnicodeScalarView()
        func flush() { for c in String(run) { out.append(.char(c)) }; run = String.UnicodeScalarView() }
        while i < scalars.count {
            if scalars[i].value == 0x1B, i + 1 < scalars.count, scalars[i + 1] == "[" {
                var j = i + 2
                while j < scalars.count, !(0x40...0x7E).contains(scalars[j].value) { j += 1 }
                let end = min(scalars.count, j + 1)
                flush()
                var seq = String.UnicodeScalarView(); seq.append(contentsOf: scalars[i..<end])
                out.append(.escape(String(seq)))
                i = end
            } else {
                run.append(scalars[i]); i += 1
            }
        }
        flush()
        return out
    }

    /// Display width ignoring CSI escapes.
    public static func width(_ s: String) -> Int {
        guard s.utf8.contains(0x1B) else { return DisplayWidth.of(s) }
        return tokens(s).reduce(0) { if case .char(let c) = $1 { return $0 + DisplayWidth.of(c) } else { return $0 } }
    }

    public static func strip(_ s: String) -> String {
        guard s.utf8.contains(0x1B) else { return s }
        return tokens(s).reduce(into: "") { if case .char(let c) = $1 { $0.append(c) } }
    }

    /// Cut to at most `width` cells keeping escape sequences intact (a reset is appended when anything styled was cut).
    public static func fit(_ s: String, to width: Int) -> String {
        guard width >= 0 else { return "" }
        if width == 0 { return "" }
        guard s.utf8.contains(0x1B) else { return DisplayWidth.prefix(s, width: width) }
        var out = "", n = 0, cut = false, sawEscape = false
        for t in tokens(s) {
            switch t {
            case .escape(let e): out += e; sawEscape = true
            case .char(let c):
                let w = DisplayWidth.of(c)
                if cut || n + w > width { cut = true; continue }
                out.append(c); n += w
            }
        }
        if cut && sawEscape { out += "\u{1B}[0m" }
        return out
    }
}
