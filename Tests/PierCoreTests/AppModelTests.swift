import XCTest
@testable import PierCore

final class AppModelTests: XCTestCase {
    func svc(_ port: UInt16, pid: Int32 = 100, name: String = "node", kind: ServiceKind = .devServer,
             project: String? = nil, path: String? = nil, framework: String? = nil, infra: String? = nil,
             managed: Bool = false, noise: Bool = false, scope: BindScope = .loopback,
             health: Health? = nil, title: String? = nil) -> Service {
        var s = Service(port: port, process: ProcInfo(pid: pid == 100 ? Int32(port) : pid, ppid: 1, uid: 501, name: name),
                        addresses: ["127.0.0.1"], bindScope: scope)
        s.kind = kind
        s.projectName = project
        s.projectPath = path ?? project.map { "/dev/\($0)" }
        s.framework = framework.map { Framework(id: $0.lowercased(), name: $0) }
        s.infraName = infra
        s.isManaged = managed
        s.isNoise = noise
        if health != nil || title != nil { s.probe = ProbeResult(protocolKind: .http, health: health ?? .ok, title: title) }
        return s
    }

    let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    func manifest(_ id: String, _ state: ManagedManifest.State) -> ManagedManifest {
        ManagedManifest(id: id, name: id, wrapperPid: 1, childPid: 2, command: ["x"], cwd: "/", startedAt: epoch, state: state)
    }

    // MARK: grouping

    func testGroupOrderAndPinned() {
        let a = svc(3000, project: "alpha", framework: "Next.js")
        let b = svc(3001, project: "beta", managed: true)
        let c = svc(5432, kind: .infra, infra: "PostgreSQL")
        let d = svc(9000, kind: .other)
        let e = svc(5000, name: "ControlCenter", kind: .system, noise: true)
        var cfg = PierConfig()
        cfg.pins = [c.stableKey, a.stableKey]
        let secs = AppModel.sections([a, b, c, d, e], config: cfg, showNoise: true)
        XCTAssertEqual(secs.map(\.group), [.pinned, .managed, .other, .system])
        XCTAssertEqual(secs[0].services.map(\.port), [5432, 3000], "pin order, not port order")
        XCTAssertEqual(secs[1].services.map(\.port), [3001])
    }

    func testSystemHiddenWithoutShowNoise() {
        let e = svc(5000, kind: .system, noise: true)
        XCTAssertTrue(AppModel.sections([e], config: PierConfig(), showNoise: false).isEmpty)
        XCTAssertEqual(AppModel.sections([e], config: PierConfig(), showNoise: true).map(\.group), [.system])
    }

    func testInfraAndDockerShareGroupAndPortOrder() {
        let dk = svc(8080, kind: .docker)
        let pg = svc(5432, kind: .infra, infra: "PostgreSQL")
        let p = svc(3000, project: "a")
        let secs = AppModel.sections([dk, pg, p], config: PierConfig(), showNoise: false)
        XCTAssertEqual(secs.map(\.group), [.projects, .infra])
        XCTAssertEqual(secs[1].services.map(\.port), [5432, 8080])
    }

    func testCrashedManagedShowsInManagedSection() {
        let secs = AppModel.sections([], config: PierConfig(), showNoise: false, crashed: [manifest("abc", .crashed)])
        XCTAssertEqual(secs.map(\.group), [.managed])
        XCTAssertEqual(secs[0].crashed.count, 1)
    }

    func testNavigationOrderSkipsCollapsed() {
        let a = svc(3000, project: "a"), e = svc(5000, kind: .system, noise: true)
        let secs = AppModel.sections([a, e], config: PierConfig(), showNoise: true)
        XCTAssertEqual(AppModel.navigationOrder(secs, collapsed: [.system]).map(\.port), [3000])
        XCTAssertEqual(AppModel.navigationOrder(secs, collapsed: []).map(\.port), [3000, 5000])
    }

    // MARK: rename / filter

    func testRenameApplied() {
        let a = svc(3000, project: "alpha")
        var cfg = PierConfig()
        XCTAssertEqual(AppModel.displayName(a, config: cfg), "alpha")
        AppModel.setRename("  My App ", for: a, in: &cfg)
        XCTAssertEqual(AppModel.displayName(a, config: cfg), "My App")
        AppModel.setRename("", for: a, in: &cfg)
        XCTAssertNil(cfg.renames[a.stableKey])
    }

