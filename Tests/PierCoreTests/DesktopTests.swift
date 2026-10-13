import XCTest
@testable import PierCore

final class DesktopTabMatchTests: XCTestCase {
    func testLoopbackEquivalence() {
        let target = "http://localhost:3000"
        for tab in ["http://127.0.0.1:3000/", "http://[::1]:3000/x?y=1", "http://0.0.0.0:3000", "https://localhost:3000/a#b",
                    "http://app.localhost:3000/"] {
            XCTAssertTrue(TabMatcher.matches(tab: tab, target: target), tab)
        }
    }

    func testDifferentPortOrHostDoNotMatch() {
        XCTAssertFalse(TabMatcher.matches(tab: "http://localhost:3001", target: "http://localhost:3000"))
        XCTAssertFalse(TabMatcher.matches(tab: "http://example.com:3000", target: "http://localhost:3000"))
        XCTAssertFalse(TabMatcher.matches(tab: "http://192.168.1.5:3000", target: "http://localhost:3000"))
        XCTAssertTrue(TabMatcher.matches(tab: "http://192.168.1.5:3000/x", target: "http://192.168.1.5:3000"))
        XCTAssertFalse(TabMatcher.matches(tab: "about:blank", target: "http://localhost:3000"))
        XCTAssertFalse(TabMatcher.matches(tab: "chrome://newtab/", target: "http://localhost:3000"))
    }

    func testDefaultPorts() {
        XCTAssertTrue(TabMatcher.matches(tab: "http://localhost/", target: "http://127.0.0.1:80"))
        XCTAssertTrue(TabMatcher.matches(tab: "https://localhost/", target: "https://localhost:443"))
        XCTAssertFalse(TabMatcher.matches(tab: "https://localhost/", target: "http://localhost"))
    }

    func testFirstMatch() {
        let tabs = ["https://google.com", "http://localhost:5173/", "http://127.0.0.1:3000/dash", "http://localhost:3000/"]
        XCTAssertEqual(TabMatcher.firstMatch(in: tabs, target: "http://localhost:3000"), 2)
        XCTAssertNil(TabMatcher.firstMatch(in: tabs, target: "http://localhost:9999"))
    }

    func testTabRowParsing() {
        let rows = BrowserOpener.parseTabRows("12\t1\thttp://localhost:3000/\n12\t2\thttps://a.b/c?d=\t1\nbad line\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], .init(windowID: 12, tabIndex: 1, url: "http://localhost:3000/"))
        XCTAssertEqual(rows[1].url, "https://a.b/c?d=\t1")
    }

    func testCandidateOrder() {
        let order = BrowserOpener.candidateOrder(running: ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser"],
                                                 preferred: "company.thebrowser.Browser", defaultBrowser: "com.google.Chrome")
        XCTAssertEqual(order, ["company.thebrowser.Browser", "com.google.Chrome", "com.apple.Safari"])
        // preferred not running: ignored
        XCTAssertEqual(BrowserOpener.candidateOrder(running: ["com.apple.Safari"], preferred: "x.y", defaultBrowser: nil), ["com.apple.Safari"])
    }
}

final class DesktopTerminalTests: XCTestCase {
    private func o(_ k: OwnerKind) -> OwnerLink { OwnerLink(pid: 100, name: "\(k)", kind: k) }

    func testTTYFormatting() {
        XCTAssertEqual(TerminalJumper.ttyPath(devName: "ttys003"), "/dev/ttys003")
        XCTAssertEqual(TerminalJumper.ttyPath(devName: "/dev/ttys012"), "/dev/ttys012")
        XCTAssertNil(TerminalJumper.ttyPath(devName: "??"))
        XCTAssertNil(TerminalJumper.ttyPath(devName: ""))
        XCTAssertNil(TerminalJumper.ttyPath(devName: nil))
    }

    func testTTYOfUnknownPidIsNil() {
        XCTAssertNil(TerminalJumper.ttyPath(forPid: 2_000_000))
    }

    func testStrategySelection() {
        XCTAssertEqual(TerminalJumper.plan(for: [o(.iterm)]), .init(viaTmux: false, terminal: .iterm))
        XCTAssertEqual(TerminalJumper.plan(for: [o(.claudeCode), o(.terminal)]), .init(viaTmux: false, terminal: .terminal))
        XCTAssertEqual(TerminalJumper.plan(for: [o(.vscode)]), .init(viaTmux: false, terminal: .app(.vscode)))
        XCTAssertEqual(TerminalJumper.plan(for: [o(.ghostty)]), .init(viaTmux: false, terminal: .app(.ghostty)))
        XCTAssertEqual(TerminalJumper.plan(for: [o(.wezterm)]).terminal, .wezterm)
        XCTAssertEqual(TerminalJumper.plan(for: [o(.kitty)]).terminal, .kitty)
        XCTAssertEqual(TerminalJumper.plan(for: [o(.tmux), o(.launchd)]), .init(viaTmux: true, terminal: .generic))
        XCTAssertEqual(TerminalJumper.plan(for: [o(.other), o(.launchd)]), .init(viaTmux: false, terminal: .generic))
        XCTAssertEqual(TerminalJumper.plan(for: []), .init(viaTmux: false, terminal: .generic))
    }

