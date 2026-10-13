import XCTest
@testable import PierCore

private func caps(color: ColorLevel = .truecolor, unicode: Bool = true, tty: Bool = true, cols: Int = 100, term: String = "xterm-256color") -> TermCaps {
    var env = ["TERM": term, "LANG": unicode ? "en_US.UTF-8" : "C"]
    switch color {
    case .truecolor: env["COLORTERM"] = "truecolor"
    case .ansi256: break
    case .basic16: env["TERM"] = "xterm"
    case .none: env["NO_COLOR"] = "1"
    }
    return TermCaps.detect(env: env, stdinTTY: tty, stdoutTTY: tty, stderrTTY: tty, measuredColumns: cols)
}

private func hasEscape(_ s: String) -> Bool { s.contains("\u{1B}") }

final class MascotArtTests: XCTestCase {
    func testEveryPoseHasBothSizesWithConsistentDimensions() {
        for pose in MascotPose.allCases {
            for (name, cols, rows) in [("small", 16, 16), ("medium", 30, 30)] {
                guard let grid = MascotArt.grids[pose.rawValue]?[name] else { return XCTFail("\(pose) \(name) missing") }
                XCTAssertEqual(grid.count, rows, "\(pose) \(name) rows")
                XCTAssertEqual(grid.count % 2, 0)
                for row in grid {
                    XCTAssertEqual(row.count, cols, "\(pose) \(name) width")
                    XCTAssertTrue(row.allSatisfy { MascotArt.paletteChars.contains($0) }, row)
                }
                XCTAssertTrue(grid.joined().contains("y"), "\(pose) \(name): the beak must survive")
                XCTAssertTrue(grid.joined().contains("n"), "\(pose) \(name): outline")
            }
        }
        XCTAssertEqual(MascotArt.paletteRGB.count, MascotArt.paletteChars.count)
    }

    func testAsciiGullIsSmallAndPlain() {
        for pose in MascotPose.allCases {
            let art = MascotASCII.art(for: pose)
            XCTAssertLessThanOrEqual(art.count, 8)
            XCTAssertEqual(Set(art.map { $0.count }).count, 1, "\(pose): uniform width")
            for l in art {
                XCTAssertLessThanOrEqual(l.count, 20)
                XCTAssertTrue(l.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }, l)
            }
        }
        XCTAssertNotEqual(MascotASCII.standing, MascotASCII.sleeping)
    }
}

final class MascotRendererTests: XCTestCase {
    func testLineCountAndVisibleWidthAtEveryColorLevel() {
        for level in [ColorLevel.truecolor, .ansi256, .basic16] {
            let style = MascotStyle(color: level, unicode: true)
            for pose in MascotPose.allCases {
                for (size, cols, rows) in [(MascotSize.small, 16, 8), (.medium, 30, 15)] {
                    let lines = Mascot.render(pose, size, style: style)
                    XCTAssertEqual(lines.count, rows, "\(pose) \(size) \(level)")
                    for l in lines {
                        XCTAssertEqual(AnsiText.width(l), cols, "\(pose) \(size) \(level)")
                        if hasEscape(l) { XCTAssertTrue(l.hasSuffix("\u{1B}[0m"), "attributes reset at line end") }
                    }
                }
            }
        }
    }

    func testTruecolorUsesExactPaletteRGB() {
        let joined = Mascot.render(.standing, .medium, style: MascotStyle(color: .truecolor, unicode: true)).joined()
        XCTAssertTrue(joined.contains("38;2;13;27;76"), "navy outline")
        XCTAssertTrue(joined.contains("38;2;245;184;46"), "yellow beak")
        XCTAssertFalse(joined.contains("38;5;"))
    }

    func testNoColorGivesPlainAsciiWithoutEscapes() {
        for pose in MascotPose.allCases {
            let lines = Mascot.render(pose, .medium, caps: caps(color: .none))
            XCTAssertEqual(lines, MascotASCII.art(for: pose))
            XCTAssertFalse(lines.contains(where: hasEscape))
        }
    }

    func testNoUnicodeFallsBackToAsciiEvenWithColor() {
        let c = caps(color: .truecolor, unicode: false)
        for pose in MascotPose.allCases {
            let lines = Mascot.render(pose, .small, caps: c)
            XCTAssertFalse(lines.contains(where: hasEscape))
            XCTAssertTrue(lines.joined().unicodeScalars.allSatisfy { $0.value < 0x7F })
        }
    }

