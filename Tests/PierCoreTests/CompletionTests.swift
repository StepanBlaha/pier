import XCTest
@testable import PierCore

private func svc(_ port: UInt16, pid: Int32 = 100, name: String = "node", project: String? = nil, infra: String? = nil,
                 framework: Framework? = nil, title: String? = nil) -> Service {
    var s = Service(port: port, process: ProcInfo(pid: pid, ppid: 1, uid: 501, name: name), addresses: ["127.0.0.1"], bindScope: .loopback)
    s.projectName = project; s.infraName = infra; s.framework = framework
    if let title { s.probe = ProbeResult(title: title) }
    return s
}

final class CompletionTests: XCTestCase {
    let services = [
        svc(3100, pid: 1, project: "Relay CRM", framework: Framework(id: "next", name: "Next.js")),
        svc(3101, pid: 2, project: "Relay CRM"),
        svc(5432, pid: 3, name: "postgres", infra: "PostgreSQL"),
        svc(11434, pid: 4, name: "ollama", infra: "Ollama"),
        svc(8000, pid: 5, name: "python3", framework: Framework(id: "fastapi", name: "FastAPI")),
        svc(9000, pid: 6, name: "Some Tool"),
    ]

    func testNameTokenPrecedence() {
        XCTAssertEqual(Completion.nameToken(services[0]), "relay-crm")   // project, spaces -> '-'
        XCTAssertEqual(Completion.nameToken(services[2]), "postgresql")  // infra
        XCTAssertEqual(Completion.nameToken(services[4]), "fastapi")     // framework id
        XCTAssertEqual(Completion.nameToken(services[5]), "some-tool")   // process name
    }

    func testAllCandidatesPortsFirstDeduped() {
        let values = Completion.candidates(prefix: "", services: services).map(\.value)
        XCTAssertEqual(values, ["3100", "3101", "5432", "8000", "9000", "11434",
                                "fastapi", "ollama", "postgresql", "relay-crm", "some-tool"])
    }

    func testPrefixFilter() {
        XCTAssertEqual(Completion.candidates(prefix: "31", services: services).map(\.value), ["3100", "3101"])
        XCTAssertEqual(Completion.candidates(prefix: "re", services: services).map(\.value), ["relay-crm"])
        XCTAssertEqual(Completion.candidates(prefix: "RELAY", services: services).map(\.value), ["relay-crm"])
        XCTAssertTrue(Completion.candidates(prefix: "zzz", services: services).isEmpty)
    }

    func testDetails() {
        let c = Completion.candidates(prefix: "", services: services)
        XCTAssertEqual(c.first { $0.value == "3100" }?.detail, "Relay CRM · Next.js")
        XCTAssertEqual(c.first { $0.value == "relay-crm" }?.detail, "ports 3100 3101")
    }

    func testRender() {
        let c = Completion.Candidate(value: "3100", detail: "Relay CRM")
        XCTAssertEqual(Completion.render(c, shell: "zsh"), "3100:Relay CRM")
        XCTAssertEqual(Completion.render(c, shell: "fish"), "3100\tRelay CRM")
        XCTAssertEqual(Completion.render(c, shell: "bash"), "3100")
        XCTAssertEqual(Completion.render(c, shell: nil), "3100")
        XCTAssertEqual(Completion.render(.init(value: "a:b", detail: "d"), shell: "zsh"), "a\\:b:d")
    }

    func testQuickSnapshotIsFastAndSynchronous() {
        let t0 = Date()
        let s = ServiceCatalog.quickSnapshot()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0)
        XCTAssertTrue(s.allSatisfy { $0.probe == nil && $0.process.cpuPercent == nil })
    }
}
