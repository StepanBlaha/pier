import Foundation

/// One MCP tool: metadata for `tools/list` plus its handler.
public struct MCPTool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSON
    public let annotations: JSON
    let handler: @Sendable (MCPContext, MCPArgs) async throws -> MCPToolResult

    var listing: JSON {
        ["name": .string(name), "title": .string(name), "description": .string(description),
         "inputSchema": inputSchema, "annotations": annotations]
    }
}

public enum MCPTools {
    public static var all: [MCPTool] {
        [listServices, serviceInfo, readLogs, killService, restartService, findFreePort, waitForPort, staleServices, runService]
    }

    public static func tool(named name: String) -> MCPTool? { all.first { $0.name == name } }

    // MARK: Schema helpers

    private static func schema(_ props: [String: JSON], required: [String] = []) -> JSON {
        var o: [String: JSON] = ["type": "object", "properties": .object(props)]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        return .object(o)
    }

    private static func annotations(readOnly: Bool, destructive: Bool? = nil, idempotent: Bool? = nil) -> JSON {
        var o: [String: JSON] = ["readOnlyHint": .bool(readOnly), "openWorldHint": false]
        if let d = destructive { o["destructiveHint"] = .bool(d) }
        if let i = idempotent { o["idempotentHint"] = .bool(i) }
        return .object(o)
    }

    private static let targetProp: JSON = [
        "type": "string",
        "description": "Port number (e.g. \"3000\", always exact) or a fuzzy name matched against page title, project, framework, infra or process name (e.g. \"relay\", \"next\", \"postgres\").",
    ]

    // MARK: Summaries

    /// Compact, token-friendly view of a service for lists.
    static func summary(_ s: Service, now: Date = Date()) -> JSON {
        var o: [String: JSON] = [
            "port": .int(Int(s.port)),
            "name": .string(s.displayName),
            "kind": .string(s.kind.rawValue),
            "health": .string(s.probe?.health.rawValue ?? "unknown"),
            "url": .string(s.localURL),
            "managed": .bool(s.isManaged),
            "pid": .int(Int(s.process.pid)),
            "owners": .array(s.owners.map { .string($0.kind.rawValue) }),
        ]
        func set(_ k: String, _ v: String?) { if let v, !v.isEmpty { o[k] = .string(v) } }
        set("project", s.projectName)
        set("project_path", s.projectPath)
        set("framework", s.framework?.name)
        set("infra", s.infraName)
        set("git_branch", s.gitBranch)
        set("runtime", s.runtime)
        set("lan_url", s.lanURL)
        set("tunnel_url", s.tunnelURL)
        set("managed_id", s.managedID)
        set("docker_container", s.docker?.containerName)
        if let st = s.probe?.httpStatus { o["http_status"] = .int(st) }
        if let p = s.probe, p.protocolKind != .unknown { o["protocol"] = .string(p.protocolKind.rawValue) }
        if let start = s.process.startTime { o["uptime_s"] = .int(max(0, Int(now.timeIntervalSince(start)))) }
        if s.isNoise { o["noise"] = true }
        return .object(o)
    }

    // MARK: list_services

    static let listServices = MCPTool(
        name: "list_services",
        description: "List everything listening on localhost TCP ports, identified: port, name, project and path, framework/infra, kind (devServer/infra/docker/system/other), health (ok/error/timeout/unknown), HTTP status, URLs (local/LAN/tunnel), managed flag, pid, uptime, launcher chain (e.g. claudeCode, node), git branch. Call this first to see what is running before acting on a port or name.",
        inputSchema: schema([
            "include_noise": ["type": "boolean", "description": "Include hidden macOS/system noise (AirPlay, rapportd, app helpers). Default false."],
            "probe": ["type": "boolean", "description": "HTTP-probe each port for title/health (300ms timeout, parallel). Default true; false is faster but has no health/title."],
        ]),
        annotations: annotations(readOnly: true, idempotent: true),
        handler: { ctx, args in
            let noise = try args.bool("include_noise") ?? false
            let probe = try args.bool("probe") ?? true
            let services = await ctx.snapshot(noise, probe)
            let now = Date()
            let rows = JSON.array(services.map { summary($0, now: now) })
            return .json(rows, wrapKey: "services")
        })

    // MARK: service_info

