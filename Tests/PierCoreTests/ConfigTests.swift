import XCTest
@testable import PierCore

final class ConfigTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pier-cfg-\(UUID().uuidString)/sub/config.json")
        ConfigStore.overrideURL = tmp
    }

    override func tearDown() {
        ConfigStore.overrideURL = nil
        try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent().deletingLastPathComponent())
    }

    func svc(_ port: UInt16, project: String? = nil, name: String = "node", title: String? = nil) -> Service {
        var s = Service(port: port, process: ProcInfo(pid: Int32(port), ppid: 1, uid: 501, name: name),
                        addresses: ["127.0.0.1"], bindScope: .loopback)
        s.projectName = project
        s.projectPath = project.map { "/dev/\($0)" }
        if let title { s.probe = ProbeResult(protocolKind: .http, health: .ok, title: title) }
        return s
    }

    // MARK: get / set / unset

    func testGetSetUnsetRoundTripThroughFile() throws {
        XCTAssertEqual(ConfigStore.load(), PierConfig(), "missing file = defaults")
        var c = try ConfigStore.loadStrict()
        try ConfigEditing.set(.editor, to: "Cursor", in: &c)
        try ConfigEditing.set(.hotkey, to: "Ctrl + Shift + Space", in: &c)
        try ConfigEditing.set(.notifyCrash, to: "off", in: &c)
        try ConfigEditing.set(.browser, to: "chrome", in: &c)
        try ConfigStore.save(c)   // creates the missing directory, atomically

        let back = try ConfigStore.loadStrict()
        XCTAssertEqual(ConfigEditing.value(.editor, in: back), "cursor")
        XCTAssertEqual(ConfigEditing.value(.hotkey, in: back), "ctrl+shift+space")
        XCTAssertEqual(ConfigEditing.value(.notifyCrash, in: back), "false")
        XCTAssertEqual(ConfigEditing.value(.browser, in: back), "com.google.Chrome")
        XCTAssertFalse(ConfigEditing.isDefault(.editor, in: back))
        XCTAssertTrue(ConfigEditing.isDefault(.showNoise, in: back))

        var c2 = back
        for k in ConfigKey.allCases { ConfigEditing.unset(k, in: &c2) }
        XCTAssertEqual(c2, PierConfig())
        XCTAssertEqual(ConfigEditing.value(.browser, in: c2), "default")
    }

    func testValidation() {
        var c = PierConfig()
        func fails(_ k: ConfigKey, _ v: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try ConfigEditing.set(k, to: v, in: &c), "\(k) = \(v)", file: file, line: line) {
                guard case ConfigError.invalidValue = $0 else { return XCTFail("wrong error \($0)", file: file, line: line) }
            }
        }
        fails(.hotkey, "p")             // no modifier
        fails(.hotkey, "cmd+")          // no key
        fails(.hotkey, "cmd+banana")
        fails(.hotkey, "")
        fails(.editor, "  ")
        fails(.editor, "bad\u{1B}[31mname")
        fails(.browser, "not a bundle")
        fails(.browser, "..")
        fails(.showNoise, "maybe")
        XCTAssertEqual(c, PierConfig(), "a failed set leaves the config untouched")

        XCTAssertNoThrow(try ConfigEditing.set(.hotkey, to: "opt+cmd+p", in: &c))
        XCTAssertNoThrow(try ConfigEditing.set(.hotkey, to: "f5", in: &c))
        XCTAssertNoThrow(try ConfigEditing.set(.editor, to: "com.jetbrains.WebStorm", in: &c))
        XCTAssertEqual(c.editor, "com.jetbrains.WebStorm")
        try? ConfigEditing.set(.editor, to: "Sublime Text", in: &c)
        XCTAssertEqual(c.editor, "Sublime Text")
        try? ConfigEditing.set(.editor, to: "VS Code", in: &c)
        XCTAssertEqual(c.editor, "vscode")
        try? ConfigEditing.set(.browser, to: "org.mozilla.firefox", in: &c)
        XCTAssertEqual(c.browser, "org.mozilla.firefox")
        try? ConfigEditing.set(.browser, to: "default", in: &c)
        XCTAssertNil(c.browser)
    }

    func testBooleans() {
        for t in ["true", "on", "YES", "1"] { XCTAssertEqual(ConfigEditing.parseBool(t), true, t) }
        for t in ["false", "off", "No", "0"] { XCTAssertEqual(ConfigEditing.parseBool(t), false, t) }
        XCTAssertNil(ConfigEditing.parseBool("2"))
    }

    func testKeyParsing() {
        XCTAssertEqual(ConfigKey.parse("notify-crash"), .notifyCrash)
        XCTAssertEqual(ConfigKey.parse("NOTIFY_NEW_SERVICE"), .notifyNewService)
        XCTAssertEqual(ConfigKey.parse("launchAtLogin"), .launchAtLogin)
        XCTAssertNil(ConfigKey.parse("pins"))
    }

    func testStrictLoadRefusesBrokenFileButLenientLoadDefaults() throws {
        try FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: tmp)
        XCTAssertEqual(ConfigStore.load(), PierConfig())
        XCTAssertThrowsError(try ConfigStore.loadStrict())
        try Data("  \n".utf8).write(to: tmp)
        XCTAssertEqual(try ConfigStore.loadStrict(), PierConfig(), "blank file = defaults")
        // Older / partial files keep working (backward compatible shape).
        try Data(#"{"editor":"zed","unknown":1}"#.utf8).write(to: tmp)
        let c = try ConfigStore.loadStrict()
        XCTAssertEqual(c.editor, "zed")
        XCTAssertEqual(c.hotkey, "opt+cmd+p")
    }

    // MARK: pins & renames

    func testPinUnpinByStableKey() {
        var c = PierConfig()
        let a = svc(3000, project: "alpha")
        XCTAssertTrue(ConfigEditing.pin(a, in: &c))
        XCTAssertFalse(ConfigEditing.pin(a, in: &c), "already pinned")
        XCTAssertEqual(c.pins, ["project:/dev/alpha"])
        XCTAssertTrue(ConfigDisplay.isPinned(a, config: c))
        // survives a restart on another port: same project path
        XCTAssertTrue(ConfigDisplay.isPinned(svc(3005, project: "alpha"), config: c))
        XCTAssertTrue(ConfigEditing.unpin(key: a.stableKey, in: &c))
        XCTAssertFalse(ConfigEditing.unpin(key: a.stableKey, in: &c))
        XCTAssertTrue(c.pins.isEmpty)
    }

    func testPinKeyMatchingForStoppedServices() {
        var c = PierConfig()
        c.pins = ["project:/Users/me/dev/relay", "project:/Users/me/dev/relay-docs", "postgres:5432"]
        XCTAssertEqual(ConfigEditing.pinKeys(matching: "relay", in: c), ["project:/Users/me/dev/relay"], "exact folder beats substring")
        XCTAssertEqual(ConfigEditing.pinKeys(matching: "docs", in: c), ["project:/Users/me/dev/relay-docs"])
        XCTAssertEqual(ConfigEditing.pinKeys(matching: "POSTGRES:5432", in: c), ["postgres:5432"])
        XCTAssertEqual(ConfigEditing.pinKeys(matching: "rel", in: c).count, 2)
        XCTAssertTrue(ConfigEditing.pinKeys(matching: "nothing", in: c).isEmpty)
        XCTAssertTrue(ConfigEditing.pinKeys(matching: " ", in: c).isEmpty)
    }

    func testRenameSetResetAndSanitizing() throws {
        var c = PierConfig()
        let s = svc(3100, project: "relay", title: "Relay (dev)")
        XCTAssertEqual(try ConfigEditing.rename(s, to: "  My API \n", in: &c), .set("My API"))
        XCTAssertEqual(c.renames[s.stableKey], "My API")
        XCTAssertEqual(ConfigDisplay.name(s, config: c), "My API")
        XCTAssertEqual(ConfigDisplay.customName(s, config: c), "My API")

        // control characters / escapes never get stored
        XCTAssertEqual(try ConfigEditing.rename(s, to: "Evil\u{1B}[31m name\u{7}", in: &c), .set("Evil name"))
        // same as the automatic name, or empty = no rename
        XCTAssertEqual(try ConfigEditing.rename(s, to: "Relay (dev)", in: &c), .cleared)
        XCTAssertNil(c.renames[s.stableKey])
        XCTAssertEqual(ConfigDisplay.name(s, config: c), "Relay (dev)")
        XCTAssertNil(ConfigDisplay.customName(s, config: c))

        XCTAssertThrowsError(try ConfigEditing.rename(s, to: String(repeating: "x", count: 81), in: &c))
        _ = try ConfigEditing.rename(s, to: "Again", in: &c)
        XCTAssertTrue(ConfigEditing.resetRename(s, in: &c))
        XCTAssertFalse(ConfigEditing.resetRename(s, in: &c))
    }

    func testOrderedPinsFirstThenPort() {
        let a = svc(5000, project: "a"), b = svc(3000, project: "b"), c = svc(4000, project: "c"), d = svc(2000, project: "d")
        var cfg = PierConfig()
        XCTAssertEqual(ConfigDisplay.ordered([a, b, c, d], config: cfg).map(\.port), [2000, 3000, 4000, 5000])
        cfg.pins = [a.stableKey, c.stableKey]   // pin order, not port order
        XCTAssertEqual(ConfigDisplay.ordered([d, c, b, a], config: cfg).map(\.port), [5000, 4000, 2000, 3000])
        cfg.pins = ["project:/dev/gone"]        // stale pins are harmless
        XCTAssertEqual(ConfigDisplay.ordered([c, a], config: cfg).map(\.port), [4000, 5000])
    }

    func testPinsAndRenamesSurviveSaveAndKeepShape() throws {
        var c = PierConfig()
        c.pins = ["project:/dev/a"]; c.renames = ["project:/dev/a": "A"]
        try ConfigStore.save(c)
        let json = try String(contentsOf: tmp, encoding: .utf8)
        for key in ["pins", "renames", "hotkey", "editor", "notifyCrash", "notifyNewService", "showNoise", "launchAtLogin"] {
            XCTAssertTrue(json.contains("\"\(key)\""), key)
        }
        XCTAssertEqual(ConfigStore.load(), c)
    }
}
