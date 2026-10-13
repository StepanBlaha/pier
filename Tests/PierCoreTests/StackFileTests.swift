import XCTest
@testable import PierCore

final class StackFileTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pier-stack-\(UUID().uuidString)/myproj", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    func parse(_ yaml: String) throws -> StackFile {
        try StackLoader.parse(yaml: yaml, url: dir.appendingPathComponent("pier.yml"))
    }
    func issues(_ yaml: String) -> [StackIssue] {
        do { _ = try parse(yaml); XCTFail("expected validation failure"); return [] }
        catch StackError.invalid(let i) { return i }
        catch { XCTFail("unexpected \(error)"); return [] }
    }

    // MARK: parsing

    func testStringRunIsShellSplit() throws {
        let f = try parse("services:\n  web:\n    run: pnpm dev --port \"3 000\" 'a b'\n")
        XCTAssertEqual(f.services[0].command, ["pnpm", "dev", "--port", "3 000", "a b"])
    }

    func testArrayRunKept() throws {
        let f = try parse("services:\n  db:\n    run: [docker, compose, up, postgres]\n")
        XCTAssertEqual(f.services[0].command, ["docker", "compose", "up", "postgres"])
        XCTAssertEqual(f.services[0].display, "docker compose up postgres")
    }

    func testShellOperatorsGoThroughShell() throws {
        for run in ["cd api && uv run uvicorn main:app", "npm run a | tee log", "a; b", "echo $HOME", "FOO=1 node x.js", "echo `date`", "x > out.log"] {
            let c = try StackShell.command(for: run)
            XCTAssertEqual(c, ["/bin/sh", "-c", run], run)
        }
    }

    func testQuotedOperatorsAreLiteral() throws {
        XCTAssertEqual(try StackShell.command(for: "echo 'a && b | $c'"), ["echo", "a && b | $c"])
        XCTAssertEqual(try StackShell.command(for: "echo \"a && b\""), ["echo", "a && b"])
        XCTAssertEqual(try StackShell.command(for: "echo \"$HOME\""), ["/bin/sh", "-c", "echo \"$HOME\""])
    }

    func testUnterminatedQuoteIsValidationError() {
        let i = issues("services:\n  web:\n    run: echo 'oops\n")
        XCTAssertEqual(i.count, 1)
        XCTAssertEqual(i[0].keyPath, "services.web.run")
        XCTAssertTrue(i[0].message.contains("unterminated"))
    }

    func testDefaults() throws {
        let f = try parse("""
        services:
          web:
            run: pnpm dev
            port: 3100
          worker:
            run: node w.js
        """)
        XCTAssertEqual(f.name, "myproj")
        let web = f.service("web")!, worker = f.service("worker")!
        XCTAssertEqual(web.ready, .port)
        XCTAssertEqual(worker.ready, StackReadyCheck.none)
        XCTAssertEqual(web.readyTimeout, 60)
        XCTAssertEqual(web.cwd, dir.standardizedFileURL.path)
        XCTAssertEqual(web.port, 3100)
        XCTAssertTrue(web.env.isEmpty)
        XCTAssertEqual(f.path, dir.appendingPathComponent("pier.yml").standardizedFileURL.path)
    }

    func testFullServiceFields() throws {
        let f = try parse("""
        name: relay
        services:
          db:
            run: [docker, compose, up, postgres]
            port: 5432
          web:
            run: pnpm dev
            cwd: ./apps/web
            port: 3100
            env: { NODE_ENV: development, DEBUG: true, N: 5, EMPTY: }
            depends_on: [db]
            ready: http
            ready_timeout: 12.5
          w:
            run: node w.js
            depends_on: db
            ready: "log:listening on \\\\d+"
        """)
        XCTAssertEqual(f.name, "relay")
        let web = f.service("web")!
        XCTAssertEqual(web.cwd, dir.standardizedFileURL.appendingPathComponent("apps/web").path)
        XCTAssertEqual(web.env, ["NODE_ENV": "development", "DEBUG": "true", "N": "5", "EMPTY": ""])
        XCTAssertEqual(web.dependsOn, ["db"])
        XCTAssertEqual(web.ready, .http)
        XCTAssertEqual(web.readyTimeout, 12.5)
        XCTAssertEqual(f.service("w")!.dependsOn, ["db"])
        XCTAssertEqual(f.service("w")!.ready, .log("listening on \\d+"))
        XCTAssertEqual(f.serviceNames, ["db", "web", "w"])
    }

    func testUnknownKeysWarn() throws {
        let f = try parse("""
        colour: red
        services:
          web:
            run: x
            prot: 1
        """)
        XCTAssertEqual(f.warnings.count, 2)
        XCTAssertTrue(f.warnings[0].contains("pier.yml:1"))
        XCTAssertTrue(f.warnings.contains { $0.contains("services.web.prot") && $0.contains(":5") })
    }

    func testDefaultNameSanitized() throws {
        let weird = dir.deletingLastPathComponent().appendingPathComponent("My App!", isDirectory: true)
        try FileManager.default.createDirectory(at: weird, withIntermediateDirectories: true)
        let f = try StackLoader.parse(yaml: "services:\n  a:\n    run: x\n", url: weird.appendingPathComponent("pier.yml"))
        XCTAssertEqual(f.name, "My-App-")
    }

    // MARK: validation

    func testMissingRun() {
        let i = issues("services:\n  web:\n    port: 3000\n")
        XCTAssertEqual(i.map(\.keyPath), ["services.web"])
        XCTAssertTrue(i[0].message.contains("missing required `run:`"))
        XCTAssertEqual(i[0].line, 2)
        XCTAssertTrue(i[0].description.hasPrefix("pier.yml:2: services.web:"))
    }

    func testUnknownDependency() {
        let i = issues("services:\n  web:\n    run: x\n    depends_on: [dbb]\n")
        XCTAssertEqual(i.count, 1)
        XCTAssertEqual(i[0].keyPath, "services.web.depends_on")
        XCTAssertTrue(i[0].message.contains("unknown dependency 'dbb'"))
        XCTAssertEqual(i[0].line, 4)
    }

    func testCycle() {
        let i = issues("""
        services:
          a: { run: x, depends_on: [b] }
          b: { run: x, depends_on: [c] }
          c: { run: x, depends_on: [a] }
        """)
        XCTAssertEqual(i.count, 1)
        XCTAssertTrue(i[0].message.contains("a -> b -> c -> a"), i[0].message)
    }

    func testSelfDependency() {
        let i = issues("services:\n  a: { run: x, depends_on: [a] }\n")
        XCTAssertTrue(i.contains { $0.message.contains("depends on itself") })
    }

    func testDuplicatePorts() {
        let i = issues("services:\n  a: { run: x, port: 3000 }\n  b: { run: y, port: 3000 }\n")
        XCTAssertEqual(i.count, 1)
        XCTAssertEqual(i[0].keyPath, "services.b.port")
        XCTAssertTrue(i[0].message.contains("already used by service 'a'"))
    }

    func testInvalidPorts() {
        for bad in ["0", "70000", "abc", "-1", "3.5"] {
            let i = issues("services:\n  a:\n    run: x\n    port: \(bad)\n")
            XCTAssertEqual(i.first?.keyPath, "services.a.port", bad)
            XCTAssertTrue(i.first?.message.contains("invalid port") ?? false, bad)
        }
    }

    func testReadyValidation() {
        XCTAssertTrue(issues("services:\n  a: { run: x, ready: http }\n")[0].message.contains("needs `port:`"))
        XCTAssertTrue(issues("services:\n  a: { run: x, ready: banana }\n")[0].message.contains("unknown ready check"))
        XCTAssertTrue(issues("services:\n  a: { run: x, ready: \"log:(\" }\n")[0].message.contains("invalid regex"))
        XCTAssertTrue(issues("services:\n  a: { run: x, ready_timeout: -3 }\n")[0].keyPath.hasSuffix("ready_timeout"))
    }

    func testStructuralErrors() {
        XCTAssertTrue(issues("name: x\n")[0].message.contains("missing required `services:`"))
        XCTAssertTrue(issues("services: [a, b]\n")[0].message.contains("must be a mapping"))
        XCTAssertTrue(issues("services:\n  a: just-a-string\n")[0].message.contains("must be a mapping"))
        XCTAssertTrue(issues("services:\n  \"a/b\": { run: x }\n")[0].message.contains("invalid service name"))
        XCTAssertThrowsError(try parse("services: [unclosed\n")) { e in
            guard case StackError.syntax = e else { return XCTFail("\(e)") }
        }
    }

    func testAllIssuesReportedTogether() {
        let i = issues("services:\n  a: { port: 0 }\n  b: { run: x, depends_on: [zzz] }\n")
        XCTAssertGreaterThanOrEqual(i.count, 3)
    }

    // MARK: discovery

    func testLoadFromFileAndDirectoryAndAltNames() throws {
        try "services:\n  a: { run: x }\n".write(to: dir.appendingPathComponent(".pier.yml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try StackLoader.load(url: dir).serviceNames, ["a"])
        XCTAssertEqual(StackLoader.file(in: dir)?.lastPathComponent, ".pier.yml")
        try "services:\n  b: { run: x }\n".write(to: dir.appendingPathComponent("pier.yaml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(StackLoader.file(in: dir)?.lastPathComponent, "pier.yaml")   // pier.yaml beats .pier.yml
        try "services:\n  c: { run: x }\n".write(to: dir.appendingPathComponent("pier.yml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(StackLoader.file(in: dir)?.lastPathComponent, "pier.yml")
        XCTAssertThrowsError(try StackLoader.load(url: dir.appendingPathComponent("nope.yml")))
    }

    func testFindWalksUpAndStopsAtHome() throws {
        let home = dir.deletingLastPathComponent()          // fake $HOME
        let deep = dir.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        XCTAssertNil(StackLoader.find(from: deep, home: dir))
        try "services:\n  a: { run: x }\n".write(to: dir.appendingPathComponent("pier.yml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(StackLoader.find(from: deep, home: home)?.lastPathComponent, "pier.yml")
        // a file ABOVE home is never reached
        let outside = home.deletingLastPathComponent()
        try "services:\n  a: { run: x }\n".write(to: outside.appendingPathComponent("pier.yml"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside.appendingPathComponent("pier.yml")) }
        XCTAssertNil(StackLoader.find(from: home.appendingPathComponent("elsewhere"), home: home))
    }

    // MARK: registry

    func testRegistryRecordsAndOrders() throws {
        let root = dir.deletingLastPathComponent().appendingPathComponent("reg", isDirectory: true)
        let f1 = dir.appendingPathComponent("pier.yml"); try "x".write(to: f1, atomically: true, encoding: .utf8)
        let f2 = dir.appendingPathComponent("two.yml"); try "x".write(to: f2, atomically: true, encoding: .utf8)
        StackRegistry.record(name: "one", file: f1.path, at: Date(timeIntervalSince1970: 100), root: root)
        StackRegistry.record(name: "two", file: f2.path, at: Date(timeIntervalSince1970: 200), root: root)
        StackRegistry.record(name: "one-renamed", file: f1.path, at: Date(timeIntervalSince1970: 300), root: root)
        let k = StackRegistry.known(root: root)
        XCTAssertEqual(k.map(\.name), ["one-renamed", "two"])
        try FileManager.default.removeItem(at: f2)
        XCTAssertEqual(StackRegistry.known(root: root).map(\.name), ["one-renamed"])
        XCTAssertEqual(StackRegistry.known(root: root, includeMissing: true).count, 2)
    }
}

final class StackPlannerTests: XCTestCase {
    func svc(_ n: String, _ deps: [String] = []) -> StackService {
        StackService(name: n, command: ["x"], cwd: "/tmp", dependsOn: deps)
    }
    func file(_ s: [StackService]) -> StackFile { StackFile(name: "t", services: s) }

    func testWaves() throws {
        let f = file([svc("web", ["api", "db"]), svc("api", ["db", "cache"]), svc("db"), svc("cache"), svc("worker", ["db"])])
        XCTAssertEqual(try StackPlanner.plan(f), [["db", "cache"], ["api", "worker"], ["web"]])
    }

    func testIndependentServicesShareAWave() throws {
        let f = file([svc("a"), svc("b"), svc("c")])
        XCTAssertEqual(try StackPlanner.plan(f), [["a", "b", "c"]])
    }

    func testSelectionPullsInDependencies() throws {
        let f = file([svc("web", ["api"]), svc("api", ["db"]), svc("db"), svc("worker", ["db"]), svc("other")])
        XCTAssertEqual(try StackPlanner.plan(f, selection: ["web"]), [["db"], ["api"], ["web"]])
        XCTAssertEqual(try StackPlanner.plan(f, selection: ["worker", "other"]), [["db", "other"], ["worker"]])
        XCTAssertEqual(try StackPlanner.plan(f, selection: ["web"], includeDependencies: false), [["web"]])
    }

    func testUnknownSelection() {
        let f = file([svc("a")])
        XCTAssertThrowsError(try StackPlanner.plan(f, selection: ["zz"])) { e in
            XCTAssertEqual(e as? StackError, .unknownService("zz", known: ["a"]))
        }
    }

    func testCycleDetectedInMemory() {
        let f = file([svc("a", ["b"]), svc("b", ["a"])])
        XCTAssertThrowsError(try StackPlanner.plan(f)) { e in
            guard case StackError.cycle(let p) = e else { return XCTFail("\(e)") }
            XCTAssertEqual(p, ["a", "b", "a"])
        }
    }

    func testDependents() {
        let f = file([svc("web", ["api"]), svc("api", ["db"]), svc("db"), svc("x")])
        XCTAssertEqual(StackPlanner.dependents(of: "db", in: f), ["api", "web"])
    }
}
