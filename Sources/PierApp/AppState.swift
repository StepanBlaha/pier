import AppKit
import SwiftUI
import PierCore

/// Single source of truth for the menu bar app. Heavy work (scan, probe, file IO, process control) runs off the
/// main actor; results are applied here.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Data
    @Published private(set) var services: [Service] = []
    @Published private(set) var managed: [ManagedManifest] = []
    @Published var config: PierConfig = ConfigStore.load()
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var loadedOnce = false
    @Published var showWelcome = DebugFlags.forceWelcome || !Welcome.seen

    // UI state
    @Published var query = ""
    @Published var selectedID: String?
    @Published var detailID: String?
    @Published var collapsed: Set<AppModel.Group> = [.system]
    @Published var banner: Banner?
    @Published var qrService: Service?
    @Published var focusSearchToken = 0
    @Published var busy: Set<String> = []          // "kill:<id>", "restart:<id>", "expose:<port>"
    @Published var exposed: [UInt16: String] = [:]  // optimistic tunnel URLs until the next refresh sees them
    @Published var renaming = false
    @Published private(set) var now = Date()
    /// Expanded project groups (ids "g:<key>").
    @Published var expanded: Set<String> = []
    /// Service id -> uptime of services Staleness considers stale (>=3d, idle). Cheap, no connection counting.
    @Published private(set) var staleAges: [String: TimeInterval] = [:]
    @Published private(set) var knownStacks: [KnownStack] = []
    @Published private(set) var stackTotals: [String: Int] = [:]
    @Published var stackProgress: [String: StackProgress] = [:]   // by pier.yml path
    @Published var cleanup: CleanupState?

    struct StackProgress: Equatable { var text: String; var isError = false; var working = false }

    struct Banner: Equatable { var text: String; var isError: Bool; var token = UUID() }

    // Internals
    private(set) var popoverVisible = false
    weak var popoverWindow: NSWindow?
    private var pollTask: Task<Void, Never>?
    private var inFlight = false
    private var wantsFull = false
    private var tick = 0
    private var started = false
    private var previousManaged: [ManagedManifest] = []

    // MARK: - Derived

    var menuBar: AppModel.MenuBarState {
        AppModel.menuBarState(services, managed: managed, showNoise: config.showNoise)
    }

    var crashedManaged: [ManagedManifest] { managed.filter { $0.state == .crashed } }

    var visibleServices: [Service] { services.filter { config.showNoise || AppModel.group(of: $0) != .system } }

    /// Sections for the list (no query), one row per project.
    var sections: [AppModel.ProjectSection] {
        AppModel.projectSections(services, managed: managed, config: config, showNoise: config.showNoise, crashed: crashedManaged)
    }

    /// Search results as project rows; nil = no query.
    var filtered: [AppModel.Project]? {
        AppModel.filterProjects(visibleServices, managed: managed, query: query, config: config)
    }

    /// Selectable ids in on-screen order for keyboard navigation (project rows, plus member rows of expanded groups).
    var navigation: [String] {
        if let f = filtered { return f.flatMap { AppModel.navigationIDs(of: $0, expanded: expanded) } }
        return AppModel.navigationIDs(sections, collapsed: collapsed, expanded: expanded)
    }

    /// Project rows currently on screen.
    var shownProjects: [AppModel.Project] {
        if let f = filtered { return f }
        return sections.filter { !collapsed.contains($0.group) }.flatMap(\.projects)
    }

    /// The service the selection stands for (the main member for a group row).
    var selected: Service? {
        guard let id = selectedID else { return nil }
        if let s = services.first(where: { $0.id == id }) { return s }
        return selectedProject?.main
    }
    var selectedProject: AppModel.Project? {
        guard let id = selectedID, id.hasPrefix("g:") else { return nil }
        return shownProjects.first { $0.id == id }
    }
    var detailService: Service? { detailID.flatMap { id in services.first { $0.id == id } } }

    var stackStatuses: [AppModel.StackStatus] {
        AppModel.stackStatuses(known: knownStacks, totals: stackTotals, managed: managed)
    }

    var staleCount: Int { staleAges.count }

    func manifest(for s: Service) -> ManagedManifest? {
        guard let id = s.managedID else { return nil }
        return managed.first { $0.id == id }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        pollTask = Task { [weak self] in
            await self?.refresh(full: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                self.tick += 1
                self.now = Date()
                // Full probe on open (see popoverOpened) and every ~15s in the background (keeps health fresh).
                await self.refresh(full: self.tick % 5 == 0)
            }
        }
    }

    func popoverOpened() {
        guard !popoverVisible else { return }
        popoverVisible = true
        MenuBarModel.shared.setHeld(true)
        config = ConfigStore.load()
        query = ""
        detailID = nil
        qrService = nil
        renaming = false
        cleanup = nil
        focusSearchToken += 1
        ensureSelection()
        Task { await refresh(full: true) }
    }

    func dismissWelcome() {
        Welcome.seen = true
        showWelcome = false
        focusSearchToken += 1
    }

    func popoverClosed() {
        guard popoverVisible else { return }
        popoverVisible = false
        detailID = nil
        qrService = nil
        renaming = false
        query = ""
        if cleanup?.phase != .running { cleanup = nil }
        // The status item was frozen while the popover was open (changing it dismisses the window); catch up now.
        MenuBarModel.shared.setHeld(false)
        MenuBarModel.shared.update(menuBar, immediate: true)
    }

    // MARK: - Refresh

    func refresh(full: Bool) async {
        if inFlight { if full { wantsFull = true }; return }
        inFlight = true
        defer { inFlight = false }

        let showNoise = config.showNoise
        let previous = services

        async let managedNow = Task.detached(priority: .utility) { ManagedRegistry.all() }.value
        var fresh: [Service]
        if full {
            fresh = await ServiceCatalog.snapshot(.init(includeNoise: showNoise, probe: true))
        } else {
            let raw = await ServiceCatalog.snapshot(.init(includeNoise: showNoise, probe: false))
            fresh = AppModel.mergeProbes(previous: previous, fresh: raw, showNoise: showNoise)
            // New services appear unprobed; probe just those so noise filtering and health stay right.
            let todo = fresh.filter(AppModel.needsProbe)
            if !todo.isEmpty {
                let results = await withTaskGroup(of: (String, ProbeResult).self) { group -> [(String, ProbeResult)] in
                    for s in todo { let (id, port) = (s.id, s.port); group.addTask { (id, await Prober.probe(port: port, timeout: 0.3)) } }
                    var out: [(String, ProbeResult)] = []
                    for await r in group { out.append(r) }
                    return out
                }
                for (id, r) in results { AppModel.applyProbe(r, toID: id, in: &fresh, showNoise: showNoise) }
            }
        }
        var manifests = await managedNow
        if DebugFlags.forceEmpty { fresh = []; manifests = [] }   // PIER_DEBUG_EMPTY: screenshot aid
        #if DEBUG
        if DebugFlags.demo { fresh = DemoData.services(); manifests = [] }   // PIER_DEBUG_DEMO: screenshot aid
        #endif
        if full {
            let stacks = await Task.detached(priority: .utility) { Self.loadStacks() }.value
            if stacks.known != knownStacks { knownStacks = stacks.known }
            if stacks.totals != stackTotals { stackTotals = stacks.totals }
        }

        let events = loadedOnce
            ? AppModel.transitions(previousServices: previous, currentServices: fresh,
                                   previousManaged: previousManaged, currentManaged: manifests)
            : []
        if fresh != services { services = fresh }
        if manifests != managed { managed = manifests }
        previousManaged = manifests
        // MenuBarModel parks this while the popover is open (see its doc); popoverClosed() applies the latest state.
        MenuBarModel.shared.update(menuBar)
        refreshedAt = Date()
        now = Date()
        let ages = AppModel.staleAges(visibleServices, now: now)
        if ages != staleAges { staleAges = ages }
        loadedOnce = !DebugFlags.forceLoading
        exposed = exposed.filter { port, _ in !fresh.contains { $0.port == port && $0.tunnelURL != nil } }
        ensureSelection()
        if let d = detailID, !fresh.contains(where: { $0.id == d }) { detailID = nil; qrService = nil }
        deliver(events)

        #if DEBUG
        DebugHarness.log("refresh applied full=\(full) services=\(fresh.count)")
        #endif
        if wantsFull { wantsFull = false; await refresh(full: true) }
    }

    func ensureSelection() {
        let nav = navigation
        if let id = selectedID, nav.contains(id) { return }
        selectedID = nav.first
    }

    /// Known stacks plus the number of services each declares (parses the ymls; call off the main actor).
    nonisolated static func loadStacks() -> (known: [KnownStack], totals: [String: Int]) {
        let known = StackRegistry.known()
        var totals: [String: Int] = [:]
        for k in known {
            if let f = try? StackLoader.load(url: URL(fileURLWithPath: k.file)) { totals[k.file] = f.services.count }
        }
        return (known, totals)
    }

    private func deliver(_ events: [AppModel.Event]) {
        for e in events {
            switch e {
            case .managedCrashed(let m):
                guard config.notifyCrash else { continue }
                let code = m.lastExitCode.map { " (exit \($0))" } ?? ""
                Notifier.post(title: "\(m.name) crashed", body: "Managed service stopped unexpectedly\(code).", id: "crash-\(m.id)-\(m.restartCount)")
            case .newService(let s):
                guard config.notifyNewService, !s.isNoise else { continue }
                Notifier.post(title: "New service on :\(s.port)", body: AppModel.displayName(s, config: config), id: "new-\(s.id)")
            }
        }
    }

    // MARK: - Config

    func updateConfig(_ change: (inout PierConfig) -> Void) {
        var c = config
        change(&c)
        guard c != config else { return }
        config = c
        do { try ConfigStore.save(c) } catch { flash("Could not save config: \(error.localizedDescription)", error: true) }
        ensureSelection()
    }

    func togglePin(_ s: Service) { updateConfig { AppModel.togglePin(s, in: &$0) } }
    func rename(_ s: Service, to name: String) { updateConfig { AppModel.setRename(name, for: s, in: &$0) } }

    // MARK: - Banner

    func flash(_ text: String, error: Bool = false) {
        let b = Banner(text: text, isError: error)
        banner = b
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: error ? 6_000_000_000 : 2_500_000_000)
            if self?.banner?.token == b.token { self?.banner = nil }
        }
    }

    // MARK: - Actions

    private func isWeb(_ s: Service) -> Bool {
        if let p = s.probe?.protocolKind { return p == .http || p == .https || p == .websocket }
        return !Identifier.isKnownNonHTTP(s)
    }

    func open(_ s: Service) {
        guard isWeb(s) else {
            Clipboard.copy("localhost:\(s.port)")
            flash("Not a web service. Copied localhost:\(s.port)")
            return
        }
        let url = s.localURL, browser = config.browser
        Task.detached { BrowserOpener.open(url, reuseTab: true, browserBundleID: browser) }
        closePopover()
    }

    func openURL(_ url: String) {
        let browser = config.browser
        Task.detached { BrowserOpener.open(url, reuseTab: true, browserBundleID: browser) }
        closePopover()
    }

    func copy(_ text: String, label: String = "URL") {
        Clipboard.copy(text)
        flash("Copied \(label)")
    }

    func copyURL(_ s: Service) { copy(s.tunnelURL ?? s.localURL) }

    // MARK: - Project rows

    /// Click / Return on a project row: one service opens, a group expands or collapses.
    func activate(_ p: AppModel.Project) {
        if p.isGroup { toggleExpanded(p) } else { open(p.main) }
    }

    /// Return on the current selection (a group row toggles, a service opens).
    func activateSelection() {
        if let p = selectedProject { toggleExpanded(p) } else if let s = selected { open(s) }
    }

    func toggleExpanded(_ p: AppModel.Project) { setExpanded(p, !expanded.contains(p.id)) }

    func setExpanded(_ p: AppModel.Project, _ on: Bool) {
        if on { expanded.insert(p.id) } else { expanded.remove(p.id); selectedID = p.id }
        ensureSelection()
    }

    /// Right arrow on a group row: expand it, or step into its first member when already open. False = not a group.
    func expandSelection() -> Bool {
        guard let p = selectedProject else { return false }
        if expanded.contains(p.id) { move(1) } else { setExpanded(p, true) }
        return true
    }

    /// Left arrow on a group row or one of its member rows: collapse the group and select it. False = nothing to do.
    func collapseSelection() -> Bool {
        guard let id = selectedID, let p = AppModel.project(containing: id, in: shownProjects), p.isGroup,
              expanded.contains(p.id) else { return false }
        setExpanded(p, false)
        return true
    }

    func togglePin(_ p: AppModel.Project) { updateConfig { AppModel.togglePin(p, in: &$0) } }

    /// Opens the logs of the first managed member (single rows only expose this on hover).
    func showLogs(_ p: AppModel.Project) { if let m = p.services.first(where: { $0.isManaged }) { showLogs(m) } }

    func openEditor(_ s: Service) {
        guard let path = s.projectPath ?? s.process.cwd else { flash("No project folder for this service", error: true); return }
        let editor = config.editor
        Task {
            do { try await Task.detached { try EditorOpener.open(path: path, editor: editor) }.value }
            catch { flash("Open in editor failed: \(error.localizedDescription)", error: true) }
        }
    }

    func jumpToTerminal(_ s: Service) {
        Task {
            let ok = await Task.detached { TerminalJumper.jump(to: s) }.value
            if !ok { flash("No terminal owner found to jump to", error: true) } else { closePopover() }
        }
    }

    func showQR(_ s: Service) { qrService = s }

    func showLogs(_ s: Service) {
        guard let m = manifest(for: s) else { flash("Logs need `pier run` (managed service)", error: true); return }
        WindowManager.shared.showLogs(for: m, title: AppModel.displayName(s, config: config))
        closePopover()
    }

    func showLogs(manifest m: ManagedManifest) {
        WindowManager.shared.showLogs(for: m, title: m.name)
        closePopover()
    }

    // Kill

    /// Stops one service: managed -> ManagedClient.stop, else SIGTERM/SIGKILL (admin prompt on EPERM when `elevate`).
    /// Returns nil on success (or already gone), else a short failure text.
    func stopService(_ s: Service, elevate: Bool = true) async -> String? {
        let manifest = manifest(for: s)
        do {
            if let m = manifest {
                do { try await ManagedClient.stop(m) } catch ManagedError.notRunning { return nil }
                return nil
            }
            var outcome = try await Killer.terminate(pid: s.process.pid)
            if outcome == .permissionDenied, elevate { outcome = try await Killer.terminateElevated(pid: s.process.pid) }
            switch outcome {
            case .terminated, .killed, .alreadyGone: return nil
            case .permissionDenied: return "permission denied"
            case .stillRunning: return "process survived SIGKILL"
            case .failed(let e): return "kill failed (errno \(e))"
            }
        } catch { return "\(error.localizedDescription)" }
    }

    func isStoppable(_ s: Service) -> Bool { s.process.pid > 1 && !s.isNoise && s.kind != .system }

    func requestKill(_ s: Service) {
        guard s.process.pid > 1 else { flash("Refusing to kill pid \(s.process.pid)", error: true); return }
        if s.isNoise || s.kind == .system { flash("Kill is not offered for system services", error: true); return }
        if Killer.requiresConfirmation(s) {
            let kind = s.kind == .docker ? "Docker container proxy" : (s.kind == .infra ? s.infraName ?? "infrastructure service" : "this process")
            guard Dialogs.confirm(title: "Kill \(AppModel.displayName(s, config: config)) (:\(s.port))?",
                                  message: "This stops \(kind) (pid \(s.process.pid)). Unsaved data may be lost.",
                                  button: "Kill") else { return }
        }
        let key = "kill:\(s.id)"
        guard !busy.contains(key) else { return }
        busy.insert(key)
        Task {
            defer { busy.remove(key) }
            if let err = await stopService(s) {
                flash(manifest(for: s) != nil ? "Kill failed: \(err)" : "\(err.prefix(1).uppercased() + err.dropFirst())", error: true)
            } else {
                flash(manifest(for: s).map { "Stopped \($0.name)" } ?? "Stopped :\(s.port)")
            }
            if detailID == s.id { detailID = nil }
            await refresh(full: false)
        }
    }

    /// Stop for a project row: a single service goes through `requestKill`; a group always asks first.
    func requestStop(_ p: AppModel.Project) {
        guard p.isGroup else { requestKill(p.main); return }
        let targets = p.services.filter(isStoppable)
        guard !targets.isEmpty else { flash("Kill is not offered for system services", error: true); return }
        let ports = targets.map { ":\($0.port)" }.joined(separator: " ")
        guard Dialogs.confirm(title: "Stop \(p.title)?",
                              message: "This stops \(targets.count) services (\(ports)). Unsaved data may be lost.",
                              button: "Stop all") else { return }
        let key = "kill:\(p.id)"
        guard !busy.contains(key) else { return }
        busy.insert(key)
        Task {
            defer { busy.remove(key) }
            var failures: [String] = []
            var seen = Set<Int32>()
            for s in targets where seen.insert(s.process.pid).inserted {
                if let err = await stopService(s) { failures.append(":\(s.port) \(err)") }
            }
            if failures.isEmpty { flash("Stopped \(p.title) (\(targets.count) services)") }
            else { flash("Could not stop \(failures.joined(separator: ", "))", error: true) }
            await refresh(full: false)
        }
    }

    // Restart

    func canRestart(_ s: Service) -> Bool {
        if s.isManaged { return manifest(for: s) != nil }
        return s.process.isAccessible && !s.isNoise && s.kind != .docker && s.kind != .system
    }

    func canRestart(_ p: AppModel.Project) -> Bool { p.services.contains(where: canRestart) }

    func requestRestart(_ p: AppModel.Project) {
        guard p.isGroup else { requestRestart(p.main); return }
        let targets = p.services.filter(canRestart)
        guard !targets.isEmpty else { return }
        let key = "restart:\(p.id)"
        guard !busy.contains(key) else { return }
        if targets.contains(where: { manifest(for: $0) == nil }) {
            guard Dialogs.confirm(
                title: "Restart \(p.title)?",
                message: "pier will restart \(targets.count) services. Ones that are not managed yet are stopped and started again inside a pier wrapper (they become managed, with live logs).",
                button: "Restart") else { return }
        }
        busy.insert(key)
        Task {
            defer { busy.remove(key) }
            var failures: [String] = []
            var seen = Set<Int32>()
            for s in targets where seen.insert(s.process.pid).inserted {
                do {
                    if let m = manifest(for: s) { try await ManagedClient.restart(m) } else { _ = try await ManagedLauncher.adopt(s) }
                } catch { failures.append(":\(s.port) \(error)") }
            }
            if failures.isEmpty { flash("Restarted \(p.title)") } else { flash("Restart failed: \(failures.joined(separator: ", "))", error: true) }
            await refresh(full: true)
        }
    }

    func requestRestart(_ s: Service) {
        let key = "restart:\(s.id)"
        guard !busy.contains(key) else { return }
        let name = AppModel.displayName(s, config: config)
        if let m = manifest(for: s) {
            busy.insert(key)
            Task {
                defer { busy.remove(key) }
                do { try await ManagedClient.restart(m); flash("Restarted \(name)") }
                catch { flash("Restart failed: \(error)", error: true) }
                await refresh(full: false)
            }
            return
        }
        guard Dialogs.confirm(
            title: "Restart \(name)?",
            message: "pier will stop it and start it again inside a pier wrapper, so it becomes a managed service with live logs. Environment is captured on a best-effort basis.",
            button: "Restart") else { return }
        busy.insert(key)
        Task {
            defer { busy.remove(key) }
            do { let m = try await ManagedLauncher.adopt(s); flash("Restarted \(m.name) (now managed)") }
            catch { flash("Restart failed: \(error)", error: true) }
            await refresh(full: true)
        }
    }

    func restartCrashed(_ m: ManagedManifest) {
        let key = "restart:\(m.id)"
        busy.insert(key)
        Task {
            defer { busy.remove(key) }
            do { try await ManagedClient.restart(m); flash("Restarted \(m.name)") }
            catch { flash("Restart failed: \(error)", error: true) }
            await refresh(full: false)
        }
    }

    // Tunnel

    func expose(_ s: Service) {
        let key = "expose:\(s.port)", port = s.port
        guard !busy.contains(key) else { return }
        busy.insert(key)
        flash("Starting tunnel…")
        Task {
            defer { busy.remove(key) }
            do {
                let url = try await TunnelLauncher.expose(port: port)
                exposed[port] = url
                Clipboard.copy(url)
                flash("Tunnel ready. URL copied")
            } catch { flash("Expose failed: \(error)", error: true) }
            await refresh(full: false)
        }
    }

    func unexpose(_ s: Service) {
        let port = s.port
        do { try TunnelLauncher.unexpose(port: port); exposed[port] = nil; flash("Tunnel stopped") }
        catch { flash("Stop tunnel failed: \(error)", error: true) }
        Task { await refresh(full: false) }
    }

    // MARK: - Stacks

    private func stackEvent(_ file: String, _ e: StackEvent) {
        switch e {
        case .starting(let n, let m): stackProgress[file] = StackProgress(text: "\(n): \(m)", working: true)
        case .waiting(let n, let m, let t): stackProgress[file] = StackProgress(text: "\(n): \(m) (\(Int(t))s)", working: true)
        case .stopping(let n): stackProgress[file] = StackProgress(text: "stopping \(n)", working: true)
        case .finished(let r): stackProgress[file] = StackProgress(text: "\(r.name): \(r.state.rawValue)", isError: r.state.isFailure, working: true)
        }
    }

    func stackUp(_ k: KnownStack) { runStack(k, up: true) }
    func stackDown(_ k: KnownStack) { runStack(k, up: false) }

    private func runStack(_ k: KnownStack, up: Bool) {
        guard stackProgress[k.file]?.working != true else { return }
        stackProgress[k.file] = StackProgress(text: up ? "Starting…" : "Stopping…", working: true)
        let file = k.file
        Task {
            let hop: @Sendable (StackEvent) -> Void = { e in Task { @MainActor in AppState.shared.stackEvent(file, e) } }
            let path = await ShellEnvironment.path()
            do {
                let stack = try await Task.detached { try StackLoader.load(url: URL(fileURLWithPath: file)) }.value
                let runner = StackRunner(backend: AppStackBackend(path: path), onEvent: hop)
                if up {
                    let r = try await runner.up(stack)
                    StackRegistry.record(name: stack.name, file: file)
                    let bad = r.services.filter { $0.state.isFailure }
                    if bad.isEmpty {
                        stackProgress[file] = StackProgress(text: "Up: \(r.services.count) service\(r.services.count == 1 ? "" : "s")")
                    } else {
                        stackProgress[file] = StackProgress(text: bad.map { "\($0.name): \($0.detail ?? $0.state.rawValue)" }.joined(separator: "\n"), isError: true)
                    }
                } else {
                    let r = try await runner.down(stack)
                    let bad = r.filter { $0.state == .failed }
                    if bad.isEmpty {
                        let n = r.filter { $0.state == .stopped }.count
                        stackProgress[file] = StackProgress(text: n == 0 ? "Nothing was running" : "Stopped \(n) service\(n == 1 ? "" : "s")")
                    } else {
                        stackProgress[file] = StackProgress(text: bad.map { "\($0.name): \($0.detail ?? "failed")" }.joined(separator: "\n"), isError: true)
                    }
                }
            } catch {
                stackProgress[file] = StackProgress(text: "\(error)", isError: true)
            }
            await refresh(full: true)
            // Success notes fade; errors stay until the next action.
            let note = stackProgress[file]
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if stackProgress[file] == note, note?.isError == false { stackProgress[file] = nil }
        }
    }

    func openStackFile(_ k: KnownStack) {
        let editor = config.editor
        Task {
            do {
                if case .finder = EditorOpener.resolve(editor) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: k.file)])
                } else {
                    try await Task.detached { try EditorOpener.open(path: k.file, editor: editor) }.value
                }
            } catch { flash("Open pier.yml failed: \(error.localizedDescription)", error: true) }
        }
    }

    // MARK: - Stale cleanup

    struct CleanupState {
        enum Phase: Equatable { case loading, ready, running, done }
        var phase: Phase = .loading
        var entries: [StaleEntry] = []
        var checked: Set<String> = []
        /// Stale-looking services that were left out because something is connected to them.
        var inUse = 0
        var stopped = 0
        var failures: [String] = []
    }

    func openCleanup() {
        guard cleanup == nil else { return }
        cleanup = CleanupState()
        let list = visibleServices
        Task {
            let entries = await Task.detached(priority: .userInitiated) { Staleness.find(in: list) }.value
            guard cleanup != nil, cleanup?.phase == .loading else { return }
            cleanup = CleanupState(phase: .ready, entries: entries, checked: Set(entries.map(\.service.id)),
                                   inUse: max(0, staleAges.count - entries.count))
        }
    }

    func closeCleanup() { if cleanup?.phase != .running { cleanup = nil } }

    func toggleCleanup(_ id: String) {
        guard var c = cleanup, c.phase == .ready else { return }
        if c.checked.contains(id) { c.checked.remove(id) } else { c.checked.insert(id) }
        cleanup = c
    }

    func runCleanup() {
        guard var c = cleanup, c.phase == .ready else { return }
        let targets = c.entries.map(\.service).filter { c.checked.contains($0.id) }
        guard !targets.isEmpty else { return }
        c.phase = .running
        cleanup = c
        Task {
            var stopped = 0
            var failures: [String] = []
            var seen = Set<Int32>()
            for s in targets {
                guard seen.insert(s.process.pid).inserted else { stopped += 1; continue }
                if let err = await stopService(s, elevate: false) { failures.append(":\(s.port) \(err)") } else { stopped += 1 }
            }
            cleanup?.stopped = stopped
            cleanup?.failures = failures
            cleanup?.phase = .done
            await refresh(full: true)
        }
    }

    // MARK: - Navigation

    func move(_ delta: Int) {
        let nav = navigation
        guard !nav.isEmpty else { return }
        let i = nav.firstIndex { $0 == selectedID } ?? (delta > 0 ? -1 : nav.count)
        selectedID = nav[min(max(i + delta, 0), nav.count - 1)]
    }

    func openDetail(_ s: Service) {
        selectedID = s.id
        detailID = s.id
        qrService = nil
        renaming = false
    }

    func closeDetail() { detailID = nil; qrService = nil; renaming = false; focusSearchToken += 1 }

    func closePopover() {
        if popoverWindow?.isVisible == true { StatusItemBridge.toggle() }
    }

    func toggleGroup(_ g: AppModel.Group) {
        if collapsed.contains(g) { collapsed.remove(g) } else { collapsed.insert(g) }
        ensureSelection()
    }
}
