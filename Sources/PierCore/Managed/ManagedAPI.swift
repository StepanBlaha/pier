import Foundation
import Darwin

// Registry / client / launcher for managed services.

public enum ManagedRegistry {
    /// Live manifests (wrapper pid alive). Deletes manifests/sockets of dead wrappers.
    public static func all() -> [ManagedManifest] {
        let dir = ManagedPaths.runDir
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [ManagedManifest] = []
        var liveIDs = Set<String>()
        for n in names where n.hasSuffix(".json") && !n.hasPrefix(".") {
            let url = dir.appendingPathComponent(n)
            guard let m = ManagedFiles.readManifest(url) else { continue }
            if wrapperAlive(m.wrapperPid) {
                out.append(m); liveIDs.insert(m.id)
            } else {
                unlink(url.path)
                unlink(ManagedPaths.socketURL(id: m.id).path)
            }
        }
        // Orphaned sockets / env files / week-old logs.
        let now = Date()
        for n in names {
            let id = String(n.prefix(while: { $0 != "." }))
            guard !n.hasPrefix("."), !liveIDs.contains(id) else { continue }
            let path = dir.appendingPathComponent(n).path
            if n.hasSuffix(".sock") || n.hasSuffix(".env") {
                // Young files may belong to a wrapper that is still starting (socket binds before the manifest lands).
                let age = ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date).map { now.timeIntervalSince($0) } ?? 0
                if age > 30, !fm.fileExists(atPath: dir.appendingPathComponent("\(id).json").path) { unlink(path) }
            } else if n.hasSuffix(".log") || n.hasSuffix(".log.1") {
                if let d = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, now.timeIntervalSince(d) > 86_400 {
                    unlink(path)
                }
            }
        }
        return out.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
    }

    static func wrapperAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) == -1 { return errno == EPERM }
        return Killer.isAlive(pid)
    }

    /// Manifest whose childPid (or wrapperPid) is `pid` or an ancestor of `pid` (npm → node chains).
    public static func manifest(owning pid: Int32, parents: [ProcInfo]) -> ManagedManifest? {
        manifest(owning: pid, parents: parents, in: all())
    }

    public static func manifest(owning pid: Int32, parents: [ProcInfo], in manifests: [ManagedManifest]) -> ManagedManifest? {
        for p in [pid] + parents.map(\.pid) {
            if let m = manifests.first(where: { $0.childPid == p || $0.wrapperPid == p }) { return m }
        }
        return nil
    }

    /// Exact id, else exact name (case-insensitive), else unique name prefix. nil when nothing or ambiguous.
    public static func find(_ target: String, in manifests: [ManagedManifest]) -> [ManagedManifest] {
        let t = target.lowercased()
        if let m = manifests.first(where: { $0.id == t }) { return [m] }
        let exact = manifests.filter { $0.name.lowercased() == t }
        if !exact.isEmpty { return exact }
        return manifests.filter { $0.name.lowercased().hasPrefix(t) }
    }
}

public enum ManagedClient {
    // MARK: Synchronous core (also used by the CLI's start-up poll)

    static func request(socketPath: String, _ req: ManagedRequest, timeout: TimeInterval) throws -> ManagedResponse {
        guard let fd = UnixSocket.connect(path: socketPath, timeout: min(timeout, 2)) else {
            throw ManagedError.notRunning("cannot connect to \(socketPath)")
        }
        defer { close(fd) }
        UnixSocket.setTimeouts(fd, recv: timeout, send: timeout)
        var data = try ManagedCoding.encoder().encode(req)
        data.append(0x0A)
        guard UnixSocket.writeAll(fd, data) else { throw ManagedError.protocolError("write failed") }
        guard let line = UnixSocket.readLine(fd) else { throw ManagedError.protocolError("no response (timeout?)") }
        let resp = try ManagedCoding.decoder().decode(ManagedResponse.self, from: line)
        if !resp.ok { throw ManagedError.protocolError(resp.error ?? "request failed") }
        return resp
    }

    static func statusSync(socketPath: String, timeout: TimeInterval) throws -> ManagedManifest {
        guard let m = try request(socketPath: socketPath, .status, timeout: timeout).manifest else {
            throw ManagedError.protocolError("status without manifest")
        }
        return m
    }

