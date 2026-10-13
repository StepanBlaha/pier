import ArgumentParser
import Foundation
import PierCore

struct Kill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop a service (SIGTERM, then SIGKILL after 3s).",
        discussion: "Dev servers are stopped without a prompt; databases, Docker and system services ask first.")

    @Argument(help: "Port number or (fuzzy) name.", completion: TargetCompletion.kind) var target: String
    @Flag(help: "Skip SIGTERM and send SIGKILL immediately.") var force = false
    @Flag(name: [.short, .long], help: "Don't ask for confirmation.") var yes = false

    func run() async throws {
        let services = try await Resolver.resolve(target, probe: false)
        try await KillFlow.run(services, force: force, yes: yes)
    }
}

/// Shared by `pier kill` and `pier stop` (non-managed targets): validate, confirm, then stop each service
/// (managed ones through their wrapper, others with signals).
enum KillFlow {
    static func label(_ s: Service) -> String { "\(Term.clean(s.displayName)) (pid \(s.process.pid)) on :\(s.port)" }

    static func run(_ services: [Service], force: Bool, yes: Bool, verb: String = "Kill") async throws {
        for s in services {
            do { try Killer.validate(pid: s.process.pid) } catch {
                Term.fail("\(error.localizedDescription) (:\(s.port))")
                throw ExitCode(1)
            }
        }

        if !yes, services.contains(where: Killer.requiresConfirmation) {
            let question = "\(verb) " + services.map(label).joined(separator: " and ") + "?"
            guard Term.canPrompt else {
                Term.fail("\(question) Confirmation required; pass --yes to proceed non-interactively.")
                throw ExitCode(1)
            }
            guard Term.confirm(question) else {
                print("Aborted.")
                throw ExitCode(1)
            }
        }

        var failed = false
        for s in services {
            if !(await kill(s, force: force, yes: yes)) { failed = true }
        }
        if failed { throw ExitCode(1) }
    }

    private static func kill(_ s: Service, force: Bool, yes: Bool) async -> Bool {
        // Managed: stop via the wrapper so it exits cleanly instead of lingering as "crashed".
        if let id = s.managedID, let m = ManagedRegistry.all().first(where: { $0.id == id }) {
            do {
                try await ManagedClient.stop(m)
                print("Stopped \(Term.clean(m.name)) (managed) on :\(s.port)")
                return true
            } catch {
                Term.err("managed stop failed (\(error)); falling back to signals")
            }
        }
        let name = label(s)
        do {
            var outcome = try await Killer.terminate(pid: s.process.pid, force: force)
            if outcome == .permissionDenied {
                guard Term.canPrompt else {
                    Term.fail("permission denied killing \(name); it belongs to another user or root (re-run in a terminal to use admin elevation)")
                    return false
                }
                guard yes || Term.confirm("Permission denied for \(name). Retry with administrator privileges?") else {
                    return false
                }
                outcome = try await Killer.terminateElevated(pid: s.process.pid)
            }
            switch outcome {
            case .terminated: print("Stopped \(name)")
            case .killed: print("Force killed \(name)")
            case .alreadyGone: print("\(name) already exited")
            case .permissionDenied: Term.fail("permission denied killing \(name)"); return false
            case .stillRunning: Term.fail("\(name) is still running after SIGKILL"); return false
            case .failed(let e): Term.fail("failed to kill \(name): \(String(cString: strerror(e)))"); return false
            }
            return true
        } catch {
            Term.fail(error.localizedDescription)
            return false
        }
    }
}
