import Foundation

/// Pure state + reducer behind `pier watch`. No I/O: the command feeds it keys, snapshots and the
/// terminal size, and executes the `Effect`s it returns.
public struct WatchState {
    public enum Mode: Equatable {
        case normal
        case filtering
        case confirmKill(Service)
    }

    public enum Effect: Equatable {
        case quit
        /// Start a snapshot now (queue it if one is in flight).
        case refresh
        case open(Service)
        case copyURL(Service)
        /// Already confirmed by the user.
        case kill(Service)
        /// Wipe and repaint everything (Ctrl-L).
        case redraw
    }

    public struct Status: Equatable {
        public var text: String
        public var isError: Bool
        public var expires: Date
    }

    public struct Layout: Equatable {
        public var tableHeight: Int
        /// Lines used by the detail pane including its separator; 0 when hidden.
        public var detailHeight: Int
        public var detailColumns: Int
    }

    // Data
    public private(set) var services: [Service] = []
    /// `services` after the filter, in port order.
    public private(set) var visible: [Service] = []
    public private(set) var hasLoaded = false
    public var scanning = true
    public private(set) var lastRefresh: Date?
    public var interval: TimeInterval
    public private(set) var includeNoise: Bool

    // UI
    public private(set) var mode: Mode = .normal
    public private(set) var filter = ""
    public private(set) var showDetail = false
    public private(set) var selectedID: String?
    public private(set) var scroll = 0
    public private(set) var cols = 80
    public private(set) var rows = 24
    public private(set) var status: Status?
    private var lastIndex = 0

    public static let statusDuration: TimeInterval = 5

    public init(interval: TimeInterval = 2, includeNoise: Bool = false) {
        self.interval = interval
        self.includeNoise = includeNoise
    }

    // MARK: Derived

    public var selectedIndex: Int? { selectedID.flatMap { id in visible.firstIndex { $0.id == id } } }
    public var selected: Service? { selectedIndex.map { visible[$0] } }

    public func layout() -> Layout {
        let avail = max(0, rows - 3)                       // header + table header + footer
        guard showDetail, let s = selected, rows >= 12 else {
            return Layout(tableHeight: avail, detailHeight: 0, detailColumns: 1)
        }
        let n = ServiceDetail.fields(s).count
        let columns = cols >= 110 ? 2 : 1
        let needed = (n + columns - 1) / columns
        let body = min(needed, max(3, avail / 2 - 1))
        return Layout(tableHeight: max(2, avail - body - 1), detailHeight: body + 1, detailColumns: columns)
    }

    public func activeStatus(now: Date) -> Status? {
        guard let status, status.expires > now else { return nil }
        return status
    }

    // MARK: Inputs

    public mutating func resize(cols: Int, rows: Int) {
        self.cols = max(12, cols); self.rows = max(4, rows)
        normalizeScroll()
    }

    /// Apply a finished snapshot. Selection stays on the same service id; if it vanished, on the same row index.
    public mutating func update(services: [Service], now: Date) {
        self.services = services
        hasLoaded = true
        scanning = false
        lastRefresh = now
        recompute()
    }

    public mutating func setStatus(_ text: String, isError: Bool = false, now: Date) {
        status = Status(text: text, isError: isError, expires: now.addingTimeInterval(Self.statusDuration))
    }

    public mutating func handle(_ key: Key, now: Date) -> Effect? {
        if key == .ctrl("c") || key == .ctrl("d") { return .quit }
        if key == .ctrl("l") { return .redraw }
        if case .paste(let text) = key {
            // Pasted text is data: it may extend the filter, and is never run as commands.
            if mode == .filtering {
                filter += Sanitize.line(text).trimmingCharacters(in: .whitespaces)
                recompute()
            }
            return nil
        }
        switch mode {
        case .confirmKill(let s): return handleConfirm(key, s, now: now)
        case .filtering: return handleFiltering(key)
        case .normal: return handleNormal(key, now: now)
        }
    }

    // MARK: Normal mode

