import XCTest
@testable import PierCore

final class TermCompatCapsTests: XCTestCase {
    private func color(_ env: [String: String], tty: Bool = true) -> ColorLevel {
        TermCaps.colorLevel(env: env, isTTY: tty)
    }

    func testColorDecisionTable() {
        let xterm = ["TERM": "xterm-256color"]
        XCTAssertEqual(color(xterm), .ansi256)
        XCTAssertEqual(color(["TERM": "xterm"]), .basic16)
        XCTAssertEqual(color(["TERM": "xterm", "COLORTERM": "truecolor"]), .truecolor)
        XCTAssertEqual(color(["TERM": "linux"]), .basic16)
        XCTAssertEqual(color(["TERM": "screen-256color"]), .ansi256)
        // not a TTY -> none, unless forced
        XCTAssertEqual(color(xterm, tty: false), .none)
        XCTAssertNotEqual(color(xterm.merging(["FORCE_COLOR": "1"]) { $1 }, tty: false), .none)
        XCTAssertNotEqual(color(["CLICOLOR_FORCE": "1"], tty: false), .none)
        XCTAssertEqual(color(["CLICOLOR_FORCE": "0"], tty: false), .none)
        XCTAssertEqual(color(["FORCE_COLOR": "0", "TERM": "xterm"]), .none)
        // NO_COLOR (any non-empty value) wins, even over force
        for v in ["1", "0", "false", "yes"] {
            XCTAssertEqual(color(xterm.merging(["NO_COLOR": v]) { $1 }), .none, v)
            XCTAssertEqual(color(["NO_COLOR": v, "FORCE_COLOR": "1"], tty: false), .none, v)
        }
        XCTAssertNotEqual(color(xterm.merging(["NO_COLOR": ""]) { $1 }), .none, "empty NO_COLOR is unset")
        XCTAssertEqual(color(xterm.merging(["CLICOLOR": "0"]) { $1 }), .none)
        // dumb / unset TERM -> none (but forced wins)
        XCTAssertEqual(color(["TERM": "dumb"]), .none)
        XCTAssertEqual(color([:]), .none)
        XCTAssertNotEqual(color(["TERM": "dumb", "FORCE_COLOR": "1"]), .none)
    }

    func testUnicodeDecisionTable() {
        XCTAssertTrue(TermCaps.unicodeSupported(env: ["LANG": "en_US.UTF-8", "TERM": "xterm"]))
        XCTAssertTrue(TermCaps.unicodeSupported(env: ["LANG": "cs_CZ.utf8"]))
        XCTAssertTrue(TermCaps.unicodeSupported(env: ["LC_ALL": "C.UTF-8"]))
        XCTAssertFalse(TermCaps.unicodeSupported(env: ["LANG": "C"]))
        XCTAssertFalse(TermCaps.unicodeSupported(env: ["LANG": "en_US.ISO-8859-1"]))
        // LC_ALL > LC_CTYPE > LANG
        XCTAssertFalse(TermCaps.unicodeSupported(env: ["LC_ALL": "C", "LANG": "en_US.UTF-8"]))
        XCTAssertTrue(TermCaps.unicodeSupported(env: ["LC_ALL": "en_US.UTF-8", "LANG": "C"]))
        XCTAssertFalse(TermCaps.unicodeSupported(env: ["LC_CTYPE": "C", "LANG": "en_US.UTF-8"]))
        XCTAssertTrue(TermCaps.unicodeSupported(env: ["LC_ALL": "", "LANG": "en_US.UTF-8"]), "empty LC_ALL is unset")
        // linux console / dumb: never
        XCTAssertFalse(TermCaps.unicodeSupported(env: ["LANG": "en_US.UTF-8", "TERM": "linux"]))
        XCTAssertFalse(TermCaps.unicodeSupported(env: ["LANG": "en_US.UTF-8", "TERM": "dumb"]))
        // no locale at all: only a self-announcing terminal is trusted
        XCTAssertFalse(TermCaps.unicodeSupported(env: ["TERM": "xterm"]))
        XCTAssertTrue(TermCaps.unicodeSupported(env: ["TERM": "xterm-256color", "TERM_PROGRAM": "Apple_Terminal"]))
        XCTAssertFalse(TermCaps.unicodeSupported(env: [:]))
    }

