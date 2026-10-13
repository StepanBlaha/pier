import XCTest
@testable import PierCore

final class IdentifyClassificationTests: IdentifyTestCase {
    // MARK: infra

    func testInfraByProcessName() {
        let cases: [(String, UInt16, String)] = [
            ("postgres", 5432, "PostgreSQL"), ("redis-server", 6379, "Redis"), ("mongod", 27017, "MongoDB"),
            ("mysqld", 3306, "MySQL"), ("ollama", 11434, "Ollama"), ("memcached", 11211, "Memcached"),
            ("minio", 9000, "MinIO"), ("meilisearch", 7700, "Meilisearch"), ("nats-server", 4222, "NATS"),
            ("clickhouse", 8123, "ClickHouse"),
        ]
        for (name, port, infra) in cases {
            let s = enriched(proc(name, exe: "/opt/homebrew/bin/\(name)"), port: port)
            XCTAssertEqual(s.infraName, infra, name)
            XCTAssertEqual(s.kind, .infra, name)
        }
    }

    func testNameMatchBeatsPort() {
        // postgres on an unusual port, redis on 5432
        XCTAssertEqual(enriched(proc("postgres"), port: 5555).infraName, "PostgreSQL")
        XCTAssertEqual(enriched(proc("redis-server"), port: 5432).infraName, "Redis")
    }

    func testInfraByJavaArgs() {
        let es = enriched(proc("java", args: ["java", "-cp", "lib", "org.elasticsearch.bootstrap.Elasticsearch"]), port: 9200)
        XCTAssertEqual(es.infraName, "Elasticsearch")
        let kafka = enriched(proc("java", args: ["java", "kafka.Kafka", "server.properties"]), port: 9092)
        XCTAssertEqual(kafka.infraName, "Kafka")
        let rabbit = enriched(proc("beam.smp", args: ["beam.smp", "-sname", "rabbit@host", "rabbitmq"]), port: 5672)
        XCTAssertEqual(rabbit.infraName, "RabbitMQ")
    }

    func testDockerProxiedPortsAreDockerKindWithInfraName() {
        let docker = proc("com.docker.backend", exe: "/Applications/Docker.app/Contents/MacOS/com.docker.backend")
        let pg = enriched(docker, port: 5432)
        XCTAssertEqual(pg.kind, .docker)
        XCTAssertEqual(pg.infraName, "PostgreSQL")
        XCTAssertEqual(enriched(docker, port: 54323).infraName, "Supabase")
        XCTAssertNil(enriched(docker, port: 3000).infraName)
        XCTAssertEqual(enriched(proc("vpnkit"), port: 8080).kind, .docker)
        XCTAssertEqual(enriched(proc("com.docker.backe"), port: 8080).kind, .docker) // truncated p_comm
    }

    func testPortOnlyInfraSkippedForDevServers() throws {
        try write("proj/package.json", "{}")
        let cwd = tmp.appendingPathComponent("proj").path
        // A node dev server that happens to use 9000 or 5432 is not MinIO / Postgres.
        let s = enriched(proc("node", args: ["node", "server.js"], cwd: cwd), port: 9000)
        XCTAssertNil(s.infraName)
        XCTAssertEqual(s.kind, .devServer)
        XCTAssertNil(enriched(proc("php-fpm"), port: 9000).infraName)
        XCTAssertEqual(enriched(proc("somedb"), port: 5432).infraName, "PostgreSQL") // unknown, no dev context
    }

    func testIsKnownNonHTTP() {
        func nonHTTP(_ name: String, _ port: UInt16, args: [String]? = nil) -> Bool {
            Identifier.isKnownNonHTTP(enriched(proc(name, args: args ?? [name]), port: port))
        }
        XCTAssertTrue(nonHTTP("postgres", 5432))
        XCTAssertTrue(nonHTTP("redis-server", 6379))
        XCTAssertTrue(nonHTTP("mongod", 27017))
        XCTAssertTrue(nonHTTP("mysqld", 3306))
        XCTAssertTrue(nonHTTP("memcached", 11211))
        XCTAssertTrue(nonHTTP("nats-server", 4222))
        XCTAssertTrue(nonHTTP("beam.smp", 5672, args: ["beam.smp", "rabbitmq"]))
        XCTAssertFalse(nonHTTP("beam.smp", 15672, args: ["beam.smp", "rabbitmq"]))
        XCTAssertFalse(nonHTTP("ollama", 11434))
        XCTAssertFalse(nonHTTP("minio", 9000))
        XCTAssertFalse(nonHTTP("meilisearch", 7700))
        XCTAssertFalse(nonHTTP("java", 9200, args: ["java", "org.elasticsearch.bootstrap.Elasticsearch"]))
        XCTAssertFalse(nonHTTP("node", 3000))
        let docker = proc("com.docker.backend", exe: "/Applications/Docker.app/Contents/MacOS/com.docker.backend")
        XCTAssertFalse(Identifier.isKnownNonHTTP(enriched(docker, port: 54322))) // Supabase
        XCTAssertTrue(Identifier.isKnownNonHTTP(enriched(docker, port: 6379)))
    }