    func testCjkLocaleUsesAscii() {
        let c = TermCaps.detect(env: ["TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "ja_JP.UTF-8"],
                                stdinTTY: true, stdoutTTY: true, stderrTTY: true, measuredColumns: 100)
        XCTAssertFalse(MascotStyle(caps: c).blocks)
        XCTAssertEqual(Mascot.render(.standing, .small, caps: c), MascotASCII.standing)
    }

    func testTransparentPixelsNeverGetABackground() {
        // one opaque pixel over a transparent one: half block with foreground only
        for level in [ColorLevel.truecolor, .ansi256, .basic16] {
            let l = Mascot.blocks([[1, 0], [0, 0]], level: level)
            XCTAssertEqual(l.count, 1)
            XCTAssertTrue(l[0].contains("\u{2580}"))
            XCTAssertFalse(l[0].contains(";48;") || l[0].contains("[48;") || l[0].contains("m\u{1B}[4"), l[0])
            XCTAssertEqual(AnsiText.width(l[0]), 2)
        }
        let lower = Mascot.blocks([[0], [1]], level: .truecolor)
        XCTAssertTrue(lower[0].contains("\u{2584}"))
        // a stored row of nothing but transparency has no escapes at all
        XCTAssertEqual(Mascot.blocks([[0, 0], [0, 0]], level: .truecolor), ["  "])
    }

    func testAnsi256MappingIsDeterministicAndAvoidsThemeColors() {
        XCTAssertEqual(Mascot.nearest256(251, 251, 247), 231)
        XCTAssertEqual(Mascot.nearest256(245, 184, 46), 214)
        XCTAssertEqual(Mascot.nearest256(0, 0, 0), 16)
        XCTAssertEqual(Mascot.nearest256(128, 128, 128), 244)
        for i in 1..<MascotArt.paletteRGB.count {
            XCTAssertEqual(Mascot.ansi256Index(i), Mascot.ansi256Index(i))
            XCTAssertGreaterThanOrEqual(Mascot.ansi256Index(i), 16)
        }
        XCTAssertEqual(Mascot.color(6, .ansi256, fg: true), "38;5;214")
        XCTAssertEqual(Mascot.color(6, .ansi256, fg: false), "48;5;214")
    }

    func testBasic16MappingAndNoBrightBackgrounds() {
        XCTAssertEqual(Mascot.color(1, .basic16, fg: true), "34")     // navy -> blue
        XCTAssertEqual(Mascot.color(3, .basic16, fg: true), "97")
        XCTAssertEqual(Mascot.color(0, .basic16, fg: true), nil)
        for i in 1..<MascotArt.paletteRGB.count {
            let bg = Int(Mascot.color(i, .basic16, fg: false) ?? "") ?? 0
            XCTAssertTrue((40...47).contains(bg), "background \(bg) must be a plain 40-47 color")
        }
        let a = Mascot.render(.waving, .small, style: MascotStyle(color: .basic16, unicode: true))
        XCTAssertEqual(a, Mascot.render(.waving, .small, style: MascotStyle(color: .basic16, unicode: true)))
        XCTAssertFalse(a.joined().contains("38;"))
        XCTAssertFalse(a.joined().contains("38;5"))
    }

    func testRenderedLinesNeverContainForeignEscapes() {
        for level in [ColorLevel.truecolor, .ansi256, .basic16] {
            for l in Mascot.render(.celebrating, .medium, style: MascotStyle(color: level, unicode: true)) {
                let stripped = l.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
                XCTAssertFalse(stripped.contains("\u{1B}"))
            }
        }
    }
}

final class MascotSceneTests: XCTestCase {
    func testSceneIsNilWhenNotATTY() {
        XCTAssertNil(Mascot.scene(.sleeping, text: ["x"], caps: caps(tty: false), env: [:]))
    }

    func testSceneIsNilForDumbTerminalNarrowWidthAndOptOut() {
        XCTAssertNil(Mascot.scene(.sleeping, text: ["x"], caps: caps(term: "dumb"), env: [:]))
        XCTAssertNil(Mascot.scene(.sleeping, text: ["x"], caps: caps(cols: 39), env: [:]))
        XCTAssertNil(Mascot.scene(.sleeping, text: ["x"], caps: caps(), env: ["PIER_NO_MASCOT": "1"]))
        XCTAssertNotNil(Mascot.scene(.sleeping, text: ["x"], caps: caps(), env: ["PIER_NO_MASCOT": "0"]))
        XCTAssertNotNil(Mascot.scene(.sleeping, text: ["x"], caps: caps(), env: [:]))
    }

