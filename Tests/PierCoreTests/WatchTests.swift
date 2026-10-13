import XCTest
@testable import PierCore

private func svc(_ port: UInt16, pid: Int32 = 100, name: String = "node", title: String? = nil, project: String? = nil,
                 infra: String? = nil, framework: Framework? = nil, kind: ServiceKind = .devServer) -> Service {
    var s = Service(port: port, process: ProcInfo(pid: pid, ppid: 1, uid: 501, name: name, startTime: now.addingTimeInterval(-3700),
                                                  cpuPercent: 1.5, rssBytes: 150 << 20),
                    addresses: ["127.0.0.1"], bindScope: .loopback)
    s.projectName = project; s.infraName = infra; s.framework = framework; s.kind = kind
    s.projectPath = project.map { "/dev/\($0)" }
    s.probe = ProbeResult(protocolKind: .http, health: .ok, httpStatus: 200, title: title)
    return s
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func sample() -> [Service] {
    [svc(3000, pid: 10, project: "haf-pet", framework: Framework(id: "next", name: "Next.js")),
     svc(3100, pid: 11, project: "relay-crm", framework: Framework(id: "vite", name: "Vite")),
     svc(5173, pid: 12, project: "playdeck", framework: Framework(id: "vite", name: "Vite")),
     svc(5432, pid: 13, name: "postgres", infra: "PostgreSQL", kind: .infra)]
}

private func loaded(_ services: [Service] = sample(), rows: Int = 24, cols: Int = 100) -> WatchState {
    var st = WatchState(interval: 2)
    st.resize(cols: cols, rows: rows)
    st.update(services: services, now: now)
    return st
}

private func press(_ st: inout WatchState, _ keys: Key...) -> [WatchState.Effect] {
    keys.compactMap { st.handle($0, now: now) }
}

final class WatchKeyDecoderTests: XCTestCase {
    func testPlainAndArrowKeys() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed(Array("j".utf8)), [.char("j")])
        XCTAssertEqual(d.feed([0x1B, 0x5B, 0x41]), [.up])
        XCTAssertEqual(d.feed([0x1B, 0x5B, 0x42]), [.down])
        XCTAssertEqual(d.feed([0x1B, 0x4F, 0x43]), [.right])           // SS3
        XCTAssertEqual(d.feed([0x0D]), [.enter])
        XCTAssertEqual(d.feed([0x7F]), [.backspace])
        XCTAssertEqual(d.feed([0x03]), [.ctrl("c")])
        XCTAssertEqual(d.feed([0x1B, 0x5B, 0x35, 0x7E]), [.pageUp])
        XCTAssertEqual(d.feed([0x1B, 0x5B, 0x33, 0x7E]), [.delete])
    }

    func testSplitSequenceAcrossReads() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x1B]), [])
        XCTAssertTrue(d.hasPending)
        XCTAssertEqual(d.feed([0x5B]), [])
        XCTAssertEqual(d.feed([0x41]), [.up])
        XCTAssertFalse(d.hasPending)
    }

    func testLoneEscapeNeedsFlush() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x1B]), [])
        XCTAssertEqual(d.flush(), [.escape])
        XCTAssertFalse(d.hasPending)
        XCTAssertEqual(d.flush(), [])
    }

    func testEscapeFollowedByKeyIsNotSwallowed() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x1B, 0x1B]), [.escape])
        XCTAssertEqual(d.flush(), [.escape])
    }

    func testBatchedKeysAndUTF8() {
        var d = KeyDecoder()
        XCTAssertEqual(d.feed([0x6A, 0x1B, 0x5B, 0x41, 0x71]), [.char("j"), .up, .char("q")])
        XCTAssertEqual(d.feed(Array("é".utf8)), [.char("é")])
        XCTAssertEqual(d.feed([0xC3]), [])                              // half a character
        XCTAssertEqual(d.feed([0xA9]), [.char("é")])
    }
}

final class WatchStateTests: XCTestCase {
    func testSelectionMovesAndClamps() {
        var st = loaded()
        XCTAssertEqual(st.selected?.port, 3000)
        _ = press(&st, .up)
        XCTAssertEqual(st.selected?.port, 3000)
        _ = press(&st, .down, .char("j"))
        XCTAssertEqual(st.selected?.port, 5173)
        _ = press(&st, .char("G"))
        XCTAssertEqual(st.selected?.port, 5432)
        _ = press(&st, .down)
        XCTAssertEqual(st.selected?.port, 5432)
        _ = press(&st, .char("g"))
        XCTAssertEqual(st.selected?.port, 3000)
    }

