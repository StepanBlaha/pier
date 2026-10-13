import Foundation

/// Pure `WatchState` + clock -> full-screen frame. Every line is exactly `state.cols` visible columns wide
/// (padded) and there are exactly `state.rows` lines, so the caller can overwrite the screen in one write.
public enum WatchRenderer {
    public struct Style: Sendable {
        /// Foreground colors (health dots, warnings). Off for NO_COLOR / non-color terminals.
        public var color: Bool
        /// Bold / dim / reverse video. Allowed even under NO_COLOR; off only for dumb terminals.
        public var attributes: Bool
        /// Unicode glyphs (false: ASCII glyphs, and non-ASCII data is shown as "?").
        public var unicode: Bool
        /// Show the sleeping gull when nothing is listening (nil: plain text only).
        public var mascot: MascotStyle?
        public init(color: Bool, attributes: Bool, unicode: Bool = true, mascot: MascotStyle? = nil) {
            self.color = color; self.attributes = attributes; self.unicode = unicode; self.mascot = mascot
        }
        public static let plain = Style(color: false, attributes: false)
        public static let full = Style(color: true, attributes: true)
        var glyphs: Glyphs { unicode ? .unicode : .ascii }
    }

    // Attribute codes are paired with targeted "off" codes (22 / 39 / 27) so nesting inside a
    // reverse-video selected row never resets the reverse.
    private enum Sgr {
        static let bold = ("\u{1B}[1m", "\u{1B}[22m")
        static let dim = ("\u{1B}[2m", "\u{1B}[22m")
        static let reverse = ("\u{1B}[7m", "\u{1B}[27m")
        static let red = ("\u{1B}[31m", "\u{1B}[39m")
        static let green = ("\u{1B}[32m", "\u{1B}[39m")
        static let yellow = ("\u{1B}[33m", "\u{1B}[39m")
    }

    private enum Role { case attr, color }

    private static func wrap(_ s: String, _ code: (String, String), _ role: Role, _ style: Style) -> String {
        guard role == .attr ? style.attributes : style.color else { return s }
        return code.0 + s + code.1
    }

    // MARK: Frame

    /// Every row is addressed explicitly (CUP), so a terminal that disagrees about a glyph's width can only
    /// damage one row. No erase-to-EOL / erase-below: rows are already full width, and those would wipe the
    /// last column on terminals that keep the cursor there after a full-width write. The very last cell of
    /// the screen is never written (no scroll risk). `clear` wipes the screen first (resize, resume, redraw).
    public static func frame(_ state: WatchState, now: Date, style: Style, clear: Bool = false) -> String {
        let lines = self.lines(state, now: now, style: style)
        var out = clear ? "\u{1B}[2J" : ""
        for (i, line) in lines.enumerated() {
            out += "\u{1B}[\(i + 1);1H"
            out += i == lines.count - 1 ? pad(AnsiText.fit(line, to: max(0, state.cols - 1)), to: state.cols - 1) : line
        }
        return out
    }

    public static func lines(_ state: WatchState, now: Date, style: Style) -> [String] {
        let w = state.cols
        let layout = state.layout()
        var out: [String] = [header(state, now: now, style: style)]
        out += table(state, height: layout.tableHeight, now: now, style: style)
        if layout.detailHeight > 0, let s = state.selected {
            out += detail(s, state: state, layout: layout, now: now, style: style)
        }
        out = Array(out.prefix(state.rows - 1))
        while out.count < state.rows - 1 { out.append("") }
        out.append(footer(state, now: now, style: style))
        return out.map { pad(AnsiText.fit($0, to: w), to: w) }
    }

    // MARK: Header / footer

    static func header(_ state: WatchState, now: Date, style: Style) -> String {
        let g = style.glyphs
        let n = state.visible.count
        var left = "pier watch \(g.dash) \(n) service\(n == 1 ? "" : "s")"
        if !state.filter.isEmpty { left += " of \(state.services.count)" }
        left += " \(g.sep) refreshed " + (state.lastRefresh.map { timeText($0) } ?? "--:--:--")
        if !state.hasLoaded { left += " \(g.sep) \(g.refresh) scanning\(g.ellipsis)" }
        else if state.scanning { left += " \(g.sep) \(g.refresh) refreshing\(g.ellipsis)" }
        else { left += " \(g.sep) \(g.refresh) every \(intervalText(state.interval))" }
        if state.includeNoise { left += " \(g.sep) +noise" }
        let hints = "\(g.enter) details  q quit"
        let w = state.cols
        let lw = DisplayWidth.of(left), hw = DisplayWidth.of(hints)
        if lw + 2 + hw <= w {
            let gap = String(repeating: " ", count: w - lw - hw)
            return wrap(left, Sgr.bold, .attr, style) + gap + hints
        }
        return wrap(clip(left, to: w, style), Sgr.bold, .attr, style)
    }

