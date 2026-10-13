import Foundation

public struct StackServiceResult: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Started and passed its readiness check.
        case ready
        /// Started; no readiness check configured.
        case started
        case alreadyRunning = "already-running"
        case failed
        /// Not started because a dependency failed.
        case skipped
        case stopped
        case notRunning = "not-running"

        public var isFailure: Bool { self == .failed || self == .skipped }
    }
    public var name: String
    public var port: UInt16?
    public var state: State
    public var url: String?
    public var detail: String?
    public var managedID: String?
    public var pid: Int32?
    public init(name: String, port: UInt16? = nil, state: State, url: String? = nil, detail: String? = nil,
                managedID: String? = nil, pid: Int32? = nil) {
        self.name = name; self.port = port; self.state = state; self.url = url; self.detail = detail
        self.managedID = managedID; self.pid = pid
    }
}

public struct StackRunResult: Sendable {
    public var stack: String
    public var waves: [[ServiceName]]
    public var services: [StackServiceResult]
    public var ok: Bool { !services.contains { $0.state.isFailure } }
}

/// Progress notifications; may arrive from concurrent tasks.
public enum StackEvent: Sendable {
    case starting(service: ServiceName, message: String)
    /// Periodic "still waiting" ping while a readiness check is pending.
    case waiting(service: ServiceName, message: String, elapsed: TimeInterval)
    case finished(StackServiceResult)
    case stopping(service: ServiceName)
}

public struct StackRunner: Sendable {
    public var backend: StackBackend
    /// Readiness poll interval (seconds). Tests lower it.
    public var pollInterval: TimeInterval
    public var onEvent: @Sendable (StackEvent) -> Void
    /// Resolves a stack name to its file for `downAll` ordering.
    public var fileForStack: @Sendable (String) -> StackFile?

    public init(backend: StackBackend = LiveStackBackend(), pollInterval: TimeInterval = 0.25,
                onEvent: @escaping @Sendable (StackEvent) -> Void = { _ in },
                fileForStack: @escaping @Sendable (String) -> StackFile? = { StackRegistry.file(named: $0) }) {
        self.backend = backend; self.pollInterval = pollInterval; self.onEvent = onEvent; self.fileForStack = fileForStack
    }

    // MARK: up

    public func up(_ file: StackFile, selection: [ServiceName] = []) async throws -> StackRunResult {
        let waves = try StackPlanner.plan(file, selection: selection)
        var results: [ServiceName: StackServiceResult] = [:]
        var ordered: [ServiceName] = []

        for wave in waves {
            // Decide skips from earlier waves, then start the rest in parallel.
            var toStart: [StackService] = []
            for n in wave {
                guard let svc = file.service(n) else { continue }
                ordered.append(n)
                if let bad = svc.dependsOn.first(where: { results[$0]?.state.isFailure ?? false }) {
                    let r = StackServiceResult(name: n, port: svc.port, state: .skipped, detail: "dependency '\(bad)' \(results[bad]?.state == .skipped ? "was skipped" : "failed")")
                    results[n] = r; onEvent(.finished(r))
                } else { toStart.append(svc) }
            }
            await withTaskGroup(of: StackServiceResult.self) { group in
                for svc in toStart { group.addTask { await self.start(svc, in: file) } }
                for await r in group { results[r.name] = r }
            }
        }
        return StackRunResult(stack: file.name, waves: waves, services: ordered.compactMap { results[$0] })
    }

    static func fullName(_ stack: String, _ service: String) -> String { "\(stack)/\(service)" }

    private func isLive(_ m: ManagedManifest) -> Bool { m.state != .exited && m.state != .crashed }