    private mutating func handleNormal(_ key: Key, now: Date) -> Effect? {
        switch key {
        case .up, .ctrl("p"): move(-1)
        case .down, .char("j"), .ctrl("n"): move(1)
        case .home, .char("g"): select(index: 0)
        case .end, .char("G"): select(index: visible.count - 1)
        case .pageUp: move(-max(1, layout().tableHeight - 1))
        case .pageDown: move(max(1, layout().tableHeight - 1))
        case .enter, .char(" "):
            showDetail.toggle()
            normalizeScroll()
        case .char("r"):
            scanning = true
            return .refresh
        case .char("a"):
            includeNoise.toggle()
            scanning = true
            setStatus(includeNoise ? "showing system noise" : "hiding system noise", now: now)
            return .refresh
        case .char("/"): mode = .filtering
        case .char("o"):
            guard let s = selected else { return nil }
            if Identifier.isKnownNonHTTP(s) {
                setStatus("\(Self.label(s)) is not an HTTP service", isError: true, now: now)
                return nil
            }
            return .open(s)
        case .char("c"):
            guard let s = selected else { return nil }
            return .copyURL(s)
        case .char("k"):
            guard let s = selected else { return nil }
            do { try Killer.validate(pid: s.process.pid) } catch {
                setStatus(error.localizedDescription, isError: true, now: now)
                return nil
            }
            mode = .confirmKill(s)
        case .char("q"): return .quit
        case .escape:
            if showDetail { showDetail = false; normalizeScroll() }
            else if !filter.isEmpty { filter = ""; recompute() }
            else { return .quit }
        default: break
        }
        return nil
    }

    // MARK: Filter mode

    private mutating func handleFiltering(_ key: Key) -> Effect? {
        switch key {
        case .escape:
            filter = ""; mode = .normal; recompute()
        case .enter:
            mode = .normal
        case .backspace:
            if filter.isEmpty { mode = .normal } else { filter.removeLast(); recompute() }
        case .ctrl("u"):
            filter = ""; recompute()
        case .up, .ctrl("p"): move(-1)
        case .down, .ctrl("n"): move(1)
        case .char(let c):
            filter.append(c); recompute()
        default: break
        }
        return nil
    }

    // MARK: Kill confirmation

    private mutating func handleConfirm(_ key: Key, _ s: Service, now: Date) -> Effect? {
        mode = .normal
        if key == .char("y") || key == .char("Y") {
            setStatus("killing \(Self.label(s))…", now: now)
            return .kill(s)
        }
        setStatus("kill cancelled", now: now)
        return nil
    }

    // MARK: Selection / scrolling

    private mutating func move(_ delta: Int) {
        guard !visible.isEmpty else { return }
        select(index: (selectedIndex ?? lastIndex) + delta)
    }

    private mutating func select(index: Int) {
        guard !visible.isEmpty else { selectedID = nil; return }
        let i = min(max(0, index), visible.count - 1)
        selectedID = visible[i].id
        lastIndex = i
        normalizeScroll()
    }

    private mutating func recompute() {
        visible = Self.filtered(services, query: filter)
        if let id = selectedID, let i = visible.firstIndex(where: { $0.id == id }) {
            lastIndex = i
            normalizeScroll()
        } else {
            select(index: lastIndex)       // vanished: stay at the same row position
        }
    }

    private mutating func normalizeScroll() {
        let h = max(1, layout().tableHeight)
        var s = scroll
        if let i = selectedIndex {
            if i < s { s = i }
            if i >= s + h { s = i - h + 1 }
        }
        scroll = max(0, min(s, max(0, visible.count - h)))
    }

    // MARK: Helpers

    /// Port-prefix or Matcher fuzzy match, kept in port order (not relevance order) so rows don't jump while typing.
    public static func filtered(_ services: [Service], query: String) -> [Service] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return services }
        let ranked = Set(Matcher.rank(q, in: services).map(\.service.id))
        return services.filter { String($0.port).hasPrefix(q) || ranked.contains($0.id) }
    }

    public static func label(_ s: Service) -> String { "\(s.displayName) (:\(s.port))" }

    /// Why confirmation is extra important (nil for plain dev servers).
    public static func confirmReason(_ s: Service) -> String? {
        guard Killer.requiresConfirmation(s) else { return nil }
        if s.isNoise { return "system process" }
        if !s.process.isAccessible { return "other user's process" }
        switch s.kind {
        case .infra: return "infrastructure"
        case .docker: return "docker"
        case .system: return "system"
        default: return "not a recognised dev server"
        }
    }

    /// Status line for a finished kill; the bool is "is an error".
    public static func killMessage(_ outcome: Killer.Outcome, for s: Service) -> (String, Bool) {
        let l = label(s)
        switch outcome {
        case .terminated: return ("killed \(l)", false)
        case .killed: return ("force-killed \(l)", false)
        case .alreadyGone: return ("\(l) already exited", false)
        case .permissionDenied: return ("permission denied — use `pier kill` in a shell", true)
        case .stillRunning: return ("\(l) is still running after SIGKILL", true)
        case .failed(let e): return ("kill failed: \(String(cString: strerror(e)))", true)
        }
    }
}