    func testSelectionStableByIdAcrossRefresh() {
        var st = loaded()
        _ = press(&st, .down, .down)                                    // 5173
        var next = sample()
        next.insert(svc(2000, pid: 5, project: "new"), at: 0)           // shifts every index
        st.update(services: next, now: now)
        XCTAssertEqual(st.selected?.port, 5173)
    }

    func testSelectionFallsBackToSameRowWhenServiceVanishes() {
        var st = loaded()
        _ = press(&st, .down)                                           // 3100 @ index 1
        st.update(services: sample().filter { $0.port != 3100 }, now: now)
        XCTAssertEqual(st.selected?.port, 5173)                         // next row slid into index 1
        st.update(services: [], now: now)
        XCTAssertNil(st.selected)
        XCTAssertEqual(press(&st, .char("k")), [])                      // no selection: nothing to kill
    }

    func testScrollFollowsSelection() {
        let many = (0..<40).map { svc(UInt16(4000 + $0), pid: Int32(100 + $0), project: "p\($0)") }
        var st = loaded(many, rows: 12)                                 // table height 9
        let h = st.layout().tableHeight
        XCTAssertEqual(h, 9)
        _ = press(&st, .char("G"))
        XCTAssertEqual(st.scroll, 40 - h)
        XCTAssertEqual(st.selected?.port, 4039)
        _ = press(&st, .char("g"))
        XCTAssertEqual(st.scroll, 0)
        for _ in 0..<h { _ = press(&st, .down) }
        XCTAssertEqual(st.scroll, 1)
        st.resize(cols: 100, rows: 40)                                  // resize keeps selection visible
        XCTAssertTrue((st.scroll..<st.scroll + st.layout().tableHeight).contains(st.selectedIndex!))
    }

    func testFilterIncrementalEscClearsAndKeepsPortOrder() {
        var st = loaded()
        XCTAssertEqual(press(&st, .char("/")), [])
        XCTAssertEqual(st.mode, .filtering)
        _ = press(&st, .char("v"), .char("i"), .char("t"))              // "vit" -> Vite framework
        XCTAssertEqual(st.visible.map(\.port), [3100, 5173])
        XCTAssertEqual(st.selected?.port, 3100)
        _ = press(&st, .backspace, .backspace, .backspace)
        XCTAssertEqual(st.visible.count, 4)
        _ = press(&st, .char("3"), .char("1"))                          // port prefix
        XCTAssertEqual(st.visible.map(\.port), [3100])
        XCTAssertEqual(press(&st, .char("q")), [])                      // q is text while filtering
        XCTAssertEqual(st.visible.count, 0)
        _ = press(&st, .escape)
        XCTAssertEqual(st.mode, .normal)
        XCTAssertEqual(st.filter, "")
        XCTAssertEqual(st.visible.count, 4)
    }

    func testEscapeLayers() {
        var st = loaded()
        _ = press(&st, .char("/"), .char("r"), .enter)                  // keep filter
        XCTAssertEqual(st.filter, "r")
        _ = press(&st, .enter)
        XCTAssertTrue(st.showDetail)
        XCTAssertEqual(press(&st, .escape), [])                         // closes detail
        XCTAssertFalse(st.showDetail)
        XCTAssertEqual(press(&st, .escape), [])                         // clears filter
        XCTAssertEqual(st.filter, "")
        XCTAssertEqual(press(&st, .escape), [.quit])
    }

    func testQuitKeys() {
        var st = loaded()
        XCTAssertEqual(press(&st, .char("q")), [.quit])
        XCTAssertEqual(press(&st, .ctrl("c")), [.quit])
        _ = press(&st, .char("/"))
        XCTAssertEqual(press(&st, .ctrl("c")), [.quit])
    }

