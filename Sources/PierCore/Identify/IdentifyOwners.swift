import Foundation

/// Classifies a service's parent chain into owner links (editor / terminal / agent / launchd...).
enum OwnerClassifier {
    struct Rule {
        let kind: OwnerKind
        var names: [String] = []
        var namePrefixes: [String] = []
        var paths: [String] = []
    }

    /// Ordered; first match wins. All values lowercased.
    static let rules: [Rule] = [
        Rule(kind: .vscode, namePrefixes: ["code helper"], paths: ["visual studio code.app/", "vscodium.app/", "code - insiders.app/"]),
        Rule(kind: .cursor, names: ["cursor"], namePrefixes: ["cursor helper"], paths: ["/cursor.app/"]),
        Rule(kind: .zed, names: ["zed", "zed-editor"], paths: ["/zed.app/", "/zed preview.app/"]),
        Rule(kind: .xcode, names: ["xcode"], paths: ["/xcode.app/", "/xcode-beta.app/"]),
        Rule(kind: .iterm, namePrefixes: ["iterm"], paths: ["/iterm.app/"]),
        Rule(kind: .terminal, names: ["terminal"], paths: ["/terminal.app/"]),
        Rule(kind: .ghostty, names: ["ghostty"], paths: ["/ghostty.app/"]),
        Rule(kind: .warp, names: ["warp", "warp-terminal"], paths: ["/warp.app/"]),
        Rule(kind: .wezterm, namePrefixes: ["wezterm"], paths: ["/wezterm.app/"]),
        Rule(kind: .kitty, names: ["kitty"], paths: ["/kitty.app/"]),
        Rule(kind: .alacritty, names: ["alacritty"], paths: ["/alacritty.app/"]),
        Rule(kind: .tmux, namePrefixes: ["tmux"]),
        Rule(kind: .docker, namePrefixes: ["docker", "com.docker", "containerd"], paths: ["/docker.app/"]),
    ]

    /// Shells and thin wrappers that add no information to the chain.
    static let skipped: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish", "login", "sudo", "su", "env"]

    static func kind(of p: ProcInfo) -> OwnerKind? {
        let f = ProcFacets(p)
        if p.pid == 1 || f.name == "launchd" { return .launchd }
        if isClaudeCode(f) { return .claudeCode }
        if let r = rules.first(where: { r in
            r.names.contains(where: f.isNamed) || f.hasNamePrefix(anyOf: r.namePrefixes) || f.pathContains(anyOf: r.paths)
        }) { return r.kind }
        if f.name == "stable" && f.exe.isEmpty { return .warp }   // Warp's binary, when the path is unreadable
        if skipped.contains(f.name) || skipped.contains(f.exeName) { return nil }
        return .other
    }

    /// Claude Code: a binary named "claude" (but not Claude.app desktop), its versioned install dir,
    /// or a node process running the claude-code package.
    private static func isClaudeCode(_ f: ProcFacets) -> Bool {
        if f.pathContains(anyOf: ["/claude/versions/", "/.claude/local/", "@anthropic-ai/claude-code"]) { return true }
        if (f.name == "claude" || f.exeName == "claude") && !f.exe.contains(".app/") { return true }
        return RuntimeDetector.key(f) == "node" && f.args.contains { $0.contains("claude-code") }
    }

    /// Nearest first. Shells are dropped; consecutive links of the same known kind
    /// (e.g. the Code Helper → Electron chain of one VS Code) collapse into the nearest one.
    static func owners(from parents: [ProcInfo]) -> [OwnerLink] {
        var out: [OwnerLink] = []
        for p in parents where p.pid > 0 {
            guard let kind = kind(of: p) else { continue }
            if kind != .other, out.last?.kind == kind { continue }
            out.append(OwnerLink(pid: p.pid, name: p.name, kind: kind))
        }
        return out
    }
}