    func testCJKLocalesFallBackToAsciiGlyphs() {
        let caps = TermCaps.detect(env: ["LANG": "ja_JP.UTF-8", "TERM": "xterm"], stdinTTY: true, stdoutTTY: true, stderrTTY: true)
        XCTAssertTrue(caps.unicode)
        XCTAssertFalse(caps.fancyGlyphs)
        XCTAssertEqual(caps.glyphs, .ascii)
        let en = TermCaps.detect(env: ["LANG": "en_US.UTF-8", "TERM": "xterm"], stdinTTY: true, stdoutTTY: true, stderrTTY: true)
        XCTAssertEqual(en.glyphs, .unicode)
    }

    func testWidthResolution() {
        func caps(_ env: [String: String], tty: Bool = true, measured: Int? = nil) -> TermCaps {
            TermCaps.detect(env: env, stdinTTY: tty, stdoutTTY: tty, stderrTTY: tty, measuredColumns: measured)
        }
        XCTAssertEqual(caps(["COLUMNS": "40"], measured: 120).width, 120, "ioctl wins")
        XCTAssertEqual(caps(["COLUMNS": "40"]).width, 40)
        XCTAssertEqual(caps([:]).width, 80)
        XCTAssertEqual(caps(["COLUMNS": "abc"], measured: 0).width, 80)
        XCTAssertGreaterThan(caps(["COLUMNS": "40"], tty: false).tableWidth, 10_000, "piped output is never truncated")
        XCTAssertEqual(caps(["COLUMNS": "40"]).tableWidth, 40)
    }

    func testInteractiveNeedsCapableTerminal() {
        func caps(_ env: [String: String], stdin: Bool = true, stdout: Bool = true) -> TermCaps {
            TermCaps.detect(env: env, stdinTTY: stdin, stdoutTTY: stdout, stderrTTY: true)
        }
        XCTAssertTrue(caps(["TERM": "xterm-256color"]).interactive)
        XCTAssertTrue(caps(["TERM": "screen"]).interactive)
        XCTAssertTrue(caps(["TERM": "linux"]).interactive)
        XCTAssertFalse(caps(["TERM": "dumb"]).interactive)
        XCTAssertFalse(caps([:]).interactive)
        XCTAssertFalse(caps(["TERM": "xterm"], stdout: false).interactive)
        XCTAssertFalse(caps(["TERM": "xterm"], stdin: false).interactive)
    }

    func testQRColors() {
        XCTAssertEqual(TermCaps.qrSGR(level: .truecolor, term: "xterm"), "38;2;0;0;0;48;2;255;255;255")
        XCTAssertEqual(TermCaps.qrSGR(level: .basic16, term: "linux"), "30;47")
        XCTAssertEqual(TermCaps.qrSGR(level: .basic16, term: "xterm"), "30;107")
    }
}

final class TermCompatWidthTests: XCTestCase {
    func testDisplayWidth() {
        XCTAssertEqual(DisplayWidth.of("abc"), 3)
        XCTAssertEqual(DisplayWidth.of("café"), 4)
        XCTAssertEqual(DisplayWidth.of("e\u{301}"), 1, "combining acute")
        XCTAssertEqual(DisplayWidth.of("日本語"), 6)
        XCTAssertEqual(DisplayWidth.of("한글"), 4)
        XCTAssertEqual(DisplayWidth.of("ｱ"), 1)              // halfwidth katakana
        XCTAssertEqual(DisplayWidth.of("Ａ"), 2)             // fullwidth latin
        XCTAssertEqual(DisplayWidth.of("🚀"), 2)
        XCTAssertEqual(DisplayWidth.of("👨‍👩‍👧"), 2, "ZWJ family is one wide cluster")
        XCTAssertEqual(DisplayWidth.of("❤️"), 2, "VS16 emoji presentation")
        XCTAssertEqual(DisplayWidth.of("🇨🇿"), 2)
        XCTAssertEqual(DisplayWidth.of("a\u{200B}b"), 2, "zero width space")
        XCTAssertEqual(DisplayWidth.of("\u{7}"), 0)
        XCTAssertEqual(DisplayWidth.of("●"), 1)
    }

