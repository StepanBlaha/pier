import ArgumentParser
import PierCore

struct Free: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the next free TCP port.")

    @Argument(help: "Start searching from this port.") var port: UInt16 = 3000
    @Flag(help: "Output JSON.") var json = false

    func run() throws {
        guard let free = PortFinder.nextFree(from: port) else {
            Term.fail("no free port at or above \(port)")
            throw ExitCode(1)
        }
        Term.out(json ? "{\n  \"port\" : \(free)\n}" : "\(free)")
    }
}
