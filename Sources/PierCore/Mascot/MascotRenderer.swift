import Foundation

// The pier gull in the terminal. Pure functions (caps + environment in, lines out) so every terminal
// combination is unit-testable. Degradation ladder:
//
//   truecolor            half blocks, exact palette RGB
//   256 colors           half blocks, nearest of the xterm 6x6x6 cube / grey ramp (never the theme-defined 0-15)
//   16 colors            half blocks, mapped onto the basic colors (navy -> blue, outline carries the shape)
//   no color / no UTF-8  hand-drawn ASCII gull (also CJK locales, where block glyphs may be double width)
//
// Transparent pixels never get a background color, so the gull sits on dark and light themes alike. Every
// line is exactly the art's width in visible cells and ends with an attribute reset.

public enum MascotPose: String, CaseIterable, Sendable {
    case standing, sleeping, celebrating, saluting, waving, thinking, coffee, surprised
}

public enum MascotSize: Sendable { case small, medium }

/// What the renderer needs to know about the terminal.
public struct MascotStyle: Equatable, Sendable {
    public var color: ColorLevel
    /// Half-block glyphs are safe (UTF-8 and not a CJK locale).
    public var unicode: Bool

    public init(color: ColorLevel, unicode: Bool) { self.color = color; self.unicode = unicode }
    public init(caps: TermCaps) { self.init(color: caps.color, unicode: caps.fancyGlyphs) }

    /// Colored half blocks (otherwise the ASCII gull).
    public var blocks: Bool { unicode && color != .none }
}

public enum Mascot {
    public static let repoURL = "https://github.com/StepanBlha/pier"
    /// Narrower terminals get no mascot at all.
    public static let minTerminalWidth = 40

    // MARK: Policy

    /// PIER_NO_MASCOT=1 (any non-empty value except 0 / false) turns every decorative gull off.
    public static func disabled(env: [String: String]) -> Bool {
        guard let v = env["PIER_NO_MASCOT"]?.lowercased(), !v.isEmpty else { return false }
        return v != "0" && v != "false" && v != "no"
    }

    /// Decorations are for people at a terminal: stdout is an interactive-capable TTY, wide enough, not opted out.
    public static func enabled(caps: TermCaps, env: [String: String]) -> Bool {
        caps.stdoutTTY && caps.cursorControl && caps.width >= minTerminalWidth && !disabled(env: env)
    }

    // MARK: Render

    public static func render(_ pose: MascotPose, _ size: MascotSize, caps: TermCaps) -> [String] {
        render(pose, size, style: MascotStyle(caps: caps))
    }

    /// Lines of the gull; every line is exactly `width(pose, size, style:)` visible cells wide.
    public static func render(_ pose: MascotPose, _ size: MascotSize, style: MascotStyle) -> [String] {
        guard style.blocks, let rows = MascotArt.grids[pose.rawValue]?[size == .small ? "small" : "medium"] else {
            return MascotASCII.art(for: pose)
        }
        let grid = rows.map { $0.map { MascotArt.paletteChars.firstIndex(of: $0) ?? 0 } }
        return blocks(grid, level: style.color)
    }

    public static func width(_ pose: MascotPose, _ size: MascotSize, style: MascotStyle) -> Int {
        render(pose, size, style: style).map { AnsiText.width($0) }.max() ?? 0
    }

    // MARK: Half blocks

    private static let top: Character = "\u{2580}"      // ▀
    private static let bottom: Character = "\u{2584}"   // ▄
    private static let full: Character = "\u{2588}"     // █