    static let serviceInfo = MCPTool(
        name: "service_info",
        description: "Full details for one service: process (argv, cwd, CPU, memory, start time), bind addresses, project, framework, runtime, git branch, owner chain, docker mapping, HTTP probe, tunnel.",
        inputSchema: schema(["target": targetProp], required: ["target"]),
        annotations: annotations(readOnly: true, idempotent: true),
        handler: { ctx, args in
            let target = try args.requiredString("target")
            switch await MCPTarget.services(for: target, ctx: ctx) {
            case .failure(let f): return f.result
            case .success(let services):
                let now = Date()
                let items = services.map { s -> JSON in
                    var j = JSON.encoding(s)
                    if case .object(var o) = j, let start = s.process.startTime {
                        o["uptimeSeconds"] = .int(max(0, Int(now.timeIntervalSince(start))))
                        j = .object(o)
                    }
                    return j
                }
                // Several pids can share one port; a single match is the common case.
                return .json(items.count == 1 ? items[0] : .array(items), wrapKey: "services")
            }
        })

    // MARK: read_logs

    static func findManifest(_ target: String, in manifests: [ManagedManifest]) -> MCPManifestMatch {
        let t = target.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return .none }
        if let m = manifests.first(where: { $0.id.lowercased() == t }) { return .one(m) }
        let byName = manifests.filter { $0.name.lowercased() == t }
        if byName.count == 1 { return .one(byName[0]) }
        if byName.count > 1 { return .many(byName) }
        return .none
    }

    private static func manifestList(_ ms: [ManagedManifest]) -> String {
        ms.map { "  - \($0.id) \($0.name) (\($0.state.rawValue))" }.joined(separator: "\n")
    }

    static let readLogs = MCPTool(
        name: "read_logs",
        description: "Read the last lines of a service's output (ANSI codes stripped). Only works for pier-managed services (started with run_service / `pier run`, or adopted via restart_service), including ones that crashed; target may be the managed id, its name, a port, or a fuzzy name. For a non-managed service, call restart_service to adopt it so future logs are captured.",
        inputSchema: schema([
            "target": targetProp,
            "lines": ["type": "integer", "minimum": 1, "maximum": 5000, "default": 200, "description": "How many trailing lines to return. Default 200."],
        ], required: ["target"]),
        annotations: annotations(readOnly: true, idempotent: true),
        handler: { ctx, args in
            let target = try args.requiredString("target")
            let lines = min(max(try args.int("lines") ?? 200, 1), 5000)
            let manifests = ctx.managed()

            var manifest: ManagedManifest?
            switch findManifest(target, in: manifests) {
            case .one(let m): manifest = m
            case .many(let ms):
                return .error("'\(target)' matches several managed services; use one of these ids:\n\(manifestList(ms))")
            case .none: break
            }

            if manifest == nil {
                let all = await ctx.snapshot(true, true)
                switch MCPTarget.resolve(target, in: all) {
                case .ambiguous(let c):
                    return MCPTarget.ambiguousError(target, c)
                case .found(let services):
                    if let id = services.compactMap(\.managedID).first, let m = manifests.first(where: { $0.id == id }) {
                        manifest = m
                    } else {
                        let s = services[0]
                        return .error("\(MCPTarget.describe(s)) is not managed by pier, so its output was never captured. Call restart_service on it: it restarts the process under pier (adoption) and logs are available from then on. (Services started with run_service are managed from the start.)")
                    }
                case .none:
                    // Crashed managed services no longer listen; try a loose name match on manifests.
                    let t = target.lowercased()
                    let loose = manifests.filter { $0.name.lowercased().contains(t) }
                    if loose.count == 1 { manifest = loose[0] }
                    else if loose.count > 1 { return .error("'\(target)' matches several managed services; use one of these ids:\n\(manifestList(loose))") }
                    else {
                        let known = manifests.isEmpty ? "No managed services are registered." : "Managed services:\n\(manifestList(manifests))"
                        return .error("no service or managed service matches '\(target)'. \(known)")
                    }
                }
            }

            guard let m = manifest else { return MCPTarget.notFoundError(target) }
            do {
                let raw = try await ManagedClient.logs(m, tail: lines)
                let text = MCPText.lastLines(MCPText.stripANSI(raw), lines)
                let header: JSON = ["managed_id": .string(m.id), "name": .string(m.name), "state": .string(m.state.rawValue),
                                    "lines": .int(text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count)]
                var structured = header.objectValue ?? [:]
                structured["logs"] = .string(text)
                return MCPToolResult(text: text.isEmpty ? "(no output captured yet for \(m.name) [\(m.id)], state \(m.state.rawValue))" : text,
                                     structured: .object(structured))
            } catch {
                var msg = "could not read logs of \(m.name) [\(m.id)] (state \(m.state.rawValue)): \(error)"
                if let code = m.lastExitCode { msg += "; last exit code \(code)" }
                return .error(msg)
            }
        })

    // MARK: kill_service

    static let killService = MCPTool(
        name: "kill_service",
        description: "Stop a service (SIGTERM, then SIGKILL after 3s; managed services are stopped through their wrapper). Dev servers are stopped directly. Databases, Docker, system/unreadable services, or several pids on one port are refused unless confirm=true; only set confirm after the user agreed. Never touches pid 1 or pier itself. Ambiguous names are refused; pass a port.",
        inputSchema: schema([
            "target": targetProp,
            "confirm": ["type": "boolean", "default": false, "description": "Required to stop infra (postgres, redis...), Docker, system or unreadable processes."],
        ], required: ["target"]),
        annotations: annotations(readOnly: false, destructive: true, idempotent: true),
        handler: { ctx, args in
            let target = try args.requiredString("target")
            let confirm = try args.bool("confirm") ?? false
            let services: [Service]
            switch await MCPTarget.services(for: target, ctx: ctx) {
            case .failure(let f): return f.result
            case .success(let s): services = s
            }

            for s in services {
                do { try Killer.validate(pid: s.process.pid) } catch {
                    return .error("\(error.localizedDescription) (\(MCPTarget.describe(s)))")
                }
            }
            let needsConfirm = services.count > 1 || services.contains(where: Killer.requiresConfirmation)
            if needsConfirm && !confirm {
                let what = services.map { MCPTarget.describe($0) + " [\($0.kind.rawValue)\($0.isNoise ? ", system noise" : "")]" }.joined(separator: "; ")
                return .error("Refusing to kill without confirmation: \(what). This is not a plain dev server (or several processes share the port). If the user really wants it stopped, call kill_service again with confirm=true.")
            }

            let manifests = ctx.managed()
            var results: [JSON] = []
            var failed = false
            for s in services {
                var entry: [String: JSON] = ["port": .int(Int(s.port)), "pid": .int(Int(s.process.pid)), "name": .string(s.displayName)]
                if let id = s.managedID, let m = manifests.first(where: { $0.id == id }) {
                    do {
                        try await ManagedClient.stop(m)
                        entry["outcome"] = "stopped (managed)"
                    } catch {
                        entry["outcome"] = .string("failed: \(error)"); failed = true
                    }
                } else {
                    do {
                        let outcome = try await Killer.terminate(pid: s.process.pid)
                        switch outcome {
                        case .terminated: entry["outcome"] = "terminated"
                        case .killed: entry["outcome"] = "killed (needed SIGKILL)"
                        case .alreadyGone: entry["outcome"] = "already gone"
                        case .permissionDenied:
                            entry["outcome"] = "permission denied: owned by root or another user; run `pier kill \(s.port)` in a terminal for the admin prompt"
                            failed = true
                        case .stillRunning: entry["outcome"] = "still running after SIGKILL"; failed = true
                        case .failed(let e): entry["outcome"] = .string("failed (errno \(e))"); failed = true
                        }
                    } catch {
                        entry["outcome"] = .string("refused: \(error.localizedDescription)"); failed = true
                    }
                }
                results.append(.object(entry))
            }
            let payload: JSON = ["results": .array(results)]
            var r = MCPToolResult.json(payload)
            r.isError = failed
            return r
        })

    // MARK: restart_service

    static let restartService = MCPTool(
        name: "restart_service",
        description: "Restart a service. Managed services restart exactly (same command, cwd, env). A non-managed dev server is adopted: its command, cwd and environment are captured, it is killed and respawned under pier, so read_logs works afterwards. Not allowed for infra/docker/system services.",
        inputSchema: schema(["target": targetProp], required: ["target"]),
        annotations: annotations(readOnly: false, destructive: true, idempotent: false),
        handler: { ctx, args in
            let target = try args.requiredString("target")
            let manifests = ctx.managed()

            // Exact managed id/name first (also covers crashed services that no longer listen).
            var managedHit: ManagedManifest?
            if case .one(let m) = findManifest(target, in: manifests) { managedHit = m }

            var service: Service?
            if managedHit == nil {
                switch await MCPTarget.services(for: target, ctx: ctx) {
                case .failure(let f): return f.result
                case .success(let services):
                    if services.count > 1 {
                        return MCPTarget.ambiguousError(target, services)
                    }
                    service = services[0]
                    if let id = service?.managedID { managedHit = manifests.first(where: { $0.id == id }) }
                }
            }

            if let m = managedHit {
                do {
                    try await ManagedClient.restart(m)
                    let fresh = (try? await ManagedClient.status(m)) ?? m
                    return .json(["restarted": true, "adopted": false, "managed": JSON.encoding(fresh)])
                } catch {
                    return .error("restart of \(m.name) [\(m.id)] failed: \(error)")
                }
            }

            guard let s = service else { return MCPTarget.notFoundError(target) }
            if s.isNoise || s.kind == .infra || s.kind == .docker || s.kind == .system {
                return .error("Refusing to restart \(MCPTarget.describe(s)) [\(s.kind.rawValue)]: only dev servers can be restarted via adoption. Use kill_service with confirm=true and start it yourself if the user wants that.")
            }
            do { try Killer.validate(pid: s.process.pid) } catch {
                return .error("\(error.localizedDescription) (\(MCPTarget.describe(s)))")
            }
            do {
                let m = try await ManagedLauncher.adopt(s)
                return .json(["restarted": true, "adopted": true, "managed": JSON.encoding(m),
                              "note": "Now managed by pier; read_logs target \"\(m.id)\" shows its output."])
            } catch {
                return .error("could not adopt and restart \(MCPTarget.describe(s)): \(error)")
            }
        })

    // MARK: find_free_port

    static let findFreePort = MCPTool(
        name: "find_free_port",
        description: "Find the next TCP port that nothing is bound to, starting at `from` (default 3000).",
        inputSchema: schema([
            "from": ["type": "integer", "minimum": 1, "maximum": 65535, "default": 3000, "description": "First port to try."],
        ]),
        annotations: annotations(readOnly: true, idempotent: true),
        handler: { _, args in
            let from = try args.int("from") ?? 3000
            guard (1...65535).contains(from) else { return .error("'from' must be between 1 and 65535") }
            guard let port = PortFinder.nextFree(from: UInt16(from)) else {
                return .error("no free port found from \(from) up to 65535")
            }
            return .json(["port": .int(Int(port)), "requested_from": .int(from)])
        })

    // MARK: wait_for_port

    static let waitForPort = MCPTool(
        name: "wait_for_port",
        description: "Block until something listens on a port (polls every 250ms), optionally until it also answers HTTP sanely (healthy=true: any 2xx-4xx). Use after run_service or restart_service. Returns elapsed time plus the service summary, or an error on timeout.",
        inputSchema: schema([
            "port": ["type": "integer", "minimum": 1, "maximum": 65535, "description": "TCP port to wait for."],
            "timeout_s": ["type": "number", "minimum": 0.25, "maximum": 600, "default": 30, "description": "Give up after this many seconds. Default 30."],
            "healthy": ["type": "boolean", "default": false, "description": "Also require an HTTP probe to report ok."],
        ], required: ["port"]),
        annotations: annotations(readOnly: true, idempotent: true),
        handler: { ctx, args in
            let port = try args.port("port")
            let timeout = min(max(try args.double("timeout_s") ?? 30, 0.25), 600)
            let healthy = try args.bool("healthy") ?? false
            let started = Date()
            let deadline = started.addingTimeInterval(timeout)
            var lastHealth = "not probed"

            while true {
                try Task.checkCancellation()
                let listening = ProcScanner.listeningSockets().contains { $0.port == port }
                if listening {
                    var ok = true
                    if healthy {
                        let probe = await Prober.probe(port: port, timeout: 1.0)
                        ok = probe.health == .ok
                        lastHealth = probe.health.rawValue + (probe.httpStatus.map { " (HTTP \($0))" } ?? "")
                    }
                    if ok {
                        let services = await ctx.snapshot(true, healthy ? true : false).filter { $0.port == port }
                        let elapsed = (Date().timeIntervalSince(started) * 1000).rounded() / 1000
                        var o: [String: JSON] = ["port": .int(Int(port)), "listening": true, "elapsed_s": .double(elapsed)]
                        if healthy { o["healthy"] = true }
                        if let s = services.first {
                            o["service"] = summary(s)
                            if services.count > 1 { o["other_pids"] = .array(services.dropFirst().map { .int(Int($0.process.pid)) }) }
                        }
                        return .json(.object(o))
                    }
                }
                if Date() >= deadline {
                    let elapsed = (Date().timeIntervalSince(started) * 10).rounded() / 10
                    if listening {
                        return .error("port \(port) is listening but did not become healthy within \(elapsed)s (last probe: \(lastHealth)). Check read_logs.")
                    }
                    return .error("nothing listened on port \(port) within \(elapsed)s. If you started it with run_service, check read_logs for a startup failure.")
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        })

    // MARK: stale_services

    static let staleServices = MCPTool(
        name: "stale_services",
        description: "Find forgotten dev servers: running at least `days` days, idle CPU, and no active client connections. Read-only; use kill_service to clean them up (with the user's agreement).",
        inputSchema: schema([
            "days": ["type": "number", "minimum": 0, "default": 3, "description": "Minimum uptime in days. Default 3."],
        ]),
        annotations: annotations(readOnly: true, idempotent: true),
        handler: { ctx, args in
            let days = max(try args.double("days") ?? 3, 0)
            let services = await ctx.snapshot(false, false)
            let now = Date()
            let entries = Staleness.find(in: services, now: now, minAge: days * 86_400)
            let rows = entries.map { e -> JSON in
                var o = summary(e.service, now: now).objectValue ?? [:]
                o["reasons"] = .array(e.verdict.reasons.map { .string($0) })
                if let c = e.verdict.activeConnections { o["active_connections"] = .int(c) }
                if let rss = e.service.process.rssBytes { o["memory_bytes"] = .int(Int(rss)) }
                return .object(o)
            }
            let payload: JSON = ["days": .double(days), "count": .int(rows.count), "stale": .array(rows)]
            return .json(payload)
        })

    // MARK: run_service

    static let runService = MCPTool(
        name: "run_service",
        description: "Start a command (typically a dev server) under pier as a managed, detached service so its logs stay readable and it can be restarted. Returns the managed manifest (id, pid, state). Follow with wait_for_port, then read_logs with the managed id. `command` is an argv array (run directly) or a string (run through `zsh -lc`).",
        inputSchema: schema([
            "command": [
                "oneOf": [
                    ["type": "array", "items": ["type": "string"], "minItems": 1],
                    ["type": "string"],
                ],
                "description": "e.g. [\"npm\",\"run\",\"dev\"] or \"npm run dev -- --port 3005\".",
            ],
            "cwd": ["type": "string", "description": "Absolute working directory (the project folder). ~ is expanded."],
            "name": ["type": "string", "description": "Display name; defaults to the cwd's folder name."],
        ], required: ["command", "cwd"]),
        annotations: annotations(readOnly: false, destructive: false, idempotent: false),
        handler: { _, args in
            var argv: [String] = []
            switch args.values["command"] {
            case .some(.array(let a)):
                argv = a.compactMap(\.stringValue)
                if argv.count != a.count { return .error("'command' array must contain only strings") }
            case .some(.string(let s)):
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { argv = ["/bin/zsh", "-lc", t] }
            default: break
            }
            guard let first = argv.first, !first.isEmpty else { return .error("'command' is required (argv array or shell string)") }

            let cwdArg = try args.requiredString("cwd")
            let cwd = (cwdArg as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
                return .error("cwd '\(cwd)' is not an existing directory")
            }
            let name = try args.string("name").flatMap { $0.isEmpty ? nil : $0 }

            do {
                let m = try await ManagedLauncher.spawnDetached(command: argv, cwd: cwd, name: name)
                return .json(["started": true, "managed": JSON.encoding(m),
                              "next": "wait_for_port with the port the server prints, then read_logs target \"\(m.id)\"."])
            } catch {
                return .error("could not start \(argv.joined(separator: " ")): \(error)")
            }
        })
}
