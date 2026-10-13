import XCTest
import Foundation
import Darwin
@testable import PierCore

private let now = Date(timeIntervalSince1970: 2_000_000_000)

private func svc(port: UInt16 = 3000, pid: Int32 = 500, kind: ServiceKind = .devServer, project: String? = "relay",
                 ageDays: Double? = 11, cpu: Double? = 0.0, noise: Bool = false, accessible: Bool = true,
                 rss: UInt64? = 100 << 20) -> Service {
    var p = ProcInfo(pid: pid, ppid: 1, uid: 501, name: "node", startTime: ageDays.map { now.addingTimeInterval(-$0 * 86_400) },
                     cpuPercent: cpu, rssBytes: rss, isAccessible: accessible)
    p.cwd = project.map { "/tmp/\($0)" }
    var s = Service(port: port, process: p, addresses: ["127.0.0.1"], bindScope: .loopback)
    s.kind = kind; s.projectName = project; s.projectPath = project.map { "/tmp/\($0)" }; s.isNoise = noise
    return s
}

final class StaleEvaluateTests: XCTestCase {
    private let week: TimeInterval = 3 * 86_400

    func testOldIdleDevServerIsStale() {
        let v = Staleness.evaluate(svc(), now: now, minAge: week, maxCPU: 1)
        XCTAssertEqual(v?.reasons, ["up 11d", "idle 0.0% CPU"])
    }

    func testTooYoungNotStale() {
        XCTAssertNil(Staleness.evaluate(svc(ageDays: 2.9), now: now, minAge: week, maxCPU: 1))
        XCTAssertNotNil(Staleness.evaluate(svc(ageDays: 3), now: now, minAge: week, maxCPU: 1))
    }

    func testBusyNotStaleAndNilCPUCountsIdle() {
        XCTAssertNil(Staleness.evaluate(svc(cpu: 1.5), now: now, minAge: week, maxCPU: 1))
        XCTAssertNotNil(Staleness.evaluate(svc(cpu: 1.0), now: now, minAge: week, maxCPU: 1))
        XCTAssertNotNil(Staleness.evaluate(svc(cpu: nil), now: now, minAge: week, maxCPU: 1))
    }

    func testUnknownStartTimeNotStale() {
        XCTAssertNil(Staleness.evaluate(svc(ageDays: nil), now: now, minAge: 0, maxCPU: 1))
    }

    func testKindRules() {
        XCTAssertNotNil(Staleness.evaluate(svc(kind: .other), now: now, minAge: week, maxCPU: 1))
        XCTAssertNil(Staleness.evaluate(svc(kind: .other, project: nil), now: now, minAge: week, maxCPU: 1))
        for k in [ServiceKind.infra, .docker] {
            XCTAssertNil(Staleness.evaluate(svc(kind: k), now: now, minAge: week, maxCPU: 1))
            XCTAssertNotNil(Staleness.evaluate(svc(kind: k), now: now, minAge: week, maxCPU: 1, includeInfra: true))
        }
        XCTAssertNil(Staleness.evaluate(svc(kind: .system), now: now, minAge: week, maxCPU: 1, includeInfra: true))
        XCTAssertNil(Staleness.evaluate(svc(noise: true), now: now, minAge: week, maxCPU: 1, includeInfra: true))
        XCTAssertNil(Staleness.evaluate(svc(accessible: false), now: now, minAge: week, maxCPU: 1))
    }

    func testConnectionReasons() {
        XCTAssertEqual(Staleness.evaluate(svc(), now: now, minAge: week, maxCPU: 1, activeConnections: 0)?.reasons.last, "no open connections")
        XCTAssertEqual(Staleness.evaluate(svc(), now: now, minAge: week, maxCPU: 1, activeConnections: 2)?.reasons.last, "2 open connections")
    }

    func testFindSortsByUptimeAndFiltersActive() {
        let services = [svc(port: 3001, pid: 11, ageDays: 5), svc(port: 3002, pid: 12, ageDays: 15),
                        svc(port: 3003, pid: 13, ageDays: 9), svc(port: 3004, pid: 14, ageDays: 1)]
        let counts: [UInt16: Int] = [3001: 0, 3002: 0, 3003: 4, 3004: 0]
        let counter: (Service) -> Int? = { counts[$0.port] }
        let found = Staleness.find(in: services, now: now, minAge: week, maxCPU: 1, connectionCount: counter)
        XCTAssertEqual(found.map(\.service.port), [3002, 3001])   // 3003 active, 3004 young
        let withActive = Staleness.find(in: services, now: now, minAge: week, maxCPU: 1, includeActive: true, connectionCount: counter)
        XCTAssertEqual(withActive.map(\.service.port), [3002, 3003, 3001])
        XCTAssertEqual(withActive[1].verdict.reasons.last, "4 open connections")
        let scoped = Staleness.find(in: services, now: now, minAge: 0, maxCPU: 1, ports: [3001], connectionCount: counter)
        XCTAssertEqual(scoped.map(\.service.port), [3001])
    }

    func testFindNeverTargetsPid1OrSelf() {
        let me = ProcessInfo.processInfo.processIdentifier
        let found = Staleness.find(in: [svc(pid: 1), svc(port: 3001, pid: 0), svc(port: 3002, pid: me)], now: now, minAge: 0, maxCPU: 100,
                                   connectionCount: { _ in 0 })
        XCTAssertTrue(found.isEmpty)
    }

    func testTotalMemoryCountsPidOnce() {
        let entries = Staleness.find(in: [svc(port: 3001, pid: 7), svc(port: 3002, pid: 7), svc(port: 3003, pid: 8)],
                                     now: now, minAge: 0, maxCPU: 1, connectionCount: { _ in 0 })
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(Staleness.totalMemory(entries), 200 << 20)
    }
}

final class StaleConnectionsTests: XCTestCase {
    /// Real loopback listener + client in this process: counts the accepted ESTABLISHED socket.
    func testEstablishedCountOnLoopback() throws {
        let lfd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThan(lfd, 0)
        defer { close(lfd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(lfd, $0, len) } }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(lfd, 4), 0)
        withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(lfd, $0, &len) } }
        let port = UInt16(bigEndian: addr.sin_port)

        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertEqual(Connections.established(pid: me, port: port), 0)

        let cfd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(cfd) }
        let conn = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(cfd, $0, len) } }
        XCTAssertEqual(conn, 0)
        let afd = accept(lfd, nil, nil)
        XCTAssertGreaterThan(afd, 0)
        defer { close(afd) }
        // Server-side accepted socket has local port == listener port.
        XCTAssertEqual(Connections.established(pid: me, port: port), 1)
    }
}
