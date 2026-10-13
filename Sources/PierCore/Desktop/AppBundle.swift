import Foundation
import AppKit

/// Assembly of Pier.app from the built `PierApp` + `pier` binaries (no Xcode project, no Apple Developer account).
///
/// Layout:
///   Pier.app/Contents/Info.plist
///   Pier.app/Contents/MacOS/Pier          (PierApp binary)
///   Pier.app/Contents/Resources/pier      (CLI copy; the app points PIER_BIN at it to spawn managed processes)
///   Pier.app/Contents/Resources/pier_PierApp.bundle   (SwiftPM resource bundle of PierApp: mascot images)
public enum AppBundle {
    public static let bundleID = "io.github.stepanblaha.pier"
    public static let appName = "Pier"
    public static let version = "0.1.0"
    /// SwiftPM names a target's resource bundle `<package>_<target>.bundle`; it sits next to the PierApp binary.
    public static let resourceBundleName = "pier_PierApp.bundle"

    /// Placeholder in the template replaced by `version`.
    static let versionToken = "{{VERSION}}"

    /// Same content as packaging/Info.plist (a test keeps the two in sync). Used when the repo template
    /// is not reachable, e.g. `pier app install` run from a Homebrew install.
    public static let infoPlistTemplate = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleDevelopmentRegion</key>
        <string>en</string>
        <key>CFBundleExecutable</key>
        <string>Pier</string>
        <key>CFBundleIconFile</key>
        <string>AppIcon</string>
        <key>CFBundleIdentifier</key>
        <string>io.github.stepanblaha.pier</string>
        <key>CFBundleInfoDictionaryVersion</key>
        <string>6.0</string>
        <key>CFBundleName</key>
        <string>Pier</string>
        <key>CFBundleDisplayName</key>
        <string>Pier</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>CFBundleShortVersionString</key>
        <string>{{VERSION}}</string>
        <key>CFBundleVersion</key>
        <string>{{VERSION}}</string>
        <key>LSApplicationCategoryType</key>
        <string>public.app-category.developer-tools</string>
        <key>LSMinimumSystemVersion</key>
        <string>14.0</string>
        <key>LSUIElement</key>
        <true/>
        <key>NSAppTransportSecurity</key>
        <dict>
            <key>NSAllowsLocalNetworking</key>
            <true/>
        </dict>
        <key>NSAppleEventsUsageDescription</key>
        <string>Pier reuses your existing browser tabs and focuses the terminal that started a server.</string>
        <key>NSHighResolutionCapable</key>
        <true/>
        <key>NSHumanReadableCopyright</key>
        <string>MIT License</string>
        <key>NSPrincipalClass</key>
        <string>NSApplication</string>
    </dict>
    </plist>