    func testTmuxParsing() {
        let panes = TerminalJumper.parseTmuxPanes("/dev/ttys004 %3 1 0 dev server\n/dev/ttys005 %4 2 1 work\njunk\n")
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes[0], .init(tty: "/dev/ttys004", paneID: "%3", windowIndex: "1", paneIndex: "0", session: "dev server"))
        XCTAssertEqual(panes[1].target, "work:2")
        let clients = TerminalJumper.parseTmuxClients("/dev/ttys001 4242 dev server\n/dev/ttys002 notapid x\n")
        XCTAssertEqual(clients, [.init(tty: "/dev/ttys001", pid: 4242, session: "dev server")])
    }

    func testGenericFallbackFindsNothingForUnknownPids() {
        XCTAssertNil(TerminalJumper.guiApp(in: [2_000_000, 2_000_001]))
    }
}

final class DesktopEditorTests: XCTestCase {
    func testResolution() {
        XCTAssertEqual(EditorOpener.resolve("vscode"), .known("vscode"))
        XCTAssertEqual(EditorOpener.resolve("Code"), .known("vscode"))
        XCTAssertEqual(EditorOpener.resolve("cursor"), .known("cursor"))
        XCTAssertEqual(EditorOpener.resolve("Finder"), .finder)
        XCTAssertEqual(EditorOpener.resolve("com.jetbrains.WebStorm"), .bundleID("com.jetbrains.WebStorm"))
        XCTAssertEqual(EditorOpener.resolve("Sublime Text"), .appName("Sublime Text"))
    }

    func testMissingPathThrows() {
        XCTAssertThrowsError(try EditorOpener.open(path: "/definitely/not/here", editor: "vscode"))
    }
}

