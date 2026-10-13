import Foundation

/// Project grouping for the menu bar list: services that share a project folder (or a managed stack) collapse into one
/// row. Pure logic only (no UI, no I/O) so it is unit-testable.
extension AppModel {

    // MARK: - Model

    /// One row of the list: either a single service, or several services of the same project / stack.
    public struct Project: Identifiable, Equatable, Sendable {
        /// Service id for a single-service row (keeps selection stable), "g:<key>" for a group.
        public var id: String
        /// Grouping key ("project:<path>", "stack:<name>") or the service id for individual rows.
        public var key: String
        /// Members ordered by port.
        public var services: [Service]
        /// The member whose title / favicon / URL represents the group.
        public var main: Service
        public var title: String
        /// Single row: the usual "project · framework · :port · branch". Group: "project · framework" (the view
        /// draws the port chips itself, see `portChips`).
        public var subtitle: String
        /// Worst health across members.
        public var health: Health
        public var badges: [Badge]
        public var glyph: Glyph
        public var isPinned: Bool
        /// Lowest index in `config.pins` among the members (nil when not pinned).
        public var pinIndex: Int?
        public var ports: [UInt16]

        public var isGroup: Bool { services.count > 1 }
        public var lowestPort: UInt16 { ports.first ?? 0 }
    }

    // MARK: - Grouping

    /// Only dev-ish services with a project folder (or a stack) group; infra, Docker proxies, system noise and
    /// anything without a project stay individual rows.
    static func isGroupable(_ s: Service) -> Bool {
        !s.isNoise && s.docker == nil && s.kind != .system && s.kind != .infra
    }

    /// Group key for a service, nil = individual row. A managed stack wins over the project path.
    public static func groupKey(_ s: Service, managed: [String: ManagedManifest] = [:]) -> String? {
        guard isGroupable(s) else { return nil }
        if let id = s.managedID, let stack = managed[id]?.stack, !stack.isEmpty { return "stack:\(stack)" }
        if let p = s.projectPath, !p.isEmpty { return "project:\(p)" }
        return nil
    }

    /// The member that represents the group: has a page title and answers, is HTTP, lowest port.
    public static func mainService(of members: [Service]) -> Service {
        func rank(_ s: Service) -> (Int, Int, UInt16, Int32) {
            let titled = (s.probe?.title?.isEmpty == false && s.probe?.health != .timeout) ? 0 : 1
            let web = (s.probe?.protocolKind == .http || s.probe?.protocolKind == .https) ? 0 : 1
            return (titled, web, s.port, s.process.pid)
        }
        return members.min { rank($0) < rank($1) } ?? members[0]
    }

    static func healthRank(_ h: Health) -> Int {
        switch h { case .error: 3; case .timeout: 2; case .ok: 1; case .unknown: 0 }
    }

    /// error > timeout > ok > unknown.
    public static func worstHealth(_ services: [Service]) -> Health {
        services.map(health).max { healthRank($0) < healthRank($1) } ?? .unknown
    }

    /// Union of member badges in canonical order.
    public static func badgeUnion(_ services: [Service]) -> [Badge] {
        let all = Set(services.flatMap(badges))
        return Badge.allCases.filter(all.contains)
    }

    /// First `max` ports plus how many more there are: [4200, 4201, 4202] + 2 -> ":4200 :4201 :4202 +2".
    public static func portChips(_ ports: [UInt16], max: Int = 3) -> (shown: [UInt16], overflow: Int) {
        let max = Swift.max(1, max)
        return (Array(ports.prefix(max)), Swift.max(0, ports.count - max))
    }

    /// Text form of `portChips` (accessibility labels, tests).
    public static func portChipsText(_ ports: [UInt16], max: Int = 3) -> String {
        let (shown, more) = portChips(ports, max: max)
        return (shown.map { ":\($0)" } + (more > 0 ? ["+\(more)"] : [])).joined(separator: " ")
    }

