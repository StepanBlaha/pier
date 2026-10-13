import XCTest
import Darwin
@testable import PierCore

private func svc(_ port: UInt16, pid: Int32 = 100, name: String = "node", title: String? = nil, project: String? = nil,
                 infra: String? = nil, framework: Framework? = nil, kind: ServiceKind = .devServer) -> Service {
    var s = Service(port: port, process: ProcInfo(pid: pid, ppid: 1, uid: 501, name: name), addresses: ["127.0.0.1"], bindScope: .loopback)
    s.projectName = project; s.infraName = infra; s.framework = framework; s.kind = kind
    if let title { s.probe = ProbeResult(title: title) }
    return s
}

final class ActionsMatcherTests: XCTestCase {
    let services = [
        svc(3000, pid: 1, project: "haf-pet", framework: Framework(id: "next", name: "Next.js")),
        svc(3001, pid: 2, project: "haf-pet-api", framework: Framework(id: "express", name: "Express")),
        svc(5432, pid: 3, name: "postgres", infra: "PostgreSQL", kind: .infra),
        svc(5173, pid: 4, project: "playdeck", framework: Framework(id: "vite", name: "Vite")),
    ]

    func testPortIsExact() {
        guard case .found(let f) = Matcher.resolve("5432", in: services) else { return XCTFail() }
        XCTAssertEqual(f.map(\.port), [5432])
    }

    func testSamePortMultiplePidsAllFound() {
        let dup = services + [svc(3000, pid: 99, project: "other")]
        guard case .found(let f) = Matcher.resolve("3000", in: dup) else { return XCTFail() }
        XCTAssertEqual(Set(f.map(\.process.pid)), [1, 99])
    }

    func testExactBeatsPrefix() {
        guard case .found(let f) = Matcher.resolve("haf-pet", in: services) else { return XCTFail("expected unique exact") }
        XCTAssertEqual(f.first?.port, 3000)
    }

    func testPrefixAmbiguous() {
        guard case .ambiguous(let c) = Matcher.resolve("haf", in: services) else { return XCTFail() }
        XCTAssertEqual(Set(c.map(\.port)), [3000, 3001])
    }

    func testCaseInsensitiveFieldsAndSubstring() {
        guard case .found(let f) = Matcher.resolve("POSTGRES", in: services) else { return XCTFail() }
        XCTAssertEqual(f.first?.port, 5432)
        guard case .found(let g) = Matcher.resolve("next", in: services) else { return XCTFail() }   // framework name/id
        XCTAssertEqual(g.first?.port, 3000)
        guard case .found(let h) = Matcher.resolve("deck", in: services) else { return XCTFail() }  // substring
        XCTAssertEqual(h.first?.port, 5173)
    }

    func testFuzzySubsequenceRanksLast() {
        let ranked = Matcher.rank("pdk", in: services)
        XCTAssertEqual(ranked.map(\.service.port), [5173])
        XCTAssertLessThan(ranked[0].score, Matcher.substring)
        XCTAssertTrue(Matcher.rank("zzz", in: services).isEmpty)
    }

    func testTitleMatches() {
        let s = [svc(3011, title: "Haf Pet | Dog grooming", project: "web")]
        guard case .found = Matcher.resolve("dog", in: s) else { return XCTFail() }
    }

    func testUnknownPortFallsBackToNone() {
        guard case .none = Matcher.resolve("9999", in: services) else { return XCTFail() }
    }
}

final class ActionsPortFinderTests: XCTestCase {
    func testFindsFreePortAndSkipsHeldOne() throws {
        let start = try XCTUnwrap(PortFinder.nextFree(from: 41000))
        XCTAssertTrue(PortFinder.isFree(start))

        // Hold `start` on 127.0.0.1 and expect the finder to move on.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = start.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &a.sin_addr)
        let rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(rc, 0)
        XCTAssertEqual(listen(fd, 1), 0)

        XCTAssertFalse(PortFinder.isFree(start))
        let next = try XCTUnwrap(PortFinder.nextFree(from: start))
        XCTAssertGreaterThan(next, start)
        XCTAssertTrue(PortFinder.isFree(next))
    }
}

final class ActionsQRTests: XCTestCase {
    func testMatrixDimensions() throws {
        let m = try XCTUnwrap(QR.matrix(for: "http://192.168.1.23:3000"))
        XCTAssertTrue((21...57).contains(m.size), "size \(m.size)")
        XCTAssertEqual((m.size - 21) % 4, 0)
        XCTAssertEqual(m.modules.count, m.size * m.size)
    }