    static func footer(_ state: WatchState, now: Date, style: Style) -> String {
        let g = style.glyphs
        let w = state.cols
        switch state.mode {
        case .confirmKill(let s):
            var q = "Kill \(clean(WatchState.label(s), style))?"
            if let reason = WatchState.confirmReason(s) { q += " [\(reason)]" }
            q += " y/N"
            return wrap(wrap(clip(q, to: w, style), Sgr.yellow, .color, style), Sgr.bold, .attr, style)
        case .filtering:
            let hint = "   esc clear \(g.sep) \(g.enter) keep"
            let prompt = "/" + clean(state.filter, style) + g.cursor
            let shown = clip(prompt, to: w, style)
            return wrap(shown, Sgr.bold, .attr, style)
                + (DisplayWidth.of(shown) + DisplayWidth.of(hint) <= w ? hint : "")
        case .normal:
            if let st = state.activeStatus(now: now) {
                return wrap(clip(clean(st.text, style), to: w, style), st.isError ? Sgr.red : Sgr.green, .color, style)
            }
            var legend = "\(g.arrows) move  \(g.enter) details  o open  c copy  k kill  / filter  a noise  r refresh  q quit"
            if !state.filter.isEmpty { legend = "[/\(clean(state.filter, style))] esc clears  " + legend }
            return clip(legend, to: w, style)
        }
    }

    // MARK: Table

    private static let headers = ["PORT", "NAME", "PROJECT", "FRAMEWORK/INFRA", "HEALTH", "BIND", "UPTIME", "CPU%", "MEM"]

    static func table(_ state: WatchState, height: Int, now: Date, style: Style) -> [String] {
        guard height > 0 else { return [] }
        let gutterWidth = 2
        let visible = state.visible
        let rows = visible.map { s in
            [String(s.port), s.displayName, s.projectName ?? "-", s.framework?.name ?? s.infraName ?? "-",
             healthText(s, style), Format.bindLabel(s.bindScope), Format.uptime(s.process, now: now) ?? "-",
             s.process.cpuPercent.map { String(format: "%.1f", $0) } ?? "-",
             s.process.rssBytes.map(Format.bytes) ?? "-"]
        }
        var table = TextTable(headers: headers, rows: rows, shrinkable: [1, 2, 3], dropOrder: [8, 7, 6, 3, 2, 5])
        table.ellipsis = style.glyphs.ellipsis
        table.asciiOnly = !style.unicode
        let selected = state.selectedIndex
        let rendered = table.render(maxWidth: max(10, state.cols - gutterWidth)) { row, col, text in
            guard let row else { return wrap(text, Sgr.bold, .attr, style) }
            switch col {
            case 0: return wrap(text, Sgr.bold, .attr, style)
            case 4:
                guard let color = healthColor(visible[row].probe?.health ?? .unknown), text.hasPrefix(style.glyphs.bullet) else { return text }
                return wrap(style.glyphs.bullet, color, .color, style) + String(text.dropFirst(style.glyphs.bullet.count))
            case 5 where visible[row].bindScope != .loopback: return wrap(text, Sgr.yellow, .color, style)
            default: return text
            }
        }

        var out = [gutter(false, style) + rendered[0]]
        if visible.isEmpty {
            let msg: String
            let g = style.glyphs
            if !state.hasLoaded { msg = "scanning\(g.ellipsis)" }
            else if !state.filter.isEmpty { msg = "no matches for \(g.openQuote)\(clean(state.filter, style))\(g.closeQuote)" }
            else if let art = emptyMascot(state, height: height, style: style) { return out + art }
            else { msg = "no services listening" }
            out.append("  " + clip(msg, to: max(0, state.cols - 2), style))
            return out
        }
        let body = rendered.dropFirst()
        let window = body.enumerated().filter { $0.offset >= state.scroll && $0.offset < state.scroll + height }
        for (i, line) in window {
            if i == selected {
                let content = pad(gutter(true, style) + line, to: state.cols)
                out.append(wrap(content, Sgr.reverse, .attr, style))
            } else {
                out.append(gutter(false, style) + line)
            }
        }
        return out
    }

