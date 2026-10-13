import Foundation

/// Text helpers for the logs window.
public enum LogText {
    private static let csi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-?]*[ -/]*[@-~]")
    private static let osc = try! NSRegularExpression(pattern: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)")
    private static let other = try! NSRegularExpression(pattern: "\u{1B}[()#][0-9A-Za-z]|\u{1B}[=>78MDEHc]")

    /// Removes ANSI escape sequences (colors, cursor moves, OSC titles) and normalizes line endings.
    public static func stripANSI(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0 == "\u{1B}" || $0 == "\r" }) else { return s }
        var out = s
        for re in [osc, csi, other] {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        out = out.replacingOccurrences(of: "\r\n", with: "\n")
        // A lone CR means "redraw this line" (progress bars): keep only the last segment of each line.
        if out.unicodeScalars.contains("\r") {
            out = out.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                line.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? ""
            }.joined(separator: "\n")
        }
        return out
    }

    /// Keeps at most `maxLines` trailing lines.
    public static func trimmed(_ s: String, maxLines: Int) -> String {
        var count = 0
        var idx = s.endIndex
        while idx > s.startIndex {
            idx = s.index(before: idx)
            if s[idx] == "\n" { count += 1; if count > maxLines { return String(s[s.index(after: idx)...]) } }
        }
        return s
    }
}
