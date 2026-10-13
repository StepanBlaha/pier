import Foundation

/// Pure view-model logic for the menu bar app: grouping, ordering, filtering, badges, probe merging and
/// transition detection. No UI, no I/O, so everything here is unit-testable.
public enum AppModel {

    // MARK: - Groups

    public enum Group: String, CaseIterable, Sendable, Identifiable {
        case pinned, managed, projects, infra, other, system
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .pinned: "Pinned"
            case .managed: "Managed"
            case .projects: "Projects"
            case .infra: "Infra"
            case .other: "Other"
            case .system: "System"
            }
        }
    }

    public struct Section: Identifiable, Equatable, Sendable {
        public var group: Group
        public var services: [Service]
        /// Managed services that crashed (no listening port any more); shown at the top of the Managed section.
        public var crashed: [ManagedManifest] = []
        public var id: String { group.rawValue }
        public var collapsedByDefault: Bool { group == .system }
        public var isEmpty: Bool { services.isEmpty && crashed.isEmpty }
        public var count: Int { services.count + crashed.count }
    }

    /// Display name with user renames applied.
    public static func displayName(_ s: Service, config: PierConfig) -> String {
        if let r = config.renames[s.stableKey]?.trimmingCharacters(in: .whitespaces), !r.isEmpty { return r }
        return s.displayName
    }

    public static func isPinned(_ s: Service, config: PierConfig) -> Bool { config.pins.contains(s.stableKey) }

    /// Port, then pid, for a stable order inside a group.
    static func byPort(_ a: Service, _ b: Service) -> Bool { (a.port, a.process.pid) < (b.port, b.process.pid) }

    /// Which group a (non-pinned) service lands in.
    public static func group(of s: Service) -> Group {
        if s.isNoise || s.kind == .system { return .system }
        if s.isManaged { return .managed }
        switch s.kind {
        case .devServer: return .projects
        case .infra, .docker: return .infra
        case .other: return .other
        case .system: return .system
        }
    }

    /// Pinned → Managed → Projects → Infra → Other → System. Empty groups are dropped; System only with `showNoise`.
    /// Pinned services leave their natural group. Pinned order = config.pins order; others ordered by port.
    public static func sections(_ services: [Service], config: PierConfig, showNoise: Bool,
                                crashed: [ManagedManifest] = []) -> [Section] {
        var visible = services
        if !showNoise { visible.removeAll { group(of: $0) == .system } }

        var out: [Section] = []
        let pinOrder = Dictionary(config.pins.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let pinned = visible.filter { pinOrder[$0.stableKey] != nil }
            .sorted { a, b in
                let (ia, ib) = (pinOrder[a.stableKey]!, pinOrder[b.stableKey]!)
                return ia != ib ? ia < ib : byPort(a, b)
            }
        let pinnedIDs = Set(pinned.map(\.id))
        out.append(Section(group: .pinned, services: pinned))

        let rest = visible.filter { !pinnedIDs.contains($0.id) }
        for g in Group.allCases where g != .pinned {
            let items = rest.filter { group(of: $0) == g }.sorted(by: byPort)
            out.append(Section(group: g, services: items, crashed: g == .managed ? crashed : []))
        }
        return out.filter { !$0.isEmpty }
    }

    /// Services in on-screen order (for keyboard navigation). Collapsed sections are skipped.
    public static func navigationOrder(_ sections: [Section], collapsed: Set<Group>) -> [Service] {
        sections.filter { !collapsed.contains($0.group) }.flatMap(\.services)
    }

    // MARK: - Filtering

    /// Fields searched for a service (renamed name first).
    static func searchFields(_ s: Service, config: PierConfig) -> [String] {
        var f: [String] = []
        if let r = config.renames[s.stableKey], !r.isEmpty { f.append(r) }
        f.append(contentsOf: Matcher.fields(of: s))
        if let b = s.gitBranch { f.append(b) }
        if let d = s.docker { f.append(d.containerName); if let c = d.composeService { f.append(c) } }
        return f
    }

    /// Fuzzy filter, best match first (ties by port). Empty query returns nil (= no filtering).
    /// A numeric query matches ports by prefix too ("30" finds :3000, :3001).
    public static func filter(_ services: [Service], query: String, config: PierConfig) -> [Service]? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        let isNumber = q.allSatisfy(\.isNumber)
        var scored: [(Service, Int)] = []
        for s in services {
            var best = searchFields(s, config: config).map { Matcher.score(q, $0.lowercased()) }.max() ?? 0
            if isNumber {
                let p = String(s.port)
                if p == q { best = max(best, Matcher.portScore) }
                else if p.hasPrefix(q) { best = max(best, Matcher.prefix) }
            }
            if best > 0 { scored.append((s, best)) }
        }
        return scored.sorted { a, b in
            a.1 != b.1 ? a.1 > b.1 : byPort(a.0, b.0)
        }.map(\.0)
    }

    // MARK: - Row presentation

    public enum Badge: String, Sendable, Equatable, CaseIterable {
        case lan = "LAN", managed = "managed", tunnel = "tunnel"
    }

    public static func badges(_ s: Service) -> [Badge] {
        var b: [Badge] = []
        if s.bindScope != .loopback { b.append(.lan) }
        if s.isManaged { b.append(.managed) }
        if s.tunnelURL != nil { b.append(.tunnel) }
        return b
    }

    /// "project · framework · :port · branch" (compact tier). Parts equal to the title or missing are dropped.
    public static func secondaryLine(_ s: Service, title: String? = nil) -> String {
        let title = (title ?? s.displayName).lowercased()
        var parts: [String] = []
        func add(_ p: String?) {
            guard let p, !p.isEmpty, p.lowercased() != title, !parts.contains(p) else { return }
            parts.append(p)
        }
        add(s.projectName)
        if let d = s.docker { add(d.composeService ?? d.containerName) }
        add(s.framework?.name)
        if s.framework == nil { add(s.infraName) }
        parts.append(":\(s.port)")
        add(s.gitBranch)
        if !s.process.isAccessible && s.projectName == nil { parts.insert("limited info", at: 0) }
        return parts.joined(separator: " · ")
    }

    public static func health(_ s: Service) -> Health { s.probe?.health ?? .unknown }

    public enum Glyph: Equatable, Sendable {
        case symbol(String)
        case letter(String)
    }

    /// Fallback icon when there's no favicon: SF symbol for infra/docker/system, framework letter otherwise.
    public static func fallbackGlyph(_ s: Service) -> Glyph {
        if let infra = s.infraName?.lowercased() {
            if infra.contains("postgres") || infra.contains("mysql") || infra.contains("maria") || infra.contains("mongo")
                || infra.contains("sql") || infra.contains("supabase") { return .symbol("cylinder.split.1x2") }
            if infra.contains("redis") || infra.contains("memcache") || infra.contains("valkey") { return .symbol("memorychip") }
            if infra.contains("ollama") || infra.contains("llm") { return .symbol("sparkles") }
        }
        if s.docker != nil { return .symbol("shippingbox") }
        if s.kind == .system || s.isNoise { return .symbol("gearshape") }
        if let name = s.framework?.name ?? s.projectName ?? s.infraName, let c = name.first(where: { $0.isLetter || $0.isNumber }) {
            return .letter(String(c).uppercased())
        }
        if s.kind == .infra { return .symbol("server.rack") }
        return .symbol("network")
    }

    /// A row's rename-aware, ready-to-render data.
    public struct Row: Identifiable, Equatable, Sendable {
        public var service: Service
        public var title: String
        public var subtitle: String
        public var health: Health
        public var badges: [Badge]
        public var glyph: Glyph
        public var isPinned: Bool
        public var id: String { service.id }
    }

    public static func row(_ s: Service, config: PierConfig) -> Row {
        let title = displayName(s, config: config)
        return Row(service: s, title: title, subtitle: secondaryLine(s, title: title), health: health(s),
                   badges: badges(s), glyph: fallbackGlyph(s), isPinned: isPinned(s, config: config))
    }

    // MARK: - Menu bar

    public struct MenuBarState: Equatable, Sendable {
        public var count: Int
        /// Amber dot: a visible service answers 5xx, or a managed service crashed.
        public var warning: Bool
        public init(count: Int, warning: Bool) { self.count = count; self.warning = warning }
    }

    public static func menuBarState(_ services: [Service], managed: [ManagedManifest], showNoise: Bool) -> MenuBarState {
        let visible = showNoise ? services : services.filter { group(of: $0) != .system }
        let unhealthy = visible.contains { $0.probe?.health == .error }
        let crashed = managed.contains { $0.state == .crashed }
        // The count is the number of project rows (a project with several ports counts once).
        return MenuBarState(count: projects(visible, managed: managed, config: PierConfig()).count, warning: unhealthy || crashed)
    }

    // MARK: - Probe merge across refreshes

    /// Takes a cheap (unprobed) snapshot and re-attaches the probe results of the previous list by service id,
    /// then re-applies post-probe refinement. Services that were never probed keep `probe == nil`
    /// (see `needsProbe`). Noise discovered by refinement is dropped unless `showNoise`.
    public static func mergeProbes(previous: [Service], fresh: [Service], showNoise: Bool) -> [Service] {
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out = fresh
        for i in out.indices {
            // Cheap snapshots skip tunnel detection; keep the last known URL until the next full refresh.
            if out[i].tunnelURL == nil { out[i].tunnelURL = old[out[i].id]?.tunnelURL }
            if out[i].probe == nil, let p = old[out[i].id]?.probe {
                out[i].probe = p
                Identifier.refine(&out[i])
            }
        }
        if !showNoise { out.removeAll(where: \.isNoise) }
        return out.sorted(by: byPort)
    }

    /// Services that still need an HTTP probe (never probed, plausibly HTTP, not noise).
    public static func needsProbe(_ s: Service) -> Bool {
        s.probe == nil && !s.isNoise && !Identifier.isKnownNonHTTP(s)
    }

    /// Applies an out-of-band probe result to the matching service (by id) and refines it.
    public static func applyProbe(_ result: ProbeResult, toID id: String, in services: inout [Service], showNoise: Bool) {
        guard let i = services.firstIndex(where: { $0.id == id }) else { return }
        services[i].probe = result
        Identifier.refine(&services[i])
        if !showNoise, services[i].isNoise { services.remove(at: i) }
    }

    // MARK: - Transitions

    public enum Event: Equatable, Sendable {
        case managedCrashed(ManagedManifest)
        case newService(Service)
    }

    /// Identity used to decide "is this a new service": survives a restart (new pid, same port + project).
    static func appearanceKey(_ s: Service) -> String { "\(s.port)|\(s.stableKey)" }

    /// Compares two refreshes. Managed crash = state flipped to `.crashed`; new service = port/project not in the
    /// previous list. Both lists are "what the user can see", so noise being toggled doesn't fire events
    /// as long as callers filter consistently.
    public static func transitions(previousServices: [Service], currentServices: [Service],
                                   previousManaged: [ManagedManifest], currentManaged: [ManagedManifest]) -> [Event] {
        var events: [Event] = []
        let oldState = Dictionary(previousManaged.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        for m in currentManaged where m.state == .crashed && oldState[m.id] != .crashed {
            events.append(.managedCrashed(m))
        }
        let known = Set(previousServices.map(appearanceKey))
        for s in currentServices where !s.isNoise && !known.contains(appearanceKey(s)) {
            events.append(.newService(s))
        }
        return events
    }

    // MARK: - Config helpers

    public static func togglePin(_ s: Service, in config: inout PierConfig) {
        if let i = config.pins.firstIndex(of: s.stableKey) { config.pins.remove(at: i) }
        else { config.pins.append(s.stableKey) }
    }

    /// Empty / whitespace-only name (or one equal to the auto name) removes the rename.
    public static func setRename(_ name: String, for s: Service, in config: inout PierConfig) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == s.displayName { config.renames.removeValue(forKey: s.stableKey) }
        else { config.renames[s.stableKey] = t }
    }

    // MARK: - Detail

    /// Footer text: "5 projects · refreshed 3s ago" (`unit` "service" by default).
    public static func footer(count: Int, unit: String = "service", refreshedAt: Date?, now: Date = Date()) -> String {
        let n = "\(count) \(unit)\(count == 1 ? "" : "s")"
        guard let t = refreshedAt else { return n }
        let secs = max(0, Int(now.timeIntervalSince(t)))
        return "\(n) · refreshed \(secs < 2 ? "just now" : Format.duration(Double(secs)) + " ago")"
    }
}