    // MARK: noise

    func testNoiseByName() {
        for name in ["ControlCenter", "rapportd", "sharingd", "remoted", "identityservicesd", "Spotify", "figma_agent",
                     "Raycast", "1Password", "Discord", "zoom.us", "Microsoft Teams", "Dropbox", "Adobe Desktop Service",
                     "Creative Cloud Helper", "steam_osx", "LogiOptionsMgr"] {
            let s = enriched(proc(name, uid: 501, cwd: "/"), port: 5000)
            XCTAssertTrue(s.isNoise, name)
            XCTAssertEqual(s.kind, .system, name)
        }
        XCTAssertTrue(enriched(proc("identityservices"), port: 1).isNoise) // truncated
    }

    func testNoiseBySystemPath() {
        let daemon = proc("someunknownd", uid: 0, exe: "/usr/libexec/someunknownd", cwd: "/")
        XCTAssertTrue(enriched(daemon).isNoise)
        XCTAssertTrue(enriched(proc("x", uid: 0, exe: "/System/Library/CoreServices/x", accessible: false)).isNoise)
        XCTAssertTrue(enriched(proc("sshd", uid: 0, exe: "/usr/sbin/sshd", cwd: "/"), port: 22).isNoise)
        XCTAssertTrue(enriched(proc("x", exe: "/Library/Apple/System/Library/x", cwd: "/")).isNoise)
    }

    func testUserRunSystemPythonWithProjectCwdIsNotNoise() throws {
        try write("p/requirements.txt", "")
        let py = proc("python3", exe: "/System/Library/Frameworks/Python.framework/Versions/3.9/bin/python3.9",
                      args: ["python3", "-m", "http.server"], cwd: tmp.appendingPathComponent("p").path)
        let s = enriched(py, port: 8000)
        XCTAssertFalse(s.isNoise)
        XCTAssertEqual(s.kind, .devServer)
    }

    func testDevServersAreNotNoise() throws {
        try write("app/package.json", "{}")
        let s = enriched(proc("node", exe: "/opt/homebrew/bin/node", args: ["node", "x.js"], cwd: tmp.appendingPathComponent("app").path))
        XCTAssertFalse(s.isNoise)
    }

    // MARK: kind

    func testKinds() throws {
        try write("app/package.json", "{}")
        let cwd = tmp.appendingPathComponent("app").path
        XCTAssertEqual(enriched(proc("node", args: ["node", "x.js"], cwd: cwd)).kind, .devServer)
        XCTAssertEqual(enriched(proc("python3", args: ["python3", "x.py"], cwd: cwd)).kind, .devServer)
        XCTAssertEqual(enriched(proc("myapp", args: ["myapp"], cwd: cwd)).kind, .other)        // compiled binary, no framework
        XCTAssertEqual(enriched(proc("node", args: ["node", "x.js"])).kind, .other)            // runtime but no project
        XCTAssertEqual(enriched(proc("myapp", args: ["myapp", "serve"], cwd: cwd)).kind, .other)
        let hugo = enriched(proc("hugo", args: ["hugo", "server"], cwd: cwd))
        XCTAssertEqual(hugo.kind, .devServer)
        XCTAssertEqual(hugo.framework?.id, "hugo")
    }

    // MARK: owners

