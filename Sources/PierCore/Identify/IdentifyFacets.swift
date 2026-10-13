import Foundation

/// Lowercased, pre-normalised view of a process used by all rule tables.
struct ProcFacets {
    /// Lowercased process name, login-shell dash stripped ("-zsh" → "zsh").
    let name: String
    /// Lowercased full executable path ("" if unknown).
    let exe: String
    let exeName: String
    /// Lowercased argv.
    let args: [String]
    /// Basename of argv[0], lowercased.
    let arg0Name: String

    init(_ p: ProcInfo) {
        var n = p.name.lowercased()
        if n.hasPrefix("-") { n.removeFirst() }
        name = n
        exe = (p.executablePath ?? "").lowercased()
        exeName = (exe as NSString).lastPathComponent
        args = p.arguments.map { $0.lowercased() }
        arg0Name = ((args.first ?? "") as NSString).lastPathComponent
    }

    /// Space-joined argv with trailing space (so phrases like "php -s " match at the end).
    var haystack: String { args.joined(separator: " ") + " " }

    /// Exact name match against process name or executable basename.
    /// Tolerates kernel-truncated names (p_comm is ~16 chars).
    func isNamed(_ x: String) -> Bool {
        for n in [name, exeName] where !n.isEmpty {
            if n == x || (n.count >= 15 && x.hasPrefix(n)) { return true }
        }
        return false
    }

    func isNamed(anyOf xs: [String]) -> Bool { xs.contains(where: isNamed) }

    func hasNamePrefix(_ x: String) -> Bool { name.hasPrefix(x) || exeName.hasPrefix(x) }

    func hasNamePrefix(anyOf xs: [String]) -> Bool { xs.contains(where: hasNamePrefix) }

    func pathContains(anyOf xs: [String]) -> Bool { !exe.isEmpty && xs.contains(where: exe.contains) }
}

/// Bounded upward directory walks. Never visits "/" or `home` itself, and never
/// descends into toolchain prefixes (e.g. /opt/homebrew is itself a git repo).
enum DirWalk {
    static let excludedPrefixes = ["/opt/homebrew", "/usr", "/System", "/Library", "/Applications", "/bin", "/sbin", "/private/var/db", "/var/db"]

    static var defaultHome: String { normalize(ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()) }

    static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func isExcluded(_ dir: String) -> Bool {
        excludedPrefixes.contains { dir == $0 || dir.hasPrefix($0 + "/") }
    }

    /// Nearest dir at or above `start` satisfying `predicate`.
    static func findUp(from start: String, home: String, where predicate: (String) -> Bool) -> String? {
        var dir = normalize(start)
        let home = normalize(home)
        guard !isExcluded(dir) else { return nil }
        while dir != "/", dir != home, !dir.isEmpty {
            if predicate(dir) { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }
}
