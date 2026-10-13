import XCTest
@testable import PierCore

final class ManagedCoreTests: XCTestCase {
    // MARK: Ring buffer

    func testRingBufferKeepsLastLines() {
        let rb = LogRingBuffer(maxLines: 5, maxBytes: 1 << 20)
        for i in 1...12 { rb.append("line \(i)\n") }
        XCTAssertEqual(rb.lineCount, 5)
        XCTAssertEqual(rb.tail(2), "line 11\nline 12\n")
        XCTAssertEqual(rb.all(), (8...12).map { "line \($0)\n" }.joined())
        XCTAssertEqual(rb.tail(0), "")
    }

    func testRingBufferByteCapAndPartialLines() {
        let rb = LogRingBuffer(maxLines: 10_000, maxBytes: 100)
        for _ in 0..<50 { rb.append("0123456789\n") }
        XCTAssertLessThanOrEqual(rb.byteCount, 100)
        rb.append("par")
        rb.append("tial")
        XCTAssertTrue(rb.tail(1).hasSuffix("partial"))
        XCTAssertTrue(rb.hasPartialLine)
        rb.append("\n")
        XCTAssertFalse(rb.hasPartialLine)
    }

    func testRingBufferPreservesANSI() {
        let rb = LogRingBuffer()
        rb.append("\u{1B}[31mred\u{1B}[0m\n")
        XCTAssertEqual(rb.tail(5), "\u{1B}[31mred\u{1B}[0m\n")
    }

    func testRingBufferHandlesTenThousandLines() {
        let rb = LogRingBuffer()
        for i in 0..<25_000 { rb.append("l\(i)\n") }
        XCTAssertEqual(rb.lineCount, 10_000)
        XCTAssertTrue(rb.tail(1) == "l24999\n")
    }

    // MARK: ANSI / UTF-8

    func testANSIStripper() {
        XCTAssertEqual(ANSIStripper.strip("\u{1B}[1;32mok\u{1B}[0m done\r\n"), "ok done\n")
        XCTAssertEqual(ANSIStripper.strip("\u{1B}]0;title\u{07}text"), "text")
        XCTAssertEqual(ANSIStripper.strip("a\u{1B}[2K\rb"), "a\nb")
        // Escape split across chunks.
        var st = ANSIStripper()
        XCTAssertEqual(st.feed("x\u{1B}[3"), "x")
        XCTAssertEqual(st.feed("1mred"), "red")
    }

    func testUTF8ChunkerDoesNotSplitScalars() {
        let bytes = Array("héllo ✓".utf8)
        var c = UTF8Chunker()
        var out = ""
        for b in bytes { out += c.decode(Data([b])) }
        XCTAssertEqual(out, "héllo ✓")
    }

    // MARK: Coding

    func testRequestResponseCoding() throws {
        for req in [ManagedRequest.status, .logs(tail: 50, follow: true), .restart, .stop] {
            let data = try ManagedCoding.encoder().encode(req)
            XCTAssertEqual(try ManagedCoding.decoder().decode(ManagedRequest.self, from: data), req)
        }
        let m = ManagedManifest(id: "abcd1234", name: "n", wrapperPid: 1, childPid: 2, command: ["a", "b"], cwd: "/x",
                                env: ["K": "V"], restartCount: 3, state: .running, detached: true, stack: "s")
        let resp = ManagedResponse(ok: true, manifest: m, logs: "hi\n")
        let back = try ManagedCoding.decoder().decode(ManagedResponse.self, from: try ManagedCoding.encoder().encode(resp))
        XCTAssertEqual(back.manifest?.id, "abcd1234")
        XCTAssertEqual(back.manifest?.env, ["K": "V"])
        XCTAssertEqual(back.manifest?.startedAt.timeIntervalSince1970 ?? 0, m.startedAt.timeIntervalSince1970, accuracy: 0.002)
        XCTAssertEqual(back.logs, "hi\n")
    }

    func testSocketPathStaysUnderLimit() {
        XCTAssertLessThan(ManagedPaths.socketURL(id: ManagedCoding.newID()).path.utf8.count, 104)
    }

    // MARK: Registry

    private func writeManifest(id: String, wrapperPid: Int32, childPid: Int32? = nil) {
        let m = ManagedManifest(id: id, name: id, wrapperPid: wrapperPid, childPid: childPid, command: ["x"], cwd: "/tmp")
        ManagedFiles.writeManifest(m)
    }