    func testSceneIsSideBySideAndFitsTheTerminal() {
        for cols in [40, 60, 100] {
            let c = caps(cols: cols)
            let lines = Mascot.scene(.celebrating, text: ["No stale dev servers.", "nothing forgotten, time for a coffee"], caps: c, env: [:])
            XCTAssertNotNil(lines)
            XCTAssertEqual(lines?.count, 8)
            for l in lines ?? [] { XCTAssertLessThanOrEqual(AnsiText.width(l), cols) }
            XCTAssertTrue((lines ?? []).map { AnsiText.strip($0) }.contains { $0.contains("No stale dev servers.") })
        }
    }

    func testSceneWithoutColorUsesAsciiAndNoEscapes() {
        let lines = Mascot.scene(.sleeping, text: ["hi"], caps: caps(color: .none), env: [:]) ?? []
        XCTAssertFalse(lines.isEmpty)
        XCTAssertFalse(lines.contains(where: hasEscape))
    }

    func testBubbleHasUniformWidth() {
        for unicode in [true, false] {
            let b = Mascot.bubble(["Ahoy! I'm the pier gull.", "", "Tip: some long tip that has to wrap around the bubble edge nicely"],
                                  width: 40, unicode: unicode, pointer: 2)
            XCTAssertEqual(Set(b.map { DisplayWidth.of($0) }), [40])
            if !unicode { XCTAssertTrue(b.joined().unicodeScalars.allSatisfy { $0.value < 0x7F }) }
        }
    }

    func testWrapNeverExceedsWidth() {
        for l in Mascot.wrap("a verylongwordthatexceedsthewidthbymuch and short words here", width: 12) {
            XCTAssertLessThanOrEqual(DisplayWidth.of(l), 12)
        }
        XCTAssertEqual(Mascot.wrap("", width: 10), [""])
    }

    func testHelpBannerFitsAndKeepsTextAtEveryWidth() {
        for cols in [40, 56, 70, 100, 200] {
            for unicode in [true, false] {
                let c = caps(unicode: unicode, cols: cols)
                let lines = MascotHello.greeting(pose: .saluting, text: MascotHello.helpBubbleText(version: "9.9.9"),
                                                 caps: c, showMascot: true)
                let joined = lines.map { AnsiText.strip($0) }.joined(separator: " ")
                XCTAssertTrue(joined.contains("9.9.9"), "cols \(cols)")
                XCTAssertTrue(joined.contains("pier help <command>") || joined.contains("<command>"), "cols \(cols)")
                for l in lines { XCTAssertLessThanOrEqual(AnsiText.width(l), cols, "cols \(cols): \(l)") }
            }
        }
    }

    func testHelloContainsVersionTipAndRepoAtEveryWidth() {
        for cols in [30, 40, 55, 70, 100, 160] {
            for c in [caps(cols: cols), caps(color: .none, cols: cols), caps(unicode: false, cols: cols)] {
                let lines = MascotHello.lines(pose: .waving, version: "9.9.9", tip: "`pier watch` is cool", caps: c, showMascot: true)
                let text = lines.map { AnsiText.strip($0) }.joined(separator: "\n")
                XCTAssertTrue(text.contains("9.9.9"))
                XCTAssertTrue(text.contains(Mascot.repoURL), "repo url intact at \(cols)")
                XCTAssertTrue(text.contains("pier watch"))
                for l in lines where AnsiText.strip(l).trimmingCharacters(in: .whitespaces) != Mascot.repoURL {
                    XCTAssertLessThanOrEqual(AnsiText.width(l), max(cols, 20), "\(cols): \(AnsiText.strip(l))")
                }
            }
        }
        let plain = MascotHello.lines(pose: .waving, version: "1", tip: "t", caps: caps(), showMascot: false)
        XCTAssertFalse(plain.contains(where: hasEscape))
        XCTAssertEqual(MascotHello.tips.count >= 10, true)
    }

    func testPlainHelloHasNoEscapesWhenPiped() {
        let c = caps(tty: false)
        let lines = MascotHello.lines(pose: .waving, version: "1", tip: "t", caps: c, showMascot: true)
        XCTAssertFalse(lines.contains(where: hasEscape))
    }
}

final class MascotWatchTests: XCTestCase {
    private func empty(cols: Int, rows: Int, loaded: Bool = true) -> WatchState {
        var st = WatchState(interval: 2)
        st.resize(cols: cols, rows: rows)
        if loaded { st.update(services: [], now: Date()) }
        return st
    }

