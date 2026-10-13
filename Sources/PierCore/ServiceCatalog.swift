import Foundation

/// Glue: scan → group → identify → probe.
public enum ServiceCatalog {
    /// Managed-mode + docker info that Identifier doesn't own.
    static func attachExtras(_ s: inout Service, parents: [ProcInfo], dockerPorts: [UInt16: DockerInfo], checkManaged: Bool) {
        if checkManaged, let m = ManagedRegistry.manifest(owning: s.process.pid, parents: parents) {
            s.isManaged = true
            s.managedID = m.id
            s.projectName = m.name  // explicit --name (or stack/service) wins; defaults to the folder name anyway
        }
        if let d = dockerPorts[s.port] {
            s.docker = d
            if s.kind == .other || s.kind == .docker { s.kind = s.infraName == nil ? .docker : s.kind }
            if s.projectName == nil { s.projectName = d.composeProject ?? d.containerName }
            s.isNoise = false
        }
    }

    public struct Options: Sendable {
        public var includeNoise: Bool
        public var probe: Bool
        public var probeTimeout: TimeInterval
        public init(includeNoise: Bool = false, probe: Bool = true, probeTimeout: TimeInterval = 0.3) {
            self.includeNoise = includeNoise; self.probe = probe; self.probeTimeout = probeTimeout
        }
    }

    public static func snapshot(_ options: Options = .init()) async -> [Service] {
        let sockets = ProcScanner.listeningSockets()
        let grouped = Dictionary(grouping: sockets) { "\($0.port)-\($0.pid)" }
        let pids = Array(Set(sockets.map(\.pid)))
        let infos = ProcScanner.processInfos(pids: pids)
        let dockerPorts = DockerMapper.publishedPorts()
        let hasManaged = !ManagedRegistry.all().isEmpty

        var services: [Service] = grouped.values.compactMap { group in
            guard let first = group.first else { return nil }
            let proc = infos[first.pid] ?? ProcInfo(pid: first.pid, ppid: 0, uid: 0, name: "pid \(first.pid)", isAccessible: false)
            let addrs = Array(Set(group.map(\.address))).sorted()
            var s = Service(port: first.port, process: proc, addresses: addrs, bindScope: Identifier.bindScope(for: addrs))
            let parents = ProcScanner.parentChain(of: first.pid)
            Identifier.enrich(&s, parents: parents)
            attachExtras(&s, parents: parents, dockerPorts: dockerPorts, checkManaged: hasManaged)
            return s
        }

        if !options.includeNoise { services.removeAll(where: \.isNoise) }

        // Tunnel detection may spawn `tailscale`; only on full (probing) snapshots.
        let wantTunnels = options.probe
        async let tunnels: [UInt16: String] = wantTunnels ? TunnelDetector.activeTunnels() : [:]

        if options.probe {
            let timeout = options.probeTimeout
            let targets = services.enumerated().filter { !Identifier.isKnownNonHTTP($0.element) && !$0.element.isNoise }
            await withTaskGroup(of: (Int, ProbeResult).self) { group in
                for (i, s) in targets {
                    let port = s.port
                    group.addTask { (i, await Prober.probe(port: port, timeout: timeout)) }
                }
                for await (i, result) in group {
                    services[i].probe = result
                    Identifier.refine(&services[i])
                }
            }
        }

        let tunnelMap = await tunnels
        if wantTunnels { for i in services.indices { services[i].tunnelURL = tunnelMap[services[i].port] } }

        // refine() can flag app-internal ports as noise only after probing.
        if !options.includeNoise { services.removeAll(where: \.isNoise) }
        return services.sorted { ($0.port, $0.process.pid) < ($1.port, $1.process.pid) }
    }
}