final class DesktopAppBundleTests: XCTestCase {
    func testInfoPlistRendering() throws {
        let xml = AppBundle.renderInfoPlist(version: "9.8.7")
        XCTAssertFalse(xml.contains("{{VERSION}}"))
        let plist = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any]
        let d = try XCTUnwrap(plist)
        XCTAssertEqual(d["CFBundleIdentifier"] as? String, "io.github.stepanblaha.pier")
        XCTAssertEqual(d["CFBundleName"] as? String, "Pier")
        XCTAssertEqual(d["CFBundleExecutable"] as? String, "Pier")
        XCTAssertEqual(d["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(d["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(d["LSUIElement"] as? Bool, true)
        XCTAssertEqual(d["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertEqual(d["CFBundleShortVersionString"] as? String, "9.8.7")
        XCTAssertEqual(d["CFBundleVersion"] as? String, "9.8.7")
        XCTAssertEqual(d["NSAppleEventsUsageDescription"] as? String,
                       "Pier reuses your existing browser tabs and focuses the terminal that started a server.")
        XCTAssertNotNil(d["NSHumanReadableCopyright"])
        let ats = try XCTUnwrap(d["NSAppTransportSecurity"] as? [String: Any])
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
    }

    func testRepoTemplateMatchesEmbeddedTemplate() throws {
        let root = try XCTUnwrap(AppBundle.repoRoot(from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()))
        let file = try XCTUnwrap(AppBundle.templateFromRepo(root))
        XCTAssertEqual(file, AppBundle.infoPlistTemplate, "packaging/Info.plist and AppBundle.infoPlistTemplate drifted apart")
    }

    func testBundleLayoutInTempDir() throws {
        let fm = FileManager.default
        let root = try XCTUnwrap(AppBundle.repoRoot(from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()))
        // Real built binaries when available (sibling of the test bundle's products), else stand-in scripts.
        let tmp = fm.temporaryDirectory.appendingPathComponent("pier-bundle-test-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let fakeApp = tmp.appendingPathComponent("PierApp")
        let fakeCLI = tmp.appendingPathComponent("pier")
        try "#!/bin/sh\nexit 0\n".write(to: fakeApp, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: fakeCLI, atomically: true, encoding: .utf8)
        let fakeRes = tmp.appendingPathComponent(AppBundle.resourceBundleName, isDirectory: true)
        try fm.createDirectory(at: fakeRes, withIntermediateDirectories: true)
        try Data([0x89, 0x50]).write(to: fakeRes.appendingPathComponent("sleeping.png"))
        for f in [fakeApp, fakeCLI] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path) }

        let dest = tmp.appendingPathComponent("out")
        let opts = AppBundle.InstallOptions(destinationDir: dest, version: "1.2.3", sign: false, quitRunning: false,
                                            icon: AppBundle.iconFromRepo(root))
        // siblingBinaries picks the resource bundle up from next to PierApp.
        let bins = try XCTUnwrap(AppBundle.siblingBinaries(of: fakeCLI))
        XCTAssertEqual(bins.resourceBundle?.lastPathComponent, "pier_PierApp.bundle")
        let app = try AppBundle.install(bins, options: opts)
        let l = AppBundle.layout(of: app)
        XCTAssertTrue(fm.fileExists(atPath: l.resourceBundle.appendingPathComponent("sleeping.png").path))
        XCTAssertEqual(l.resourceBundle.deletingLastPathComponent().lastPathComponent, "Resources", "bundle must live in Contents/Resources, not the .app root")
        XCTAssertFalse(fm.fileExists(atPath: app.appendingPathComponent("pier_PierApp.bundle").path))
        XCTAssertEqual(app.lastPathComponent, "Pier.app")
        XCTAssertTrue(fm.isExecutableFile(atPath: l.executable.path))
        XCTAssertTrue(fm.isExecutableFile(atPath: l.cli.path))
        let plist = try String(contentsOf: l.infoPlist, encoding: .utf8)
        XCTAssertTrue(plist.contains("<string>1.2.3</string>"))

        // Re-install replaces atomically and leaves no staging directories behind.
        _ = try AppBundle.install(bins, options: opts)
        let leftovers = try fm.contentsOfDirectory(atPath: dest.path)
        XCTAssertEqual(leftovers, ["Pier.app"])
    }

    func testIconFallsBackToAppIconNextToPierApp() throws {
        // Homebrew layout: no repo checkout, `pier` (symlink target), PierApp, resource bundle and AppIcon.icns in one dir.
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("pier-libexec-test-\(UUID().uuidString)")
        let libexec = tmp.appendingPathComponent("libexec", isDirectory: true)
        try fm.createDirectory(at: libexec.appendingPathComponent(AppBundle.resourceBundleName), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        for n in ["pier", "PierApp"] {
            let f = libexec.appendingPathComponent(n)
            try "#!/bin/sh\nexit 0\n".write(to: f, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
        let icon = libexec.appendingPathComponent("AppIcon.icns")
        try Data("icns-stand-in".utf8).write(to: icon)
        // bin/pier is a symlink into libexec; lookup must follow it.
        let bin = tmp.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: bin.appendingPathComponent("pier"), withDestinationURL: libexec.appendingPathComponent("pier"))
        let resolved = bin.appendingPathComponent("pier").resolvingSymlinksInPath()
        let bins = try XCTUnwrap(AppBundle.siblingBinaries(of: resolved))
        XCTAssertEqual(bins.icon?.lastPathComponent, "AppIcon.icns")

        // No explicit icon option (no repo): the sibling icon is installed.
        let app = try AppBundle.install(bins, options: .init(destinationDir: tmp.appendingPathComponent("out"), sign: false, quitRunning: false, icon: nil))
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("Contents/Resources/AppIcon.icns")), Data("icns-stand-in".utf8))

        // An explicit (repo) icon wins over the sibling one.
        let repoIcon = tmp.appendingPathComponent("repo.icns")
        try Data("repo-icon".utf8).write(to: repoIcon)
        let app2 = try AppBundle.install(bins, options: .init(destinationDir: tmp.appendingPathComponent("out2"), sign: false, quitRunning: false, icon: repoIcon))
        XCTAssertEqual(try Data(contentsOf: app2.appendingPathComponent("Contents/Resources/AppIcon.icns")), Data("repo-icon".utf8))
    }

    func testSiblingBinaryLookupAndSigningOfRealBuild() throws {
        // Skipped unless a built PierApp sits next to a built `pier` (e.g. after `swift build`).
        let fm = FileManager.default
        let root = try XCTUnwrap(AppBundle.repoRoot(from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()))
        let candidates = [".build-desktop", ".build"].flatMap { s in ["debug", "release"].map { root.appendingPathComponent("\(s)/\($0)") } }
        guard let dir = candidates.first(where: { fm.isExecutableFile(atPath: $0.appendingPathComponent("PierApp").path)
            && fm.isExecutableFile(atPath: $0.appendingPathComponent("pier").path) }) else {
            throw XCTSkip("PierApp binary not built")
        }
        let bins = try XCTUnwrap(AppBundle.siblingBinaries(of: dir.appendingPathComponent("pier")))
        let tmp = fm.temporaryDirectory.appendingPathComponent("pier-signed-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let app = try AppBundle.install(bins, options: .init(destinationDir: tmp, quitRunning: false))
        let r = DesktopProc.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        XCTAssertTrue(r.ok, r.stderr)
        if bins.resourceBundle != nil {
            XCTAssertTrue(fm.fileExists(atPath: AppBundle.layout(of: app).resourceBundle.path))
        }
    }
}
