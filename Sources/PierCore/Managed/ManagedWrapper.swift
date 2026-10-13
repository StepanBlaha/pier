import Foundation
import Darwin

// The `pier run` wrapper: PTY child + ring buffer + unix-socket control server + manifest.

public struct ManagedWrapperOptions: Sendable {
    public var id: String
    public var name: String
    public var command: [String]
    public var cwd: String
    public var env: [String: String]?
    public var detached: Bool
    public var stack: String?
    public init(id: String = ManagedCoding.newID(), name: String, command: [String], cwd: String,
                env: [String: String]? = nil, detached: Bool = false, stack: String? = nil) {
        self.id = id; self.name = name; self.command = command; self.cwd = cwd
        self.env = env; self.detached = detached; self.stack = stack
    }
}

public enum ManagedWrapper {
    /// Runs the wrapper until the service is gone; returns the process exit code.
    /// Attached: child exit code. Detached: 0 after the linger period / stop.
    public static func run(_ options: ManagedWrapperOptions) -> Int32 {
        WrapperRuntime(options).run()
    }

    /// Absolute path of the running executable.
    public static func currentExecutable() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
    }

    /// Resolve `argv0` to an executable path using PATH from `env` (+ common dev dirs as a fallback).
    public static func resolveExecutable(_ argv0: String, env: [String: String], cwd: String) -> String? {
        let fm = FileManager.default
        func ok(_ p: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &isDir) && !isDir.boolValue && fm.isExecutableFile(atPath: p)
        }
        if argv0.contains("/") {
            let p = argv0.hasPrefix("/") ? argv0 : (cwd as NSString).appendingPathComponent(argv0)
            return ok(p) ? p : nil
        }
        var dirs = (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        for extra in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] where !dirs.contains(extra) { dirs.append(extra) }
        for d in dirs {
            let p = (d.isEmpty ? "." : d) + "/" + argv0
            let abs = p.hasPrefix("/") ? p : (cwd as NSString).appendingPathComponent(p)
            if ok(abs) { return abs }
        }
        return nil
    }

    /// Spawns the daemon half of `pier run --detach` (a re-exec of `executable` in its own session, stdio on
    /// /dev/null) and waits until its socket answers. Returns the manifest.
    public static func startDetached(executable: String, options o: ManagedWrapperOptions, timeout: TimeInterval = 5) throws -> ManagedManifest {
        ManagedFiles.ensureRunDir()
        if let missing = resolveCheck(o) { throw ManagedError.spawnFailed(missing) }
        var args = [executable, "run", "--daemon-id", o.id, "--name", o.name, "--cwd", o.cwd]
        if let s = o.stack { args += ["--stack", s] }
        if let env = o.env, !env.isEmpty { args += ["--env-file", try ManagedEnvFile.write(env, id: o.id)] }
        args += ["--"] + o.command

        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var all = sigset_t(); sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)
        var none = sigset_t(); sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)

        let cargs = args.map { strdup($0) } + [nil]
        let cenv = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cargs.forEach { free($0) }; cenv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fa, &attr, cargs, cenv)
        guard rc == 0 else { throw ManagedError.spawnFailed("cannot exec \(executable): \(String(cString: strerror(rc)))") }

        let socketPath = ManagedPaths.socketURL(id: o.id).path
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let m = try? ManagedClient.statusSync(socketPath: socketPath, timeout: 1) {
                var st: Int32 = 0; _ = waitpid(pid, &st, WNOHANG)
                return m
            }
            var st: Int32 = 0
            if waitpid(pid, &st, WNOHANG) == pid {
                let log = (try? String(contentsOf: ManagedFiles.logURL(id: o.id))) ?? ""
                throw ManagedError.spawnFailed("wrapper exited immediately" + (log.isEmpty ? "" : ": " + String(log.suffix(400))))
            }
            usleep(60_000)
        }
        throw ManagedError.spawnFailed("timed out waiting for the wrapper to come up")
    }

    private static func resolveCheck(_ o: ManagedWrapperOptions) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: o.cwd, isDirectory: &isDir), isDir.boolValue else {
            return "working directory does not exist: \(o.cwd)"
        }
        guard let first = o.command.first else { return "empty command" }
        var env = ProcessInfo.processInfo.environment
        for (k, v) in o.env ?? [:] { env[k] = v }
        if WrapperRuntime.commandForExec(o.command, env: env, cwd: o.cwd) == nil {
            return "command not found: \(first)"
        }
        return nil
    }
}

