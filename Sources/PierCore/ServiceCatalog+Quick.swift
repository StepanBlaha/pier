import Foundation

extension ServiceCatalog {
    /// Fast synchronous snapshot for shell completion: no CPU sampling (cpuPercent stays nil), no probing.
    public static func quickSnapshot(includeNoise: Bool = false) -> [Service] {
        let sockets = ProcScanner.listeningSockets()
        let grouped = Dictionary(grouping: sockets) { "\($0.port)-\($0.pid)" }
        var infos: [Int32: ProcInfo] = [:]
        for pid in Set(sockets.map(\.pid)) { if let i = ProcScanner.processInfo(pid: pid) { infos[pid] = i } }

        let hasManaged = !ManagedRegistry.all().isEmpty

        var services: [Service] = grouped.values.compactMap { group in
            guard let first = group.first else { return nil }
            let proc = infos[first.pid] ?? ProcInfo(pid: first.pid, ppid: 0, uid: 0, name: "pid \(first.pid)", isAccessible: false)
            let addrs = Array(Set(group.map(\.address))).sorted()
            var s = Service(port: first.port, process: proc, addresses: addrs, bindScope: Identifier.bindScope(for: addrs))
            let parents = ProcScanner.parentChain(of: first.pid)
            Identifier.enrich(&s, parents: parents)
            // No docker lookup here: completion must stay fast.
            attachExtras(&s, parents: parents, dockerPorts: [:], checkManaged: hasManaged)
            return s
        }
        // Unprobed refine() still flags desktop-app helper ports (Code Helper, Notion, ...) as noise.
        for i in services.indices { Identifier.refine(&services[i]) }
        if !includeNoise { services.removeAll(where: \.isNoise) }
        return services.sorted { ($0.port, $0.process.pid) < ($1.port, $1.process.pid) }
    }
}
