import XCTest
@testable import PierCore

/// Records calls and simulates processes/ports. Keyed by full name "stack/service".
final class FakeStackBackend: StackBackend, @unchecked Sendable {
    private let lock = NSLock()
    var live: [ManagedManifest] = []
    var spawns: [(command: [String], cwd: String, env: [String: String]?, name: String, stack: String)] = []
    var stops: [String] = []
    var spawnFailures: [String: String] = [:]
    /// full name -> port that starts listening right after spawn
    var listenOnSpawn: [String: UInt16] = [:]
    var crashOnSpawn: [String: Int32] = [:]
    var logText: [String: String] = [:]
    var holders: [UInt16: StackPortHolder] = [:]
    var listening: Set<UInt16> = []
    var httpOK: Set<UInt16> = []
    var stopOrder: [String] { lock.lock(); defer { lock.unlock() }; return stops }
    var spawnNames: [String] { lock.lock(); defer { lock.unlock() }; return spawns.map(\.name) }
    private var counter = 0
    private func sync<T>(_ body: () throws -> T) rethrows -> T { try lock.withLock(body) }
    func setLog(_ n: String, _ t: String) { lock.lock(); logText[n] = t; lock.unlock() }
    func listen(_ p: UInt16) { lock.lock(); listening.insert(p); lock.unlock() }

    func runningManifests() -> [ManagedManifest] { lock.lock(); defer { lock.unlock() }; return live }

    func spawn(command: [String], cwd: String, env: [String: String]?, name: String, stack: String) async throws -> ManagedManifest {
        try sync {
        spawns.append((command, cwd, env, name, stack))
        if let why = spawnFailures[name] { throw ManagedError.spawnFailed(why) }
        counter += 1
        var m = ManagedManifest(id: "id\(counter)", name: name, wrapperPid: 1000 + Int32(counter), childPid: 2000 + Int32(counter),
                                command: command, cwd: cwd, env: env, state: .running, detached: true, stack: stack)
        if let code = crashOnSpawn[name] { m.state = .crashed; m.lastExitCode = code }
        live.append(m)
        if let p = listenOnSpawn[name] { listening.insert(p); httpOK.insert(p) }
        return m
        }
    }
    func status(_ m: ManagedManifest) async throws -> ManagedManifest {
        try sync {
        guard let x = live.first(where: { $0.id == m.id }) else { throw ManagedError.notRunning(m.id) }
        return x
        }
    }
    func logs(_ m: ManagedManifest, tail: Int) async throws -> String { sync { logText[m.name] ?? "" } }
    func stop(_ m: ManagedManifest) async throws {
        sync {
        stops.append(m.name)
        live.removeAll { $0.id == m.id }
        }
    }
    func portHolder(_ port: UInt16) -> StackPortHolder? { lock.lock(); defer { lock.unlock() }; return holders[port] }
    func isListening(_ port: UInt16) async -> Bool { sync { listening.contains(port) } }
    func httpHealthy(_ port: UInt16) async -> Bool { sync { httpOK.contains(port) } }
}

final class StackRunnerTests: XCTestCase {
    var dir: String { NSTemporaryDirectory() }

    func svc(_ n: String, deps: [String] = [], port: UInt16? = nil, ready: StackReadyCheck? = nil, timeout: TimeInterval = 0.3,
             env: [String: String] = [:]) -> StackService {
        StackService(name: n, command: [n, "run"], cwd: dir, port: port, env: env, dependsOn: deps, ready: ready, readyTimeout: timeout)
    }
    func runner(_ b: FakeStackBackend, events: EventLog? = nil) -> StackRunner {
        StackRunner(backend: b, pollInterval: 0.01, onEvent: { events?.add($0) }, fileForStack: { _ in nil })
    }
    final class EventLog: @unchecked Sendable {
        private let l = NSLock(); private var e: [StackEvent] = []
        func add(_ x: StackEvent) { l.lock(); e.append(x); l.unlock() }
        var all: [StackEvent] { l.lock(); defer { l.unlock() }; return e }
    }