    /// Builds one project per group key / individual service. Order: lowest member port.
    public static func projects(_ services: [Service], managed: [ManagedManifest] = [], config: PierConfig) -> [Project] {
        let byID = Dictionary(managed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var order: [String] = []
        var buckets: [String: [Service]] = [:]
        for s in services {
            let k = groupKey(s, managed: byID) ?? s.id
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(s)
        }
        let pinOrder = Dictionary(config.pins.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let out = order.map { k in
            makeProject(key: k, members: buckets[k]!, stackName: k.hasPrefix("stack:") ? String(k.dropFirst(6)) : nil,
                        config: config, pinOrder: pinOrder)
        }
        return out.sorted { ($0.lowestPort, $0.id) < ($1.lowestPort, $1.id) }
    }

    static func makeProject(key: String, members raw: [Service], stackName: String?, config: PierConfig,
                            pinOrder: [String: Int]) -> Project {
        let members = raw.sorted(by: byPort)
        let main = mainService(of: members)
        let pinIdx = members.compactMap { pinOrder[$0.stableKey] }.min()
        if members.count == 1 {
            let r = row(main, config: config)
            return Project(id: main.id, key: key, services: members, main: main, title: r.title, subtitle: r.subtitle,
                           health: r.health, badges: r.badges, glyph: r.glyph, isPinned: r.isPinned,
                           pinIndex: pinIdx, ports: [main.port])
        }
        // Group title: user rename (main first) > page title of the main port > project name. Stacks use the stack name.
        let ordered = [main] + members.filter { $0.id != main.id }
        let rename = ordered.lazy.compactMap { config.renames[$0.stableKey]?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        let base = stackName ?? main.projectName ?? members.lazy.compactMap(\.projectName).first
            ?? main.projectPath.map { ($0 as NSString).lastPathComponent } ?? main.process.name
        let pageTitle = main.probe?.title.flatMap { $0.isEmpty ? nil : $0 }
        // A stack is named by its pier.yml name (its services' page titles are usually generic).
        let title = rename ?? (stackName != nil ? nil : pageTitle) ?? base

        var parts: [String] = []
        func add(_ p: String?) {
            guard let p, !p.isEmpty, p.lowercased() != title.lowercased(), !parts.contains(p) else { return }
            parts.append(p)
        }
        add(base)
        add(main.framework?.name ?? members.lazy.compactMap { $0.framework?.name }.first)
        add(main.gitBranch)

        return Project(id: "g:" + key, key: key, services: members, main: main, title: title,
                       subtitle: parts.joined(separator: " · "), health: worstHealth(members),
                       badges: badgeUnion(members), glyph: fallbackGlyph(main), isPinned: pinIdx != nil,
                       pinIndex: pinIdx, ports: members.map(\.port))
    }

    // MARK: - Sections of projects

    public struct ProjectSection: Identifiable, Equatable, Sendable {
        public var group: Group
        public var projects: [Project]
        public var crashed: [ManagedManifest] = []
        public var id: String { group.rawValue }
        public var isEmpty: Bool { projects.isEmpty && crashed.isEmpty }
        public var count: Int { projects.count + crashed.count }
    }

    /// Section a project lands in (pinned handled by the caller): the "highest" group among its members.
    static func group(of p: Project) -> Group {
        p.services.map(group(of:)).min { (Group.allCases.firstIndex(of: $0) ?? 0) < (Group.allCases.firstIndex(of: $1) ?? 0) } ?? .other
    }

    /// Same section order as `sections`, but rows are projects. Pinned order = config.pins order.
    public static func projectSections(_ services: [Service], managed: [ManagedManifest] = [], config: PierConfig,
                                       showNoise: Bool, crashed: [ManagedManifest] = []) -> [ProjectSection] {
        var visible = services
        if !showNoise { visible.removeAll { group(of: $0) == .system } }
        let all = projects(visible, managed: managed, config: config)
        let pinned = all.filter(\.isPinned).sorted { ($0.pinIndex ?? 0, $0.lowestPort) < ($1.pinIndex ?? 0, $1.lowestPort) }
        let pinnedIDs = Set(pinned.map(\.id))
        var out = [ProjectSection(group: .pinned, projects: pinned)]
        let rest = all.filter { !pinnedIDs.contains($0.id) }
        for g in Group.allCases where g != .pinned {
            out.append(ProjectSection(group: g, projects: rest.filter { group(of: $0) == g },
                                      crashed: g == .managed ? crashed : []))
        }
        return out.filter { !$0.isEmpty }
    }

    /// Search results as projects: only the matching services are grouped (so "4201" finds a single ":4201" row),
    /// ordered by best match.
    public static func filterProjects(_ services: [Service], managed: [ManagedManifest] = [], query: String,
                                      config: PierConfig) -> [Project]? {
        guard let matches = filter(services, query: query, config: config) else { return nil }
        let byID = Dictionary(managed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var order: [String] = []
        var buckets: [String: [Service]] = [:]
        for s in matches {   // already best-first
            let k = groupKey(s, managed: byID) ?? s.id
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(s)
        }
        let pinOrder = Dictionary(config.pins.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return order.map { k in
            makeProject(key: k, members: buckets[k]!, stackName: k.hasPrefix("stack:") ? String(k.dropFirst(6)) : nil,
                        config: config, pinOrder: pinOrder)
        }
    }

    /// Selectable ids in on-screen order: project rows, followed by their member rows when expanded.
    public static func navigationIDs(_ sections: [ProjectSection], collapsed: Set<Group>, expanded: Set<String>) -> [String] {
        sections.filter { !collapsed.contains($0.group) }.flatMap(\.projects).flatMap { navigationIDs(of: $0, expanded: expanded) }
    }

    public static func navigationIDs(of p: Project, expanded: Set<String>) -> [String] {
        p.isGroup && expanded.contains(p.id) ? [p.id] + p.services.map(\.id) : [p.id]
    }

    /// Row ids of a member service -> its project id (for collapsing from a sub-row).
    public static func project(containing serviceID: String, in projects: [Project]) -> Project? {
        projects.first { $0.id == serviceID || $0.services.contains { $0.id == serviceID } }
    }

    // MARK: - Pins for projects

    /// Pins the main service key, or removes every member key when any is pinned.
    public static func togglePin(_ p: Project, in config: inout PierConfig) {
        let keys = Set(p.services.map(\.stableKey))
        if config.pins.contains(where: keys.contains) { config.pins.removeAll(where: keys.contains) }
        else { config.pins.append(p.main.stableKey) }
    }

    // MARK: - Stats (hover line)

    /// "up 3d · 0.4% CPU · 142 MB": oldest start, CPU and RSS summed over distinct pids.
    public static func statsLine(_ services: [Service], now: Date = Date()) -> String {
        var parts: [String] = []
        if let start = services.compactMap({ $0.process.startTime }).min() {
            parts.append("up " + Format.duration(now.timeIntervalSince(start)))
        }
        var seen = Set<Int32>()
        var cpu = 0.0, haveCPU = false, rss: UInt64 = 0, haveRSS = false
        for s in services where seen.insert(s.process.pid).inserted {
            if let c = s.process.cpuPercent { cpu += c; haveCPU = true }
            if let r = s.process.rssBytes { rss += r; haveRSS = true }
        }
        if haveCPU { parts.append(String(format: "%.1f%% CPU", cpu)) }
        if haveRSS { parts.append(Format.bytes(rss)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Staleness

    /// Service id -> uptime (seconds) of every service `Staleness.evaluate` considers stale (>=3d, idle) with the same
    /// defaults as `pier stale`. Connections are not counted here (cheap enough to run on every refresh).
    public static func staleAges(_ services: [Service], now: Date = Date()) -> [String: TimeInterval] {
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [String: TimeInterval] = [:]
        for s in services where s.process.pid > 1 && s.process.pid != me {
            guard Staleness.evaluate(s, now: now) != nil, let start = s.process.startTime else { continue }
            out[s.id] = now.timeIntervalSince(start)
        }
        return out
    }

    /// "idle 11d" when every member is stale (the group row shows the youngest age), else nil.
    public static func staleLabel(_ p: Project, ages: [String: TimeInterval]) -> String? {
        let mine = p.services.compactMap { ages[$0.id] }
        guard mine.count == p.services.count, let youngest = mine.min() else { return nil }
        return "idle " + Format.duration(youngest)
    }

    public static func staleLabel(_ s: Service, ages: [String: TimeInterval]) -> String? {
        ages[s.id].map { "idle " + Format.duration($0) }
    }

    // MARK: - Member rows (expanded group)

    /// Title of a member row: its own page title, else framework, else process name.
    public static func memberTitle(_ s: Service) -> String {
        if let t = s.probe?.title, !t.isEmpty { return t }
        if let f = s.framework?.name { return f }
        if let i = s.infraName { return i }
        return s.process.name
    }

    /// Subtitle of a member row (the port is shown as its own chip): framework, runtime, branch.
    public static func memberSubtitle(_ s: Service) -> String {
        let title = memberTitle(s).lowercased()
        var parts: [String] = []
        for p in [s.framework?.name, s.runtime, s.gitBranch] {
            guard let p, !p.isEmpty, p.lowercased() != title, !parts.contains(p) else { continue }
            parts.append(p)
        }
        if parts.isEmpty, s.process.name.lowercased() != title { parts.append(s.process.name) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Stacks

    public struct StackStatus: Identifiable, Equatable, Sendable {
        public var stack: KnownStack
        /// Live managed services of this stack (starting / running / restarting).
        public var running: Int
        /// Services declared in the yml; nil when the file could not be parsed.
        public var total: Int?
        public var id: String { stack.file }
        /// "2/3 running", "stopped" (nothing running), "3 services" etc.
        public var summary: String {
            switch (running, total) {
            case (0, let t?): return "stopped · \(t) service\(t == 1 ? "" : "s")"
            case (0, nil): return "stopped"
            case (let r, let t?): return "\(r)/\(t) running"
            case (let r, nil): return "\(r) running"
            }
        }
    }

    public static func stackStatuses(known: [KnownStack], totals: [String: Int], managed: [ManagedManifest]) -> [StackStatus] {
        known.map { k in
            let running = managed.filter { $0.stack == k.name && ($0.state == .running || $0.state == .starting || $0.state == .restarting) }.count
            return StackStatus(stack: k, running: running, total: totals[k.file])
        }
    }

    // MARK: - Recent run folders

    /// Most-recent-first, de-duplicated, capped.
    public static func pushRecent(_ path: String, into list: [String], limit: Int = 5) -> [String] {
        var out = list.filter { $0 != path }
        out.insert(path, at: 0)
        return Array(out.prefix(limit))
    }
}
