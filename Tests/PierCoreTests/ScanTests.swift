import XCTest
import Darwin
@testable import PierCore

final class ScanTests: XCTestCase {
    /// Opens a listening TCP socket on an ephemeral port. Returns (fd, port).
    private func listen(family: Int32, loopback: Bool) throws -> (Int32, UInt16) {
        let fd = socket(family, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var port: UInt16 = 0
        if family == AF_INET {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
            a.sin_addr.s_addr = loopback ? UInt32(0x7f000001).bigEndian : INADDR_ANY
            XCTAssertEqual(withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }, 0)
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
            port = UInt16(bigEndian: a.sin_port)
        } else {
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_addr = loopback ? in6addr_loopback : in6addr_any
            XCTAssertEqual(withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }, 0)
            var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
            _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
            port = UInt16(bigEndian: a.sin6_port)
        }
        XCTAssertEqual(Darwin.listen(fd, 4), 0)
        return (fd, port)
    }

    func testFindsOwnListeners() throws {
        let (fd4, port4) = try listen(family: AF_INET, loopback: true)
        let (fd6, port6) = try listen(family: AF_INET6, loopback: true)
        let (fdAny, portAny) = try listen(family: AF_INET, loopback: false)
        let (fdAny6, portAny6) = try listen(family: AF_INET6, loopback: false)
        defer { [fd4, fd6, fdAny, fdAny6].forEach { close($0) } }

        let socks = ProcScanner.listeningSockets()
        let me = getpid()
        XCTAssertTrue(socks.contains(ListeningSocket(port: port4, pid: me, address: "127.0.0.1", family: .v4)))
        XCTAssertTrue(socks.contains(ListeningSocket(port: port6, pid: me, address: "::1", family: .v6)))
        XCTAssertTrue(socks.contains(ListeningSocket(port: portAny, pid: me, address: "0.0.0.0", family: .v4)))
        XCTAssertTrue(socks.contains(ListeningSocket(port: portAny6, pid: me, address: "::", family: .v6)))
        XCTAssertEqual(socks.count, Set(socks).count, "no duplicates")
    }

    func testClosedSocketDisappears() throws {
        let (fd, port) = try listen(family: AF_INET, loopback: true)
        close(fd)
        XCTAssertFalse(ProcScanner.listeningSockets().contains { $0.port == port && $0.pid == getpid() })
    }

    func testProcessInfoSelf() throws {
        let info = try XCTUnwrap(ProcScanner.processInfo(pid: getpid()))
        XCTAssertEqual(info.pid, getpid())
        XCTAssertEqual(info.ppid, getppid())
        XCTAssertEqual(info.uid, getuid())
        XCTAssertFalse(info.name.isEmpty)
        XCTAssertNotNil(info.executablePath)
        XCTAssertEqual(info.arguments.count, CommandLine.arguments.count)
        XCTAssertEqual(info.arguments.first, CommandLine.arguments.first)
        XCTAssertEqual(info.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
        XCTAssertGreaterThan(info.rssBytes ?? 0, 0)
        XCTAssertTrue(info.isAccessible)
        let start = try XCTUnwrap(info.startTime)
        XCTAssertLessThan(abs(start.timeIntervalSinceNow), 3600)
    }

    func testProcessInfoMissingPid() {
        XCTAssertNil(ProcScanner.processInfo(pid: 999_999))
    }

    func testBatchFillsCPU() throws {
        let infos = ProcScanner.processInfos(pids: [getpid(), getppid(), getpid()])
        let me = try XCTUnwrap(infos[getpid()])
        XCTAssertNotNil(me.cpuPercent)
        XCTAssertGreaterThanOrEqual(me.cpuPercent ?? -1, 0)
    }

    func testParentChain() throws {
        let chain = ProcScanner.parentChain(of: getpid())
        XCTAssertFalse(chain.isEmpty)
        XCTAssertEqual(chain.first?.pid, getppid())
        XCTAssertFalse(chain.contains { $0.pid == getpid() })
        XCTAssertEqual(Set(chain.map(\.pid)).count, chain.count)
        XCTAssertEqual(chain.last?.pid, 1)
        XCTAssertEqual(ProcScanner.parentChain(of: getpid(), maxDepth: 1).count, 1)
        XCTAssertTrue(ProcScanner.parentChain(of: 1).isEmpty)
    }

    /// Cross-check against lsof (only listeners owned by our uid, which lsof also sees without root).
    func testMatchesLsof() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pn"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()

        var expected = Set<String>(), pid: Int32 = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n"), let port = line.split(separator: ":").last { expected.insert("\(port)-\(pid)") }
        }
        let ours = Set(ProcScanner.listeningSockets().map { "\($0.port)-\($0.pid)" })
        print("lsof: \(expected.count) (port,pid), scanner: \(ours.count)")
        let missing = expected.subtracting(ours)
        XCTAssertTrue(missing.isEmpty, "scanner missed: \(missing.sorted())")
    }
}

extension ScanTests {
    func testLaunchdIsDescribable() throws {
        let info = try XCTUnwrap(ProcScanner.processInfo(pid: 1))
        XCTAssertEqual(info.name, "launchd")
        XCTAssertEqual(info.ppid, 0)
    }
}