    func testHappyPathStartsInDependencyOrderWithSpawnArgs() async throws {
        let b = FakeStackBackend()
        b.listenOnSpawn = ["s/db": 5432, "s/web": 3100]
        let f = StackFile(name: "s", services: [
            svc("web", deps: ["db"], port: 3100, ready: .http, env: ["A": "1"]),
            svc("db", port: 5432),
            svc("worker", deps: ["db"]),
        ])
        let r = try await runner(b).up(f)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.waves, [["db"], ["web", "worker"]])
        XCTAssertEqual(b.spawnNames.first, "s/db")
        XCTAssertEqual(Set(b.spawnNames), ["s/db", "s/web", "s/worker"])
        let web = b.spawns.first { $0.name == "s/web" }!
        XCTAssertEqual(web.command, ["web", "run"]); XCTAssertEqual(web.stack, "s"); XCTAssertEqual(web.env, ["A": "1"])
        XCTAssertNil(b.spawns.first { $0.name == "s/db" }!.env)
        XCTAssertEqual(r.services.map(\.state), [.ready, .ready, .started])
        XCTAssertEqual(r.services[1].url, "http://localhost:3100")
        XCTAssertEqual(r.services.map(\.name), ["db", "web", "worker"])
    }

    func testReadinessWaitsUntilPortListens() async throws {
        let b = FakeStackBackend()
        let f = StackFile(name: "s", services: [svc("db", port: 5432, timeout: 2)])
        Task { try? await Task.sleep(nanoseconds: 100_000_000); b.listen(5432) }
        let t0 = Date()
        let r = try await runner(b).up(f)
        XCTAssertTrue(r.ok)
        XCTAssertGreaterThan(Date().timeIntervalSince(t0), 0.05)
    }

    func testFailedServiceSkipsDependentsButNotIndependent() async throws {
        let b = FakeStackBackend()
        b.crashOnSpawn = ["s/db": 3]
        b.logText["s/db"] = "boom: cannot open data dir\n"
        let f = StackFile(name: "s", services: [
            svc("db", port: 5432), svc("api", deps: ["db"]), svc("web", deps: ["api"]), svc("other"),
        ])
        let r = try await runner(b).up(f)
        XCTAssertFalse(r.ok)
        let st = Dictionary(uniqueKeysWithValues: r.services.map { ($0.name, $0) })
        XCTAssertEqual(st["db"]?.state, .failed)
        XCTAssertTrue(st["db"]?.detail?.contains("exited with code 3") ?? false, st["db"]?.detail ?? "")
        XCTAssertTrue(st["db"]?.detail?.contains("boom") ?? false)
        XCTAssertEqual(st["api"]?.state, .skipped)
        XCTAssertTrue(st["api"]?.detail?.contains("'db' failed") ?? false)
        XCTAssertEqual(st["web"]?.state, .skipped)
        XCTAssertTrue(st["web"]?.detail?.contains("'api' was skipped") ?? false)
        XCTAssertEqual(st["other"]?.state, .started)
        XCTAssertFalse(b.spawnNames.contains("s/api")); XCTAssertFalse(b.spawnNames.contains("s/web"))
    }

    func testSpawnFailure() async throws {
        let b = FakeStackBackend()
        b.spawnFailures["s/db"] = "no such binary"
        let f = StackFile(name: "s", services: [svc("db"), svc("web", deps: ["db"])])
        let r = try await runner(b).up(f)
        XCTAssertEqual(r.services.map(\.state), [.failed, .skipped])
        XCTAssertTrue(r.services[0].detail?.contains("no such binary") ?? false)
    }

    func testReadyTimeoutFails() async throws {
        let b = FakeStackBackend()
        let f = StackFile(name: "s", services: [svc("web", port: 3100, timeout: 0.1), svc("x", deps: ["web"])])
        let t0 = Date()
        let r = try await runner(b).up(f)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3)
        XCTAssertEqual(r.services.map(\.state), [.failed, .skipped])
        XCTAssertTrue(r.services[0].detail?.contains("not ready after 0.1s") ?? false, r.services[0].detail ?? "")
    }

    func testPortConflictReportsHolderAndSkipsDependents() async throws {
        let b = FakeStackBackend()
        b.holders[3100] = StackPortHolder(pid: 4821, description: "node (pid 4821, project other)")
        let f = StackFile(name: "s", services: [svc("web", port: 3100), svc("e2e", deps: ["web"]), svc("db")])
        let r = try await runner(b).up(f)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.services[0].state, .failed)
        XCTAssertEqual(r.services[0].detail, "port 3100 is already in use by node (pid 4821, project other)")
        XCTAssertEqual(r.services.map(\.name), ["web", "db", "e2e"])
        XCTAssertEqual(r.services.map(\.state), [.failed, .started, .skipped])
        XCTAssertEqual(b.spawnNames, ["s/db"])
    }

    func testAlreadyRunningIsNotRespawned() async throws {
        let b = FakeStackBackend()
        b.live = [ManagedManifest(id: "old", name: "s/db", wrapperPid: 1, childPid: 2, command: ["db"], cwd: "/", state: .running, stack: "s")]
        b.listening = [5432]
        b.holders[5432] = StackPortHolder(description: "the old db")   // must NOT count as a conflict
        let f = StackFile(name: "s", services: [svc("db", port: 5432), svc("web", deps: ["db"])])
        let r = try await runner(b).up(f)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.services.map(\.state), [.alreadyRunning, .started])
        XCTAssertEqual(r.services[0].managedID, "old")
        XCTAssertEqual(b.spawnNames, ["s/web"])
    }

    func testSameServiceNameInOtherStackIsNotAlreadyRunning() async throws {
        let b = FakeStackBackend()
        b.live = [ManagedManifest(id: "o", name: "other/db", wrapperPid: 1, childPid: 2, command: ["db"], cwd: "/", state: .running, stack: "other")]
        let r = try await runner(b).up(StackFile(name: "s", services: [svc("db")]))
        XCTAssertEqual(b.spawnNames, ["s/db"]); XCTAssertEqual(r.services[0].state, .started)
    }

    func testLogReadiness() async throws {
        let b = FakeStackBackend()
        let f = StackFile(name: "s", services: [svc("api", ready: .log("Listening on \\d+"), timeout: 2)])
        Task { try? await Task.sleep(nanoseconds: 80_000_000); b.setLog("s/api", "boot\n\u{1B}[32mListening on 8080\u{1B}[0m\n") }
        let r = try await runner(b).up(f)
        XCTAssertEqual(r.services[0].state, .ready)
    }

    func testLogReadinessNeverMatchesTimesOut() async throws {
        let b = FakeStackBackend()
        b.logText["s/api"] = "nothing useful"
        let r = try await runner(b).up(StackFile(name: "s", services: [svc("api", ready: .log("ready"), timeout: 0.1)]))
        XCTAssertEqual(r.services[0].state, .failed)
        XCTAssertTrue(r.services[0].detail?.contains("log /ready/") ?? false)
    }

    func testMissingCwdFails() async throws {
        let b = FakeStackBackend()
        var s = svc("a"); s.cwd = "/definitely/not/here"
        let r = try await runner(b).up(StackFile(name: "s", services: [s]))
        XCTAssertEqual(r.services[0].state, .failed)
        XCTAssertTrue(b.spawnNames.isEmpty)
    }

    func testSelectionOnlyStartsNeeded() async throws {
        let b = FakeStackBackend()
        let f = StackFile(name: "s", services: [svc("web", deps: ["db"]), svc("db"), svc("unrelated")])
        _ = try await runner(b).up(f, selection: ["web"])
        XCTAssertEqual(b.spawnNames, ["s/db", "s/web"])
    }

    func testEventsEmitted() async throws {
        let b = FakeStackBackend(); let log = EventLog()
        _ = try await runner(b, events: log).up(StackFile(name: "s", services: [svc("a")]))
        let kinds = log.all.map { e -> String in
            switch e { case .starting: return "starting"; case .finished: return "finished"; case .waiting: return "waiting"; case .stopping: return "stopping" }
        }
        XCTAssertEqual(kinds, ["starting", "finished"])
    }

    // MARK: down

    func running(_ name: String, _ stack: String, id: String, at: TimeInterval = 0) -> ManagedManifest {
        ManagedManifest(id: id, name: name, wrapperPid: 1, childPid: 2, command: ["x"], cwd: "/",
                        startedAt: Date(timeIntervalSince1970: at), state: .running, stack: stack)
    }

    func testDownStopsDependentsFirstAndOnlyThisStack() async throws {
        let b = FakeStackBackend()
        b.live = [running("s/db", "s", id: "1"), running("s/api", "s", id: "2"), running("s/web", "s", id: "3"),
                  running("t/db", "t", id: "4"), running("plain", "", id: "5")]
        b.live[4].stack = nil
        let f = StackFile(name: "s", services: [svc("web", deps: ["api"]), svc("api", deps: ["db"]), svc("db")])
        let r = try await runner(b).down(f)
        XCTAssertEqual(b.stopOrder, ["s/web", "s/api", "s/db"])
        XCTAssertEqual(r.map(\.state), [.stopped, .stopped, .stopped])
        XCTAssertEqual(Set(b.live.map(\.name)), ["t/db", "plain"])
    }

    func testDownSelectionLeavesDependenciesUp() async throws {
        let b = FakeStackBackend()
        b.live = [running("s/db", "s", id: "1"), running("s/web", "s", id: "3")]
        let f = StackFile(name: "s", services: [svc("web", deps: ["db"]), svc("db")])
        let r = try await runner(b).down(f, selection: ["web"])
        XCTAssertEqual(b.stopOrder, ["s/web"])
        XCTAssertEqual(r.map(\.name), ["web"])
        XCTAssertEqual(b.live.map(\.name), ["s/db"])
    }

    func testDownReportsNotRunningAndOrphans() async throws {
        let b = FakeStackBackend()
        b.live = [running("s/removed", "s", id: "9")]
        let f = StackFile(name: "s", services: [svc("web")])
        let r = try await runner(b).down(f)
        XCTAssertEqual(b.stopOrder, ["s/removed"])
        XCTAssertEqual(r.map(\.state), [.stopped, .notRunning])
        XCTAssertEqual(r.map(\.name), ["removed", "web"])
    }

    func testDownUnknownService() async {
        let f = StackFile(name: "s", services: [svc("web")])
        do { _ = try await runner(FakeStackBackend()).down(f, selection: ["nope"]); XCTFail() }
        catch { XCTAssertEqual(error as? StackError, .unknownService("nope", known: ["web"])) }
    }

    func testDownAllStacks() async throws {
        let b = FakeStackBackend()
        b.live = [running("a/db", "a", id: "1", at: 1), running("a/web", "a", id: "2", at: 2), running("b/x", "b", id: "3", at: 3)]
        let known = StackFile(name: "a", services: [svc("web", deps: ["db"]), svc("db")])
        let rn = StackRunner(backend: b, pollInterval: 0.01, fileForStack: { $0 == "a" ? known : nil })
        let r = await rn.downAll()
        XCTAssertEqual(r.count, 3)
        let order = b.stopOrder
        XCTAssertLessThan(order.firstIndex(of: "a/web")!, order.firstIndex(of: "a/db")!)
        XCTAssertTrue(b.live.isEmpty)
    }
}
