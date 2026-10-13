import ArgumentParser
import PierCore

@main
struct Pier: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pier",
        abstract: "Browse, identify and control everything listening on localhost.",
        discussion: """
        TARGETS
          Most commands take a <target>: a port (3100, always exact) or a fuzzy name
          matched against page title, project, framework, infra or process name
          (relay, next, postgres, ollama). Ambiguous matches list candidates (exit 2).

        EXAMPLES
          pier                       list everything (same as `pier ls`)
          pier watch                 live view; o open, k kill, enter info, q quit
          pier ls --all              include hidden system / app-helper noise
          pier info relay            path, branch, runtime, owners, CPU/RAM
          pier open relay --lan      open the LAN URL
          pier url 3100 | pbcopy     copy a URL
          pier kill 3000             free a stuck port (SIGTERM, then SIGKILL)
          pier stop relay            stop cleanly (managed) or like kill
          pier pin relay             pin to the top; `pier rename 3100 My API`
          pier free 5173             next free port from 5173
          pier qr relay              QR of the LAN URL for phone testing
          pier stale --days 3        forgotten dev servers; `pier prune` kills them
          pier config set editor cursor   app + CLI settings
          pier completions --install enable <TAB> completion of ports and names
          pier ls --json | jq '.[].displayName'

        MANAGED & SHARING
          pier run                   run package.json "dev" managed (logs + restart)
          pier run -- python app.py  run any command managed
          pier logs relay -f         follow logs of a managed service
          pier restart relay         restart (adopts unmanaged services)
          pier up / pier down        start / stop a pier.yml stack
          pier expose relay          public https URL via cloudflared
          pier mcp                   MCP server for Claude Code
          pier app install           install the menu bar app

        EXIT CODES
          0 ok, 1 not found / error, 2 ambiguous target
        """,
        version: PierVersion.current,
        groupedSubcommands: [
            CommandGroup(name: "Inspect", subcommands: [Ls.self, Watch.self, Info.self, Url.self, Stale.self]),
            CommandGroup(name: "Act", subcommands: [Open.self, Stop.self, Kill.self, Prune.self, QRCommand.self, Free.self, Pin.self, Unpin.self, Rename.self]),
            CommandGroup(name: "Managed", subcommands: [Run.self, Logs.self, Restart.self, Up.self, Down.self]),
            CommandGroup(name: "Share & integrate", subcommands: [Expose.self, MCP.self, App.self]),
            CommandGroup(name: "Setup", subcommands: [ConfigCommand.self, Completions.self, Hello.self]),
        ],
        defaultSubcommand: Ls.self
    )

    /// Ignore SIGPIPE first (so `pier ls | head -1` ends quietly), then run normally.
    static func main() async {
        Term.bootstrap()
        await Self.main(nil)
    }
}
