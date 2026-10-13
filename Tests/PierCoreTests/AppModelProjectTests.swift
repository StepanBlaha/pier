import XCTest
@testable import PierCore

final class AppModelProjectTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func svc(_ port: UInt16, project: String? = nil, path: String? = nil, kind: ServiceKind = .devServer,
             title: String? = nil, health: Health? = nil, framework: String? = nil, infra: String? = nil,
             managedID: String? = nil, scope: BindScope = .loopback, noise: Bool = false,
             pid: Int32? = nil, startedAgo: TimeInterval? = nil, cpu: Double? = nil, rss: UInt64? = nil) -> Service {
        var proc = ProcInfo(pid: pid ?? Int32(port), ppid: 1, uid: 501, name: "node",
                            startTime: startedAgo.map { now.addingTimeInterval(-$0) }, cpuPercent: cpu, rssBytes: rss)
        proc.cwd = path
        var s = Service(port: port, process: proc, addresses: ["127.0.0.1"], bindScope: scope)
        s.kind = kind
        s.projectName = project
        s.projectPath = path ?? project.map { "/dev/\($0)" }
        s.framework = framework.map { Framework(id: $0.lowercased(), name: $0) }
        s.infraName = infra
        s.isNoise = noise
        s.isManaged = managedID != nil
        s.managedID = managedID
        if title != nil || health != nil { s.probe = ProbeResult(protocolKind: .http, health: health ?? .ok, title: title) }
        return s
    }

    func codexRouter() -> [Service] {
        [svc(4200, project: "codex-router", title: "Codex Router Dashboard", health: .ok),
         svc(4201, project: "codex-router"), svc(4202, project: "codex-router"),
         svc(4203, project: "codex-router"), svc(4208, project: "codex-router", scope: .all)]
    }

    // MARK: grouping

    func testGroupsByProjectPath() {
        let services = codexRouter() + [svc(3000, project: "other")]
        let ps = AppModel.projects(services, config: PierConfig())
        XCTAssertEqual(ps.count, 2)
        let g = ps.first { $0.isGroup }!
        XCTAssertEqual(g.ports, [4200, 4201, 4202, 4203, 4208])
        XCTAssertEqual(g.id, "g:project:/dev/codex-router")
        XCTAssertEqual(ps.first { !$0.isGroup }!.id, services.last!.id, "single rows keep the service id")
    }

    func testDockerInfraAndNoiseStayIndividual() {
        var dockerA = svc(8080, path: "/dev/x", kind: .docker)
        dockerA.docker = DockerInfo(containerID: "a", containerName: "a", image: "i", containerPort: 80)
        var dockerB = svc(8081, path: "/dev/x", kind: .docker)
        dockerB.docker = DockerInfo(containerID: "b", containerName: "b", image: "i", containerPort: 80)
        let pg1 = svc(5432, kind: .infra, infra: "PostgreSQL"), pg2 = svc(5433, kind: .infra, infra: "PostgreSQL")
        let infraWithPath1 = svc(6379, project: "p", kind: .infra, infra: "Redis"), infraWithPath2 = svc(6380, project: "p", kind: .infra, infra: "Redis")
        let n1 = svc(5000, project: "q", kind: .system, noise: true), n2 = svc(7000, project: "q", kind: .system, noise: true)
        let ps = AppModel.projects([dockerA, dockerB, pg1, pg2, infraWithPath1, infraWithPath2, n1, n2], config: PierConfig())
        XCTAssertEqual(ps.count, 8)
        XCTAssertTrue(ps.allSatisfy { !$0.isGroup })
    }

    func testStackGroupsAcrossFolders() {
        let a = svc(3000, project: "web", title: "Directory listing for /", managedID: "m1"), b = svc(8000, project: "api", managedID: "m2")
        let c = svc(9000, project: "solo", managedID: "m3")
        let manifests = [
            ManagedManifest(id: "m1", name: "shop/web", wrapperPid: 1, childPid: 2, command: ["x"], cwd: "/", stack: "shop"),
            ManagedManifest(id: "m2", name: "shop/api", wrapperPid: 1, childPid: 2, command: ["x"], cwd: "/", stack: "shop"),
            ManagedManifest(id: "m3", name: "solo", wrapperPid: 1, childPid: 2, command: ["x"], cwd: "/"),
        ]
        let ps = AppModel.projects([a, b, c], managed: manifests, config: PierConfig())
        XCTAssertEqual(ps.count, 2)
        let g = ps.first { $0.isGroup }!
        XCTAssertEqual(g.id, "g:stack:shop")
        XCTAssertEqual(g.title, "shop")
        XCTAssertEqual(g.ports, [3000, 8000])
        XCTAssertEqual(g.badges, [.managed])
    }

    func testOrderingByLowestPort() {
        let ps = AppModel.projects([svc(5000, project: "b"), svc(3001, project: "a"), svc(3000, project: "a"), svc(4000, project: "c")],
                                   config: PierConfig())
        XCTAssertEqual(ps.map(\.lowestPort), [3000, 4000, 5000])
        XCTAssertEqual(ps.first!.ports, [3000, 3001], "members ordered by port")
    }

    // MARK: naming

    func testGroupTitlePrecedence() {
        // page title of the main port wins over the project name
        var ps = AppModel.projects(codexRouter(), config: PierConfig())
        XCTAssertEqual(ps[0].title, "Codex Router Dashboard")
        XCTAssertEqual(ps[0].main.port, 4200)
        // no titles at all: project name
        ps = AppModel.projects([svc(4201, project: "codex-router"), svc(4202, project: "codex-router")], config: PierConfig())
        XCTAssertEqual(ps[0].title, "codex-router")
        // a rename beats everything
        var cfg = PierConfig()
        cfg.renames["project:/dev/codex-router"] = "Router"
        ps = AppModel.projects(codexRouter(), config: cfg)
        XCTAssertEqual(ps[0].title, "Router")
        XCTAssertTrue(AppModel.projects(codexRouter(), config: cfg)[0].isGroup)
    }

    func testMainPrefersTitledHTTPThenLowestPort() {
        let a = svc(4300, project: "p"), b = svc(4301, project: "p", title: "Hello"), c = svc(4302, project: "p", title: "Later")
        XCTAssertEqual(AppModel.mainService(of: [a, b, c]).port, 4301)
        XCTAssertEqual(AppModel.mainService(of: [c, a]).port, 4302)
        XCTAssertEqual(AppModel.mainService(of: [svc(9, project: "p"), svc(7, project: "p")]).port, 7)
    }

    func testGroupSubtitleDropsTitleDuplicates() {
        let ps = AppModel.projects([svc(4200, project: "codex-router", title: "codex-router", framework: "Next.js"),
                                    svc(4201, project: "codex-router")], config: PierConfig())
        XCTAssertEqual(ps[0].subtitle, "Next.js")
    }

    // MARK: aggregate

    func testWorstHealth() {
        func h(_ hs: [Health?]) -> Health {
            AppModel.worstHealth(hs.enumerated().map { svc(UInt16(3000 + $0), project: "p", health: $1) })
        }
        XCTAssertEqual(h([.ok, .ok]), .ok)
        XCTAssertEqual(h([.ok, .error, .timeout]), .error)
        XCTAssertEqual(h([.ok, .timeout]), .timeout)
        XCTAssertEqual(h([nil, .ok]), .ok, "unknown never beats ok")
        XCTAssertEqual(h([nil, nil]), .unknown)
        let ps = AppModel.projects([svc(1, project: "p", health: .ok), svc(2, project: "p", health: .error)], config: PierConfig())
        XCTAssertEqual(ps[0].health, .error)
    }

    func testBadgeUnionIsOrderedAndDeduplicated() {
        var a = svc(3000, project: "p", managedID: "x")
        a.tunnelURL = "https://t"
        let b = svc(3001, project: "p", managedID: "y", scope: .all)
        XCTAssertEqual(AppModel.badgeUnion([a, b]), [.lan, .managed, .tunnel])
        XCTAssertEqual(AppModel.badgeUnion([svc(1, project: "q")]), [])
    }

    func testPortChipOverflow() {
        XCTAssertEqual(AppModel.portChips([4200, 4201]).overflow, 0)
        let c = AppModel.portChips([4200, 4201, 4202, 4203, 4208])
        XCTAssertEqual(c.shown, [4200, 4201, 4202])
        XCTAssertEqual(c.overflow, 2)
        XCTAssertEqual(AppModel.portChipsText([4200, 4201, 4202, 4203, 4208]), ":4200 :4201 :4202 +2")
        XCTAssertEqual(AppModel.portChipsText([4200, 4201, 4202]), ":4200 :4201 :4202")
        XCTAssertEqual(AppModel.portChipsText([1, 2, 3, 4], max: 2), ":1 :2 +2")
        XCTAssertEqual(AppModel.portChipsText([], max: 3), "")
    }

    // MARK: menu bar count

    func testMenuBarCountsProjectsNotPorts() {
        let services = codexRouter() + [svc(3000, project: "other"), svc(5000, kind: .system, noise: true)]
        XCTAssertEqual(AppModel.menuBarState(services, managed: [], showNoise: false).count, 2)
        XCTAssertEqual(AppModel.menuBarState(services, managed: [], showNoise: true).count, 3)
        XCTAssertEqual(AppModel.menuBarState(codexRouter(), managed: [], showNoise: false).count, 1)
    }

    func testMenuBarWarningStillSeesErrorsInsideGroups() {
        let s = [svc(4200, project: "x", health: .ok), svc(4201, project: "x", health: .error)]
        XCTAssertTrue(AppModel.menuBarState(s, managed: [], showNoise: false).warning)
    }

    func testFooterUnit() {
        XCTAssertEqual(AppModel.footer(count: 3, unit: "project", refreshedAt: nil), "3 projects")
        XCTAssertEqual(AppModel.footer(count: 1, unit: "project", refreshedAt: nil), "1 project")
    }

    // MARK: sections + navigation

    func testProjectSectionsAndPinned() {
        let pg = svc(5432, kind: .infra, infra: "PostgreSQL")
        let services = codexRouter() + [svc(3000, project: "other", managedID: "m"), pg]
        var cfg = PierConfig()
        let secs = AppModel.projectSections(services, config: cfg, showNoise: false)
        XCTAssertEqual(secs.map(\.group), [.managed, .projects, .infra])
        XCTAssertEqual(secs[1].projects.count, 1)
        XCTAssertTrue(secs[1].projects[0].isGroup)

        cfg.pins = ["project:/dev/codex-router"]
        let pinned = AppModel.projectSections(services, config: cfg, showNoise: false)
        XCTAssertEqual(pinned.map(\.group), [.pinned, .managed, .infra])
        XCTAssertEqual(pinned[0].projects.count, 1, "the whole group is pinned as one row")
        XCTAssertTrue(pinned[0].projects[0].isPinned)
    }

    func testNavigationIDsIncludeMembersOnlyWhenExpanded() {
        let services = codexRouter() + [svc(3000, project: "other")]
        let secs = AppModel.projectSections(services, config: PierConfig(), showNoise: false)
        let group = secs[0].projects.first { $0.isGroup }!
        let collapsed = AppModel.navigationIDs(secs, collapsed: [], expanded: [])
        XCTAssertEqual(collapsed.count, 2)
        XCTAssertTrue(collapsed.contains(group.id))
        let open = AppModel.navigationIDs(secs, collapsed: [], expanded: [group.id])
        XCTAssertEqual(open.count, 7)
        XCTAssertEqual(Array(open.dropFirst().prefix(2)), [group.id, "4200-4200"], "members follow their group row")
        XCTAssertEqual(AppModel.project(containing: "4202-4202", in: secs[0].projects)?.id, group.id)
    }

    func testFilterGroupsOnlyMatchingMembers() {
        let services = codexRouter() + [svc(3000, project: "other")]
        // a port query finds one member: it shows as a single row
        let byPort = AppModel.filterProjects(services, query: "4202", config: PierConfig())!
        XCTAssertEqual(byPort.count, 1)
        XCTAssertFalse(byPort[0].isGroup)
        XCTAssertEqual(byPort[0].main.port, 4202)
        // a project query keeps the group together
        let byName = AppModel.filterProjects(services, query: "codex", config: PierConfig())!
        XCTAssertEqual(byName.count, 1)
        XCTAssertEqual(byName[0].services.count, 5)
        XCTAssertNil(AppModel.filterProjects(services, query: "", config: PierConfig()))
    }

    func testTogglePinOnProject() {
        let g = AppModel.projects(codexRouter(), config: PierConfig())[0]
        var cfg = PierConfig()
        AppModel.togglePin(g, in: &cfg)
        XCTAssertEqual(cfg.pins, ["project:/dev/codex-router"])
        AppModel.togglePin(g, in: &cfg)
        XCTAssertEqual(cfg.pins, [])
    }

    // MARK: stats / stale

    func testStatsLineSumsDistinctPids() {
        let a = svc(3000, project: "p", pid: 10, startedAgo: 3 * 86_400, cpu: 0.4, rss: 100 * 1_048_576)
        let a2 = svc(3001, project: "p", pid: 10, startedAgo: 3 * 86_400, cpu: 0.4, rss: 100 * 1_048_576)   // same process
        let b = svc(3002, project: "p", pid: 11, startedAgo: 3600, cpu: 1.1, rss: 50 * 1_048_576)
        XCTAssertEqual(AppModel.statsLine([a], now: now), "up 3d · 0.4% CPU · 100 MB")
        XCTAssertEqual(AppModel.statsLine([a, a2, b], now: now), "up 3d · 1.5% CPU · 150 MB")
        XCTAssertEqual(AppModel.statsLine([svc(1, project: "p")], now: now), "")
    }

    func testStaleAgesAndLabels() {
        let old = svc(3000, project: "old", startedAgo: 11 * 86_400, cpu: 0)
        let young = svc(3001, project: "young", startedAgo: 86_400, cpu: 0)
        let busy = svc(3002, project: "busy", startedAgo: 11 * 86_400, cpu: 40)
        let db = svc(5432, kind: .infra, infra: "PostgreSQL", startedAgo: 30 * 86_400, cpu: 0)
        let ages = AppModel.staleAges([old, young, busy, db], now: now)
        XCTAssertEqual(Set(ages.keys), [old.id])
        XCTAssertEqual(AppModel.staleLabel(old, ages: ages), "idle 11d")
        XCTAssertNil(AppModel.staleLabel(young, ages: ages))

        // a group is stale only when every member is
        let g1 = svc(4200, project: "g", startedAgo: 12 * 86_400, cpu: 0), g2 = svc(4201, project: "g", startedAgo: 5 * 86_400, cpu: 0)
        let g3 = svc(4202, project: "g", startedAgo: 86_400, cpu: 0)
        let all = AppModel.staleAges([g1, g2, g3], now: now)
        XCTAssertNil(AppModel.staleLabel(AppModel.projects([g1, g2, g3], config: PierConfig())[0], ages: all))
        let two = AppModel.staleAges([g1, g2], now: now)
        XCTAssertEqual(AppModel.staleLabel(AppModel.projects([g1, g2], config: PierConfig())[0], ages: two), "idle 5d")
    }

    // MARK: member rows

    func testMemberTitles() {
        XCTAssertEqual(AppModel.memberTitle(svc(1, project: "p", title: "Dash")), "Dash")
        XCTAssertEqual(AppModel.memberTitle(svc(1, project: "p", framework: "Vite")), "Vite")
        XCTAssertEqual(AppModel.memberTitle(svc(1, project: "p")), "node")
        var s = svc(1, project: "p", framework: "Vite")
        s.gitBranch = "main"; s.runtime = "node 20"
        XCTAssertEqual(AppModel.memberSubtitle(s), "node 20 · main")
    }

    // MARK: stacks + recents

    func testStackStatuses() {
        let k1 = KnownStack(name: "shop", file: "/a/pier.yml"), k2 = KnownStack(name: "idle", file: "/b/pier.yml")
        func m(_ id: String, _ stack: String?, _ st: ManagedManifest.State) -> ManagedManifest {
            ManagedManifest(id: id, name: "\(stack ?? "x")/\(id)", wrapperPid: 1, childPid: 2, command: ["x"], cwd: "/", state: st, stack: stack)
        }
        let st = AppModel.stackStatuses(known: [k1, k2], totals: ["/a/pier.yml": 3],
                                        managed: [m("a", "shop", .running), m("b", "shop", .starting), m("c", "shop", .crashed), m("d", nil, .running)])
        XCTAssertEqual(st[0].running, 2)
        XCTAssertEqual(st[0].total, 3)
        XCTAssertEqual(st[0].summary, "2/3 running")
        XCTAssertEqual(st[1].running, 0)
        XCTAssertNil(st[1].total)
        XCTAssertEqual(st[1].summary, "stopped")
        XCTAssertEqual(AppModel.StackStatus(stack: k1, running: 0, total: 1).summary, "stopped · 1 service")
    }

    func testRecentFolders() {
        var r: [String] = []
        for p in ["/a", "/b", "/c", "/d", "/e", "/f"] { r = AppModel.pushRecent(p, into: r) }
        XCTAssertEqual(r, ["/f", "/e", "/d", "/c", "/b"])
        r = AppModel.pushRecent("/d", into: r)
        XCTAssertEqual(r, ["/d", "/f", "/e", "/c", "/b"])
    }
}
