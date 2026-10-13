import Foundation
import AppKit

/// Scheme-less host:port matching between a service URL and browser tab URLs.
public enum TabMatcher {
    public struct HostPort: Equatable, Sendable {
        public var host: String
        public var port: Int
    }

    /// Host normalisation: localhost, *.localhost, 127.0.0.1, ::1, [::1] and 0.0.0.0 are one machine.
    public static func normalizedHost(_ raw: String) -> String {
        var h = raw.lowercased()
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if h.hasSuffix(".") { h.removeLast() }
        if h == "localhost" || h.hasSuffix(".localhost") || h == "127.0.0.1" || h == "::1" || h == "0.0.0.0"
            || h == "0:0:0:0:0:0:0:1" || h.hasPrefix("127.") { return "localhost" }
        return h
    }

    public static func hostPort(of urlString: String) -> HostPort? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: trimmed), let host = c.host, !host.isEmpty else { return nil }
        let scheme = (c.scheme ?? "http").lowercased()
        let port: Int
        if let p = c.port { port = p }
        else if scheme == "https" || scheme == "wss" { port = 443 }
        else { port = 80 }
        return HostPort(host: normalizedHost(host), port: port)
    }

    public static func matches(tab: String, target: String) -> Bool {
        guard let a = hostPort(of: tab), let b = hostPort(of: target) else { return false }
        return a == b
    }

    /// Index of the first tab URL matching the target.
    public static func firstMatch(in tabs: [String], target: String) -> Int? {
        guard let t = hostPort(of: target) else { return nil }
        return tabs.firstIndex { hostPort(of: $0) == t }
    }
}

public enum BrowserOpener {
    public enum Family: Sendable { case chrome, safari }

    public struct Browser: Sendable, Equatable {
        public var bundleID: String
        public var name: String
        public var family: Family
    }

