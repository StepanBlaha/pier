import ArgumentParser
import Foundation
import PierCore

struct Expose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Public URL for a service via a cloudflared tunnel.",
        discussion: "Starts a detached `cloudflared tunnel` (trycloudflare.com quick tunnel). Requires cloudflared: brew install cloudflared.")

    @Argument(help: "Port number or (fuzzy) name.", completion: TargetCompletion.kind) var target: String
    @Flag(help: "Stop the tunnel for this service.") var stop = false
    @Flag(help: "Output JSON.") var json = false
    @Flag(help: "Expose even if it looks like a database or other infrastructure.") var force = false

    func run() async throws {
        if stop { try await runStop() } else { try await runExpose() }
    }

    // MARK: stop

    private func runStop() async throws {
        // A bare port works even when nothing listens on it any more (the app died, the tunnel did not).
        var port: UInt16
        if let p = UInt16(target) {
            port = p
        } else {
            port = try await Resolver.resolveOne(target, probe: false).port
        }
        do {
            try TunnelLauncher.unexpose(port: port)
        } catch {
            Term.fail("\(error)")
            throw ExitCode(1)
        }
        if json {
            printJSON(["port": port, "stopped": true] as [String: Any])
        } else {
            print("Stopped tunnel for :\(port)")
        }
    }

    // MARK: expose

    private func runExpose() async throws {
        if let p = UInt16(target), !ProcScanner.listeningSockets().contains(where: { $0.port == p }) {
            Term.fail("nothing is listening on :\(p)")
            throw ExitCode(1)
        }
        let service = try await Resolver.resolveOne(target, probe: false)

        if service.kind == .infra && !force {
            Term.fail("refusing to expose a database; use --force (\(service.displayName) on :\(service.port))")
            throw ExitCode(1)
        }

        let name = service.projectName ?? service.displayName
        let alreadyThere = service.tunnelURL != nil

        let url: String
        if let existing = service.tunnelURL {
            url = existing
        } else {
            if Term.interactive { Term.err("Starting cloudflared tunnel for :\(service.port) ...") }
            do {
                url = try await TunnelLauncher.expose(port: service.port)
            } catch {
                Term.fail("\(error)")
                throw ExitCode(1)
            }
        }

        let copied = Term.interactive && Self.copyToClipboard(url)

        if json {
            printJSON(["port": service.port, "name": name, "url": url, "copied": copied, "existing": alreadyThere] as [String: Any])
            return
        }
        let arrow = Self.unicodeOK ? "→" : "->"
        print("\(alreadyThere ? "Already exposed" : "Exposing") \(name) (:\(service.port)) \(arrow) \(url)\(copied ? "  (copied)" : "")")
        print("Anyone with this URL can reach it. Stop: pier expose \(target) --stop")
    }

    // MARK: helpers

    private static var unicodeOK: Bool {
        guard Term.stdoutIsTTY else { return false }
        let env = ProcessInfo.processInfo.environment
        if env["TERM"] == "dumb" { return false }
        let loc = (env["LC_ALL"] ?? env["LC_CTYPE"] ?? env["LANG"] ?? "").uppercased()
        return loc.isEmpty || loc.contains("UTF")
    }

    private func printJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return }
        print(s)
    }

    /// pbcopy via Process; any failure is ignored.
    private static func copyToClipboard(_ text: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            pipe.fileHandleForWriting.write(Data(text.utf8))
            try? pipe.fileHandleForWriting.close()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch { return false }
    }
}
