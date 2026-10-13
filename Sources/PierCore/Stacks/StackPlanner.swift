import Foundation

public enum StackPlanner {
    /// Start order as waves: every service in a wave only depends on services from earlier waves, so a wave can start in parallel.
    /// `selection` empty = all services. With `includeDependencies` (default) the selection is expanded with its transitive deps.
    /// Within a wave services keep declaration order.
    public static func plan(_ file: StackFile, selection: [ServiceName] = [], includeDependencies: Bool = true) throws -> [[ServiceName]] {
        let byName = Dictionary(file.services.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for n in selection where byName[n] == nil {
            throw StackError.unknownService(n, known: file.serviceNames)
        }
        var wanted: Set<ServiceName>
        if selection.isEmpty { wanted = Set(file.serviceNames) }
        else {
            wanted = Set(selection)
            if includeDependencies {
                var stack = selection
                while let n = stack.popLast() {
                    for d in byName[n]?.dependsOn ?? [] where wanted.insert(d).inserted { stack.append(d) }
                }
            }
        }
        for n in wanted where byName[n] == nil { throw StackError.unknownService(n, known: file.serviceNames) }

        let order = file.serviceNames.filter(wanted.contains)
        var adj: [ServiceName: [ServiceName]] = [:]
        for n in order { adj[n] = (byName[n]?.dependsOn ?? []).filter(wanted.contains) }
        if let cycle = findCycle(adj, order: order) { throw StackError.cycle(cycle) }

        var remaining = order
        var done = Set<ServiceName>()
        var waves: [[ServiceName]] = []
        while !remaining.isEmpty {
            let wave = remaining.filter { Set(adj[$0] ?? []).isSubset(of: done) }
            if wave.isEmpty { throw StackError.cycle(remaining) }   // unreachable after findCycle
            waves.append(wave)
            done.formUnion(wave)
            remaining.removeAll { done.contains($0) }
        }
        return waves
    }

    /// Transitive dependents of `name` (services that need it), excluding itself.
    public static func dependents(of name: ServiceName, in file: StackFile) -> Set<ServiceName> {
        var out = Set<ServiceName>()
        var stack = [name]
        while let n = stack.popLast() {
            for s in file.services where s.dependsOn.contains(n) && out.insert(s.name).inserted { stack.append(s.name) }
        }
        return out
    }

    /// Returns a cycle as ["a", "b", "a"] or nil. Deterministic: starts from the first service (in `order`) that is part of one.
    static func findCycle(_ adj: [String: [String]], order: [String]) -> [String]? {
        enum Mark { case visiting, done }
        var marks: [String: Mark] = [:]
        var path: [String] = []
        func visit(_ n: String) -> [String]? {
            if marks[n] == .done { return nil }
            if marks[n] == .visiting {
                let start = path.firstIndex(of: n) ?? 0
                return Array(path[start...]) + [n]
            }
            marks[n] = .visiting
            path.append(n)
            for d in adj[n] ?? [] { if let c = visit(d) { return c } }
            path.removeLast()
            marks[n] = .done
            return nil
        }
        for n in order { if let c = visit(n) { return c } }
        return nil
    }
}