    func testTruncateNeverSplitsClusters() {
        XCTAssertEqual(DisplayWidth.truncate("hello", to: 10), "hello")
        XCTAssertEqual(DisplayWidth.truncate("hello world", to: 8), "hello w…")
        XCTAssertEqual(DisplayWidth.truncate("hello world", to: 8, ellipsis: "..."), "hello...")
        XCTAssertEqual(DisplayWidth.truncate("日本語テキスト", to: 6), "日本…")          // 4 + 1 (a wide char would overflow)
        XCTAssertEqual(DisplayWidth.truncate("e\u{301}e\u{301}e\u{301}e\u{301}", to: 3), "e\u{301}e\u{301}…")
        XCTAssertEqual(DisplayWidth.truncate("a👨‍👩‍👧b👨‍👩‍👧c", to: 4), "a👨‍👩‍👧…")
        XCTAssertEqual(DisplayWidth.truncate("abc", to: 0), "")
        XCTAssertEqual(DisplayWidth.truncate("abcdef", to: 2, ellipsis: "..."), "..")
        for w in 1...12 {
            let t = DisplayWidth.truncate("日本語 café 🚀 text", to: w)
            XCTAssertLessThanOrEqual(DisplayWidth.of(t), w, t)
        }
    }

    func testTableAlignsWideAndCombiningCells() {
        let t = TextTable(headers: ["PORT", "NAME", "PID"],
                          rows: [["1", "café", "7"], ["22", "日本語", "8"], ["333", "🚀 go", "9"], ["4444", "e\u{301}e\u{301}", "10"]])
        let lines = t.render(maxWidth: 80)
        let cols = lines.map { l -> Int in
            // display column where the PID column starts = width of everything before the last cell
            DisplayWidth.of(l) - DisplayWidth.of(l.components(separatedBy: " ").last!)
        }
        XCTAssertEqual(Set(cols).count, 1, "PID column must start at the same display column: \(lines)")
    }

    func testTableDropsLowPriorityColumnsOnNarrowTerminals() {
        let t = TextTable(headers: ["PORT", "NAME", "PROJECT", "FRAMEWORK/INFRA", "HEALTH", "BIND", "UPTIME", "PID"],
                          rows: [["3000", String(repeating: "n", count: 30), "relay-crm", "Next.js", "● ok", "local", "3h", "1234"]],
                          shrinkable: [1, 2, 3], dropOrder: [7, 6, 3, 2, 5])
        for width in [40, 30, 20, 120] {
            let lines = t.render(maxWidth: width)
            XCTAssertTrue(lines.allSatisfy { DisplayWidth.of($0) <= width }, "width \(width): \(lines)")
        }
        let narrow = t.render(maxWidth: 40)
        XCTAssertTrue(narrow[0].hasPrefix("PORT"))
        XCTAssertFalse(narrow[0].contains("PID"))
        XCTAssertTrue(narrow[0].contains("HEALTH"))
        XCTAssertTrue(t.render(maxWidth: 200)[0].contains("PID"))
    }

    func testTableAsciiEllipsisAndSanitizedCells() {
        var t = TextTable(headers: ["PORT", "NAME"], rows: [["1", String(repeating: "x", count: 50)]], shrinkable: [1])
        t.ellipsis = "..."
        let lines = t.render(maxWidth: 20)
        XCTAssertTrue(lines[1].hasSuffix("..."))
        XCTAssertLessThanOrEqual(lines[1].count, 20)

        let evil = TextTable(headers: ["PORT", "NAME"], rows: [["1", "\u{1B}]0;pwn\u{7}hi\u{1B}[31m red\u{1B}[2J"]])
        let out = evil.render(maxWidth: 80).joined()
        XCTAssertFalse(out.contains("\u{1B}"))
        XCTAssertFalse(out.contains("\u{7}"))
        XCTAssertTrue(out.contains("hi red"))
    }
}

final class TermCompatSanitizeTests: XCTestCase {
    func testPlainTextUntouched() {
        XCTAssertEqual(Sanitize.line("My App - café 日本 🚀"), "My App - café 日本 🚀")
    }

