import Foundation

/// macOS / desktop-app background services that are never what you're looking for.
enum NoiseRules {
    /// Exact process names (lowercased).
    static let names: [String] = [
        "controlcenter",          // AirPlay receiver :5000 / :7000
        "rapportd", "sharingd", "remoted", "identityservicesd", "airplayxpchelper", "mdnsresponder", "cupsd",
        "apsd", "netbiosd", "screensharingd", "ardagent", "mediaremoted", "wifiagent", "assistantd",
        "universalaccessd", "usernoted", "coreduetd", "trustd", "launchd", "figma_agent",
    ]

    /// Process-name prefixes (lowercased): third-party desktop app helpers.
    static let namePrefixes: [String] = [
        "com.apple.", "spotify", "adobe", "creative cloud", "ccxprocess", "coresync", "dropbox", "figma", "raycast",
        "logioptions", "logi options", "logitech", "lghub", "1password", "steam", "discord", "zoom",
        "microsoft", "msteams", "onedrive",
    ]

    /// Substrings of the lowercased executable path.
    static let pathFragments: [String] = [
        "/spotify.app/", "/adobe", "/creative cloud", "/dropbox.app/", "/figma", "/raycast.app/", "/1password",
        "/steam.app/", "/discord.app/", "/zoom.us.app/", "/microsoft teams", "/microsoft ", "/onedrive.app/",
        "/logi options", "/logitech",
    ]

    /// Executables living here, owned by launchd with cwd "/", are system daemons.
    static let systemPrefixes: [String] = ["/system/", "/usr/libexec/", "/usr/sbin/", "/library/apple/"]

    static func isNoise(_ f: ProcFacets, cwd: String?) -> Bool {
        if f.isNamed(anyOf: names) || f.hasNamePrefix(anyOf: namePrefixes) || f.pathContains(anyOf: pathFragments) { return true }
        let atRoot = cwd == nil || cwd == "/"
        return atRoot && systemPrefixes.contains { f.exe.hasPrefix($0) }
    }
}

/// Runtime detection + cheap version derivation from install paths. Never spawns processes.
enum RuntimeDetector {
    /// process/exe basename → runtime label.
    static let exact: [String: String] = [
        "node": "node", "nodejs": "node", "bun": "bun", "deno": "deno", "ruby": "ruby", "java": "java",
        "php": "php", "dotnet": "dotnet", "go": "go", "beam.smp": "erlang",
    ]
    static let jsRuntimes: Set<String> = ["node", "bun", "deno"]

    static func key(_ f: ProcFacets) -> String? {
        for n in [f.exeName, f.name, f.arg0Name] where !n.isEmpty {
            if let k = exact[n] { return k }
            if n.hasPrefix("python") || n == "pypy" || n.hasPrefix("pypy3") { return "python" }
        }
        return nil
    }

    private static let toolPrefix = "(?:(?:node|nodejs|python|ruby|php|java|jdk|openjdk|temurin|zulu|corretto|bun|deno|go|erlang|elixir|otp)[-@])?"
    private static let dotted = try! NSRegularExpression(pattern: "^\(toolPrefix)v?(\\d+(?:\\.\\d+)+)(?:[_+-][A-Za-z0-9.]+)?(?:\\.jdk)?$")
    private static let majorOnly = try! NSRegularExpression(pattern: "^(?:node|nodejs|python|ruby|php|java|jdk|openjdk|temurin|zulu|corretto)[-@](\\d+)(?:\\.jdk)?$")
    private static let basenameVersion = try! NSRegularExpression(pattern: "^(?:python|pypy|ruby|node|php)(\\d+(?:\\.\\d+)+)$")

    private static func firstGroup(_ re: NSRegularExpression, in s: String) -> String? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// Version from install-path components: nvm `v20.11.1`, Cellar `22.1.0`, pyenv `3.12.2`, `node@20`, `jdk-21.0.2.jdk`.
    /// Most specific (most dotted parts) wins; ties go to the deepest component.
    static func version(fromPath path: String, basename: String) -> String? {
        var best: String?
        for comp in path.split(separator: "/").map(String.init) {
            guard let v = firstGroup(dotted, in: comp) ?? firstGroup(majorOnly, in: comp) else { continue }
            if best == nil || v.split(separator: ".").count >= best!.split(separator: ".").count { best = v }
        }
        return best ?? firstGroup(basenameVersion, in: basename)
    }

    static func runtime(_ f: ProcFacets, process p: ProcInfo) -> String? {
        guard let k = key(f) else { return nil }
        let path = p.executablePath ?? (p.arguments.first.map { $0.hasPrefix("/") ? $0 : "" } ?? "")
        let basename = (path as NSString).lastPathComponent.lowercased()
        let v = version(fromPath: path, basename: basename.isEmpty ? f.name : basename)
        return v.map { "\(k) \($0)" } ?? k
    }
}