    private func start(_ svc: StackService, in file: StackFile) async -> StackServiceResult {
        let full = Self.fullName(file.name, svc.name)
        func result(_ state: StackServiceResult.State, _ detail: String? = nil, _ m: ManagedManifest? = nil) -> StackServiceResult {
            let r = StackServiceResult(name: svc.name, port: svc.port, state: state,
                                       url: svc.port.map { "http://localhost:\($0)" }, detail: detail,
                                       managedID: m?.id, pid: m?.childPid)
            onEvent(.finished(r)); return r
        }

        // 1. Already running under this stack?
        if let existing = backend.runningManifests().first(where: { $0.stack == file.name && $0.name == full && isLive($0) }) {
            onEvent(.starting(service: svc.name, message: "already running (\(existing.id)), checking readiness"))
            if let why = await awaitReady(svc, existing) { return result(.failed, "already running but not ready: \(why)", existing) }
            return result(.alreadyRunning, nil, existing)
        }

        // 2. Expected port taken by something else?
        if let port = svc.port, let holder = backend.portHolder(port) {
            return result(.failed, "port \(port) is already in use by \(holder.description)")
        }
        if !FileManager.default.fileExists(atPath: svc.cwd) {
            return result(.failed, "cwd does not exist: \(svc.cwd)")
        }

        // 3. Spawn.
        onEvent(.starting(service: svc.name, message: svc.display))
        let manifest: ManagedManifest
        do {
            manifest = try await backend.spawn(command: svc.command, cwd: svc.cwd, env: svc.env.isEmpty ? nil : svc.env, name: full, stack: file.name)
        } catch { return result(.failed, "could not start: \(error)") }

        // 4. Readiness.
        if svc.ready == .none { return result(.started, nil, manifest) }
        if let why = await awaitReady(svc, manifest) { return result(.failed, why, manifest) }
        return result(.ready, nil, manifest)
    }

    /// nil = ready, otherwise the failure reason.
    private func awaitReady(_ svc: StackService, _ manifest: ManagedManifest) async -> String? {
        if svc.ready == .none { return nil }
        let begun = Date()
        let deadline = begun.addingTimeInterval(svc.readyTimeout)
        let regex: NSRegularExpression? = { if case .log(let p) = svc.ready { return try? NSRegularExpression(pattern: p, options: [.anchorsMatchLines]) }; return nil }()
        var lastPing = begun
        let what: String = {
            switch svc.ready {
            case .http: return "HTTP on :\(svc.port ?? 0)"
            case .port: return "port :\(svc.port ?? 0)"
            case .log(let p): return "log /\(p)/"
            case .none: return ""
            }
        }()

        while true {
            switch svc.ready {
            case .port: if let p = svc.port, await backend.isListening(p) { return nil }
            case .http: if let p = svc.port, await backend.httpHealthy(p) { return nil }
            case .log:
                if let regex, let text = try? await backend.logs(manifest, tail: 1000) {
                    let plain = Self.stripANSI(text)
                    if regex.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)) != nil { return nil }
                }
            case .none: return nil
            }

            // Did the process die?
            let live = backend.runningManifests().first { $0.id == manifest.id }
            if let live {
                if let st = try? await backend.status(live), st.state == .crashed || (st.state == .exited && (st.lastExitCode ?? 0) != 0) {
                    return "exited" + (st.lastExitCode.map { " with code \($0)" } ?? "") + " before ready" + (await Self.logTail(backend, live))
                }
            } else {
                // Wrapper is gone. One-shot launchers (`docker compose up -d`) may still bring the port up; logs are unreachable though.
                if case .log = svc.ready { return "process exited before the log pattern appeared" }
            }