    func testEmptyWatchShowsCenteredSleepingGull() {
        let st = empty(cols: 100, rows: 30)
        let style = WatchRenderer.Style(color: true, attributes: true, mascot: MascotStyle(color: .truecolor, unicode: true))
        let lines = WatchRenderer.lines(st, now: Date(), style: style)
        XCTAssertEqual(lines.count, 30)
        for l in lines { XCTAssertEqual(WatchRenderer.visibleWidth(l), 100) }
        let plain = lines.map(WatchRenderer.stripped)
        XCTAssertTrue(plain.contains { $0.contains("No services listening.") })
        XCTAssertTrue(plain.contains { $0.contains("pier run") })
        XCTAssertTrue(lines.contains { $0.contains("38;2;") }, "colored gull")
        XCTAssertTrue(plain.first!.hasPrefix("pier watch"))
        // centered: the text row is indented about half the free space
        let row = plain.first { $0.contains("No services listening.") }!
        let indent = row.prefix { $0 == " " }.count
        XCTAssertEqual(indent, (100 - "No services listening.".count) / 2)
    }

    func testEmptyWatchFallsBackWhenThereIsNoRoomOrNoMascot() {
        let ms = MascotStyle(color: .truecolor, unicode: true)
        // small gull still fits at 16 rows; below that plain text
        let medium = WatchRenderer.lines(empty(cols: 100, rows: 30), now: Date(), style: WatchRenderer.Style(color: true, attributes: true, mascot: ms))
        let small = WatchRenderer.lines(empty(cols: 100, rows: 16), now: Date(), style: WatchRenderer.Style(color: true, attributes: true, mascot: ms))
        XCTAssertTrue(medium.contains { WatchRenderer.stripped($0).contains("No services listening.") })
        XCTAssertTrue(small.contains { WatchRenderer.stripped($0).contains("No services listening.") })
        XCTAssertEqual(medium.filter { $0.contains("\u{1B}[38;2") }.count, 15)
        XCTAssertEqual(small.filter { $0.contains("\u{1B}[38;2") }.count, 8)
        for (cols, rows) in [(100, 8), (30, 30)] {
            let l = WatchRenderer.lines(empty(cols: cols, rows: rows), now: Date(), style: WatchRenderer.Style(color: true, attributes: true, mascot: ms))
            XCTAssertTrue(l.contains { WatchRenderer.stripped($0).contains("no services listening") }, "\(cols)x\(rows)")
            XCTAssertEqual(l.count, rows)
        }
        let off = WatchRenderer.lines(empty(cols: 100, rows: 30), now: Date(), style: .full)
        XCTAssertTrue(off.contains { WatchRenderer.stripped($0).contains("no services listening") })
        XCTAssertFalse(off.contains { $0.contains("\u{1B}[38;2") })
    }

    func testEmptyWatchAsciiGullWithoutColor() {
        let st = empty(cols: 80, rows: 24)
        let style = WatchRenderer.Style(color: false, attributes: false, unicode: false, mascot: MascotStyle(color: .none, unicode: false))
        let lines = WatchRenderer.lines(st, now: Date(), style: style)
        XCTAssertEqual(lines.count, 24)
        for l in lines {
            XCTAssertEqual(WatchRenderer.visibleWidth(l), 80)
            XCTAssertTrue(l.unicodeScalars.allSatisfy { $0.value < 0x7F }, l)
        }
        XCTAssertTrue(lines.contains { $0.contains("/=====\\") })
    }

    func testNoGullWhileScanningOrFiltering() {
        let ms = MascotStyle(color: .truecolor, unicode: true)
        let style = WatchRenderer.Style(color: true, attributes: true, mascot: ms)
        let scanning = WatchRenderer.lines(empty(cols: 100, rows: 30, loaded: false), now: Date(), style: style)
        XCTAssertTrue(scanning.contains { WatchRenderer.stripped($0).contains("scanning") })
        XCTAssertFalse(scanning.contains { $0.contains("\u{1B}[38;2") })
        var filtering = empty(cols: 100, rows: 30)
        _ = filtering.handle(.char("/"), now: Date()); _ = filtering.handle(.char("x"), now: Date())
        let l = WatchRenderer.lines(filtering, now: Date(), style: style)
        XCTAssertTrue(l.contains { WatchRenderer.stripped($0).contains("no matches") })
        XCTAssertFalse(l.contains { $0.contains("\u{1B}[38;2") })
    }
}
