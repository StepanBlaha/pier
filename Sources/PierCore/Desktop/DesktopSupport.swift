import Foundation
import AppKit

/// Process / AppleScript plumbing shared by the desktop actions. Everything here blocks the calling thread
/// (bounded by a timeout), so GUI callers should invoke the actions from a background task.
enum DesktopProc {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
        var launchFailed: Bool
        var ok: Bool { status == 0 && !timedOut && !launchFailed }
    }

    private final class DataBox: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 5) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            return Result(status: -1, stdout: "", stderr: "\(error)", timedOut: false, launchFailed: true)
        }
        let box = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { box.out = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { box.err = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL) }
        }
        _ = group.wait(timeout: .now() + 1)
        return Result(status: timedOut ? -1 : p.terminationStatus,
                      stdout: String(decoding: box.out, as: UTF8.self),
                      stderr: String(decoding: box.err, as: UTF8.self),
                      timedOut: timedOut, launchFailed: false)
    }

    /// Finds a CLI in PATH plus the usual GUI-app-invisible locations (a menu bar app has a minimal PATH).
    static func findTool(_ name: String, extra: [String] = []) -> String? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/opt/local/bin",
                 NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.nix-profile/bin"]
        var candidates = dirs.map { $0 + "/" + name }
        candidates += extra
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: AppleScript

    struct ScriptResult {
        var output: String
        var ok: Bool
        /// -1743: the user (or MDM) denied Automation for the target app.
        var automationDenied: Bool
        var timedOut: Bool
    }

    static func osascript(_ script: String, timeout: TimeInterval = 2) -> ScriptResult {
        let r = run("/usr/bin/osascript", ["-e", script], timeout: timeout)
        let denied = r.stderr.contains("-1743") || r.stderr.contains("Not authorized to send Apple events")
        return ScriptResult(output: r.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                            ok: r.ok, automationDenied: denied, timedOut: r.timedOut)
    }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Apps

    static func runningApp(bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }

    /// Raises an app via LaunchServices (`open <bundle>`): reliable from a CLI, no Automation permission needed.
    @discardableResult
    static func raise(_ app: NSRunningApplication) -> Bool {
        if app.isHidden { app.unhide() }
        if let url = app.bundleURL {
            return run("/usr/bin/open", [url.path], timeout: 3).ok
        }
        return app.activate()
    }

    static func open(_ args: [String]) -> Result { run("/usr/bin/open", args, timeout: 5) }
}
