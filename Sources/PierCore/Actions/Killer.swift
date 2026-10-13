import Foundation
import Darwin

/// Process termination with the safety rules from the spec.
public enum Killer {
    public enum Refusal: Error, Equatable, LocalizedError {
        case protectedPID(Int32)
        case selfProcess
        public var errorDescription: String? {
            switch self {
            case .protectedPID(let p): "refusing to kill pid \(p)"
            case .selfProcess: "refusing to kill pier itself"
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case terminated          // exited after SIGTERM
        case killed              // needed SIGKILL
        case alreadyGone
        case permissionDenied    // EPERM: root / other user
        case stillRunning        // survived SIGKILL
        case failed(Int32)       // errno
    }

    /// Never pid <= 1 (0 and negatives would signal process groups) and never ourselves.
    public static func validate(pid: Int32) throws {
        if pid <= 1 { throw Refusal.protectedPID(pid) }
        if pid == ProcessInfo.processInfo.processIdentifier { throw Refusal.selfProcess }
    }

    /// Dev servers die without a prompt; infra / docker / system / unreadable processes need confirmation.
    public static func requiresConfirmation(_ s: Service) -> Bool {
        if s.isNoise || !s.process.isAccessible { return true }
        switch s.kind {
        case .devServer: return false
        case .other: return s.projectPath == nil
        case .infra, .docker, .system: return true
        }
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == -1 && errno == ESRCH { return false }
        // Zombies still answer kill(pid, 0); treat them as gone.
        var info = proc_bsdshortinfo()
        let n = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size))
        if n <= 0 { return false }
        return info.pbsi_status != UInt32(SZOMB)
    }

    /// SIGTERM, wait up to `grace`, then SIGKILL. `force` skips straight to SIGKILL.
    public static func terminate(pid: Int32, force: Bool = false, grace: TimeInterval = 3) async throws -> Outcome {
        try validate(pid: pid)
        if !force {
            if let early = send(SIGTERM, to: pid) { return early }
            if await waitForExit(pid, timeout: grace) { return .terminated }
        }
        if let early = send(SIGKILL, to: pid) { return early }
        return await waitForExit(pid, timeout: 2) ? .killed : .stillRunning
    }

    /// Same escalation via the macOS admin prompt (one dialog). No privileged helper.
    public static func terminateElevated(pid: Int32, grace: TimeInterval = 3) async throws -> Outcome {
        try validate(pid: pid)
        let polls = Int(grace * 2)
        let shell = "kill -TERM \(pid); i=0; while [ $i -lt \(polls) ]; do kill -0 \(pid) 2>/dev/null || exit 0; sleep 0.5; i=$((i+1)); done; kill -KILL \(pid)"
        let status: Int32 = await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"\(shell)\" with administrator privileges"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(returning: -1) }
        }
        if !isAlive(pid) { return .terminated }
        return status == 0 ? .stillRunning : .permissionDenied   // non-zero: user cancelled or auth failed
    }

    /// nil = signal delivered; otherwise the terminal outcome.
    private static func send(_ sig: Int32, to pid: Int32) -> Outcome? {
        if kill(pid, sig) == 0 { return nil }
        switch errno {
        case ESRCH: return .alreadyGone
        case EPERM: return .permissionDenied
        default: return .failed(errno)
        }
    }

    private static func waitForExit(_ pid: Int32, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isAlive(pid) {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }
}