    """

    public static func renderInfoPlist(template: String = infoPlistTemplate, version: String = version) -> String {
        let escaped = version.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return template.replacingOccurrences(of: versionToken, with: escaped)
    }

    // MARK: Paths

    public static var defaultInstallDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    }

    public static func appURL(in dir: URL) -> URL { dir.appendingPathComponent("\(appName).app", isDirectory: true) }

    public struct Layout: Equatable, Sendable {
        public var app: URL
        public var infoPlist: URL { app.appendingPathComponent("Contents/Info.plist") }
        public var executable: URL { app.appendingPathComponent("Contents/MacOS/\(AppBundle.appName)") }
        public var cli: URL { app.appendingPathComponent("Contents/Resources/pier") }
        public var resourceBundle: URL { app.appendingPathComponent("Contents/Resources/\(AppBundle.resourceBundleName)", isDirectory: true) }
    }

    public static func layout(of app: URL) -> Layout { Layout(app: app) }

    /// `Contents/Resources/pier` of the running app bundle, if this process is Pier.app. Apps set PIER_BIN to it.
    public static func bundledCLI(of bundle: Bundle = .main) -> URL? {
        guard bundle.bundleURL.pathExtension == "app" else { return nil }
        let url = bundle.bundleURL.appendingPathComponent("Contents/Resources/pier")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    // MARK: Locating binaries

    public struct Binaries: Equatable, Sendable {
        public var app: URL
        public var cli: URL
        /// PierApp's SwiftPM resource bundle (copied into Contents/Resources before signing); nil = app runs without mascot art.
        public var resourceBundle: URL?
        /// AppIcon.icns next to the PierApp binary (Homebrew libexec layout: pier, PierApp, pier_PierApp.bundle, AppIcon.icns).
        /// Used when `InstallOptions.icon` is nil, i.e. the repo's packaging/AppIcon.icns is not reachable.
        public var icon: URL?
        public init(app: URL, cli: URL, resourceBundle: URL? = nil, icon: URL? = nil) {
            self.app = app; self.cli = cli; self.resourceBundle = resourceBundle; self.icon = icon
        }
    }

    /// Path of the running executable with symlinks resolved (Homebrew links bin/pier into the Cellar).
    public static func currentExecutable() -> URL? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath()
    }

    /// Binaries next to `executable`: `PierApp` in the same directory (the SwiftPM build dir or Homebrew bin),
    /// or the Contents/MacOS/Pier of an already-installed bundle when `executable` is its Resources/pier.
    public static func siblingBinaries(of executable: URL) -> Binaries? {
        let fm = FileManager.default
        let dir = executable.deletingLastPathComponent()
        let sibling = dir.appendingPathComponent("PierApp")
        func bundle(in d: URL) -> URL? {
            let b = d.appendingPathComponent(resourceBundleName, isDirectory: true)
            return fm.fileExists(atPath: b.path) ? b : nil
        }
        func icon(in d: URL) -> URL? {
            let i = d.appendingPathComponent("AppIcon.icns")
            return fm.fileExists(atPath: i.path) ? i : nil
        }
        if fm.isExecutableFile(atPath: sibling.path) {
            return Binaries(app: sibling, cli: executable, resourceBundle: bundle(in: dir), icon: icon(in: dir))
        }
        let installed = dir.deletingLastPathComponent().appendingPathComponent("MacOS/\(appName)")
        if dir.lastPathComponent == "Resources", fm.isExecutableFile(atPath: installed.path) {
            return Binaries(app: installed, cli: executable, resourceBundle: bundle(in: dir), icon: icon(in: dir))
        }
        return nil
    }

    /// Nearest ancestor of `dir` that is the pier package (Package.swift declaring name "pier" and Sources/PierApp).
    public static func repoRoot(from dir: URL) -> URL? {
        var cur = dir.standardizedFileURL
        for _ in 0..<12 {
            let manifest = cur.appendingPathComponent("Package.swift")
            if let text = try? String(contentsOf: manifest, encoding: .utf8),
               text.contains("name: \"pier\""),
               FileManager.default.fileExists(atPath: cur.appendingPathComponent("Sources/PierApp").path) {
                return cur
            }
            let parent = cur.deletingLastPathComponent()
            if parent == cur { break }
            cur = parent
        }
        return nil
    }

    /// packaging/Info.plist of the repo, if reachable.
    public static func templateFromRepo(_ root: URL?) -> String? {
        guard let root else { return nil }
        return try? String(contentsOf: root.appendingPathComponent("packaging/Info.plist"), encoding: .utf8)
    }

    /// packaging/AppIcon.icns of the repo (generated by packaging/make-icon.sh), if present.
    public static func iconFromRepo(_ root: URL?) -> URL? {
        guard let root else { return nil }
        let u = root.appendingPathComponent("packaging/AppIcon.icns")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    // MARK: Install

    public struct InstallOptions: Sendable {
        public var destinationDir: URL
        public var version: String
        public var template: String
        /// Ad-hoc `codesign --force --deep --sign -`.
        public var sign: Bool
        /// Terminate a running Pier first (macOS cannot replace a running app cleanly).
        public var quitRunning: Bool
        /// AppIcon.icns copied to Resources (the template references it; a missing icon just means the generic one).
        public var icon: URL?
        public init(destinationDir: URL = AppBundle.defaultInstallDir, version: String = AppBundle.version,
                    template: String = AppBundle.infoPlistTemplate, sign: Bool = true, quitRunning: Bool = true, icon: URL? = nil) {
            self.destinationDir = destinationDir; self.version = version; self.template = template
            self.sign = sign; self.quitRunning = quitRunning; self.icon = icon
        }
    }

    /// Builds the bundle next to its destination, signs it, quits any running Pier, then swaps it in atomically.
    /// Returns the installed app URL.
    @discardableResult
    public static func install(_ binaries: Binaries, options: InstallOptions = InstallOptions()) throws -> URL {
        let fm = FileManager.default
        let dest = appURL(in: options.destinationDir)
        try fm.createDirectory(at: options.destinationDir, withIntermediateDirectories: true)

        let staging = options.destinationDir.appendingPathComponent(".\(appName).app.staging-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try assemble(at: staging, binaries: binaries, options: options)

        if options.quitRunning { quitRunningPier() }

        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: dest)
        }
        return dest
    }

    /// Writes the bundle into `app` (must not exist). No quitting, no swapping — used by `install` and tests.
    static func assemble(at app: URL, binaries: Binaries, options: InstallOptions) throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: binaries.app.path) else { throw DesktopError("PierApp binary not found at \(binaries.app.path)") }
        guard fm.isExecutableFile(atPath: binaries.cli.path) else { throw DesktopError("pier binary not found at \(binaries.cli.path)") }
        let l = layout(of: app)
        try fm.createDirectory(at: l.executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: l.cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: binaries.app, to: l.executable)
        try fm.copyItem(at: binaries.cli, to: l.cli)
        // Inside Contents/Resources (a bundle at the .app root would break codesign). PierApp finds it via Bundle.main.resourceURL.
        if let rb = binaries.resourceBundle, fm.fileExists(atPath: rb.path) {
            try fm.copyItem(at: rb, to: l.resourceBundle)
        }
        // Icon lookup order: repo packaging/AppIcon.icns (options.icon), then AppIcon.icns next to the PierApp binary.
        if let icon = [options.icon, binaries.icon].compactMap({ $0 }).first(where: { fm.fileExists(atPath: $0.path) }) {
            try fm.copyItem(at: icon, to: app.appendingPathComponent("Contents/Resources/AppIcon.icns"))
        }
        try renderInfoPlist(template: options.template, version: options.version)
            .write(to: l.infoPlist, atomically: true, encoding: .utf8)
        for f in [l.executable, l.cli] {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
        _ = DesktopProc.run("/usr/bin/xattr", ["-cr", app.path], timeout: 10)
        if options.sign {
            // Sign the CLI copy first (it lives in Resources, which --deep does not treat as code), then the bundle.
            let cli = DesktopProc.run("/usr/bin/codesign", ["--force", "--sign", "-", l.cli.path], timeout: 30)
            guard cli.ok else { throw DesktopError("codesign failed for the bundled CLI: \(cli.stderr)") }
            let r = DesktopProc.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path], timeout: 60)
            guard r.ok else { throw DesktopError("codesign failed: \(r.stderr)") }
        }
    }

    // MARK: Running instance

    public static func runningInstances() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
    }

    /// Asks Pier to quit (managed processes keep running — they are owned by their own `pier run` wrappers).
    /// Returns true if nothing is running afterwards.
    @discardableResult
    public static func quitRunningPier(timeout: TimeInterval = 4) -> Bool {
        let apps = runningInstances()
        if apps.isEmpty { return true }
        for a in apps { a.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !runningInstances().isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        for a in runningInstances() { a.forceTerminate() }
        let end = Date().addingTimeInterval(1)
        while Date() < end, !runningInstances().isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        return runningInstances().isEmpty
    }

    public static func launch(_ app: URL) throws {
        let r = DesktopProc.open([app.path])
        if !r.ok { throw DesktopError("could not launch \(app.path): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    public static func uninstall(from dir: URL) throws -> URL? {
        let app = appURL(in: dir)
        guard FileManager.default.fileExists(atPath: app.path) else { return nil }
        quitRunningPier()
        try FileManager.default.removeItem(at: app)
        return app
    }
}
