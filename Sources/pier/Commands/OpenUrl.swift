import ArgumentParser
import Foundation
import PierCore

struct Open: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a service in the browser (reuses an existing tab).",
        discussion: """
        Default: focus an already-open tab for that host:port in Chrome / Arc / Brave / Edge / Safari
        (macOS asks once for Automation permission); otherwise open a new tab.
        --editor opens the project folder in your configured editor; --terminal focuses the terminal
        tab or window that started the process.
        """
    )

    @Argument(help: "Port number or (fuzzy) name.", completion: TargetCompletion.kind) var target: String
    @Flag(help: "Open the LAN URL instead of localhost.") var lan = false
    @Flag(name: .customLong("new-tab"), help: "Always open a new tab; never reuse an existing one.") var newTab = false
    @Flag(help: "Open the project folder in the configured editor instead.") var editor = false
    @Flag(help: "Focus the terminal tab/window that started the service instead.") var terminal = false

    func validate() throws {
        if editor && terminal { throw ValidationError("--editor and --terminal are mutually exclusive.") }
        if (editor || terminal) && (lan || newTab) {
            throw ValidationError("--lan / --new-tab only apply to opening in the browser.")
        }
    }

    func run() async throws {
        let s = try await Resolver.resolveOne(target, probe: !(editor || terminal))
        if editor {
            guard let path = s.projectPath ?? s.process.cwd else {
                Term.fail("no project folder known for :\(s.port) (process cwd unreadable)")
                throw ExitCode(1)
            }
            let ed = ConfigStore.load().editor
            do { try EditorOpener.open(path: path, editor: ed) } catch {
                Term.fail("\(error)")
                throw ExitCode(1)
            }
            print("Opened \(path) in \(ed)")
            return
        }
        if terminal {
            let r = TerminalJumper.jumpDetailed(to: s)
            guard r.success else {
                Term.fail("could not jump to the terminal of :\(s.port): \(r.detail)")
                throw ExitCode(1)
            }
            print(r.detail.prefix(1).uppercased() + r.detail.dropFirst())
            return
        }
        let url = try Urls.pick(s, lan: lan)
        switch BrowserOpener.perform(url, reuseTab: !newTab, browserBundleID: ConfigStore.load().browser) {
        case .reusedTab(let browser):
            print("Switched to existing tab in \(browser): \(url)")
        case .opened(let note):
            print("Opened \(url)")
            if let note { Term.err("pier: \(note)") }
        case .failed(let message):
            Term.fail(message)
            throw ExitCode(1)
        }
    }
}

struct Url: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print a service URL (pipe-friendly).")

    @Argument(help: "Port number or (fuzzy) name.", completion: TargetCompletion.kind) var target: String
    @Flag(help: "Print the LAN URL.") var lan = false
    @Flag(help: "Print the public tunnel URL.") var tunnel = false

    func validate() throws {
        if lan && tunnel { throw ValidationError("--lan and --tunnel are mutually exclusive.") }
    }

    func run() async throws {
        let s = try await Resolver.resolveOne(target)
        if tunnel {
            guard let url = s.tunnelURL else {
                Term.fail("no tunnel detected for \(s.displayName) (:\(s.port)); start one with `pier expose \(target)`")
                throw ExitCode(1)
            }
            print(url)
            return
        }
        print(try Urls.pick(s, lan: lan))
    }
}

enum Urls {
    static func pick(_ s: Service, lan: Bool) throws -> String {
        guard lan else { return s.localURL }
        guard let url = s.lanURL else {
            Term.fail("service is bound to localhost only; no LAN URL")
            throw ExitCode(1)
        }
        return url
    }
}
