import Foundation
import AppKit

public struct DesktopError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

public enum EditorOpener {
    struct Editor {
        var key: String
        var name: String
        var bundleIDs: [String]
        var cli: String?
        /// CLI path inside the app bundle (works when the shell command was never installed).
        var bundledCLI: String?
    }

    static let editors: [Editor] = [
        Editor(key: "vscode", name: "Visual Studio Code",
               bundleIDs: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium"],
               cli: "code", bundledCLI: "Contents/Resources/app/bin/code"),
        Editor(key: "cursor", name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"],
               cli: "cursor", bundledCLI: "Contents/Resources/app/bin/cursor"),
        Editor(key: "zed", name: "Zed", bundleIDs: ["dev.zed.Zed", "dev.zed.Zed-Preview"],
               cli: "zed", bundledCLI: "Contents/MacOS/cli"),
        Editor(key: "windsurf", name: "Windsurf", bundleIDs: ["com.exafunction.windsurf"],
               cli: "windsurf", bundledCLI: "Contents/Resources/app/bin/windsurf"),
    ]

    /// Which kind of target an editor string resolves to (pure; unit-tested).
    public enum Resolution: Equatable, Sendable {
        case finder
        case known(String)
        case bundleID(String)
        case appName(String)
    }

    public static func resolve(_ editor: String) -> Resolution {
        let e = editor.trimmingCharacters(in: .whitespaces)
        let lower = e.lowercased()
        if lower == "finder" { return .finder }
        let aliases = ["code": "vscode", "vs code": "vscode", "visual studio code": "vscode"]
        let key = aliases[lower] ?? lower
        if editors.contains(where: { $0.key == key }) { return .known(key) }
        if e.contains("."), !e.contains(" "), !e.hasSuffix(".app") { return .bundleID(e) }
        return .appName(e)
    }

    /// editor: "vscode" | "cursor" | "zed" | "windsurf" | "finder" | any app name / bundle id. Opens the folder.
    public static func open(path: String, editor: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw DesktopError("path does not exist: \(expanded)")
        }
        switch resolve(editor) {
        case .finder:
            let r = DesktopProc.open(["-a", "Finder", expanded])
            if !r.ok { throw DesktopError("could not reveal in Finder: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
        case .known(let key):
            let ed = editors.first { $0.key == key }!
            try openKnown(ed, path: expanded)
        case .bundleID(let id):
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
                throw DesktopError("no app with bundle id '\(id)' is installed")
            }
            try openWithApp(app, path: expanded, label: id)
        case .appName(let name):
            let r = DesktopProc.open(["-a", name, expanded])
            if !r.ok {
                throw DesktopError("could not open '\(name)' (not an installed app?) — set `editor` to vscode, cursor, zed, windsurf, finder, an app name or a bundle id")
            }
        }
    }

    private static func openKnown(_ ed: Editor, path: String) throws {
        // 1. the app itself, via LaunchServices
        for id in ed.bundleIDs {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                if (try? openWithApp(app, path: path, label: ed.name)) != nil { return }
                // fall through to the CLI if LaunchServices refused
                if let cli = cliPath(for: ed, app: app), DesktopProc.run(cli, [path], timeout: 10).ok { return }
                throw DesktopError("could not open \(ed.name) at \(path)")
            }
        }
        // 2. CLI on its own (e.g. app in a non-standard location)
        if let cli = cliPath(for: ed, app: nil), DesktopProc.run(cli, [path], timeout: 10).ok { return }
        throw DesktopError("\(ed.name) is not installed (no app with bundle id \(ed.bundleIDs[0]) and no `\(ed.cli ?? ed.key)` command found)")
    }

    private static func cliPath(for ed: Editor, app: URL?) -> String? {
        if let app, let rel = ed.bundledCLI {
            let p = app.appendingPathComponent(rel).path
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return ed.cli.flatMap { DesktopProc.findTool($0) }
    }

    private static func openWithApp(_ app: URL, path: String, label: String) throws {
        let r = DesktopProc.open(["-a", app.path, path])
        if !r.ok { throw DesktopError("could not open \(label): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }
}