            if Date() >= deadline {
                return "not ready after \(Self.fmt(svc.readyTimeout))s (waiting for \(what))" + (live == nil ? "; process has exited" : "; still running, see `pier logs \(manifest.name)`")
            }
            let now = Date()
            if now.timeIntervalSince(lastPing) >= 1 {
                lastPing = now
                onEvent(.waiting(service: svc.name, message: "waiting for \(what)", elapsed: now.timeIntervalSince(begun)))
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    private static func logTail(_ backend: StackBackend, _ m: ManagedManifest) async -> String {
        guard let t = try? await backend.logs(m, tail: 5) else { return "" }
        let lines = stripANSI(t).split(separator: "\n", omittingEmptySubsequences: true).suffix(3)
        return lines.isEmpty ? "" : ": " + lines.joined(separator: " | ")
    }

    static func fmt(_ t: TimeInterval) -> String { t == t.rounded() ? String(Int(t)) : String(format: "%.1f", t) }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    // MARK: down

    /// Stops managed services of `file`'s stack, dependents first. `selection` limits to named services (their dependencies stay up).
    public func down(_ file: StackFile, selection: [ServiceName] = []) async throws -> [StackServiceResult] {
        for n in selection where file.service(n) == nil { throw StackError.unknownService(n, known: file.serviceNames) }
        let selected = Set(selection.isEmpty ? file.serviceNames : selection)
        var waves = try StackPlanner.plan(file).reversed().map { $0.filter(selected.contains) }.filter { !$0.isEmpty }

        let live = backend.runningManifests().filter { $0.stack == file.name && isLive($0) }
        // Services running under this stack name but no longer defined in the file: stop them first (only on a full down).
        if selection.isEmpty {
            let known = Set(file.serviceNames)
            let orphans = live.compactMap { m -> ServiceName? in
                guard let n = Self.serviceName(of: m, stack: file.name), !known.contains(n) else { return nil }
                return n
            }
            if !orphans.isEmpty { waves.insert(Array(Set(orphans)).sorted(), at: 0) }
        }

        var out: [StackServiceResult] = []
        for wave in waves {
            let results = await withTaskGroup(of: StackServiceResult?.self) { group -> [StackServiceResult] in
                for n in wave {
                    let ms = live.filter { Self.serviceName(of: $0, stack: file.name) == n }
                    let port = file.service(n)?.port
                    group.addTask { await self.stopAll(name: n, port: port, manifests: ms) }
                }
                var acc: [StackServiceResult] = []
                for await r in group { if let r { acc.append(r) } }
                return acc
            }
            out += wave.compactMap { n in results.first { $0.name == n } }
        }
        return out
    }

    /// Stops every service of every stack (ordered by the known pier.yml when available, else newest first).
    public func downAll() async -> [StackServiceResult] {
        let live = backend.runningManifests().filter { $0.stack != nil && isLive($0) }
        var out: [StackServiceResult] = []
        for stack in Set(live.compactMap(\.stack)).sorted() {
            let mine = live.filter { $0.stack == stack }
            var waves: [[ManagedManifest]]
            if let f = fileForStack(stack), let planned = try? StackPlanner.plan(f) {
                let known = Set(f.serviceNames)
                let orphans = mine.filter { !known.contains(Self.serviceName(of: $0, stack: stack) ?? "") }
                waves = (orphans.isEmpty ? [] : [orphans]) + planned.reversed().map { wave in mine.filter { wave.contains(Self.serviceName(of: $0, stack: stack) ?? "") } }
            } else {
                waves = mine.sorted { $0.startedAt > $1.startedAt }.map { [$0] }
            }
            for wave in waves where !wave.isEmpty {
                let results = await withTaskGroup(of: StackServiceResult?.self) { group -> [StackServiceResult] in
                    for m in wave {
                        let n = Self.serviceName(of: m, stack: stack) ?? m.name
                        group.addTask { await self.stopAll(name: "\(stack)/\(n)", port: nil, manifests: [m]) }
                    }
                    var acc: [StackServiceResult] = []
                    for await r in group { if let r { acc.append(r) } }
                    return acc
                }
                out += results.sorted { $0.name < $1.name }
            }
        }
        return out
    }

    static func serviceName(of m: ManagedManifest, stack: String) -> ServiceName? {
        let prefix = stack + "/"
        return m.name.hasPrefix(prefix) ? String(m.name.dropFirst(prefix.count)) : nil
    }

    private func stopAll(name: String, port: UInt16?, manifests: [ManagedManifest]) async -> StackServiceResult? {
        func finish(_ r: StackServiceResult) -> StackServiceResult { onEvent(.finished(r)); return r }
        guard !manifests.isEmpty else { return finish(StackServiceResult(name: name, port: port, state: .notRunning)) }
        onEvent(.stopping(service: name))
        var failure: String?
        var lingering = false
        for m in manifests {
            do {
                try await backend.stop(m)
            } catch ManagedError.notRunning { continue }
            catch { failure = "\(error)"; continue }
            // Wait for the wrapper to disappear (up to 5s).
            var waited = 0.0
            while backend.runningManifests().contains(where: { $0.id == m.id }), waited < 5 {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000)); waited += pollInterval
            }
            if backend.runningManifests().contains(where: { $0.id == m.id }) { lingering = true }
        }
        let first = manifests.first
        if let failure { return finish(StackServiceResult(name: name, port: port, state: .failed, detail: failure, managedID: first?.id)) }
        return finish(StackServiceResult(name: name, port: port, state: .stopped, detail: lingering ? "stop requested, still shutting down" : nil, managedID: first?.id))
    }
}
