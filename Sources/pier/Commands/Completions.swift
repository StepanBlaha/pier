import ArgumentParser
import Foundation
import PierCore

/// Dynamic `<port|name>` completion: asks the live scanner (no CPU sampling, no probing, ~50ms).
enum TargetCompletion {
    /// Closure args: (all words, index of current word, current word up to the cursor).
    static let kind: CompletionKind = .custom { _, _, prefix in
        let shell = CompletionShell.requesting?.rawValue
        let services = ServiceCatalog.quickSnapshot()
        // Page titles / process names are untrusted and end up in the shell's completion menu: strip
        // escape sequences and control characters (and tabs / newlines, which would break the per-shell line format).
        return Completion.candidates(prefix: prefix, services: services).map {
            Completion.render(.init(value: Sanitize.line($0.value).replacingOccurrences(of: " ", with: "-"),
                                    detail: Sanitize.line($0.detail)), shell: shell)
        }
    }
}

struct Completions: ParsableCommand {
    enum ShellName: String, ExpressibleByArgument, CaseIterable {
        case zsh, bash, fish
        var shell: CompletionShell {
            switch self { case .zsh: .zsh; case .bash: .bash; case .fish: .fish }
        }
    }

    static let configuration = CommandConfiguration(
        abstract: "Print or install shell completions (zsh, bash, fish).",
        discussion: """
        <TAB> after `pier kill`, `info`, `open`, `url`, `qr` completes live ports and names.

          pier completions zsh > ~/.zsh/completions/_pier     print for a shell
          pier completions --install                          write to the standard location
        """)

    @Argument(help: "Shell (default: from $SHELL).") var shell: ShellName?
    @Flag(help: "Write the script to the shell's standard completions directory.") var install = false

    func run() throws {
        guard let name = shell ?? Self.detectShell() else {
            Term.fail("could not detect your shell from $SHELL; pass zsh, bash or fish")
            throw ExitCode(1)
        }
        let script = Pier.completionScript(for: name.shell)
        guard install else { Term.out(script, terminator: script.hasSuffix("\n") ? "" : "\n"); return }

        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let (dir, file): (String, String)
        switch name {
        case .zsh: (dir, file) = ("\(home)/.zsh/completions", "_pier")
        case .bash: (dir, file) = ("\(home)/.local/share/bash-completion/completions", "pier")
        case .fish: (dir, file) = ("\(home)/.config/fish/completions", "pier.fish")
        }
        let path = "\(dir)/\(file)"
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try script.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            Term.fail("could not write \(path): \(error.localizedDescription)")
            throw ExitCode(1)
        }
        Term.out("Wrote \(name.rawValue) completions to \(path)")
        switch name {
        case .zsh: zshHints(home: home, dir: dir)
        case .bash:
            print("Needs the bash-completion package (loads files from that directory automatically). Restart your shell.")
        case .fish:
            print("Fish loads it automatically; open a new shell.")
        }
    }

    private func zshHints(home: String, dir: String) {
        let fpathLine = "fpath=(~/.zsh/completions $fpath)"
        let zshrc = (try? String(contentsOfFile: "\(home)/.zshrc", encoding: .utf8)) ?? ""
        if zshrc.contains(".zsh/completions") || zshrc.contains("\(home)/.zsh/completions") {
            print("~/.zshrc already references ~/.zsh/completions. Run `exec zsh` (or `rm -f ~/.zcompdump*; exec zsh`) to pick it up.")
        } else {
            print("""

            Add these two lines to ~/.zshrc (I don't edit rc files). The fpath line must come
            BEFORE compinit; if your .zshrc already calls compinit, only add the fpath line above it.

              \(fpathLine)
              autoload -U compinit && compinit

            Then run `exec zsh`.
            """)
        }
        // Homebrew's site-functions is already on fpath, so no rc edit needed if it is writable.
        let candidates = ["/opt/homebrew/share/zsh/site-functions", "/usr/local/share/zsh/site-functions"]
        if let brew = candidates.first(where: { FileManager.default.isWritableFile(atPath: $0) }) {
            print("""

            Alternative with no .zshrc change: Homebrew's \(brew) is writable and already on fpath:
              pier completions zsh > \(brew)/_pier
            """)
        }
    }

    private static func detectShell() -> ShellName? {
        guard let path = ProcessInfo.processInfo.environment["SHELL"] else { return nil }
        return ShellName(rawValue: (path as NSString).lastPathComponent)
    }
}