    func testEscapeSequencesStripped() {
        XCTAssertEqual(Sanitize.line("a\u{1B}[31mb\u{1B}[0mc"), "abc")
        XCTAssertEqual(Sanitize.line("a\u{1B}[2J\u{1B}[Hb"), "ab")
        XCTAssertEqual(Sanitize.line("t\u{1B}]0;evil title\u{7}x"), "tx", "OSC with BEL")
        XCTAssertEqual(Sanitize.line("t\u{1B}]8;;http://evil\u{1B}\\link\u{1B}]8;;\u{1B}\\"), "tlink", "OSC 8 hyperlink with ST")
        XCTAssertEqual(Sanitize.line("x\u{1B}P1$r\u{1B}\\y"), "xy", "DCS")
        XCTAssertEqual(Sanitize.line("x\u{1B}cy"), "xy", "RIS")
        XCTAssertEqual(Sanitize.line("x\u{1B}(By"), "xy", "charset")
        XCTAssertEqual(Sanitize.line("x\u{9B}31my"), "xy", "C1 CSI")
        XCTAssertEqual(Sanitize.line("x\u{1B}]52;c;SGVsbG8=\u{7}y"), "xy", "OSC 52 clipboard write")
        XCTAssertEqual(Sanitize.line("trailing\u{1B}"), "trailing")
        XCTAssertEqual(Sanitize.line("unterminated\u{1B}]0;title"), "unterminated")
    }

    func testControlCharactersAndSpoofing() {
        XCTAssertEqual(Sanitize.line("a\nb\rc\td"), "a b c d")
        XCTAssertEqual(Sanitize.line("a\u{0}b\u{7}c\u{8}d\u{7F}e"), "abcde")
        XCTAssertEqual(Sanitize.line("a\u{202E}b\u{2066}c"), "abc", "bidi overrides")
        XCTAssertEqual(Sanitize.text("a\nb\r\nc\u{1B}[1m"), "a\nb\nc")
        XCTAssertEqual(Sanitize.line("日本é", asciiOnly: true), "???")
        XCTAssertEqual(Sanitize.line("cafe\u{301}", asciiOnly: true), "caf?")
    }

    func testNoEscapeSurvivesFuzz() {
        let pieces = ["\u{1B}", "[", "]", "P", "\\", "\u{7}", "\u{9B}", "31", "m", ";", "x", "\n", "\u{1B}[", "\u{1B}]"]
        var seed: UInt64 = 42
        for _ in 0..<500 {
            var s = ""
            for _ in 0..<12 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; s += pieces[Int(seed >> 33) % pieces.count] }
            let out = Sanitize.line(s)
            XCTAssertFalse(out.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }, "\(s.debugDescription) -> \(out.debugDescription)")
        }
    }

    func testAnsiHelpers() {
        let styled = "\u{1B}[1mhello\u{1B}[0m 日本"
        XCTAssertEqual(AnsiText.width(styled), 10)
        XCTAssertEqual(AnsiText.strip(styled), "hello 日本")
        let cut = AnsiText.fit(styled, to: 7)
        XCTAssertEqual(AnsiText.width(cut), 6)       // the wide char does not fit in the 7th cell
        XCTAssertTrue(cut.hasSuffix("\u{1B}[0m"))
        XCTAssertEqual(AnsiText.fit("plain", to: 3), "pla")
    }
}

final class TermCompatKeyTests: XCTestCase {
    private func keys(_ s: [UInt8]) -> [Key] { var d = KeyDecoder(); return d.feed(s) }
    private func esc(_ s: String) -> [UInt8] { [0x1B] + Array(s.utf8) }

    func testArrowVariants() {
        XCTAssertEqual(keys(esc("[A")), [.up])
        XCTAssertEqual(keys(esc("OA")), [.up])
        XCTAssertEqual(keys(esc("[B")), [.down])
        XCTAssertEqual(keys(esc("OB")), [.down])
        XCTAssertEqual(keys(esc("[1;5A")), [.up], "ctrl-up")
        XCTAssertEqual(keys(esc("[1;2B")), [.down], "shift-down")
        XCTAssertEqual(keys(esc("[1;3A")), [.up], "alt-up")
        XCTAssertEqual(keys(esc("[1;9A")), [.up])
        XCTAssertEqual(keys(esc("[C") + esc("[D")), [.right, .left])
    }

    func testHomeEndVariants() {
        for s in ["[H", "[1~", "OH", "[7~", "[1;5H"] { XCTAssertEqual(keys(esc(s)), [.home], s) }
        for s in ["[F", "[4~", "OF", "[8~", "[1;5F"] { XCTAssertEqual(keys(esc(s)), [.end], s) }
        XCTAssertEqual(keys(esc("[5~")), [.pageUp])
        XCTAssertEqual(keys(esc("[6~")), [.pageDown])
        XCTAssertEqual(keys(esc("[3~")), [.delete])
    }