// MARK: - Runtime

private final class Waiter {
    let sem = DispatchSemaphore(value: 0)
    var error: String?
    func complete(_ e: String? = nil) { error = e; sem.signal() }
    func wait(_ seconds: TimeInterval) -> String? {
        if sem.wait(timeout: .now() + seconds) == .timedOut { return "timed out" }
        return error
    }
}

private final class Child {
    let pid: pid_t
    let master: Int32
    let generation: Int
    var exitStatus: Int32?              // set (under runtime.cond) once reaped
    let pumpDone = DispatchSemaphore(value: 0)
    init(pid: pid_t, master: Int32, generation: Int) { self.pid = pid; self.master = master; self.generation = generation }
}

private final class Follower {
    let fd: Int32
    let queue = DispatchQueue(label: "pier.follower")
    private let lock = NSLock()
    private var pending = 0
    private(set) var dead = false
    init(fd: Int32) { self.fd = fd }

    func send(_ data: Data) {
        lock.lock()
        if dead || pending > 8 * 1024 * 1024 { dead = true; lock.unlock(); shutdown(fd, SHUT_RDWR); return }
        pending += data.count
        lock.unlock()
        queue.async { [self] in
            if !dead, !UnixSocket.writeAll(fd, data) { markDead(); shutdown(fd, SHUT_RDWR) }
            lock.lock(); pending -= data.count; lock.unlock()
        }
    }
    func markDead() { lock.lock(); dead = true; lock.unlock() }
}

private final class LogHub {
    let ring = LogRingBuffer()
    private let lock = NSLock()
    private var followers: [Follower] = []
    private var fileFD: Int32 = -1
    private var fileSize = 0
    private let logPath: String?
    static let rotateAt = 5 * 1024 * 1024

    init(logPath: String?) {
        self.logPath = logPath
        if logPath != nil { openFile(truncate: true) }
    }

    private func openFile(truncate: Bool) {
        guard let p = logPath else { return }
        let fd = open(p, O_WRONLY | O_CREAT | O_APPEND | (truncate ? O_TRUNC : 0), 0o600)
        if fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        fileFD = fd
        fileSize = 0
    }

    private func writeFile(_ data: Data) {
        guard fileFD >= 0, let p = logPath else { return }
        if fileSize + data.count > Self.rotateAt {
            close(fileFD)
            rename(p, p + ".1")
            openFile(truncate: true)
            guard fileFD >= 0 else { return }
        }
        if UnixSocket.writeAll(fileFD, data) { fileSize += data.count }
    }

    /// CRLF → LF (the pty's ONLCR doubles newlines for the terminal; logs want plain \n).
    static func normalize(_ data: Data) -> Data {
        guard data.contains(0x0D) else { return data }
        var out = Data(capacity: data.count)
        var prevCR = false
        for b in data {
            if prevCR {
                prevCR = false
                if b == 0x0A { out.append(0x0A); continue }
                out.append(0x0D)
            }
            if b == 0x0D { prevCR = true; continue }
            out.append(b)
        }
        if prevCR { out.append(0x0D) }
        return out
    }

    func append(_ raw: Data) {
        let data = Self.normalize(raw)
        lock.lock(); defer { lock.unlock() }
        ring.append(data)
        writeFile(data)
        followers.removeAll { $0.dead }
        for f in followers { f.send(data) }
    }

    /// Marker on its own line (starts a fresh line if the previous output was unterminated).
    func marker(_ text: String) {
        lock.lock()
        let prefix = ring.hasPartialLine ? "\n" : ""
        lock.unlock()
        append(Data((prefix + text + "\n").utf8))
    }

    func tail(_ n: Int) -> String { ring.tail(n) }

    /// Registers a follower atomically with the snapshot; `greeting` (the JSON response line) is queued first.
    func addFollower(fd: Int32, tail n: Int, greeting: (String) -> Data) -> Follower {
        let f = Follower(fd: fd)
        lock.lock(); defer { lock.unlock() }
        f.send(greeting(ring.tail(n)))
        followers.append(f)
        return f
    }

    func remove(_ f: Follower) {
        lock.lock(); followers.removeAll { $0 === f }; lock.unlock()
    }
}

/// Raw-mode handling for the wrapper's own terminal.
private final class RawTerminal {
    static let shared = RawTerminal()
    private let lock = NSLock()
    private(set) var original: termios?
    private var active = false