    func testFilterFuzzyAndRename() {
        let a = svc(3000, project: "haf-pet", framework: "Next.js")
        let b = svc(3001, project: "woom", framework: "Expo")
        var cfg = PierConfig()
        XCTAssertNil(AppModel.filter([a, b], query: "  ", config: cfg))
        XCTAssertEqual(AppModel.filter([a, b], query: "haf", config: cfg)?.map(\.port), [3000])
        XCTAssertEqual(AppModel.filter([a, b], query: "hpt", config: cfg)?.map(\.port), [3000], "subsequence")
        XCTAssertEqual(AppModel.filter([a, b], query: "next", config: cfg)?.map(\.port), [3000])
        XCTAssertEqual(AppModel.filter([a, b], query: "30", config: cfg)?.map(\.port), [3000, 3001], "port prefix")
        XCTAssertEqual(AppModel.filter([a, b], query: "3001", config: cfg)?.map(\.port), [3001])
        AppModel.setRename("Banana", for: b, in: &cfg)
        XCTAssertEqual(AppModel.filter([a, b], query: "banana", config: cfg)?.map(\.port), [3001])
        XCTAssertEqual(AppModel.filter([a, b], query: "zzzz", config: cfg)?.count, 0)
    }

    func testFilterBestMatchFirst() {
        let a = svc(3000, project: "xapp")       // substring
        let b = svc(3005, project: "app")        // exact
        XCTAssertEqual(AppModel.filter([a, b], query: "app", config: PierConfig())?.map(\.port), [3005, 3000])
    }

    // MARK: rows

    func testBadges() {
        var s = svc(3000, project: "a", managed: true, scope: .all)
        s.tunnelURL = "https://x.trycloudflare.com"
        XCTAssertEqual(AppModel.badges(s), [.lan, .managed, .tunnel])
        XCTAssertEqual(AppModel.badges(svc(3001, project: "b")), [])
    }

    func testSecondaryLine() {
        var s = svc(3000, project: "haf-pet", framework: "Next.js", title: "Haf Pet")
        s.gitBranch = "main"
        XCTAssertEqual(AppModel.secondaryLine(s), "haf-pet · Next.js · :3000 · main")
        // project equal to title is dropped
        let t = svc(3001, project: "woom", framework: "Expo")
        XCTAssertEqual(AppModel.secondaryLine(t), "woom · Expo · :3001".replacingOccurrences(of: "woom · ", with: ""))
        let pg = svc(5432, kind: .infra, infra: "PostgreSQL")
        XCTAssertEqual(AppModel.secondaryLine(pg), ":5432")
    }

    func testGlyph() {
        XCTAssertEqual(AppModel.fallbackGlyph(svc(5432, kind: .infra, infra: "PostgreSQL")), .symbol("cylinder.split.1x2"))
        XCTAssertEqual(AppModel.fallbackGlyph(svc(3000, project: "a", framework: "Next.js")), .letter("N"))
        XCTAssertEqual(AppModel.fallbackGlyph(svc(9, name: "x", kind: .other)), .symbol("network"))
    }

    // MARK: menu bar

    func testMenuBarState() {
        let a = svc(3000, project: "a", health: .ok), b = svc(3001, project: "b", health: .error)
        let noise = svc(5000, kind: .system, noise: true)
        XCTAssertEqual(AppModel.menuBarState([a], managed: [], showNoise: false), .init(count: 1, warning: false))
        XCTAssertEqual(AppModel.menuBarState([a, b, noise], managed: [], showNoise: false), .init(count: 2, warning: true))
        XCTAssertEqual(AppModel.menuBarState([a, b, noise], managed: [], showNoise: true).count, 3)
        XCTAssertTrue(AppModel.menuBarState([a], managed: [manifest("m", .crashed)], showNoise: false).warning)
        XCTAssertFalse(AppModel.menuBarState([a], managed: [manifest("m", .running)], showNoise: false).warning)
    }

    // MARK: merge

    func testMergeKeepsPreviousProbe() {
        let old = svc(3000, project: "a", health: .error, title: "Old Title")
        let fresh = svc(3000, project: "a")
        let newOne = svc(3001, project: "b")
        let merged = AppModel.mergeProbes(previous: [old], fresh: [newOne, fresh], showNoise: false)
        XCTAssertEqual(merged.map(\.port), [3000, 3001])
        XCTAssertEqual(merged[0].probe?.title, "Old Title")
        XCTAssertNil(merged[1].probe)
        XCTAssertTrue(AppModel.needsProbe(merged[1]))
        XCTAssertFalse(AppModel.needsProbe(merged[0]))
    }

