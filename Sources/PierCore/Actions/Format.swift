import Foundation

/// Human-readable formatting shared by the CLI and the app.
public enum Format {
    /// "42s", "3m", "2h", "4d".
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        switch s {
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        default: return "\(s / 86400)d"
        }
    }

    public static func uptime(_ process: ProcInfo, now: Date = Date()) -> String? {
        process.startTime.map { duration(now.timeIntervalSince($0)) }
    }

    /// "512 B", "1.5 KB", "142 MB", "1.2 GB" (1024-based).
    public static func bytes(_ n: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(n), i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        if i == 0 { return "\(n) B" }
        return (v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)) + " " + units[i]
    }

    /// Outermost launcher first: "Claude Code › zsh › npm › node" (">" when `unicode` is false).
    public static func ownerChain(_ s: Service, unicode: Bool = true) -> String {
        (s.owners.reversed().map(ownerName) + [s.process.name]).joined(separator: unicode ? " › " : " > ")
    }

    static func ownerName(_ o: OwnerLink) -> String {
        switch o.kind {
        case .claudeCode: "Claude Code"
        case .vscode: "VS Code"
        default: o.name
        }
    }

    public static func bindLabel(_ scope: BindScope) -> String { scope == .loopback ? "local" : "LAN" }
}

/// Plain-text column layout. Styling is injected so the core stays terminal-agnostic.
/// All measuring / padding / truncation is by display width (CJK and emoji = 2 cells, combining marks = 0)
/// and cell text is sanitized (no escape sequences or control characters can reach the terminal).
public struct TextTable {
    public var headers: [String]
    public var rows: [[String]]
    /// Columns that may be truncated (with an ellipsis) when the table is wider than the terminal.
    public var shrinkable: Set<Int>
    /// Columns removed entirely, in this order, when shrinking is not enough (lowest priority first).
    /// Column 0 is never dropped.
    public var dropOrder: [Int] = []
    public var gap = 2
    public var minShrinkWidth = 8
    public var ellipsis = "…"
    /// Replace non-ASCII data with "?" (terminal can't be trusted with UTF-8).
    public var asciiOnly = false

    public init(headers: [String], rows: [[String]], shrinkable: Set<Int> = [], dropOrder: [Int] = []) {
        self.headers = headers; self.rows = rows; self.shrinkable = shrinkable; self.dropOrder = dropOrder
    }

    private func cleaned(_ s: String) -> String { Sanitize.line(s, asciiOnly: asciiOnly) }

    /// Column widths for the given visible columns (shrinking `shrinkable` ones down to `minShrinkWidth` as needed).
    private func widths(for cols: [Int], maxWidth: Int) -> [Int] {
        var w = cols.map { c in ([headers[c]] + rows.map { $0[c] }).map { DisplayWidth.of(cleaned($0)) }.max() ?? 0 }
        func total() -> Int { w.reduce(0, +) + gap * max(0, w.count - 1) }
        while total() > maxWidth {
            let candidates = cols.indices.filter { shrinkable.contains(cols[$0]) && w[$0] > minShrinkWidth }
            guard let i = candidates.max(by: { w[$0] < w[$1] }) else { break }
            w[i] -= 1
        }
        return w
    }

    /// Widths of all columns (no dropping).
    public func columnWidths(maxWidth: Int) -> [Int] { widths(for: Array(headers.indices), maxWidth: maxWidth) }

    /// Visible columns and their widths after shrinking and dropping.
    public func layout(maxWidth: Int) -> (columns: [Int], widths: [Int]) {
        var cols = Array(headers.indices)
        var drops = dropOrder.filter { $0 > 0 && $0 < headers.count }
        while true {
            let w = widths(for: cols, maxWidth: maxWidth)
            let total = w.reduce(0, +) + gap * max(0, w.count - 1)
            if total <= maxWidth || cols.count <= 1 { return (cols, w) }
            guard let d = drops.first else {
                // Nothing left to drop: trim the last column's width so the line fits anyway.
                var w2 = w
                let over = total - maxWidth
                w2[w2.count - 1] = max(1, w2[w2.count - 1] - over)
                return (cols, w2)
            }
            drops.removeFirst()
            cols.removeAll { $0 == d }
        }
    }

    public static func truncate(_ s: String, to width: Int, ellipsis: String = "…") -> String {
        DisplayWidth.truncate(s, to: width, ellipsis: ellipsis)
    }

    /// `style(row, column, paddedCell)`; row is nil for the header; column indexes the original columns.
    public func render(maxWidth: Int, style: (Int?, Int, String) -> String = { $2 }) -> [String] {
        let (cols, widths) = layout(maxWidth: maxWidth)
        func line(_ cells: [String], row: Int?) -> String {
            var out = ""
            for (k, c) in cols.enumerated() {
                let t = Self.truncate(cleaned(cells[c]), to: widths[k], ellipsis: ellipsis)
                let isLast = k == cols.count - 1
                let padded = isLast ? t : DisplayWidth.pad(t, to: widths[k])
                out += style(row, c, padded) + (isLast ? "" : String(repeating: " ", count: gap))
            }
            return out
        }
        return [line(headers, row: nil)] + rows.enumerated().map { line($1, row: $0) }
    }
}