    func testKillAlwaysConfirms() {
        var st = loaded()
        XCTAssertEqual(press(&st, .down, .char("k")), [])               // dev server: still asks
        guard case .confirmKill(let s) = st.mode else { return XCTFail("expected confirm") }
        XCTAssertEqual(s.port, 3100)
        XCTAssertEqual(press(&st, .char("y")), [.kill(s)])
        XCTAssertEqual(st.mode, .normal)

        _ = press(&st, .char("k"))
        XCTAssertEqual(press(&st, .char("n")), [])
        XCTAssertEqual(st.mode, .normal)
        XCTAssertEqual(st.status?.text, "kill cancelled")

        _ = press(&st, .char("k"))
        XCTAssertEqual(press(&st, .enter), [])                          // anything but y cancels
        XCTAssertFalse(st.showDetail)
    }

    func testKillRefusesProtectedPid() {
        var st = loaded([svc(1000, pid: 1, name: "launchd")])
        XCTAssertEqual(press(&st, .char("k")), [])
        XCTAssertEqual(st.mode, .normal)
        XCTAssertEqual(st.status?.isError, true)
        let me = svc(1001, pid: ProcessInfo.processInfo.processIdentifier)
        st.update(services: [me], now: now)
        _ = press(&st, .char("k"))
        XCTAssertEqual(st.mode, .normal)
    }

    func testConfirmReasonFollowsKillerSemantics() {
        XCTAssertNil(WatchState.confirmReason(svc(3000, project: "x")))
        XCTAssertEqual(WatchState.confirmReason(svc(5432, name: "postgres", infra: "PostgreSQL", kind: .infra)), "infrastructure")
    }

    func testKillMessages() {
        let s = svc(3100, title: "relay-crm", project: "relay-crm")
        XCTAssertEqual(WatchState.killMessage(.terminated, for: s).0, "killed relay-crm (:3100)")
        let denied = WatchState.killMessage(.permissionDenied, for: s)
        XCTAssertEqual(denied.0, "permission denied: use `pier kill` in a shell")
        XCTAssertTrue(denied.1)
    }

    func testEffects() {
        var st = loaded()
        XCTAssertEqual(press(&st, .char("c")), [.copyURL(st.selected!)])
        XCTAssertEqual(press(&st, .char("o")), [.open(st.selected!)])
        XCTAssertEqual(press(&st, .char("r")), [.refresh])
        XCTAssertFalse(st.includeNoise)
        XCTAssertEqual(press(&st, .char("a")), [.refresh])
        XCTAssertTrue(st.includeNoise)
    }

    func testStatusExpires() {
        var st = loaded()
        st.setStatus("hi", now: now)
        XCTAssertNotNil(st.activeStatus(now: now.addingTimeInterval(1)))
        XCTAssertNil(st.activeStatus(now: now.addingTimeInterval(WatchState.statusDuration + 1)))
    }
}

final class WatchRendererTests: XCTestCase {
    private func check(_ st: WatchState, style: WatchRenderer.Style = .full, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        let lines = WatchRenderer.lines(st, now: now, style: style)
        XCTAssertEqual(lines.count, st.rows, "line count", file: file, line: line)
        for l in lines { XCTAssertEqual(WatchRenderer.visibleWidth(l), st.cols, "width of \(WatchRenderer.stripped(l).debugDescription)", file: file, line: line) }
        return lines.map(WatchRenderer.stripped)
    }

    func testFrameFillsExactlyTheTerminal() {
        for (cols, rows) in [(100, 24), (60, 10), (30, 6), (140, 50), (20, 4)] {
            var st = loaded(rows: rows, cols: cols)
            _ = check(st)
            _ = press(&st, .enter)
            _ = check(st)
            _ = check(st, style: .plain)
        }
    }

    func testHeaderTableAndFooter() {
        let st = loaded()
        let lines = check(st)
        XCTAssertTrue(lines[0].hasPrefix("pier watch - 4 services · refreshed "), lines[0])
        XCTAssertTrue(lines[0].contains("⟳ every 2s"))
        XCTAssertTrue(lines[0].hasSuffix("⏎ details  q quit"))
        for h in ["PORT", "NAME", "PROJECT", "FRAMEWORK/INFRA", "HEALTH", "BIND", "UPTIME", "CPU%", "MEM"] { XCTAssertTrue(lines[1].contains(h), h) }
        XCTAssertTrue(lines[2].hasPrefix("▸ 3000"))
        XCTAssertTrue(lines[3].hasPrefix("  3100"))
        XCTAssertTrue(lines[2].contains("Next.js") && lines[2].contains("1h") && lines[2].contains("150 MB") && lines[2].contains("● ok"))
        XCTAssertTrue(lines.last!.contains("q quit"))
    }