    func testMergeDropsServicesThatDisappear() {
        let old = svc(3000, project: "a", health: .ok)
        XCTAssertTrue(AppModel.mergeProbes(previous: [old], fresh: [], showNoise: false).isEmpty)
    }

    func testApplyProbe() {
        var list = [svc(3000, project: "a")]
        AppModel.applyProbe(ProbeResult(protocolKind: .http, health: .error, httpStatus: 500), toID: list[0].id, in: &list, showNoise: false)
        XCTAssertEqual(list[0].probe?.health, .error)
    }

    // MARK: transitions

    func testCrashTransition() {
        let ev = AppModel.transitions(previousServices: [], currentServices: [],
                                      previousManaged: [manifest("a", .running)], currentManaged: [manifest("a", .crashed)])
        XCTAssertEqual(ev, [.managedCrashed(manifest("a", .crashed))])
        // still crashed: no repeat
        XCTAssertTrue(AppModel.transitions(previousServices: [], currentServices: [],
                                           previousManaged: [manifest("a", .crashed)], currentManaged: [manifest("a", .crashed)]).isEmpty)
    }

    func testNewServiceTransitionIgnoresRestarts() {
        let a = svc(3000, pid: 10, project: "a")
        let restarted = svc(3000, pid: 11, project: "a")
        let b = svc(3001, pid: 12, project: "b")
        let ev = AppModel.transitions(previousServices: [a], currentServices: [restarted, b], previousManaged: [], currentManaged: [])
        XCTAssertEqual(ev, [.newService(b)])
    }

    // MARK: config helpers / footer

    func testTogglePin() {
        let a = svc(3000, project: "a")
        var cfg = PierConfig()
        AppModel.togglePin(a, in: &cfg)
        XCTAssertEqual(cfg.pins, [a.stableKey])
        AppModel.togglePin(a, in: &cfg)
        XCTAssertTrue(cfg.pins.isEmpty)
    }

    func testFooter() {
        let now = Date()
        XCTAssertEqual(AppModel.footer(count: 1, refreshedAt: nil), "1 service")
        XCTAssertEqual(AppModel.footer(count: 5, refreshedAt: now.addingTimeInterval(-7), now: now), "5 services · refreshed 7s ago")
        XCTAssertEqual(AppModel.footer(count: 2, refreshedAt: now, now: now), "2 services · refreshed just now")
    }
}

final class AppModelHotkeyTests: XCTestCase {
    func testDefault() {
        XCTAssertEqual(try? HotkeyParser.parse("opt+cmd+p").get(),
                       HotkeyParser.Spec(keyCode: 35, modifiers: HotkeyParser.option | HotkeyParser.cmd))
    }
    func testAliasesAndCase() {
        XCTAssertEqual(try? HotkeyParser.parse("Ctrl+Shift+Alt+Space").get(),
                       HotkeyParser.Spec(keyCode: 49, modifiers: HotkeyParser.control | HotkeyParser.shift | HotkeyParser.option))
    }
    func testErrors() {
        XCTAssertEqual(HotkeyParser.parse("").failure, .empty)
        XCTAssertEqual(HotkeyParser.parse("cmd+opt").failure, .noKey)
        XCTAssertEqual(HotkeyParser.parse("cmd+p+q").failure, .multipleKeys)
        XCTAssertEqual(HotkeyParser.parse("cmd+§").failure, .unknownKey("§"))
        XCTAssertEqual(HotkeyParser.parse("p").failure, .noModifier)
        XCTAssertNotNil(try? HotkeyParser.parse("f5").get())
    }
    func testDisplay() {
        XCTAssertEqual(HotkeyParser.display("opt+cmd+p"), "⌥⌘P")
    }
}

final class AppModelLogTextTests: XCTestCase {
    func testStripANSI() {
        XCTAssertEqual(LogText.stripANSI("\u{1B}[32mready\u{1B}[0m - started"), "ready - started")
        XCTAssertEqual(LogText.stripANSI("\u{1B}]0;title\u{07}hello"), "hello")
        XCTAssertEqual(LogText.stripANSI("a\r\nb"), "a\nb")
        XCTAssertEqual(LogText.stripANSI("10%\r50%\r100%\ndone"), "100%\ndone")
        XCTAssertEqual(LogText.stripANSI("plain"), "plain")
    }
    func testTrimmed() {
        XCTAssertEqual(LogText.trimmed("a\nb\nc\nd\n", maxLines: 2), "c\nd\n")
        XCTAssertEqual(LogText.trimmed("a\nb\n", maxLines: 5), "a\nb\n")
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let e) = self { return e } else { return nil } }
}