    private static func blocking<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async { cont.resume(with: Result { try work() }) }
        }
    }

    // MARK: API

    public static func status(_ m: ManagedManifest) async throws -> ManagedManifest {
        let path = m.socketPath
        return try await blocking { try statusSync(socketPath: path, timeout: 3) }
    }

    public static func logs(_ m: ManagedManifest, tail: Int = 200) async throws -> String {
        let path = m.socketPath
        return try await blocking { try request(socketPath: path, .logs(tail: tail, follow: false), timeout: 5).logs ?? "" }
    }

    /// Initial tail, then live chunks until cancelled.
    public static func followLogs(_ m: ManagedManifest, tail: Int = 200) -> AsyncThrowingStream<String, Error> {
        let path = m.socketPath
        return AsyncThrowingStream { cont in
            guard let fd = UnixSocket.connect(path: path, timeout: 2) else {
                cont.finish(throwing: ManagedError.notRunning(m.id)); return
            }
            let closed = LockedFlag()
            cont.onTermination = { _ in closed.set(); shutdown(fd, SHUT_RDWR) }
            let t = Thread {
                defer { close(fd) }
                UnixSocket.setTimeouts(fd, recv: 5, send: 5)
                guard var req = try? ManagedCoding.encoder().encode(ManagedRequest.logs(tail: tail, follow: true)) else {
                    cont.finish(throwing: ManagedError.protocolError("encode")); return
                }
                req.append(0x0A)
                guard UnixSocket.writeAll(fd, req), let line = UnixSocket.readLine(fd) else {
                    cont.finish(throwing: ManagedError.protocolError("no response")); return
                }
                guard let resp = try? ManagedCoding.decoder().decode(ManagedResponse.self, from: line), resp.ok else {
                    cont.finish(throwing: ManagedError.protocolError("logs request refused")); return
                }
                UnixSocket.setTimeouts(fd, recv: nil, send: nil)
                if let initial = resp.logs, !initial.isEmpty { cont.yield(initial) }
                var chunker = UTF8Chunker()
                var buf = [UInt8](repeating: 0, count: 16384)
                while !closed.isSet {
                    let n = read(fd, &buf, buf.count)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    let s = chunker.decode(Data(buf[0..<n]))
                    if !s.isEmpty { cont.yield(s) }
                }
                cont.finish()
            }
            t.name = "pier.follow"
            t.start()
        }
    }

    public static func restart(_ m: ManagedManifest) async throws {
        let path = m.socketPath
        _ = try await blocking { try request(socketPath: path, .restart, timeout: 25) }
    }

    public static func stop(_ m: ManagedManifest) async throws {
        let path = m.socketPath
        _ = try await blocking { try request(socketPath: path, .stop, timeout: 25) }
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
}

public enum ManagedLauncher {
    public struct AdoptReport: Sendable {
        public var manifest: ManagedManifest
        /// The service's port accepted connections again (within 20s).
        public var portListening: Bool
        /// What was actually re-run, e.g. ["pnpm", "run", "dev"].
        public var command: [String]
    }

    // MARK: Spawn

    /// Spawn a detached wrapper (`pier run --detach …`) via the pier executable, wait until its socket answers.
    public static func spawnDetached(command: [String], cwd: String, env: [String: String]? = nil,
                                     name: String? = nil, stack: String? = nil) async throws -> ManagedManifest {
        guard let exe = pierExecutable() else {
            throw ManagedError.spawnFailed("cannot find the pier executable (set PIER_BIN)")
        }
        guard !command.isEmpty else { throw ManagedError.spawnFailed("empty command") }
        var args = ["run", "--detach", "--json", "--cwd", cwd]
        if let name { args += ["--name", name] }
        if let stack { args += ["--stack", stack] }
        var envFile: String?
        if let env, !env.isEmpty {
            envFile = try ManagedEnvFile.write(env, id: "launch-" + ManagedCoding.newID())
            args += ["--env-file", envFile!]
        }
        args += ["--"] + command
        let finalArgs = args
        defer { if let envFile { unlink(envFile) } }

        let (status, out, err) = try await blockingProcess(exe, finalArgs, timeout: 15)
        guard status == 0 else {
            let msg = err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManagedError.spawnFailed(msg.isEmpty ? "pier run exited with status \(status)" : msg.replacingOccurrences(of: "pier: ", with: ""))
        }
        guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let m = try? ManagedCoding.decoder().decode(ManagedManifest.self, from: Data(line.utf8)) else {
            throw ManagedError.spawnFailed("unexpected output from pier run: \(out.prefix(200))")
        }
        return m
    }

