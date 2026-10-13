import ArgumentParser
import PierCore

/// Target resolution shared by every command that takes `<port|name>`.
enum Resolver {
    /// Scans, matches, and either returns the unambiguous services or prints why not and throws
    /// (exit 1: nothing matches, exit 2: ambiguous).
    static func resolve(_ target: String, probe: Bool = true) async throws -> [Service] {
        let all = await ServiceCatalog.snapshot(.init(includeNoise: true, probe: probe))
        // Custom names from `pier rename` / the app win: exact (case-insensitive) match first.
        let renames = ConfigStore.load().renames
        let renamed = all.filter { renames[$0.stableKey]?.caseInsensitiveCompare(target) == .orderedSame }
        if !renamed.isEmpty { return renamed }
        // Prefer real services; only fall back to system noise if nothing else matches.
        var result = Matcher.resolve(target, in: all.filter { !$0.isNoise })
        if case .none = result { result = Matcher.resolve(target, in: all) }
        switch result {
        case .found(let services):
            return services
        case .none:
            Term.fail("no service matches '\(target)'")
            throw ExitCode(1)
        case .ambiguous(let candidates):
            Term.fail("'\(target)' matches \(candidates.count) services; use a port to be specific:")
            for s in candidates {
                let detail = [s.projectName, s.framework?.name ?? s.infraName].compactMap { $0 }.joined(separator: ", ")
                Term.err("  :\(s.port)  \(s.displayName)\(detail.isEmpty ? "" : "  (\(detail))")  pid \(s.process.pid)")
            }
            throw ExitCode(2)
        }
    }

    static func resolveOne(_ target: String, probe: Bool = true) async throws -> Service {
        try await resolve(target, probe: probe)[0]
    }
}
