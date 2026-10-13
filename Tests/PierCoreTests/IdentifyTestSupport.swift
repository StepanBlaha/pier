import XCTest
@testable import PierCore

/// Shared helpers for the Identify* tests.
class IdentifyTestCase: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pier-identify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    @discardableResult
    func mkdir(_ rel: String) throws -> String {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func write(_ rel: String, _ text: String) throws {
        let url = tmp.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func proc(_ name: String, pid: Int32 = 100, ppid: Int32 = 1, uid: UInt32 = 501, exe: String? = nil,
              args: [String] = [], cwd: String? = nil, accessible: Bool = true) -> ProcInfo {
        ProcInfo(pid: pid, ppid: ppid, uid: uid, name: name, executablePath: exe, arguments: args.isEmpty ? [name] : args,
                 cwd: cwd, isAccessible: accessible)
    }

    func enriched(_ p: ProcInfo, port: UInt16 = 3000, addresses: [String] = ["127.0.0.1"], parents: [ProcInfo] = []) -> Service {
        var s = Service(port: port, process: p, addresses: addresses, bindScope: Identifier.bindScope(for: addresses))
        Identifier.enrich(&s, parents: parents)
        return s
    }
}
