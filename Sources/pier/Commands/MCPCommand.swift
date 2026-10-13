import ArgumentParser
import Foundation
import PierCore

struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "MCP server (stdio) for Claude Code and other agents.",
        discussion: """
        Speaks the Model Context Protocol over stdin/stdout (newline-delimited JSON-RPC); logs go to stderr.
        Tools: list_services, service_info, read_logs, kill_service, restart_service, find_free_port,
        wait_for_port, stale_services, run_service.

        Register it:  pier mcp --print-config
        """)

    @Flag(name: .customLong("print-config"), help: "Print how to register pier with Claude Code and other MCP clients, then exit.")
    var printConfig = false

    func run() async throws {
        if printConfig {
            print(Self.configText(path: Self.executablePath()))
            return
        }
        await MCPServer.runStdio()
    }

    static func configText(path: String) -> String {
        let json = JSON.object(["mcpServers": ["pier": ["command": .string(path), "args": ["mcp"]]]]).compact
        return """
        Claude Code:

          claude mcp add pier -- \(shellQuote(path)) mcp

        Other MCP clients (Claude Desktop, Cursor, ...), add to the client's MCP config:

        \(json)
        """
    }

    /// Absolute path of this binary (symlinks resolved).
    static func executablePath() -> String {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buf, &size) == 0 {
            let raw = String(cString: buf)
            return URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath().path
        }
        let arg0 = CommandLine.arguments[0]
        return arg0.hasPrefix("/") ? arg0 : FileManager.default.currentDirectoryPath + "/" + arg0
    }

    private static func shellQuote(_ s: String) -> String {
        s.range(of: #"^[A-Za-z0-9_\/.\-+@:,=]+$"#, options: .regularExpression) != nil
            ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
