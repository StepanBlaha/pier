import Foundation

/// Defaults for `pier run`: package manager detection, the package.json dev script, project naming.
public enum ManagedDefaults {
    /// pnpm-lock.yaml → pnpm, yarn.lock → yarn, bun.lockb / bun.lock → bun, else npm (nearest lockfile wins, walking up).
    public static func packageManager(cwd: String) -> String {
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        let fm = FileManager.default
        for _ in 0..<8 {
            func has(_ f: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(f).path) }
            if has("pnpm-lock.yaml") { return "pnpm" }
            if has("yarn.lock") { return "yarn" }
            if has("bun.lockb") || has("bun.lock") { return "bun" }
            if has("package-lock.json") { return "npm" }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return "npm"
    }

    /// `<pm> run dev` when cwd/package.json has scripts.dev; otherwise an error listing what was tried.
    public static func defaultCommand(cwd: String) -> Result<[String], ManagedDefaultsError> {
        let pkg = URL(fileURLWithPath: cwd).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: pkg) else {
            return .failure(.init(message: "no command given and no package.json in \(cwd) (tried: package.json → scripts.dev)"))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.init(message: "no command given and \(pkg.path) isn't valid JSON (tried: package.json → scripts.dev)"))
        }
        let scripts = json["scripts"] as? [String: Any]
        guard scripts?["dev"] is String else {
            let have = (scripts?.keys.sorted()).map { $0.isEmpty ? "none" : $0.joined(separator: ", ") } ?? "none"
            return .failure(.init(message: "no command given and package.json has no \"dev\" script (tried: package.json → scripts.dev; scripts: \(have))"))
        }
        return .success([packageManager(cwd: cwd), "run", "dev"])
    }

    /// Folder name of the nearest project root at or above cwd (package.json / .git / pyproject…), else cwd's own name.
    public static func projectName(cwd: String) -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        let start = dir
        let markers = ["package.json", ".git", "pyproject.toml", "Gemfile", "Cargo.toml", "go.mod", "Package.swift"]
        while dir.path != "/", dir.path != home {
            if markers.contains(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) { return dir.lastPathComponent }
            dir = dir.deletingLastPathComponent()
        }
        return start.lastPathComponent.isEmpty ? "service" : start.lastPathComponent
    }
}

public struct ManagedDefaultsError: Error, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}