    static func blocks(_ pixels: [[Int]], level: ColorLevel) -> [String] {
        guard let cols = pixels.map(\.count).max() else { return [] }
        var grid = pixels.map { $0 + Array(repeating: 0, count: cols - $0.count) }
        if grid.count % 2 == 1 { grid.append(Array(repeating: 0, count: cols)) }
        var out: [String] = []
        for r in stride(from: 0, to: grid.count, by: 2) {
            var line = ""
            var cur = (fg: String?.none, bg: String?.none)
            var sawEscape = false
            func set(_ fg: String?, _ bg: String?) {
                if (cur.fg != nil && fg == nil) || (cur.bg != nil && bg == nil) {
                    line += "\u{1B}[0m"; cur = (nil, nil)
                }
                var parts: [String] = []
                if let fg, fg != cur.fg { parts.append(fg) }
                if let bg, bg != cur.bg { parts.append(bg) }
                if !parts.isEmpty { line += "\u{1B}[" + parts.joined(separator: ";") + "m"; sawEscape = true }
                cur = (fg, bg)
            }
            for c in 0..<cols {
                let t = grid[r][c], b = grid[r + 1][c]
                switch (t, b) {
                case (0, 0):
                    set(nil, nil); line.append(" ")
                case (_, 0):
                    set(color(t, level, fg: true), nil); line.append(top)
                case (0, _):
                    set(color(b, level, fg: true), nil); line.append(bottom)
                default:
                    if t == b {
                        set(color(t, level, fg: true), nil); line.append(full)
                    } else if level == .basic16 && brightOnly(t) && !brightOnly(b) {
                        // Bright colors exist only as 16-color foregrounds: keep the bright one as the foreground.
                        set(color(t, level, fg: true), color(b, level, fg: false)); line.append(top)
                    } else if level == .basic16 && brightOnly(b) && !brightOnly(t) {
                        set(color(b, level, fg: true), color(t, level, fg: false)); line.append(bottom)
                    } else {
                        set(color(t, level, fg: true), color(b, level, fg: false)); line.append(top)
                    }
                }
            }
            if sawEscape { line += "\u{1B}[0m" }
            out.append(line)
        }
        return out
    }

    // MARK: Colors

    /// SGR parameter string for a palette index at a color level ("38;2;r;g;b", "48;5;n", "97", ...).
    public static func color(_ index: Int, _ level: ColorLevel, fg: Bool) -> String? {
        guard index > 0, index < MascotArt.paletteRGB.count else { return nil }
        switch level {
        case .none:
            return nil
        case .truecolor:
            let c = MascotArt.paletteRGB[index]
            return "\(fg ? 38 : 48);2;\(c.0);\(c.1);\(c.2)"
        case .ansi256:
            return "\(fg ? 38 : 48);5;\(ansi256Index(index))"
        case .basic16:
            guard let m = basic16Map[index] else { return nil }
            return String(fg ? m.fg : m.bg)
        }
    }

    /// 16-color mapping (palette index -> SGR fg, bg). Backgrounds avoid the bright 100-107 range (missing on
    /// the Linux console); bright shades are used as foregrounds only.
    private static let basic16Map: [Int: (fg: Int, bg: Int)] = [
        1: (34, 44),     // navy   -> blue
        2: (94, 44),     // blue   -> bright blue (bg: blue)
        3: (97, 47),     // white  -> bright white (bg: white)
        4: (37, 47),     // shade  -> white
        5: (37, 47),     // grey   -> white
        6: (93, 43),     // yellow -> bright yellow (bg: yellow)
        7: (91, 41),     // pink   -> bright red (bg: red)
    ]

    private static func brightOnly(_ index: Int) -> Bool {
        guard let m = basic16Map[index] else { return false }
        return m.fg >= 90
    }

    /// Nearest xterm-256 color to a palette index: only the 6x6x6 cube (16-231) and the grey ramp (232-255),
    /// never 0-15 (those are whatever the theme says). Deterministic.
    public static func ansi256Index(_ index: Int) -> Int {
        let c = MascotArt.paletteRGB[index]
        return nearest256(Int(c.0), Int(c.1), Int(c.2))
    }

    public static func nearest256(_ r: Int, _ g: Int, _ b: Int) -> Int {
        let levels = [0, 95, 135, 175, 215, 255]
        func nearestLevel(_ v: Int) -> Int {
            var best = 0
            for i in 1..<levels.count where abs(levels[i] - v) < abs(levels[best] - v) { best = i }
            return best
        }
        let ri = nearestLevel(r), gi = nearestLevel(g), bi = nearestLevel(b)
        let cube = 16 + 36 * ri + 6 * gi + bi
        func dist(_ x: Int, _ y: Int, _ z: Int) -> Int { (x - r) * (x - r) + (y - g) * (y - g) + (z - b) * (z - b) }
        let ramp = min(23, max(0, ((r + g + b) / 3 - 8 + 5) / 10))
        let rv = 8 + 10 * ramp
        return dist(rv, rv, rv) < dist(levels[ri], levels[gi], levels[bi]) ? 232 + ramp : cube
    }

