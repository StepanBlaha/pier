import ArgumentParser
import Foundation
import PierCore

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop a service (managed ones exit cleanly; others like `pier kill`).",
        discussion: """
        Managed services (`pier run`) are asked to stop through their wrapper: the process exits and its
        record is removed, even if it had crashed and no longer listens. Any other service is stopped
        exactly like `pier kill` (SIGTERM, then SIGKILL after 3s; databases, Docker and system services
        ask first).

          pier stop relay
          pier stop 5173 --yes
        """)

    @Argument(help: "Port, name or managed id.", completion: TargetCompletion.kind) var target: String
    @Flag(help: "Skip SIGTERM and send SIGKILL immediately (non-managed services).") var force = false
    @Flag(name: [.short, .long], help: "Don't ask for confirmation.") var yes = false

    func run() async throws {
        // Managed first (by id / name): works for crashed ones that are not listening any more.
        if let m = try ManagedTargets.findManaged(target) {
            do {
                try await ManagedClient.stop(m)
                Term.out("Stopped \(Term.clean(m.name)) (managed)")
                return
            } catch {
                Term.fail("couldn't stop \(Term.clean(m.name)): \(error)")
                throw ExitCode(1)
            }
        }
        let services = try await Resolver.resolve(target, probe: false)
        try await KillFlow.run(services, force: force, yes: yes, verb: "Stop")
    }
}