    func testBasicKeys() {
        XCTAssertEqual(keys([0x7F]), [.backspace])
        XCTAssertEqual(keys([0x08]), [.backspace])
        XCTAssertEqual(keys([0x0D]), [.enter])
        XCTAssertEqual(keys([0x0A]), [.enter])
        XCTAssertEqual(keys([0x03]), [.ctrl("c")])
        XCTAssertEqual(keys([0x04]), [.ctrl("d")])
        XCTAssertEqual(keys([0x1A]), [.ctrl("z")])
        XCTAssertEqual(keys(Array("é".utf8)), [.char("é")])
        XCTAssertEqual(keys(esc("[Z")), [.tab])
    }

    func testLoneEscapeAndFlush() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x1B]), [])
        XCTAssertTrue(d.hasPending)
        XCTAssertEqual(d.flush(), [.escape])
        XCTAssertFalse(d.hasPending)
    }

    func testSequenceSplitAcrossReadsStillDecodes() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x1B]), [])
        XCTAssertEqual(d.feed(Array("[1;".utf8)), [])
        XCTAssertEqual(d.feed(Array("5A".utf8)), [.up])
    }

    func testBracketedPasteIsNotInterpretedAsCommands() {
        // "k" then "y" would kill a service; inside a paste they are text.
        var d = KeyDecoder()
        XCTAssertEqual(d.feed(esc("[200~") + Array("ky\nq".utf8) + esc("[201~") + Array("j".utf8)), [.paste("ky\nq"), .char("j")])
        var split = KeyDecoder()
        XCTAssertEqual(split.feed(esc("[200~") + Array("ab".utf8)), [])
        XCTAssertTrue(split.isPasting)
        XCTAssertEqual(split.flush(), [], "a paste in progress is not flushed on a short timeout")
        XCTAssertEqual(split.feed(Array("c".utf8) + esc("[201~")), [.paste("abc")])
        XCTAssertFalse(split.isPasting)
        split.reset()
        XCTAssertEqual(split.feed(Array("q".utf8)), [.char("q")])
    }

    func testKittyAndModifyOtherKeys() {
        XCTAssertEqual(keys(esc("[97;5u")), [.ctrl("a")])
        XCTAssertEqual(keys(esc("[113u")), [.char("q")])
        XCTAssertEqual(keys(esc("[13u")), [.enter])
        XCTAssertEqual(keys(esc("[27u")), [.escape])
        XCTAssertEqual(keys(esc("[27;5;99~")), [.ctrl("c")])
    }

    func testPasteInFilterModeOnlyFiltersAndNeverQuits() {
        var st = WatchState(interval: 2)
        XCTAssertNil(st.handle(.char("/"), now: Date()))
        XCTAssertNil(st.handle(.paste("re\u{1B}[2Jlay\nq"), now: Date()))
        XCTAssertEqual(st.filter, "relay q")
        var normal = WatchState(interval: 2)
        XCTAssertNil(normal.handle(.paste("q"), now: Date()))
        XCTAssertEqual(normal.handle(.ctrl("d"), now: Date()), .quit)
        XCTAssertEqual(normal.handle(.ctrl("l"), now: Date()), .redraw)
    }
}

final class TermCompatRendererTests: XCTestCase {
    private func svc(_ port: UInt16, name: String = "node", title: String? = nil) -> Service {
        var s = Service(port: port, process: ProcInfo(pid: Int32(port), ppid: 1, uid: 501, name: name,
                                                      arguments: ["node", "\u{1B}]0;pwned\u{7}srv.js"],
                                                      startTime: Date().addingTimeInterval(-3700),
                                                      cpuPercent: 1.5, rssBytes: 150 << 20),
                        addresses: ["127.0.0.1"], bindScope: .loopback)
        s.probe = ProbeResult(protocolKind: .http, health: .ok, httpStatus: 200, title: title)
        return s
    }

    private func state(cols: Int, rows: Int = 24, services: [Service]) -> WatchState {
        var st = WatchState(interval: 2)
        st.resize(cols: cols, rows: rows)
        st.update(services: services, now: Date())
        return st
    }