    var isTTY: Bool { isatty(STDIN_FILENO) != 0 }

    func enter() {
        lock.lock(); defer { lock.unlock() }
        guard isTTY, tcgetpgrp(STDIN_FILENO) == getpgrp() else { return }
        var t = termios()
        guard tcgetattr(STDIN_FILENO, &t) == 0 else { return }
        if original == nil { original = t }
        var raw = t
        cfmakeraw(&raw)
        if tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 { active = true }
    }

    func restore() {
        lock.lock(); defer { lock.unlock() }
        guard active, var t = original else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
        active = false
    }
}

private final class WrapperRuntime {
    let opts: ManagedWrapperOptions
    let attached: Bool
    let hub: LogHub
    private var manifest: ManagedManifest
    private let manifestLock = NSLock()

    // Control state, all guarded by `cond`.
    private let cond = NSCondition()
    private var restartWaiters: [Waiter] = []
    private var stopWaiters: [Waiter] = []
    private var stopSignal: Int32?
    private var current: Child?
    private var generation = 0
    private var lingerDeadline: Date?
    private var finishing = false

    private var listenFD: Int32 = -1
    private var stdoutOpen = true
    private var signalSources: [DispatchSourceSignal] = []
    private let lingerSeconds: TimeInterval

    init(_ o: ManagedWrapperOptions) {
        opts = o
        attached = !o.detached
        hub = LogHub(logPath: o.detached ? ManagedFiles.logURL(id: o.id).path : nil)
        manifest = ManagedManifest(id: o.id, name: o.name, wrapperPid: getpid(), childPid: nil, command: o.command, cwd: o.cwd,
                                   env: (o.env?.isEmpty ?? true) ? nil : o.env, detached: o.detached, stack: o.stack)
        lingerSeconds = ProcessInfo.processInfo.environment["PIER_LINGER_SECONDS"].flatMap(TimeInterval.init) ?? 600
    }

    // MARK: Manifest

    private func update(_ mutate: (inout ManagedManifest) -> Void) {
        manifestLock.lock(); defer { manifestLock.unlock() }
        mutate(&manifest)
        ManagedFiles.writeManifest(manifest)
    }

    func snapshot() -> ManagedManifest {
        manifestLock.lock(); defer { manifestLock.unlock() }
        return manifest
    }

    // MARK: Run