    // MARK: Composition

    /// Gull on the left, `text` lines to the right (vertically centered on the gull), `gap` cells between.
    /// Lines are clipped to `width`. Returns nil when there is no room for a sensible layout.
    public static func beside(_ art: [String], text: [String], width: Int, gap: Int = 2) -> [String]? {
        let artWidth = art.map { AnsiText.width($0) }.max() ?? 0
        let room = width - artWidth - gap
        guard room >= 16 else { return nil }
        let rows = max(art.count, text.count)
        let artTop = (rows - art.count) / 2, textTop = (rows - text.count) / 2
        let spacer = String(repeating: " ", count: gap)
        var out: [String] = []
        for r in 0..<rows {
            let a = (r - artTop >= 0 && r - artTop < art.count) ? art[r - artTop] : ""
            let t = (r - textTop >= 0 && r - textTop < text.count) ? text[r - textTop] : ""
            let pad = String(repeating: " ", count: max(0, artWidth - AnsiText.width(a)))
            out.append(a + pad + (t.isEmpty ? "" : spacer + AnsiText.fit(t, to: room)))
        }
        return out
    }

    /// Gull + text, or nil when the environment says no mascot (not a TTY, dumb terminal, narrow, PIER_NO_MASCOT).
    /// Callers print their plain output when this returns nil.
    public static func scene(_ pose: MascotPose, _ size: MascotSize = .small, text: [String],
                             caps: TermCaps, env: [String: String]) -> [String]? {
        guard enabled(caps: caps, env: env) else { return nil }
        return beside(render(pose, size, caps: caps), text: text, width: caps.width)
    }

    /// Lines centered in `width` (art lines have uniform width, so a single left pad is enough).
    public static func centered(_ lines: [String], in width: Int) -> [String] {
        let w = lines.map { AnsiText.width($0) }.max() ?? 0
        let pad = String(repeating: " ", count: max(0, (width - w) / 2))
        return lines.map { pad + $0 }
    }

    // MARK: Speech bubble

    /// Word-wrapped text in a speech bubble. The pointer row (index `pointer`) gets a tail on the left edge.
    public static func bubble(_ text: [String], width: Int, unicode: Bool, pointer: Int = 1) -> [String] {
        let inner = max(8, width - 4)
        var wrapped: [String] = []
        for line in text {
            wrapped += wrap(line, width: inner)
        }
        let h = unicode ? "─" : "-", v = unicode ? "│" : "|"
        let tl = unicode ? "╭" : ".", tr = unicode ? "╮" : ".", bl = unicode ? "╰" : "'", br = unicode ? "╯" : "'"
        let tail = unicode ? "┤" : "<"
        let rule = String(repeating: h, count: inner + 2)
        var out = [tl + rule + tr]
        for (i, l) in wrapped.enumerated() {
            let left = (i == min(pointer, wrapped.count - 1)) ? tail : v
            out.append(left + " " + DisplayWidth.pad(l, to: inner) + " " + v)
        }
        out.append(bl + rule + br)
        return out
    }

    /// Greedy word wrap by display width (words longer than the line are cut unless `breakLongWords` is false,
    /// e.g. URLs). Blank lines are kept.
    public static func wrap(_ s: String, width: Int, breakLongWords: Bool = true) -> [String] {
        guard width > 0 else { return [] }
        if s.isEmpty { return [""] }
        var lines: [String] = [], cur = ""
        for word in s.split(separator: " ", omittingEmptySubsequences: true) {
            var w = String(word)
            while breakLongWords && DisplayWidth.of(w) > width {
                if !cur.isEmpty { lines.append(cur); cur = "" }
                let p = DisplayWidth.prefix(w, width: width)
                lines.append(p); w = String(w.dropFirst(p.count))
            }
            if cur.isEmpty { cur = w }
            else if DisplayWidth.of(cur) + 1 + DisplayWidth.of(w) <= width { cur += " " + w }
            else { lines.append(cur); cur = w }
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines.isEmpty ? [""] : lines
    }
}
