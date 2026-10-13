import ArgumentParser
import Foundation
import PierCore

/// pin / unpin / rename operate on `Service.stableKey` in config.pins / config.renames, which the menu bar app shares.
enum PinSupport {
    /// One service per distinct stable key (a port can have several pids; they share the key).
    static func distinct(_ services: [Service]) -> [Service] {
        var seen = Set<String>()
        return services.filter { seen.insert($0.stableKey).inserted }
    }

    static func label(_ s: Service, config: PierConfig) -> String {
        "\(Term.clean(ConfigDisplay.name(s, config: config))) (:\(s.port))"
    }

    static func printCandidates(_ target: String, _ candidates: [Service]) {
        Term.fail("'\(Term.clean(target))' matches \(candidates.count) services; use a port to be specific:")
        for s in candidates {
            let detail = [s.projectName, s.framework?.name ?? s.infraName].compactMap { $0 }.joined(separator: ", ")
            Term.err("  :\(s.port)  \(Term.clean(s.displayName))\(detail.isEmpty ? "" : "  (\(Term.clean(detail)))")  pid \(s.process.pid)")
        }
    }

    /// Same matching as `Resolver.resolve`, but silent so callers can fall back on a miss.
    static func match(_ target: String) async -> Matcher.Resolution {
        let all = await ServiceCatalog.snapshot(.init(includeNoise: true, probe: true))
        let result = Matcher.resolve(target, in: all.filter { !$0.isNoise })
        if case .none = result { return Matcher.resolve(target, in: all) }
        return result
    }
}

struct Pin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pin a service to the top of `pier ls` and the menu bar app.",
        discussion: "Pins follow the service's identity (project folder, container or name:port), so they survive restarts. `pier unpin` removes one.")

    @Argument(help: "Port number or (fuzzy) name.", completion: TargetCompletion.kind) var target: String

    func run() async throws {
        let services = PinSupport.distinct(try await Resolver.resolve(target))
        var config = try ConfigCommand.loadForWrite()
        var changed = false
        for s in services {
            let label = PinSupport.label(s, config: config)
            if ConfigEditing.pin(s, in: &config) { changed = true; Term.out("Pinned \(label)") }
            else { Term.out("\(label) is already pinned") }
        }
        if changed { try ConfigCommand.save(config) }
    }
}

struct Unpin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove a pin.",
        discussion: "Also works for pinned services that are not running right now (matched by project or name).")

    @Argument(help: "Port number or (fuzzy) name.", completion: TargetCompletion.kind) var target: String

    func run() async throws {
        var config = try ConfigCommand.loadForWrite()
        let stored = ConfigEditing.pinKeys(matching: target, in: config)
        var removed: [String] = []
        var notPinned: [String] = []

        switch await PinSupport.match(target) {
        case .found(let found):
            for s in PinSupport.distinct(found) {
                let label = PinSupport.label(s, config: config)
                if ConfigEditing.unpin(key: s.stableKey, in: &config) { removed.append(label) } else { notPinned.append(label) }
            }
            // Nothing running was pinned, but the text names a stored pin (e.g. a stopped project of that name).
            if removed.isEmpty, stored.count == 1 {
                ConfigEditing.unpin(key: stored[0], in: &config)
                removed = [Self.describe(stored[0])]; notPinned = []
            }
        case .ambiguous(let candidates):
            if stored.count == 1 {
                ConfigEditing.unpin(key: stored[0], in: &config)
                removed = [Self.describe(stored[0])]
            } else {
                PinSupport.printCandidates(target, candidates)
                throw ExitCode(2)
            }
        case .none:
            if stored.count == 1 {
                ConfigEditing.unpin(key: stored[0], in: &config)
                removed = [Self.describe(stored[0])]
            } else if stored.count > 1 {
                Term.fail("'\(Term.clean(target))' matches \(stored.count) pins: \(stored.map(Self.describe).joined(separator: ", "))")
                throw ExitCode(2)
            } else {
                Term.fail("no service or pin matches '\(Term.clean(target))'")
                throw ExitCode(1)
            }
        }

        if !removed.isEmpty { try ConfigCommand.save(config) }
        for r in removed { Term.out("Unpinned \(r)") }
        for n in notPinned { Term.out("\(n) isn't pinned") }
    }

    /// "project:/Users/me/dev/relay" -> "relay (project)".
    static func describe(_ key: String) -> String {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return Term.clean(key) }
        let name = parts[0] == "project" ? (parts[1] as NSString).lastPathComponent : parts[1]
        return "\(Term.clean(name)) (\(parts[0]))"
    }
}

struct Rename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Give a service a custom display name (or --reset).",
        discussion: """
        The name shows in `pier ls`, `pier info` and the menu bar app. Targets still match the automatic
        name, so `pier info relay` keeps working after a rename.

          pier rename 3100 Relay API
          pier rename relay --reset
        """)

    @Argument(help: "Port number or (fuzzy) name.", completion: TargetCompletion.kind) var target: String
    @Argument(parsing: .remaining, help: "New display name.") var name: [String] = []
    @Flag(help: "Remove the custom name.") var reset = false

    func validate() throws {
        if reset, !name.isEmpty { throw ValidationError("Pass either a new name or --reset, not both.") }
        if !reset, name.isEmpty { throw ValidationError("Missing the new name (or pass --reset).") }
    }

    func run() async throws {
        let services = PinSupport.distinct(try await Resolver.resolve(target))
        guard services.count == 1 else {
            PinSupport.printCandidates(target, services)
            throw ExitCode(2)
        }
        let s = services[0]
        var config = try ConfigCommand.loadForWrite()
        let before = PinSupport.label(s, config: config)

        if reset {
            guard ConfigEditing.resetRename(s, in: &config) else {
                Term.out("\(before) has no custom name")
                return
            }
            try ConfigCommand.save(config)
            Term.out("\(before) is \(Term.clean(s.displayName)) again")
            return
        }
        let outcome: ConfigEditing.RenameOutcome
        do { outcome = try ConfigEditing.rename(s, to: name.joined(separator: " "), in: &config) } catch {
            Term.fail(error.localizedDescription)
            throw ExitCode(64)
        }
        try ConfigCommand.save(config)
        switch outcome {
        case .set(let n): Term.out("Renamed \(Term.clean(s.displayName)) (:\(s.port)) to \"\(Term.clean(n))\"")
        case .cleared: Term.out("Custom name cleared; \(Term.clean(s.displayName)) (:\(s.port))")
        }
    }
}