    private static func blockingProcess(_ exe: String, _ args: [String], timeout: TimeInterval) async throws -> (Int32, String, String) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let o = Pipe(), e = Pipe()
                p.standardOutput = o; p.standardError = e; p.standardInput = FileHandle.nullDevice
                var errData = Data()
                let lock = NSLock()
                e.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    lock.lock(); errData.append(d); lock.unlock()
                }
                do { try p.run() } catch {
                    cont.resume(throwing: ManagedError.spawnFailed("cannot run \(exe): \(error.localizedDescription)")); return
                }
                let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let outData = o.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                watchdog.cancel()
                e.fileHandleForReading.readabilityHandler = nil
                lock.lock(); let ed = errData + e.fileHandleForReading.availableData; lock.unlock()
                cont.resume(returning: (p.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: ed, as: UTF8.self)))
            }
        }
    }

    /// Absolute path of the `pier` CLI binary to exec (env PIER_BIN, then sibling of current executable, then PATH).
    public static func pierExecutable() -> String? {
        let fm = FileManager.default
        func usable(_ p: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &isDir) && !isDir.boolValue && fm.isExecutableFile(atPath: p)
        }
        if let b = ProcessInfo.processInfo.environment["PIER_BIN"], !b.isEmpty, usable(b) { return b }
        var dirs: [URL] = []
        if let exe = Bundle.main.executableURL { dirs.append(exe.resolvingSymlinksInPath().deletingLastPathComponent()) }
        if let cur = ManagedWrapper.currentExecutable() { dirs.append(URL(fileURLWithPath: cur).deletingLastPathComponent()) }
        if let a0 = CommandLine.arguments.first {
            let abs = a0.hasPrefix("/") ? a0 : (a0.contains("/") ? fm.currentDirectoryPath + "/" + a0 : nil)
            if let abs { dirs.append(URL(fileURLWithPath: abs).resolvingSymlinksInPath().deletingLastPathComponent()) }
        }
        for d in dirs {
            let p = d.appendingPathComponent("pier").path
            if usable(p) { return p }
        }
        for d in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = String(d) + "/pier"
            if usable(p) { return p }
        }
        for d in ["/opt/homebrew/bin", "/usr/local/bin"] where usable(d + "/pier") { return d + "/pier" }
        return nil
    }

    // MARK: Adoption

    /// Restart a NON-managed service by adopting it: capture argv/cwd/env, kill, respawn detached under a wrapper.
    public static func adopt(_ service: Service) async throws -> ManagedManifest {
        try await adoptWithReport(service).manifest
    }

    public static func adoptWithReport(_ service: Service) async throws -> AdoptReport {
        let proc = service.process
        if service.isNoise || service.kind == .system { throw ManagedError.spawnFailed("\(service.displayName) is a system service; pier won't restart it") }
        if let d = service.docker { throw ManagedError.spawnFailed("\(service.displayName) runs in Docker; use `docker restart \(d.containerName)`") }
        guard proc.isAccessible, proc.uid == getuid() else {
            throw ManagedError.spawnFailed("pid \(proc.pid) belongs to another user or its details are unreadable")
        }
        try Killer.validate(pid: proc.pid)

        let parents = ProcScanner.parentChain(of: proc.pid)
        var command = proc.arguments
        var cwd = proc.cwd
        var envSource = proc.pid
        var roots: [Int32] = [proc.pid]
        if let pm = outermostPackageManager(parents: parents), pm.proc.uid == getuid() {
            command = pm.command
            cwd = pm.proc.cwd ?? cwd
            envSource = pm.proc.pid
            roots = [pm.proc.pid, proc.pid]
        }
        guard !command.isEmpty else { throw ManagedError.spawnFailed("couldn't read the command line of pid \(proc.pid)") }
        guard let cwd else { throw ManagedError.spawnFailed("couldn't read the working directory of pid \(proc.pid)") }
        guard let env = ProcEnvironment.read(pid: envSource) ?? ProcEnvironment.read(pid: proc.pid) else {
            throw ManagedError.spawnFailed("couldn't read the environment of pid \(envSource)")
        }
        if roots.count == 1 { command = stabilizeArgv0(command, executablePath: proc.executablePath, env: env) }

        try await stopTree(roots: roots)

        let manifest: ManagedManifest
        do {
            manifest = try await spawnDetached(command: command, cwd: cwd, env: env,
                                               name: service.projectName ?? URL(fileURLWithPath: cwd).lastPathComponent)
        } catch {
            throw ManagedError.spawnFailed("stopped the old process but couldn't start it again: \(error)")
        }
        let listening = await waitForPort(service.port, timeout: 20)
        return AdoptReport(manifest: manifest, portListening: listening, command: command)
    }

    /// argv[0] "node" may resolve to another binary than the one that was running; pin to the real path then.
    static func stabilizeArgv0(_ argv: [String], executablePath: String?, env: [String: String]) -> [String] {
        guard let first = argv.first, !first.contains("/"), let exe = executablePath else { return argv }
        let resolved = ManagedWrapper.resolveExecutable(first, env: env, cwd: "/")
        if let resolved,
           URL(fileURLWithPath: resolved).resolvingSymlinksInPath().path == URL(fileURLWithPath: exe).resolvingSymlinksInPath().path {
            return argv
        }
        var out = argv; out[0] = exe
        return out
    }

    static let packageManagerNames: [String: String] = [
        "npm": "npm", "npm-cli": "npm", "npx": "npx", "npx-cli": "npx",
        "pnpm": "pnpm", "pnpm.cjs": "pnpm", "pnpm.mjs": "pnpm", "pnpx": "pnpx",
        "yarn": "yarn", "yarn.js": "yarn", "yarn.cjs": "yarn", "yarnpkg": "yarn",
        "bun": "bun", "bunx": "bunx",
    ]

    /// If `p` is a package-manager invocation (`npm run dev`, `node …/npm-cli.js run dev`) → its canonical command.
    static func packageManagerCommand(of p: ProcInfo) -> [String]? {
        var args = p.arguments
        if args.count == 1, args[0].contains(" ") { args = args[0].split(separator: " ").map(String.init) }   // rewritten title
        guard let first = args.first else { return nil }
        func base(_ s: String) -> String {
            let b = (s as NSString).lastPathComponent
            return packageManagerNames[b] != nil ? b : (b as NSString).deletingPathExtension
        }
        if let pm = packageManagerNames[base(first)] { return [pm] + args.dropFirst() }
        if ["node", "nodejs"].contains(base(first)), args.count > 1 {
            var i = 1
            while i < args.count, args[i].hasPrefix("-") { i += 1 }       // node flags
            if i < args.count, let pm = packageManagerNames[base(args[i])] { return [pm] + args[(i + 1)...] }
        }
        return nil
    }

    /// The farthest package-manager ancestor (parents are nearest-first).
    static func outermostPackageManager(parents: [ProcInfo]) -> (proc: ProcInfo, command: [String])? {
        var found: (ProcInfo, [String])?
        for p in parents { if let c = packageManagerCommand(of: p) { found = (p, c) } }
        return found.map { (proc: $0.0, command: $0.1) }
    }

    static func childPIDs(of pid: Int32) -> [Int32] {
        var buf = [Int32](repeating: 0, count: 512)
        let n = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<Int32>.size))
        guard n > 0 else { return [] }
        return Array(buf.prefix(Int(n) / MemoryLayout<Int32>.size)).filter { $0 > 0 }
    }

    static func descendants(of pid: Int32, depth: Int = 6) -> [Int32] {
        guard depth > 0 else { return [] }
        return childPIDs(of: pid).flatMap { [$0] + descendants(of: $0, depth: depth - 1) }
    }

    /// SIGTERM everything (roots + their descendants), ≤5s grace, then SIGKILL.
    static func stopTree(roots: [Int32]) async throws {
        var pids: [Int32] = []
        for r in roots { for p in [r] + descendants(of: r) where !pids.contains(p) { pids.append(p) } }
        pids = pids.filter { (try? Killer.validate(pid: $0)) != nil }
        for p in pids { kill(p, SIGTERM) }
        for r in roots where getpgid(r) == r { kill(-r, SIGTERM) }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, pids.contains(where: Killer.isAlive) { try await Task.sleep(nanoseconds: 50_000_000) }
        for p in pids where Killer.isAlive(p) { kill(p, SIGKILL) }
        let hard = Date().addingTimeInterval(2)
        while Date() < hard, pids.contains(where: Killer.isAlive) { try await Task.sleep(nanoseconds: 50_000_000) }
        if let alive = pids.first(where: Killer.isAlive) {
            throw ManagedError.spawnFailed("pid \(alive) is still running after SIGKILL")
        }
    }

    static func portAccepts(_ port: UInt16) -> Bool {
        for (family, addrStr) in [(AF_INET, "127.0.0.1"), (AF_INET6, "::1")] {
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            let flags = fcntl(fd, F_GETFL); _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var rc: Int32
            if family == AF_INET {
                var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
                a.sin_port = port.bigEndian; inet_pton(AF_INET, addrStr, &a.sin_addr)
                rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            } else {
                var a = sockaddr_in6(); a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); a.sin6_family = sa_family_t(AF_INET6)
                a.sin6_port = port.bigEndian; inet_pton(AF_INET6, addrStr, &a.sin6_addr)
                rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            }
            if rc == 0 { return true }
            if errno == EINPROGRESS {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&p, 1, 200) > 0 {
                    var err: Int32 = 0; var l = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &l)
                    if err == 0 { return true }
                }
            }
        }
        return false
    }

    static func waitForPort(_ port: UInt16, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if portAccepts(port) { return true }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }
}