    /// Empty, loaded, unfiltered table: a centered sleeping gull with a line of text under it, sized to the
    /// room that is left (medium, then small); nil when it does not fit or mascots are off.
    static func emptyMascot(_ state: WatchState, height: Int, style: Style) -> [String]? {
        guard let ms = style.mascot, state.hasLoaded, state.filter.isEmpty, state.cols >= Mascot.minTerminalWidth else { return nil }
        let text = ["No services listening.", wrap("start one with `pier run`", Sgr.dim, .attr, style)]
        for size in [MascotSize.medium, .small] {
            let art = Mascot.render(.sleeping, size, style: ms)
            let needed = art.count + 1 + text.count
            guard needed <= height else { continue }
            var lines = Mascot.centered(art, in: state.cols) + [""]
            lines += text.map { t in
                let pad = max(0, (state.cols - AnsiText.width(t)) / 2)
                return String(repeating: " ", count: pad) + t
            }
            return (needed + 1 <= height ? [""] : []) + lines
        }
        return nil
    }

    private static func gutter(_ selected: Bool, _ style: Style) -> String {
        selected ? (style.attributes ? style.glyphs.selector + " " : "> ") : "  "
    }

    private static func healthText(_ s: Service, _ style: Style) -> String {
        let b = style.glyphs.bullet
        switch s.probe?.health ?? .unknown {
        case .ok: return b + " ok"
        case .error: return b + " error"
        case .timeout: return b + " timeout"
        case .unknown: return b
        }
    }

    /// Only red / green / yellow: the word next to the dot carries the meaning, so no-color loses nothing.
    private static func healthColor(_ h: Health) -> (String, String)? {
        switch h {
        case .ok: Sgr.green
        case .error: Sgr.red
        case .timeout: Sgr.yellow
        case .unknown: nil
        }
    }

    // MARK: Detail pane

    static func detail(_ s: Service, state: WatchState, layout: WatchState.Layout, now: Date, style: Style) -> [String] {
        let w = state.cols
        let g = style.glyphs
        let title = " \(clean(s.displayName, style)) \(g.sep) :\(s.port) "
        let rule = g.rule + g.rule + clip(title, to: max(0, w - 2), style)
        let ruleLine = rule + String(repeating: g.rule, count: max(0, w - DisplayWidth.of(rule)))

        let fields = ServiceDetail.fields(s, now: now, unicode: style.unicode)
        let body = layout.detailHeight - 1
        let cols = layout.detailColumns
        let keyWidth = (fields.map { DisplayWidth.of($0.label) }.max() ?? 0) + 2
        let colWidth = (w - 2) / cols
        func cell(_ f: (label: String, value: String), last: Bool) -> String {
            let k = DisplayWidth.pad(f.label, to: keyWidth)
            let text = clip(clean(f.value, style), to: max(1, colWidth - keyWidth - (cols > 1 && !last ? 2 : 0)), style)
            let visibleLen = keyWidth + DisplayWidth.of(text)
            let padding = last ? "" : String(repeating: " ", count: max(0, colWidth - visibleLen))
            return wrap(k, Sgr.bold, .attr, style) + text + padding
        }
        var lines = [ruleLine]
        for r in 0..<body {
            var line = "  "
            for c in 0..<cols {
                let idx = c * body + r
                guard idx < fields.count else { continue }
                line += cell(fields[idx], last: c == cols - 1)
            }
            lines.append(line)
        }
        return lines
    }

    // MARK: Text helpers

    static func timeText(_ d: Date) -> String {
        var t = time_t(d.timeIntervalSince1970)
        var tmv = tm()
        localtime_r(&t, &tmv)
        return String(format: "%02d:%02d:%02d", tmv.tm_hour, tmv.tm_min, tmv.tm_sec)
    }

    static func intervalText(_ i: TimeInterval) -> String {
        i == i.rounded() ? "\(Int(i))s" : String(format: "%.1fs", i)
    }

    /// Visible width of a string (display cells), ignoring CSI escape sequences.
    public static func visibleWidth(_ s: String) -> Int { AnsiText.width(s) }

    /// Untrusted data -> safe single-line text for this style.
    static func clean(_ s: String, _ style: Style) -> String { Sanitize.line(s, asciiOnly: !style.unicode) }

    /// Plain-text truncation by display width with an ellipsis (do not use on strings containing escapes).
    static func clip(_ s: String, to width: Int, _ style: Style) -> String {
        DisplayWidth.truncate(s, to: max(0, width), ellipsis: style.glyphs.ellipsis)
    }

    static func pad(_ s: String, to width: Int) -> String {
        let n = AnsiText.width(s)
        return n >= width ? s : s + String(repeating: " ", count: width - n)
    }

    /// Remove CSI escapes (used by tests).
    public static func stripped(_ s: String) -> String { AnsiText.strip(s) }
}
