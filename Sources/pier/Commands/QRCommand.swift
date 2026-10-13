import ArgumentParser
import Foundation
import PierCore

struct QRCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "qr", abstract: "Show a QR code for a service's LAN URL.")

    @Argument(help: "Port number or (fuzzy) name.", completion: TargetCompletion.kind) var target: String

    func run() async throws {
        let s = try await Resolver.resolveOne(target)
        let url: String
        do { url = try QR.lanURL(for: s) } catch {
            Term.fail(error.localizedDescription)
            throw ExitCode(1)
        }
        guard let matrix = QR.matrix(for: url) else {
            Term.fail("could not generate QR code")
            throw ExitCode(1)
        }
        if Term.caps.color == .none && Term.caps.stdoutTTY {
            Term.err("note: colors are off, so the QR is drawn in your terminal colors; on a dark theme it is inverted and some phones won't scan it.")
        }
        Term.out(QRRender.render(matrix, caps: Term.caps))
        Term.out(Term.clean(url))
    }
}

enum QRRender {
    /// Picks the drawing for the terminal: half blocks (2 module rows per text row) when Unicode is safe,
    /// otherwise two ASCII characters per module (cells are about twice as tall as wide, so that is square).
    /// Explicit black-on-white is used whenever color is allowed, so the code scans on dark and light themes.
    static func render(_ m: QRMatrix, quiet: Int = 2, caps: TermCaps) -> String {
        let env = ProcessInfo.processInfo.environment
        let sgr = caps.color == .none ? nil : TermCaps.qrSGR(level: caps.color, term: env["TERM"])
        return caps.fancyGlyphs ? halfBlocks(m, quiet: quiet, sgr: sgr) : ascii(m, quiet: quiet, sgr: sgr)
    }

    /// Two module rows per text row using ▀ ▄ █ and space, with a 2-module quiet zone.
    static func halfBlocks(_ m: QRMatrix, quiet: Int = 2, color: Bool) -> String {
        halfBlocks(m, quiet: quiet, sgr: color ? TermCaps.qrSGR(level: .basic16, term: nil) : nil)
    }

    static func halfBlocks(_ m: QRMatrix, quiet: Int = 2, sgr: String?) -> String {
        let range = -quiet ..< (m.size + quiet)
        var lines: [String] = []
        for y in stride(from: range.lowerBound, to: range.upperBound, by: 2) {
            var line = ""
            for x in range {
                switch (m.isDark(x: x, y: y), m.isDark(x: x, y: y + 1)) {
                case (true, true): line += "█"
                case (true, false): line += "▀"
                case (false, true): line += "▄"
                case (false, false): line += " "
                }
            }
            lines.append(wrap(line, sgr))
        }
        return lines.joined(separator: "\n")
    }

    /// One text row per module row, "##" per dark module and two spaces per light one; rows are full width.
    static func ascii(_ m: QRMatrix, quiet: Int = 2, sgr: String?) -> String {
        let range = -quiet ..< (m.size + quiet)
        return range.map { y in
            wrap(range.map { x in m.isDark(x: x, y: y) ? "##" : "  " }.joined(), sgr)
        }.joined(separator: "\n")
    }

    private static func wrap(_ line: String, _ sgr: String?) -> String {
        guard let sgr else { return line }
        return "\u{1B}[\(sgr)m" + line + "\u{1B}[0m"
    }
}