    func testSelectedRowIsReverseVideo() {
        let st = loaded()
        let raw = WatchRenderer.lines(st, now: now, style: .full)
        XCTAssertTrue(raw[2].hasPrefix("\u{1B}[7m"))
        XCTAssertFalse(raw[3].contains("\u{1B}[7m"))
        // health color must not reset reverse video inside the selected row
        XCTAssertFalse(raw[2].contains("\u{1B}[0m"))
        let plain = WatchRenderer.lines(st, now: now, style: .plain)
        XCTAssertFalse(plain[2].contains("\u{1B}"))
        XCTAssertTrue(plain[2].hasPrefix("> 3000"))
    }

    func testNoColorStillAllowsAttributes() {
        let raw = WatchRenderer.lines(loaded(), now: now, style: .init(color: false, attributes: true))
        XCTAssertFalse(raw.joined().contains("\u{1B}[32m"))
        XCTAssertTrue(raw[2].hasPrefix("\u{1B}[7m"))
    }

    func testScanningAndEmptyStates() {
        var st = WatchState(interval: 2)
        st.resize(cols: 80, rows: 12)
        var lines = check(st)
        XCTAssertTrue(lines[0].contains("scanning…"))
        XCTAssertTrue(lines[2].contains("scanning…"))
        st.update(services: [], now: now)
        lines = check(st)
        XCTAssertTrue(lines[2].contains("no services listening"))
        st.update(services: sample(), now: now)
        _ = press(&st, .char("/"), .char("z"), .char("z"), .char("z"))
        lines = check(st)
        XCTAssertTrue(lines[2].contains("no matches for “zzz”"))
        XCTAssertTrue(lines.last!.hasPrefix("/zzz"))
    }

    func testKillPromptInFooter() {
        var st = loaded()
        _ = press(&st, .down, .char("k"))
        XCTAssertTrue(check(st).last!.hasPrefix("Kill relay-crm (:3100)? y/N"))
        _ = press(&st, .char("n"))
        st.update(services: sample(), now: now)
        _ = press(&st, .char("G"), .char("k"))
        XCTAssertTrue(check(st).last!.hasPrefix("Kill PostgreSQL (:5432)? [infrastructure] y/N"))
    }

    func testStatusLineReplacesLegend() {
        var st = loaded()
        st.setStatus("killed relay-crm (:3100)", now: now)
        XCTAssertTrue(check(st).last!.hasPrefix("killed relay-crm (:3100)"))
        XCTAssertTrue(WatchRenderer.lines(st, now: now.addingTimeInterval(60), style: .full).last!.contains("q quit"))
    }

    func testDetailPaneShowsSelectedService() {
        var st = loaded(rows: 40)
        _ = press(&st, .down, .enter)
        let lines = check(st)
        let sep = lines.firstIndex { $0.hasPrefix("──") }
        XCTAssertNotNil(sep)
        let body = lines[sep!...].joined(separator: "\n")
        XCTAssertTrue(body.contains("relay-crm") && body.contains("http://localhost:3100") && body.contains("Next") == false)
        XCTAssertTrue(body.contains("Project") && body.contains("PID"))
    }

    func testScrolledWindowContainsSelection() {
        let many = (0..<40).map { svc(UInt16(4000 + $0), pid: Int32(100 + $0), project: "p\($0)") }
        var st = loaded(many, rows: 12)
        _ = press(&st, .char("G"))
        let lines = check(st)
        XCTAssertTrue(lines.contains { $0.hasPrefix("▸ 4039") })
        XCTAssertFalse(lines.contains { $0.contains("4000") })
    }

    func testFrameControlSequences() {
        let f = WatchRenderer.frame(loaded(), now: now, style: .full)
        XCTAssertTrue(f.hasPrefix("\u{1B}[1;1H"))                 // every row addressed explicitly
        XCTAssertTrue(f.contains("\u{1B}[24;1H"))
        XCTAssertFalse(f.contains("\u{1B}[K"))                    // no EL: it would erase the last column
        XCTAssertEqual(f.components(separatedBy: ";1H").count, 25)
    }
}