    func testOwnerClassification() {
        func kind(_ name: String, exe: String? = nil, args: [String]? = nil, pid: Int32 = 50) -> OwnerKind? {
            OwnerClassifier.kind(of: proc(name, pid: pid, exe: exe, args: args ?? []))
        }
        XCTAssertEqual(kind("Code Helper (Plugin)", exe: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"), .vscode)
        XCTAssertEqual(kind("Electron", exe: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"), .vscode)
        XCTAssertEqual(kind("Cursor Helper (Plugin)", exe: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"), .cursor)
        XCTAssertEqual(kind("zed", exe: "/Applications/Zed.app/Contents/MacOS/zed"), .zed)
        XCTAssertEqual(kind("Xcode", exe: "/Applications/Xcode.app/Contents/MacOS/Xcode"), .xcode)
        XCTAssertEqual(kind("iTerm2", exe: "/Applications/iTerm.app/Contents/MacOS/iTerm2"), .iterm)
        XCTAssertEqual(kind("Terminal", exe: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"), .terminal)
        XCTAssertEqual(kind("ghostty", exe: "/Applications/Ghostty.app/Contents/MacOS/ghostty"), .ghostty)
        XCTAssertEqual(kind("stable", exe: "/Applications/Warp.app/Contents/MacOS/stable"), .warp)
        XCTAssertEqual(kind("wezterm-gui"), .wezterm)
        XCTAssertEqual(kind("kitty"), .kitty)
        XCTAssertEqual(kind("alacritty"), .alacritty)
        XCTAssertEqual(kind("tmux: server"), .tmux)
        XCTAssertEqual(kind("claude"), .claudeCode)
        XCTAssertEqual(kind("node", args: ["node", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"]), .claudeCode)
        XCTAssertEqual(kind("claude", exe: "/Applications/Claude.app/Contents/MacOS/Claude"), .other)
        XCTAssertEqual(kind("launchd", pid: 1), .launchd)
        XCTAssertEqual(kind("com.docker.backend"), .docker)
        XCTAssertEqual(kind("npm"), .other)
        XCTAssertEqual(kind("pnpm"), .other)
        XCTAssertEqual(kind("node", args: ["node", "build.js"]), .other)
        for shell in ["zsh", "-zsh", "bash", "fish", "sh", "login"] { XCTAssertNil(kind(shell), shell) }
    }

    func testOwnerChainOrderingAndShellSkipping() {
        let parents = [
            proc("npm", pid: 200, ppid: 190),
            proc("zsh", pid: 190, ppid: 180),
            proc("Code Helper (Plugin)", pid: 180, ppid: 170, exe: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/x"),
            proc("Electron", pid: 170, ppid: 1, exe: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"),
            proc("launchd", pid: 1, ppid: 0),
        ]
        let s = enriched(proc("node"), parents: parents)
        XCTAssertEqual(s.owners.map(\.kind), [.other, .vscode, .launchd])
        XCTAssertEqual(s.owners.map(\.pid), [200, 180, 1])
    }

    // MARK: bind scope + LAN

    func testBindScope() {
        XCTAssertEqual(Identifier.bindScope(for: ["127.0.0.1"]), .loopback)
        XCTAssertEqual(Identifier.bindScope(for: ["::1", "127.0.0.1"]), .loopback)
        XCTAssertEqual(Identifier.bindScope(for: ["::ffff:127.0.0.1"]), .loopback)
        XCTAssertEqual(Identifier.bindScope(for: ["localhost"]), .loopback)
        XCTAssertEqual(Identifier.bindScope(for: ["0.0.0.0"]), .all)
        XCTAssertEqual(Identifier.bindScope(for: ["::"]), .all)
        XCTAssertEqual(Identifier.bindScope(for: ["*"]), .all)
        XCTAssertEqual(Identifier.bindScope(for: ["127.0.0.1", "::"]), .all)
        XCTAssertEqual(Identifier.bindScope(for: ["192.168.1.5"]), .specific)
        XCTAssertEqual(Identifier.bindScope(for: ["127.0.0.1", "192.168.1.5"]), .specific)
    }

    func testLANURL() {
        let loop = enriched(proc("node"), port: 3000, addresses: ["127.0.0.1"])
        XCTAssertNil(loop.lanURL)
        let specific = enriched(proc("node"), port: 3000, addresses: ["192.168.1.5"])
        XCTAssertEqual(specific.lanURL, "http://192.168.1.5:3000")
        let all = enriched(proc("node"), port: 4000, addresses: ["0.0.0.0"])
        if let ip = Identifier.lanIPv4() { XCTAssertEqual(all.lanURL, "http://\(ip):4000") } else { XCTAssertNil(all.lanURL) }
    }

    func testPickLANPrefersEnInterfaces() {
        XCTAssertEqual(Identifier.pickLAN(from: [("utun3", "100.64.0.2"), ("en1", "10.0.0.9"), ("en0", "192.168.1.5")]), "192.168.1.5")
        XCTAssertEqual(Identifier.pickLAN(from: [("awdl0", "1.1.1.1"), ("bridge0", "2.2.2.2"), ("en2", "10.0.0.2"), ("en10", "10.0.0.10")]), "10.0.0.2")
        XCTAssertNil(Identifier.pickLAN(from: [("utun0", "100.1.1.1"), ("en0", "169.254.3.3"), ("llw0", "3.3.3.3")]))
        XCTAssertEqual(Identifier.pickLAN(from: [("utun0", "100.1.1.1"), ("en0", "192.168.0.2")]), "192.168.0.2")
    }

    func testLanIPv4IsValidIfPresent() {
        guard let ip = Identifier.lanIPv4() else { return }
        XCTAssertEqual(ip.split(separator: ".").count, 4)
        XCTAssertFalse(ip.hasPrefix("127."))
    }
}