    /// AppleScript-scriptable browsers. Firefox has no tab API, so it is never queried (plain open).
    public static let scriptable: [Browser] = [
        Browser(bundleID: "com.google.Chrome", name: "Google Chrome", family: .chrome),
        Browser(bundleID: "company.thebrowser.Browser", name: "Arc", family: .chrome),
        Browser(bundleID: "com.brave.Browser", name: "Brave Browser", family: .chrome),
        Browser(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", family: .chrome),
        Browser(bundleID: "org.chromium.Chromium", name: "Chromium", family: .chrome),
        Browser(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", family: .chrome),
        Browser(bundleID: "com.operasoftware.Opera", name: "Opera", family: .chrome),
        Browser(bundleID: "com.google.Chrome.beta", name: "Google Chrome Beta", family: .chrome),
        Browser(bundleID: "com.google.Chrome.canary", name: "Google Chrome Canary", family: .chrome),
        Browser(bundleID: "com.apple.Safari", name: "Safari", family: .safari),
        Browser(bundleID: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview", family: .safari),
    ]

    public enum Outcome: Equatable, Sendable {
        /// An existing tab was focused.
        case reusedTab(browser: String)
        /// A new tab/window was opened. `note` explains a degraded path (e.g. Automation denied).
        case opened(note: String?)
        case failed(String)

        public var reused: Bool { if case .reusedTab = self { return true } else { return false } }
    }

    /// Focus an existing tab whose host:port matches (Chrome family + Safari via AppleScript); else open a new one.
    /// Falls back to plain `open` if Automation permission is denied. Returns true if an existing tab was reused.
    @discardableResult
    public static func open(_ url: String, reuseTab: Bool = true, browserBundleID: String? = nil) -> Bool {
        perform(url, reuseTab: reuseTab, browserBundleID: browserBundleID).reused
    }

    public static func perform(_ url: String, reuseTab: Bool = true, browserBundleID: String? = nil) -> Outcome {
        var note: String?
        if reuseTab {
            let running = scriptable.filter { DesktopProc.runningApp(bundleID: $0.bundleID) != nil }
            let order = candidateOrder(running: running.map(\.bundleID), preferred: browserBundleID,
                                       defaultBrowser: defaultBrowserBundleID())
            var denied: [String] = []
            for id in order {
                guard let browser = running.first(where: { $0.bundleID == id }) else { continue }
                switch focusTab(matching: url, in: browser) {
                case .focused: return .reusedTab(browser: browser.name)
                case .noMatch: continue
                case .denied: denied.append(browser.name)
                case .failed: continue
                }
            }
            if !denied.isEmpty {
                note = "Automation denied for \(denied.joined(separator: ", ")); allow it in System Settings → Privacy & Security → Automation to reuse tabs"
            }
        }
        return plainOpen(url, bundleID: browserBundleID, note: note)
    }

    // MARK: Ordering (pure)

    /// Running scriptable browsers in query order: configured browser, then system default, then the rest.
    public static func candidateOrder(running: [String], preferred: String?, defaultBrowser: String?) -> [String] {
        var out: [String] = []
        for id in [preferred, defaultBrowser].compactMap({ $0 }) where running.contains(id) && !out.contains(id) {
            out.append(id)
        }
        for id in running where !out.contains(id) { out.append(id) }
        return out
    }

    public static func defaultBrowserBundleID() -> String? {
        guard let probe = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    // MARK: AppleScript

    enum FocusResult { case focused, noMatch, denied, failed }

    private static let rowSeparator = "(ASCII character 9)"

    static func listScript(for b: Browser) -> String {
        let id = DesktopProc.appleScriptString(b.bundleID)
        switch b.family {
        case .chrome:
            return """
            tell application id \(id)
              set out to ""
              repeat with w in windows
                set wid to id of w
                set ti to 0
                try
                  set theURLs to URL of tabs of w
                  repeat with u in theURLs
                    set ti to ti + 1
                    try
                      set out to out & wid & \(rowSeparator) & ti & \(rowSeparator) & (u as text) & (ASCII character 10)
                    end try
                  end repeat
                end try
              end repeat
              return out
            end tell
            """
        case .safari:
            return """
            tell application id \(id)
              set out to ""
              repeat with w in windows
                set wid to id of w
                set ti to 0
                try
                  set theURLs to URL of tabs of w
                  repeat with u in theURLs
                    set ti to ti + 1
                    try
                      set out to out & wid & \(rowSeparator) & ti & \(rowSeparator) & (u as text) & (ASCII character 10)
                    end try
                  end repeat
                end try
              end repeat
              return out
            end tell
            """
        }
    }

    static func focusScript(for b: Browser, windowID: Int, tabIndex: Int) -> String {
        let id = DesktopProc.appleScriptString(b.bundleID)
        switch b.family {
        case .chrome:
            return """
            tell application id \(id)
              set theWin to first window whose id is \(windowID)
              set active tab index of theWin to \(tabIndex)
              try
                set minimized of theWin to false
              end try
              set index of theWin to 1
              activate
            end tell
            """
        case .safari:
            return """
            tell application id \(id)
              set theWin to first window whose id is \(windowID)
              set current tab of theWin to tab \(tabIndex) of theWin
              try
                set miniaturized of theWin to false
              end try
              set index of theWin to 1
              activate
            end tell
            """
        }
    }

    /// One parsed row of the tab listing: window id, 1-based tab index, URL.
    struct TabRow: Equatable { var windowID: Int; var tabIndex: Int; var url: String }

    static func parseTabRows(_ output: String) -> [TabRow] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let w = Int(parts[0]), let t = Int(parts[1]) else { return nil }
            return TabRow(windowID: w, tabIndex: t, url: String(parts[2]))
        }
    }

    private static func focusTab(matching url: String, in b: Browser) -> FocusResult {
        let list = DesktopProc.osascript(listScript(for: b))
        if list.automationDenied { return .denied }
        guard list.ok else { return .failed }
        let rows = parseTabRows(list.output)
        guard let i = TabMatcher.firstMatch(in: rows.map(\.url), target: url) else { return .noMatch }
        let row = rows[i]
        let r = DesktopProc.osascript(focusScript(for: b, windowID: row.windowID, tabIndex: row.tabIndex))
        if r.automationDenied { return .denied }
        return r.ok ? .focused : .failed
    }

    // MARK: Fallback

    private static func plainOpen(_ url: String, bundleID: String?, note: String?) -> Outcome {
        var args: [String] = []
        if let bundleID, !bundleID.isEmpty { args += ["-b", bundleID] }
        args.append(url)
        var r = DesktopProc.open(args)
        if !r.ok, bundleID != nil {
            // Configured browser not installed: fall back to the system default.
            r = DesktopProc.open([url])
        }
        return r.ok ? .opened(note: note) : .failed("open failed for \(url): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}
