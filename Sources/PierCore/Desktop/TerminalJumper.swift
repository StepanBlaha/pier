import Foundation
import AppKit
import Darwin

public enum TerminalJumper {
    // MARK: Strategy (pure)

    /// How to reach the app hosting the process.
    public enum TerminalApp: Equatable, Sendable {
        case iterm, terminal, wezterm, kitty
        /// Known GUI host with no tab API (Ghostty, Warp, Alacritty, IDEs): just raise it.
        case app(OwnerKind)
        /// Unknown host: walk the parent chain to the first regular GUI app.
        case generic
    }

    public struct Plan: Equatable, Sendable {
        /// Service lives in a tmux pane: select it, then find the terminal showing the tmux client.
        public var viaTmux: Bool
        public var terminal: TerminalApp
    }

    /// Owner chain (nearest first) → jump strategy.
    public static func plan(for owners: [OwnerLink]) -> Plan {
        let viaTmux = owners.contains { $0.kind == .tmux }
        var terminal = TerminalApp.generic
        for o in owners {
            if let t = terminalApp(for: o.kind) { terminal = t; break }
        }
        return Plan(viaTmux: viaTmux, terminal: terminal)
    }

    static func terminalApp(for kind: OwnerKind) -> TerminalApp? {
        switch kind {
        case .iterm: return .iterm
        case .terminal: return .terminal
        case .wezterm: return .wezterm
        case .kitty: return .kitty
        case .ghostty, .warp, .alacritty, .vscode, .cursor, .zed, .xcode: return .app(kind)
        default: return nil   // tmux, claudeCode, launchd, docker, other: look further up the chain
        }
    }

    static func bundleIDs(for kind: OwnerKind) -> [String] {
        switch kind {
        case .iterm: return ["com.googlecode.iterm2"]
        case .terminal: return ["com.apple.Terminal"]
        case .wezterm: return ["com.github.wez.wezterm"]
        case .kitty: return ["net.kovidgoyal.kitty"]
        case .ghostty: return ["com.mitchellh.ghostty"]
        case .warp: return ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        case .alacritty: return ["org.alacritty"]
        case .vscode: return ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium"]
        case .cursor: return ["com.todesktop.230313mzl4w4u92"]
        case .zed: return ["dev.zed.Zed", "dev.zed.Zed-Preview"]
        case .xcode: return ["com.apple.dt.Xcode"]
        default: return []
        }
    }

    static func ownerKind(of app: TerminalApp) -> OwnerKind? {
        switch app {
        case .iterm: return .iterm
        case .terminal: return .terminal
        case .wezterm: return .wezterm
        case .kitty: return .kitty
        case .app(let k): return k
        case .generic: return nil
        }
    }

    // MARK: tty

    /// `devname()` result ("ttys003") → "/dev/ttys003"; nil for no tty ("??", empty).
    public static func ttyPath(devName: String?) -> String? {
        guard let n = devName?.trimmingCharacters(in: .whitespaces), !n.isEmpty, n != "??", n != "-" else { return nil }
        return n.hasPrefix("/dev/") ? n : "/dev/" + n
    }

    /// Controlling tty of a process (proc_pidinfo e_tdev → devname).
    public static func ttyPath(forPid pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let dev = info.e_tdev
        if dev == UInt32.max { return nil }   // NODEV
        guard let c = devname(Int32(bitPattern: dev), mode_t(S_IFCHR)) else { return nil }
        return ttyPath(devName: String(cString: c))
    }

    // MARK: tmux parsing (pure)

    public struct TmuxPane: Equatable, Sendable {
        public var tty: String
        public var paneID: String
        public var windowIndex: String
        public var paneIndex: String
        public var session: String
        public var target: String { "\(session):\(windowIndex)" }
    }

    public struct TmuxClient: Equatable, Sendable {
        public var tty: String
        public var pid: Int32
        public var session: String
    }

    static let tmuxPaneFormat = "#{pane_tty} #{pane_id} #{window_index} #{pane_index} #{session_name}"
    static let tmuxClientFormat = "#{client_tty} #{client_pid} #{client_session}"