    func run() -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTTOU, SIG_IGN)
        signal(SIGTTIN, SIG_IGN)
        ManagedFiles.ensureRunDir()

        do { listenFD = try UnixSocket.listen(path: ManagedPaths.socketURL(id: opts.id).path) } catch {
            fail("\(error)")
            return 1
        }
        ManagedFiles.writeManifest(manifest)
        atexit { RawTerminal.shared.restore() }

        let acceptThread = Thread { [self] in acceptLoop() }
        acceptThread.name = "pier.accept"
        acceptThread.start()

        if attached { RawTerminal.shared.enter() }
        installSignalHandlers()

        let code = supervise()
        RawTerminal.shared.restore()
        cleanup()
        return code
    }

    private func fail(_ message: String) {
        if attached { FileHandle.standardError.write(Data("pier: \(message)\n".utf8)) }
    }

    private func cleanup() {
        if listenFD >= 0 { close(listenFD) }
        unlink(ManagedPaths.socketURL(id: opts.id).path)
        unlink(ManagedPaths.manifestURL(id: opts.id).path)
    }

    // MARK: Supervisor

    private func supervise() -> Int32 {
        var deadline = Date.distantFuture
        defer { }
        do { try spawn(isRestart: false); if attached { startStdinRelay() } } catch {
            fail("\(error)")
            if attached { return 127 }
            update { $0.state = .crashed; $0.lastExitCode = 127; $0.childPid = nil }
            hub.marker("── failed to start: \(error) ──")
            deadline = Date().addingTimeInterval(lingerSeconds)
        }

        while true {
            cond.lock()
            var timedOut = false
            while restartWaiters.isEmpty, stopWaiters.isEmpty, stopSignal == nil, current?.exitStatus == nil {
                if !cond.wait(until: deadline) { timedOut = true; break }
            }
            let rw = restartWaiters; restartWaiters = []
            let sw = stopWaiters; stopWaiters = []
            let sig = stopSignal
            cond.unlock()

            if !sw.isEmpty || sig != nil {
                let code = terminateCurrent(final: true)
                finishing = true
                sw.forEach { $0.complete() }
                rw.forEach { $0.complete("stopping") }
                // Let stop handlers flush their reply before the socket vanishes.
                if !sw.isEmpty { Thread.sleep(forTimeInterval: 0.15) }
                return attached ? code : 0
            }
            if !rw.isEmpty {
                do {
                    try restart()
                    deadline = .distantFuture
                    rw.forEach { $0.complete() }
                } catch {
                    rw.forEach { $0.complete("\(error)") }
                }
                continue
            }
            if timedOut { return 0 }              // linger period over
            // The child exited by itself.
            let code = handleSelfExit()
            if attached { return code }
            deadline = Date().addingTimeInterval(lingerSeconds)
        }
    }

    private func handleSelfExit() -> Int32 {
        cond.lock()
        let child = current
        let status = child?.exitStatus ?? 0
        cond.unlock()
        if let child {
            cond.lock(); if current === child { current = nil }; cond.unlock()
            // Orphaned descendants of the dead leader would keep holding the port.
            kill(-child.pid, SIGTERM)
            _ = child.pumpDone.wait(timeout: .now() + 1.5)
            close(child.master)
        }
        let code = Self.exitCode(fromWaitStatus: status)
        update {
            $0.childPid = nil
            $0.lastExitCode = code
            $0.state = code == 0 ? .exited : .crashed
        }
        if !attached { hub.marker(code == 0 ? "── exited with code 0 ──" : "── exited with code \(code) ──") }
        return code
    }

    static func exitCode(fromWaitStatus st: Int32) -> Int32 {
        if st & 0x7f == 0 { return (st >> 8) & 0xff }          // WIFEXITED
        if st & 0x7f != 0x7f { return 128 + (st & 0x7f) }      // WIFSIGNALED
        return 1
    }

    /// SIGTERM the child's process group, ≤5s grace, SIGKILL; reaps and drains. Returns the child's exit code.
    @discardableResult
    private func terminateCurrent(final: Bool) -> Int32 {
        cond.lock()
        guard let child = current else { cond.unlock(); return 0 }
        cond.unlock()

        let pgid = child.pid
        if exited(child) {
            kill(-pgid, SIGTERM)
        } else {
            kill(-pgid, SIGTERM)
            if !waitGone(child, seconds: 5) {
                kill(-pgid, SIGKILL)
                _ = waitGone(child, seconds: 3)
            }
        }
        // Whole group, not just the leader: leftovers get SIGKILL after the grace period.
        if !waitGroupEmpty(pgid, seconds: exited(child) ? 3 : 0.1) { kill(-pgid, SIGKILL) }
        _ = child.pumpDone.wait(timeout: .now() + 2)
        close(child.master)
        cond.lock()
        let st = child.exitStatus ?? 0
        if current === child { current = nil }
        cond.unlock()
        let code = Self.exitCode(fromWaitStatus: st)
        if final {
            update { $0.childPid = nil; $0.lastExitCode = code; $0.state = .exited }
        }
        return code
    }

    private func exited(_ c: Child) -> Bool { cond.lock(); defer { cond.unlock() }; return c.exitStatus != nil }

    /// Leader reaped and (if `seconds` allows) the whole group gone.
    private func waitGone(_ c: Child, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        cond.lock(); defer { cond.unlock() }
        while c.exitStatus == nil {
            if !cond.wait(until: deadline) { return c.exitStatus != nil }
        }
        return true
    }

    private func waitGroupEmpty(_ pgid: pid_t, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if kill(-pgid, 0) != 0 && errno == ESRCH { return true }
            if Date() >= deadline { return false }
            usleep(50_000)
        }
    }

    private func restart() throws {
        update { $0.state = .restarting }
        terminateCurrent(final: false)
        hub.marker("── restarted by pier ──")
        if attached, stdoutOpen { _ = UnixSocket.writeAll(STDOUT_FILENO, Data("\r\n── restarted by pier ──\r\n".utf8)) }
        try spawn(isRestart: true)
    }

    // MARK: Spawning

    private func mergedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in manifest.env ?? [:] { env[k] = v }
        if env["TERM"] == nil || env["TERM"]!.isEmpty { env["TERM"] = "xterm-256color" }
        return env
    }

    static func commandForExec(_ command: [String], env: [String: String], cwd: String) -> (path: String, argv: [String])? {
        guard let first = command.first else { return nil }
        if let p = ManagedWrapper.resolveExecutable(first, env: env, cwd: cwd) { return (p, command) }
        // `pier run -- "npm run dev"` style single string.
        if command.count == 1, first.contains(" ") { return ("/bin/sh", ["sh", "-c", first]) }
        return nil
    }

    private func currentWinsize() -> winsize {
        var w = winsize()
        for fd in [STDOUT_FILENO, STDIN_FILENO, STDERR_FILENO] where isatty(fd) != 0 {
            if ioctl(fd, TIOCGWINSZ, &w) == 0, w.ws_col > 0, w.ws_row > 0 { return w }
        }
        return winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
    }

    private func spawn(isRestart: Bool) throws {
        let env = mergedEnvironment()
        let cwd = opts.cwd
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            throw ManagedError.spawnFailed("working directory does not exist: \(cwd)")
        }
        guard let (path, argvList) = Self.commandForExec(opts.command, env: env, cwd: cwd) else {
            throw ManagedError.spawnFailed("command not found: \(opts.command.first ?? "")")
        }

        let argv: [UnsafeMutablePointer<CChar>?] = argvList.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let pathC = strdup(path), cwdC = strdup(cwd)
        let errMsg = strdup("pier: failed to exec command\r\n")
        let errLen = strlen(errMsg!)
        defer {
            argv.forEach { free($0) }; envp.forEach { free($0) }
            free(pathC); free(cwdC); free(errMsg)
        }
        let maxFD = min(getdtablesize(), 4096)

        var ws = currentWinsize()
        var master: Int32 = -1
        var termPtr: UnsafeMutablePointer<termios>? = nil
        if attached, let t = RawTerminal.shared.original {
            termPtr = UnsafeMutablePointer<termios>.allocate(capacity: 1)
            termPtr!.initialize(to: t)
        }
        defer { termPtr?.deallocate() }

        let pid = forkpty(&master, nil, termPtr, &ws)
        if pid == 0 {
            // Child: async-signal-safe calls only (no allocation).
            signal(SIGPIPE, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL); signal(SIGHUP, SIG_DFL)
            signal(SIGTSTP, SIG_DFL); signal(SIGWINCH, SIG_DFL); signal(SIGCHLD, SIG_DFL); signal(SIGQUIT, SIG_DFL)
            signal(SIGTTIN, SIG_DFL); signal(SIGTTOU, SIG_DFL); signal(SIGCONT, SIG_DFL)
            var empty = sigset_t()
            sigemptyset(&empty)
            sigprocmask(SIG_SETMASK, &empty, nil)
            var fd: Int32 = 3
            while fd < maxFD { close(fd); fd += 1 }
            if chdir(cwdC) != 0 { _ = write(2, errMsg!, errLen); _exit(126) }
            execve(pathC, argv, envp)
            _ = write(2, errMsg!, errLen)
            _exit(127)
        }
        guard pid > 0 else { throw ManagedError.spawnFailed("forkpty: \(String(cString: strerror(errno)))") }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)

        cond.lock()
        generation += 1
        let child = Child(pid: pid, master: master, generation: generation)
        current = child
        cond.unlock()

        update {
            $0.childPid = pid
            $0.state = .running
            if isRestart { $0.restartCount += 1; $0.restartedAt = Date() }
        }

        let pump = Thread { [self] in pumpOutput(child) }
        pump.name = "pier.pump"
        pump.start()
        let waiter = Thread { [self] in
            var st: Int32 = 0
            while waitpid(pid, &st, 0) < 0 && errno == EINTR {}
            cond.lock()
            child.exitStatus = st
            cond.broadcast()
            cond.unlock()
        }
        waiter.name = "pier.wait"
        waiter.start()
    }

    private func pumpOutput(_ child: Child) {
        var buf = [UInt8](repeating: 0, count: 65536)
        var idleTicks = 0
        loop: while true {
            var pfd = pollfd(fd: child.master, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, 100)
            if r > 0 {
                let n = read(child.master, &buf, buf.count)
                if n > 0 {
                    idleTicks = 0
                    let chunk = Data(buf[0..<n])
                    if attached, stdoutOpen, !UnixSocket.writeAll(STDOUT_FILENO, chunk) { stdoutOpen = false }
                    hub.append(chunk)
                    continue
                }
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                break loop            // EOF / EIO: every slave end is closed
            } else if r == 0 {
                if exited(child) { idleTicks += 1; if idleTicks >= 4 { break loop } }
            } else if errno != EINTR {
                break loop
            }
        }
        child.pumpDone.signal()
    }

    // MARK: Signals / stdin

    private func installSignalHandlers() {
        func source(_ sig: Int32, _ handler: @escaping () -> Void) {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue(label: "pier.sig.\(sig)"))
            s.setEventHandler(handler: handler)
            s.resume()
            signalSources.append(s)
        }
        source(SIGINT) { [self] in forward(SIGINT) }
        for sig in [SIGTERM, SIGHUP] {
            source(sig) { [self] in
                cond.lock(); stopSignal = sig; cond.broadcast(); cond.unlock()
            }
        }
        source(SIGWINCH) { [self] in
            cond.lock(); let m = current?.master; cond.unlock()
            if let m { var w = currentWinsize(); _ = ioctl(m, TIOCSWINSZ, &w) }
        }
        if attached {
            source(SIGTSTP) {
                RawTerminal.shared.restore()
                kill(getpid(), SIGSTOP)          // stops us; resumes right after SIGCONT
                RawTerminal.shared.enter()
            }
        }
        source(SIGCONT) { [self] in
            if attached { RawTerminal.shared.enter() }
            forward(SIGCONT)
        }
    }

    private func forward(_ sig: Int32) {
        cond.lock(); let c = current; cond.unlock()
        if let c, c.exitStatus == nil { kill(-c.pid, sig) }
    }

    private func startStdinRelay() {
        let t = Thread { [self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(STDIN_FILENO, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return }          // EOF: just stop relaying (no ^D)
                cond.lock(); let m = current?.master; cond.unlock()
                if let m { _ = UnixSocket.writeAll(m, Data(buf[0..<n])) }
            }
        }
        t.name = "pier.stdin"
        t.start()
    }

    // MARK: Control server

    private func acceptLoop() {
        while true {
            var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, 250)
            if finishing { return }
            if r <= 0 { if r < 0 && errno != EINTR { return }; continue }
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { if errno == EINTR || errno == ECONNABORTED { continue }; return }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global().async { [self] in serve(fd) }
        }
    }

    private func respond(_ fd: Int32, _ r: ManagedResponse) {
        guard var data = try? ManagedCoding.encoder().encode(r) else { return }
        data.append(0x0A)
        UnixSocket.writeAll(fd, data)
    }

    private func serve(_ fd: Int32) {
        UnixSocket.setTimeouts(fd, recv: 5, send: 10)
        guard let line = UnixSocket.readLine(fd),
              let req = try? ManagedCoding.decoder().decode(ManagedRequest.self, from: line) else {
            respond(fd, ManagedResponse(ok: false, error: "bad request"))
            close(fd); return
        }
        switch req {
        case .status:
            respond(fd, ManagedResponse(ok: true, manifest: snapshot()))
            close(fd)
        case .logs(let tail, let follow):
            if !follow {
                respond(fd, ManagedResponse(ok: true, manifest: snapshot(), logs: hub.tail(tail)))
                close(fd)
                return
            }
            let m = snapshot()
            let f = hub.addFollower(fd: fd, tail: tail) { text in
                var d = (try? ManagedCoding.encoder().encode(ManagedResponse(ok: true, manifest: m, logs: text))) ?? Data()
                d.append(0x0A)
                return d
            }
            UnixSocket.setTimeouts(fd, recv: nil, send: 10)
            var scratch = [UInt8](repeating: 0, count: 256)
            while true {                       // block until the client goes away
                let n = read(fd, &scratch, scratch.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
            }
            f.markDead()
            hub.remove(f)
            f.queue.sync {}
            close(fd)
        case .restart:
            let w = Waiter()
            cond.lock(); restartWaiters.append(w); cond.broadcast(); cond.unlock()
            if let err = w.wait(20) { respond(fd, ManagedResponse(ok: false, error: err, manifest: snapshot())) }
            else { respond(fd, ManagedResponse(ok: true, manifest: snapshot())) }
            close(fd)
        case .stop:
            let w = Waiter()
            cond.lock(); stopWaiters.append(w); cond.broadcast(); cond.unlock()
            if let err = w.wait(20) { respond(fd, ManagedResponse(ok: false, error: err)) }
            else { respond(fd, ManagedResponse(ok: true, manifest: snapshot())) }
            close(fd)
        }
    }
}