    func testFinderPatternsInThreeCorners() throws {
        let m = try XCTUnwrap(QR.matrix(for: "http://192.168.1.23:3000"))
        func finder(_ ox: Int, _ oy: Int) -> Bool {
            for y in 0..<7 { for x in 0..<7 {
                let ring = x == 0 || y == 0 || x == 6 || y == 6
                let core = (2...4).contains(x) && (2...4).contains(y)
                if m.isDark(x: ox + x, y: oy + y) != (ring || core) { return false }
            } }
            return true
        }
        XCTAssertTrue(finder(0, 0) && finder(m.size - 7, 0) && finder(0, m.size - 7), "wrong orientation")
        XCTAssertFalse(m.isDark(x: -1, y: -1))
    }

    func testLoopbackRefusedWithFrameworkHint() {
        var s = svc(3000, framework: Framework(id: "next", name: "Next.js"))
        XCTAssertThrowsError(try QR.lanURL(for: s)) {
            XCTAssertTrue($0.localizedDescription.contains("next dev -H 0.0.0.0"))
        }
        s.bindScope = .all; s.lanURL = "http://192.168.1.5:3000"
        XCTAssertEqual(try QR.lanURL(for: s), "http://192.168.1.5:3000")
    }
}

final class ActionsKillerTests: XCTestCase {
    func testRefusesPid1AndSelf() async {
        XCTAssertThrowsError(try Killer.validate(pid: 1))
        XCTAssertThrowsError(try Killer.validate(pid: 0))
        XCTAssertThrowsError(try Killer.validate(pid: -5))
        XCTAssertThrowsError(try Killer.validate(pid: ProcessInfo.processInfo.processIdentifier))
        do {
            _ = try await Killer.terminate(pid: 1)
            XCTFail("should refuse")
        } catch { XCTAssertEqual(error as? Killer.Refusal, .protectedPID(1)) }
    }

    func testConfirmationRules() {
        XCTAssertFalse(Killer.requiresConfirmation(svc(3000, project: "x", kind: .devServer)))
        XCTAssertTrue(Killer.requiresConfirmation(svc(5432, infra: "PostgreSQL", kind: .infra)))
        XCTAssertTrue(Killer.requiresConfirmation(svc(5000, kind: .system)))
        XCTAssertTrue(Killer.requiresConfirmation(svc(8000, kind: .other)))
        var other = svc(8000, kind: .other); other.projectPath = "/tmp/x"
        XCTAssertFalse(Killer.requiresConfirmation(other))
    }

    func testTerminatesChildProcess() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["60"]
        try p.run()
        let pid = p.processIdentifier
        let outcome = try await Killer.terminate(pid: pid, grace: 3)
        XCTAssertEqual(outcome, .terminated)
        XCTAssertFalse(Killer.isAlive(pid))
        p.waitUntilExit()  // reap the zombie so the pid is really gone (slow CI runners)
        let again = try await Killer.terminate(pid: pid)
        XCTAssertEqual(again, .alreadyGone)
    }
}

final class ActionsFormatTests: XCTestCase {
    func testDuration() {
        XCTAssertEqual(Format.duration(5), "5s")
        XCTAssertEqual(Format.duration(180), "3m")
        XCTAssertEqual(Format.duration(7200 + 59), "2h")
        XCTAssertEqual(Format.duration(4 * 86400 + 5), "4d")
        XCTAssertEqual(Format.duration(-3), "0s")
    }

    func testBytes() {
        XCTAssertEqual(Format.bytes(512), "512 B")
        XCTAssertEqual(Format.bytes(1536), "1.5 KB")
        XCTAssertEqual(Format.bytes(142 * 1024 * 1024), "142 MB")
    }

    func testOwnerChain() {
        var s = svc(3000)
        s.owners = [OwnerLink(pid: 2, name: "npm", kind: .other), OwnerLink(pid: 3, name: "zsh", kind: .other),
                    OwnerLink(pid: 4, name: "claude", kind: .claudeCode)]
        XCTAssertEqual(Format.ownerChain(s), "Claude Code › zsh › npm › node")
    }

    func testTableTruncatesToWidth() {
        let t = TextTable(headers: ["PORT", "NAME", "PID"],
                          rows: [["3000", String(repeating: "a", count: 80), "1"]], shrinkable: [1])
        let lines = t.render(maxWidth: 40)
        XCTAssertTrue(lines.allSatisfy { $0.count <= 40 }, "\(lines)")
        XCTAssertTrue(lines[1].contains("…"))
        let wide = t.render(maxWidth: 200)
        XCTAssertFalse(wide[1].contains("…"))
    }
}
