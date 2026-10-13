import XCTest
@testable import PierCore

/// Drives the real `pier` binary (detached wrapper) against a throwaway python http.server.
final class ManagedE2ETests: XCTestCase {
    private func pierBinary() -> String? {
        let fm = FileManager.default
        if let b = ProcessInfo.processInfo.environment["PIER_BIN"], fm.isExecutableFile(atPath: b) { return b }
        let bundle = Bundle(for: ManagedE2ETests.self).bundleURL
        let sibling = bundle.deletingLastPathComponent().appendingPathComponent("pier").path
        return fm.isExecutableFile(atPath: sibling) ? sibling : nil
    }

    private func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return UInt16(bigEndian: a.sin_port)
    }

    private func waitUntil(_ seconds: TimeInterval = 10, _ cond: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func testDetachedLifecycle() async throws {
        guard let bin = pierBinary() else { throw XCTSkip("pier binary not built (set PIER_BIN)") }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("no python3") }
        setenv("PIER_BIN", bin, 1)
        XCTAssertEqual(ManagedLauncher.pierExecutable(), bin)

        let port = freePort()
        let m = try await ManagedLauncher.spawnDetached(command: ["python3", "-m", "http.server", String(port), "--bind", "127.0.0.1"],
                                                        cwd: NSTemporaryDirectory(), name: "pier-e2e")
        defer { unlink(ManagedPaths.manifestURL(id: m.id).path); unlink(ManagedPaths.socketURL(id: m.id).path) }
        XCTAssertEqual(m.name, "pier-e2e")
        XCTAssertTrue(m.detached)
        XCTAssertNotNil(m.childPid)
        XCTAssertTrue(ManagedRegistry.all().contains { $0.id == m.id })
        XCTAssertEqual(ManagedRegistry.manifest(owning: m.childPid!, parents: [])?.id, m.id)

        let st = try await ManagedClient.status(m)
        XCTAssertEqual(st.state, .running)

        let gotBanner = await waitUntil {
            ((try? await ManagedClient.logs(m, tail: 50)) ?? "").contains("Serving HTTP on")
        }
        XCTAssertTrue(gotBanner, "http.server banner should be in the logs")

        // follow sees new output
        var followed = ""
        let follower = Task {
            for try await chunk in ManagedClient.followLogs(m, tail: 5) { followed += chunk; if followed.contains("GET /pier-follow") { break } }
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/pier-follow")!)
        _ = await waitUntil(5) { followed.contains("GET /pier-follow") }
        follower.cancel()
        XCTAssertTrue(followed.contains("GET /pier-follow"), "follow stream should deliver live output; got: \(followed)")

        let oldPid = st.childPid
        try await ManagedClient.restart(m)
        let after = try await ManagedClient.status(m)
        XCTAssertEqual(after.restartCount, 1)
        XCTAssertNotNil(after.restartedAt)
        XCTAssertNotEqual(after.childPid, oldPid)
        let marker = try await ManagedClient.logs(m, tail: 100)
        XCTAssertTrue(marker.contains("── restarted by pier ──"))

        try await ManagedClient.stop(m)
        let gone = await waitUntil(5) { !FileManager.default.fileExists(atPath: ManagedPaths.manifestURL(id: m.id).path) }
        XCTAssertTrue(gone, "manifest should be removed after stop")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ManagedPaths.socketURL(id: m.id).path))
        XCTAssertFalse(ManagedRegistry.all().contains { $0.id == m.id })
        let dead = await waitUntil(5) { !Killer.isAlive(after.childPid!) }
        XCTAssertTrue(dead, "child should be gone")
    }

    func testCrashedStateIsKeptForLogs() async throws {
        guard let bin = pierBinary() else { throw XCTSkip("pier binary not built (set PIER_BIN)") }
        setenv("PIER_BIN", bin, 1)
        let m = try await ManagedLauncher.spawnDetached(command: ["sh", "-c", "echo boom; exit 3"], cwd: NSTemporaryDirectory(), name: "pier-crash")
        let crashed = await waitUntil(5) { (try? await ManagedClient.status(m))?.state == .crashed }
        XCTAssertTrue(crashed)
        let st = try await ManagedClient.status(m)
        XCTAssertEqual(st.lastExitCode, 3)
        let logs = try await ManagedClient.logs(m)
        XCTAssertTrue(logs.contains("boom"))
        try await ManagedClient.stop(m)
    }
}
