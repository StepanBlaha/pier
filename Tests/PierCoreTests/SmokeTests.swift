import XCTest
@testable import PierCore

final class SmokeTests: XCTestCase {
    func testServiceID() {
        let s = Service(port: 3000, process: ProcInfo(pid: 42, ppid: 1, uid: 501, name: "node"), addresses: ["::"], bindScope: .all)
        XCTAssertEqual(s.id, "3000-42")
    }
}

final class AppInternalTests: XCTestCase {
    private func svc(exe: String, title: String?) -> Service {
        var s = Service(port: 5000, process: ProcInfo(pid: 9, ppid: 1, uid: 501, name: "x", executablePath: exe), addresses: ["127.0.0.1"], bindScope: .loopback)
        s.probe = ProbeResult(protocolKind: .http, health: .ok, httpStatus: 200, title: title)
        return s
    }
    func testHelperWithoutTitleIsNoise() {
        var s = svc(exe: "/Applications/Notion.app/Contents/MacOS/Notion", title: nil)
        Identifier.refine(&s)
        XCTAssertTrue(s.isNoise)
    }
    func testAppWithTitleStays() {
        var s = svc(exe: "/Applications/Refill.app/Contents/MacOS/Refill", title: "Refill")
        Identifier.refine(&s)
        XCTAssertFalse(s.isNoise)
    }
}