    func testRegistryPrunesDeadWrappers() throws {
        let deadID = "zt" + String(ManagedCoding.newID().prefix(6)), liveID = "zt" + String(ManagedCoding.newID().prefix(6))
        defer {
            for id in [deadID, liveID] {
                unlink(ManagedPaths.manifestURL(id: id).path); unlink(ManagedPaths.socketURL(id: id).path)
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try p.run(); p.waitUntilExit()
        writeManifest(id: deadID, wrapperPid: p.processIdentifier)
        FileManager.default.createFile(atPath: ManagedPaths.socketURL(id: deadID).path, contents: nil)
        writeManifest(id: liveID, wrapperPid: getpid())

        let ids = ManagedRegistry.all().map(\.id)
        XCTAssertTrue(ids.contains(liveID))
        XCTAssertFalse(ids.contains(deadID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ManagedPaths.manifestURL(id: deadID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ManagedPaths.socketURL(id: deadID).path))
    }

    func testOwningMatchesChildWrapperAndAncestors() {
        let a = ManagedManifest(id: "aaaaaaaa", name: "a", wrapperPid: 100, childPid: 101, command: ["x"], cwd: "/")
        let b = ManagedManifest(id: "bbbbbbbb", name: "b", wrapperPid: 200, childPid: nil, command: ["x"], cwd: "/")
        let all = [a, b]
        func proc(_ pid: Int32) -> ProcInfo { ProcInfo(pid: pid, ppid: 1, uid: 0, name: "p") }
        XCTAssertEqual(ManagedRegistry.manifest(owning: 101, parents: [], in: all)?.id, "aaaaaaaa")
        // node (500) ← npm (101, the managed child) ← wrapper
        XCTAssertEqual(ManagedRegistry.manifest(owning: 500, parents: [proc(400), proc(101), proc(100)], in: all)?.id, "aaaaaaaa")
        // child pid unknown (restarting): wrapper ancestor still matches
        XCTAssertEqual(ManagedRegistry.manifest(owning: 600, parents: [proc(200), proc(1)], in: all)?.id, "bbbbbbbb")
        XCTAssertNil(ManagedRegistry.manifest(owning: 700, parents: [proc(300)], in: all))
    }

    func testFindByIDNameAndPrefix() {
        func m(_ id: String, _ n: String) -> ManagedManifest { ManagedManifest(id: id, name: n, wrapperPid: 1, childPid: 2, command: ["x"], cwd: "/") }
        let all = [m("aaaa1111", "Relay"), m("bbbb2222", "relay-worker"), m("cccc3333", "web")]
        XCTAssertEqual(ManagedRegistry.find("bbbb2222", in: all).map(\.name), ["relay-worker"])
        XCTAssertEqual(ManagedRegistry.find("relay", in: all).map(\.name), ["Relay"])      // exact beats prefix
        XCTAssertEqual(ManagedRegistry.find("we", in: all).map(\.name), ["web"])
        XCTAssertTrue(ManagedRegistry.find("nope", in: all).isEmpty)
    }

    // MARK: Env / package managers / defaults

    func testProcArgsParsing() {
        var buf = [UInt8]()
        withUnsafeBytes(of: Int32(2)) { buf.append(contentsOf: $0) }
        buf += Array("/usr/bin/node\0\0\0".utf8)
        buf += Array("node\0server.js\0".utf8)
        buf += Array("PATH=/bin\0TERM_SESSION_ID=abc\0FOO=a=b\0\0\0apple=ignored\0".utf8)
        let parsed = ProcEnvironment.parse(buffer: buf)
        XCTAssertEqual(parsed?.argv, ["node", "server.js"])
        XCTAssertEqual(parsed?.env, ["PATH=/bin", "TERM_SESSION_ID=abc", "FOO=a=b"])
    }

    func testReadsOwnEnvironmentAndDropsSessionVars() {
        setenv("PIER_TEST_VAR", "yes", 1)
        setenv("TERM_SESSION_ID", "sess", 1)
        let env = ProcEnvironment.read(pid: getpid())
        XCTAssertNotNil(env)
        XCTAssertNil(env?["TERM_SESSION_ID"])
        XCTAssertNil(env?["SHLVL"])
    }

    func testPackageManagerDetectionFromProcesses() {
        func p(_ args: [String]) -> ProcInfo { ProcInfo(pid: 9, ppid: 1, uid: 0, name: "node", arguments: args) }
        XCTAssertEqual(ManagedLauncher.packageManagerCommand(of: p(["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "run", "dev"])), ["npm", "run", "dev"])
        XCTAssertEqual(ManagedLauncher.packageManagerCommand(of: p(["node", "/x/pnpm.cjs", "dev"])), ["pnpm", "dev"])
        XCTAssertEqual(ManagedLauncher.packageManagerCommand(of: p(["npm run dev"])), ["npm", "run", "dev"])
        XCTAssertEqual(ManagedLauncher.packageManagerCommand(of: p(["yarn", "dev"])), ["yarn", "dev"])
        XCTAssertNil(ManagedLauncher.packageManagerCommand(of: p(["node", "server.js"])))
        XCTAssertNil(ManagedLauncher.packageManagerCommand(of: p(["/bin/zsh", "-l"])))
        let parents = [p(["sh", "-c", "next dev"]), p(["npm", "run", "dev"]), p(["/bin/zsh"])]
        XCTAssertEqual(ManagedLauncher.outermostPackageManager(parents: parents)?.command, ["npm", "run", "dev"])
    }

    func testDefaultCommandUsesLockfile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pier-def-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        if case .success = ManagedDefaults.defaultCommand(cwd: dir.path) { XCTFail("no package.json") }
        try Data(#"{"scripts":{"build":"x"}}"#.utf8).write(to: dir.appendingPathComponent("package.json"))
        if case .failure(let e) = ManagedDefaults.defaultCommand(cwd: dir.path) { XCTAssertTrue(e.message.contains("scripts.dev")) } else { XCTFail() }
        try Data(#"{"scripts":{"dev":"vite"}}"#.utf8).write(to: dir.appendingPathComponent("package.json"))
        XCTAssertEqual(try? ManagedDefaults.defaultCommand(cwd: dir.path).get(), ["npm", "run", "dev"])
        FileManager.default.createFile(atPath: dir.appendingPathComponent("pnpm-lock.yaml").path, contents: Data())
        XCTAssertEqual(try? ManagedDefaults.defaultCommand(cwd: dir.path).get(), ["pnpm", "run", "dev"])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("pnpm-lock.yaml"))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("bun.lockb").path, contents: Data())
        XCTAssertEqual(try? ManagedDefaults.defaultCommand(cwd: dir.path).get(), ["bun", "run", "dev"])
    }
}