    func testMaliciousTitleCannotInjectEscapesIntoWatch() {
        var s = svc(3000, title: "\u{1B}[2J\u{1B}]0;pwned\u{7}hello")
        s.projectName = "pro\u{1B}[31mj"
        var st = state(cols: 100, services: [s, svc(3001, name: "\u{1B}[H\u{1B}[2Jnasty")])
        _ = st.handle(.enter, now: Date())
        for style in [WatchRenderer.Style.full, .plain, .init(color: false, attributes: true, unicode: false)] {
            let lines = WatchRenderer.lines(st, now: Date(), style: style)
            for l in lines {
                // only SGR (ESC [ ... m) produced by the renderer itself may remain
                let stripped = l.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
                XCTAssertFalse(stripped.contains("\u{1B}"), l.debugDescription)
                XCTAssertFalse(stripped.contains("\u{7}"), l.debugDescription)
            }
        }
    }

    func testAsciiStyleUsesOnlyAscii() {
        var st = state(cols: 90, services: [svc(3000, title: "café 日本"), svc(3001)])
        _ = st.handle(.enter, now: Date())
        let style = WatchRenderer.Style(color: false, attributes: false, unicode: false)
        for l in WatchRenderer.lines(st, now: Date(), style: style) {
            XCTAssertTrue(l.unicodeScalars.allSatisfy { $0.value < 0x7F }, l)
            XCTAssertEqual(WatchRenderer.visibleWidth(l), 90)
        }
        let header = WatchRenderer.lines(st, now: Date(), style: style)[0]
        XCTAssertTrue(header.hasPrefix("pier watch - 2 services | refreshed "), header)
        XCTAssertTrue(header.hasSuffix("enter details  q quit"), header)
        _ = st.handle(.char("/"), now: Date())
        XCTAssertTrue(WatchRenderer.lines(st, now: Date(), style: style).last!.hasPrefix("/_"))
    }

    func testEveryLineIsExactWidthAcrossSizesWithWideData() {
        let services = [svc(3000, title: "日本語のタイトル 🚀 café"), svc(3001, name: "プロセス"), svc(3002, name: "emoji🚀proc")]
        for (cols, rows) in [(40, 24), (30, 10), (12, 5), (300, 60), (80, 24), (20, 4)] {
            var st = state(cols: cols, rows: rows, services: services)
            for opened in [false, true] {
                if opened { _ = st.handle(.enter, now: Date()) }
                for style in [WatchRenderer.Style.full, .plain, .init(color: false, attributes: true, unicode: false)] {
                    let lines = WatchRenderer.lines(st, now: Date(), style: style)
                    XCTAssertEqual(lines.count, st.rows)
                    for l in lines { XCTAssertEqual(WatchRenderer.visibleWidth(l), st.cols, "\(cols)x\(rows): \(WatchRenderer.stripped(l))") }
                }
            }
        }
    }

    func testFrameAddressesRowsAndAvoidsEraseSequences() {
        let st = state(cols: 60, rows: 8, services: [svc(3000)])
        let f = WatchRenderer.frame(st, now: Date(), style: .full)
        XCTAssertFalse(f.contains("\u{1B}[K"), "EL would wipe the last column after a full-width row")
        XCTAssertFalse(f.contains("\u{1B}[J"))
        XCTAssertFalse(f.contains("\n"))
        for row in 1...8 { XCTAssertTrue(f.contains("\u{1B}[\(row);1H"), "row \(row)") }
        XCTAssertTrue(WatchRenderer.frame(st, now: Date(), style: .full, clear: true).hasPrefix("\u{1B}[2J"))
        // the bottom-right cell is never written
        let last = f.components(separatedBy: "\u{1B}[8;1H").last!
        XCTAssertEqual(WatchRenderer.visibleWidth(last), 59)
    }

    func testNoDimOrBrightBlackIsEmitted() {
        let st = state(cols: 120, services: [svc(3000), svc(3001)])
        let raw = WatchRenderer.lines(st, now: Date(), style: .full).joined()
        XCTAssertFalse(raw.contains("\u{1B}[2m"), "dim can be invisible; never carries essential info")
        XCTAssertFalse(raw.contains("\u{1B}[90m"))
        XCTAssertFalse(raw.contains("38;"))
        XCTAssertFalse(raw.contains("48;"))
    }
}