    static func parseTmuxPanes(_ out: String) -> [TmuxPane] {
        out.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5 else { return nil }
            return TmuxPane(tty: f[0], paneID: f[1], windowIndex: f[2], paneIndex: f[3], session: f[4])
        }
    }

    static func parseTmuxClients(_ out: String) -> [TmuxClient] {
        out.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, let pid = Int32(f[1]) else { return nil }
            return TmuxClient(tty: f[0], pid: pid, session: f[2])
        }
    }

    // MARK: Jump

    public struct JumpResult: Sendable {
        public var success: Bool
        /// Human description: what was focused, or why nothing could be.
        public var detail: String
    }

    /// Focus the terminal tab/window owning the service (iTerm2/Terminal.app/WezTerm/kitty/tmux by tty;
    /// everything else by raising the GUI app that hosts it). Returns false if no jumpable owner found.
    @discardableResult
    public static func jump(to service: Service) -> Bool { jumpDetailed(to: service).success }

    public static func jumpDetailed(to service: Service) -> JumpResult {
        let pid = service.process.pid
        let chain = ProcScanner.parentChain(of: pid)
        var hostPids = [pid] + chain.map(\.pid)
        let plan = plan(for: service.owners)
        var terminal = plan.terminal
        var tty = ttyPath(forPid: pid) ?? chain.lazy.compactMap { ttyPath(forPid: $0.pid) }.first
        var prefix = ""

        if plan.viaTmux {
            if let t = tty, let host = focusTmux(serviceTTY: t) {
                switch host {
                case .detached(let target):
                    return JumpResult(success: false, detail: "selected tmux pane \(target), but its session has no attached client (attach to see it)")
                case .client(let client, let target):
                    prefix = "tmux \(target) → "
                    let clientChain = ProcScanner.parentChain(of: client.pid)
                    hostPids = [client.pid] + clientChain.map(\.pid)
                    tty = client.tty
                    let hostPlan = Self.plan(for: OwnerClassifier.owners(from: clientChain))
                    terminal = hostPlan.terminal
                }
            } else {
                tty = nil   // the pane tty means nothing to a terminal app
            }
        }
        return focus(terminal: terminal, tty: tty, hostPids: hostPids, prefix: prefix)
    }

    // MARK: Per-terminal focusing

    private static func focus(terminal: TerminalApp, tty: String?, hostPids: [Int32], prefix: String) -> JumpResult {
        var precise = false
        var name = ""
        switch terminal {
        case .iterm:
            if let tty, let app = DesktopProc.runningApp(bundleID: "com.googlecode.iterm2") {
                precise = focusITerm(tty: tty); name = app.localizedName ?? "iTerm2"
            }
        case .terminal:
            if let tty, let app = DesktopProc.runningApp(bundleID: "com.apple.Terminal") {
                precise = focusTerminalApp(tty: tty); name = app.localizedName ?? "Terminal"
            }
        case .wezterm:
            if let tty { precise = focusWezTerm(tty: tty) }
        case .kitty:
            precise = focusKitty(pids: hostPids)
        case .app, .generic:
            break
        }
        if precise {
            // The scripts above select the tab; make sure the app is frontmost too.
            if let kind = ownerKind(of: terminal) { _ = raiseHost(pids: hostPids, fallback: kind) }
            return JumpResult(success: true, detail: prefix + "focused the exact tab in " + (name.isEmpty ? "\(terminal)" : name))
        }
        if let app = raiseHost(pids: hostPids, fallback: ownerKind(of: terminal)) {
            return JumpResult(success: true, detail: prefix + "activated " + (app.localizedName ?? "terminal app"))
        }
        return JumpResult(success: false, detail: "no terminal or editor app found hosting this process (started by launchd/daemon?)")
    }

    /// GENERIC FALLBACK: first process in `pids` (nearest first) that is a regular GUI app, else a running app
    /// for the known owner kind. Raises and returns it.
    @discardableResult
    static func raiseHost(pids: [Int32], fallback: OwnerKind?) -> NSRunningApplication? {
        if let app = guiApp(in: pids) {
            DesktopProc.raise(app)
            return app
        }
        if let kind = fallback {
            for id in bundleIDs(for: kind) {
                if let app = DesktopProc.runningApp(bundleID: id) { DesktopProc.raise(app); return app }
            }
        }
        return nil
    }

    static func guiApp(in pids: [Int32]) -> NSRunningApplication? {
        for pid in pids where pid > 1 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                return app
            }
        }
        return nil
    }

    private static func focusITerm(tty: String) -> Bool {
        let script = """
        tell application id "com.googlecode.iterm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if (tty of s) is \(DesktopProc.appleScriptString(tty)) then
                  tell w to select
                  tell t to select
                  tell s to select
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
          return "nomatch"
        end tell
        """
        let r = DesktopProc.osascript(script, timeout: 3)
        return r.ok && r.output == "ok"
    }

    private static func focusTerminalApp(tty: String) -> Bool {
        let script = """
        tell application id "com.apple.Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if (tty of t) is \(DesktopProc.appleScriptString(tty)) then
                try
                  set miniaturized of w to false
                end try
                set selected tab of w to t
                set index of w to 1
                activate
                return "ok"
              end if
            end repeat
          end repeat
          return "nomatch"
        end tell
        """
        let r = DesktopProc.osascript(script, timeout: 3)
        return r.ok && r.output == "ok"
    }

    private static func focusWezTerm(tty: String) -> Bool {
        guard let bin = DesktopProc.findTool("wezterm", extra: ["/Applications/WezTerm.app/Contents/MacOS/wezterm"]) else { return false }
        let list = DesktopProc.run(bin, ["cli", "list", "--format", "json"], timeout: 3)
        guard list.ok, let data = list.stdout.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        guard let pane = arr.first(where: { ($0["tty_name"] as? String) == tty }),
              let id = pane["pane_id"] as? Int else { return false }
        return DesktopProc.run(bin, ["cli", "activate-pane", "--pane-id", String(id)], timeout: 3).ok
    }

    /// kitty only answers `@` commands when remote control is enabled; failure is expected and ignored.
    private static func focusKitty(pids: [Int32]) -> Bool {
        guard let bin = DesktopProc.findTool("kitty", extra: ["/Applications/kitty.app/Contents/MacOS/kitty"]) else { return false }
        let ls = DesktopProc.run(bin, ["@", "ls"], timeout: 2)
        guard ls.ok, let data = ls.stdout.data(using: .utf8),
              let osWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        let wanted = Set(pids)
        for osw in osWindows {
            for tab in (osw["tabs"] as? [[String: Any]]) ?? [] {
                for w in (tab["windows"] as? [[String: Any]]) ?? [] {
                    var candidates: [Int] = []
                    if let p = w["pid"] as? Int { candidates.append(p) }
                    for fg in (w["foreground_processes"] as? [[String: Any]]) ?? [] {
                        if let p = fg["pid"] as? Int { candidates.append(p) }
                    }
                    if candidates.contains(where: { wanted.contains(Int32($0)) }), let id = w["id"] as? Int {
                        return DesktopProc.run(bin, ["@", "focus-window", "--match", "id:\(id)"], timeout: 2).ok
                    }
                }
            }
        }
        return false
    }

    // MARK: tmux

    private enum TmuxFocus {
        case client(TmuxClient, target: String)
        case detached(target: String)
    }

    /// Selects the pane running the service and points a client at it. nil if tmux/pane not found.
    private static func focusTmux(serviceTTY: String) -> TmuxFocus? {
        guard let tmux = DesktopProc.findTool("tmux") else { return nil }
        let panesOut = DesktopProc.run(tmux, ["list-panes", "-a", "-F", tmuxPaneFormat], timeout: 3)
        guard panesOut.ok, let pane = parseTmuxPanes(panesOut.stdout).first(where: { $0.tty == serviceTTY }) else { return nil }

        _ = DesktopProc.run(tmux, ["select-window", "-t", pane.target], timeout: 3)
        _ = DesktopProc.run(tmux, ["select-pane", "-t", pane.paneID], timeout: 3)

        let clientsOut = DesktopProc.run(tmux, ["list-clients", "-F", tmuxClientFormat], timeout: 3)
        let clients = clientsOut.ok ? parseTmuxClients(clientsOut.stdout) : []
        guard let client = clients.first(where: { $0.session == pane.session }) ?? clients.first else {
            return .detached(target: pane.target)
        }
        if client.session != pane.session {
            _ = DesktopProc.run(tmux, ["switch-client", "-c", client.tty, "-t", pane.target], timeout: 3)
        }
        return .client(client, target: pane.target)
    }
}
