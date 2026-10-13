import AppKit
import SwiftUI
import PierCore

@main
struct PierMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Deliberately NOT observed here: re-evaluating the Scene body every refresh could rebuild the status item.
    private let state = AppState.shared

    init() {
        // Menu bar only: no Dock icon, also when run as a bare SPM binary.
        NSApplication.shared.setActivationPolicy(.accessory)
        // The bundle ships the CLI in Contents/Resources/pier; ManagedLauncher spawns wrappers through it.
        if let url = Bundle.main.url(forResource: "pier", withExtension: nil) {
            setenv("PIER_BIN", url.path, 1)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(state: state)
        } label: {
            MenuBarLabel(model: MenuBarModel.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

/// A single Image whose structure never changes; only the (cached) composed NSImage inside it does, and only when the
/// debounced state really changed.
@MainActor
struct MenuBarLabel: View {
    @ObservedObject var model: MenuBarModel
    var body: some View {
        Image(nsImage: MenuBarIcon.image(count: model.shown.count, warning: model.shown.warning))
            .accessibilityLabel("Pier, \(model.shown.count) projects\(model.shown.warning ? ", needs attention" : "")")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let state = AppState.shared
            state.start()
            KeyRouter.shared.install()
            HotkeyManager.shared.onFire = { StatusItemBridge.toggle() }
            if let err = HotkeyManager.shared.register(state.config.hotkey) {
                FileHandle.standardError.write(Data("pier: hotkey \(state.config.hotkey): \(err)\n".utf8))
            }
            #if DEBUG
            DebugHarness.run(state)
            #endif
        }
    }
}

#if DEBUG
/// Headless-verification aids, compiled into DEBUG builds only (release builds ignore every PIER_DEBUG_* variable).
@MainActor
enum DebugHarness {
    static func log(_ s: String) {
        guard let path = ProcessInfo.processInfo.environment["PIER_DEBUG_LOG"] else { return }
        let line = "\(Date().timeIntervalSince1970) \(s)\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: URL(fileURLWithPath: path)) }
    }

    static func run(_ state: AppState) {
        let env = ProcessInfo.processInfo.environment
        // PIER_DEBUG_SNAPSHOT=settings|detail:<path.png> renders a view offscreen to a PNG and quits.
        if let spec = env["PIER_DEBUG_SNAPSHOT"] {
            let delay = spec.hasPrefix("cleanup") ? 3.5 : 2.5
            if spec.hasPrefix("cleanup") { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { state.openCleanup() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { DebugSnapshot.run(spec); NSApp.terminate(nil) }
        }
        // PIER_DEBUG_OPEN=1 opens the popover shortly after launch.
        if env["PIER_DEBUG_OPEN"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { StatusItemBridge.toggle() }
            if let q = env["PIER_DEBUG_QUERY"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { state.query = q }
            }
            if env["PIER_DEBUG_ERROR"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { state.flash("Kill failed: operation not permitted", error: true) }
            }
            if env["PIER_DEBUG_SETTINGS"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { WindowManager.shared.showSettings() }
            }
            if let p = env["PIER_DEBUG_DETAIL"], let port = UInt16(p) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if let s = state.services.first(where: { $0.port == port }) { state.openDetail(s) }
                }
            }
            // PIER_DEBUG_EXPAND=1 expands every group row once the first scan is in.
            if env["PIER_DEBUG_EXPAND"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    log("expand begin")
                    for p in state.shownProjects where p.isGroup { state.expanded.insert(p.id) }
                    log("expand end")
                }
            }
            // PIER_DEBUG_SCROLLBOTTOM=1 scrolls the list to its end (to screenshot the Stacks section).
            if env["PIER_DEBUG_SCROLLBOTTOM"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrollViews) }
                    log("scroll begin")
                    guard let root = state.popoverWindow?.contentView else { return }
                    for sv in scrollViews(root) {
                        if let doc = sv.documentView { doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? max(0, doc.bounds.height - sv.contentView.bounds.height) : 0)) }
                    }
                }
            }
            if env["PIER_DEBUG_CLEANUP"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { state.openCleanup() }
            }
        }
        // PIER_DEBUG_RUN=<folder> opens the Run… window on a folder; PIER_DEBUG_RUN_START=1 presses Start
        // (PIER_DEBUG_RUN_COMMAND overrides the command). Exercises the spawn path without clicking.
        if let folder = env["PIER_DEBUG_RUN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let m = WindowManager.shared.showRun(folder: folder)
                if let c = env["PIER_DEBUG_RUN_COMMAND"] { m.command = c }
                if env["PIER_DEBUG_RUN_START"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { m.start() } }
            }
        }
        // PIER_DEBUG_STACK=up|down presses Up / Down on the first known stack (no clicking needed).
        if let act = env["PIER_DEBUG_STACK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let k = state.knownStacks.first else { log("stack: none known"); return }
                log("stack \(act) \(k.name)")
                if act == "down" { state.stackDown(k) } else { state.stackUp(k) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { log("stack progress: \(String(describing: state.stackProgress[k.file]))") }
            }
        }
        // PIER_DEBUG_STOP=<port> stops that service through the same code path as Stop / group stop / cleanup
        // (no confirmation dialog). Throwaway services only.
        if let p = env["PIER_DEBUG_STOP"], let port = UInt16(p) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let s = state.services.first(where: { $0.port == port }) else { log("stop: no service on \(port)"); return }
                Task { @MainActor in
                    let err = await state.stopService(s)
                    log("stop \(port): \(err ?? "ok")")
                }
            }
        }
        // PIER_DEBUG_LABELCHURN=1 changes the status item image every 2s (root-causing "popover closes itself").
        if env["PIER_DEBUG_LABELCHURN"] != nil {
            var n = 3
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated { n += 1; MenuBarModel.shared.update(.init(count: n, warning: n % 2 == 0), immediate: true) }
            }
        }
        // PIER_DEBUG_LOG=<path> appends popover open/close events (and why) for the "popover closes itself" check.
        if let path = env["PIER_DEBUG_LOG"] {
            @MainActor func log(_ s: String) {
                let line = "\(Date().timeIntervalSince1970) \(s)\n"
                if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                else { try? Data(line.utf8).write(to: URL(fileURLWithPath: path)) }
            }
            for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { n in
                    MainActor.assumeIsolated { log("\(n.name.rawValue) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")") }
                }
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                         NSWindow.didChangeOcclusionStateNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { n in
                    MainActor.assumeIsolated {
                        guard let w = n.object as? NSWindow, String(describing: type(of: w)).contains("MenuBarExtra") || w === AppState.shared.popoverWindow else { return }
                        log("\(n.name.rawValue) visible=\(w.isVisible) key=\(w.isKeyWindow) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                    }
                }
            }
        }
    }
}
#endif

#if DEBUG
@MainActor
enum DebugSnapshot {
    static func run(_ spec: String) {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let state = AppState.shared
        let view: AnyView, size: NSSize
        switch parts[0] {
        case "menubar":
            let rows = [(3, false), (16, false), (16, true), (99, true)]
            var x: CGFloat = 4
            let out = NSImage(size: NSSize(width: 400, height: 60), flipped: false) { _ in
                NSColor(white: 0.9, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 400, height: 60).fill()
                x = 4
                for (c, w) in rows {
                    let img = MenuBarIcon.image(count: c, warning: w)
                    img.draw(in: NSRect(x: x, y: 20, width: img.size.width, height: img.size.height)); x += img.size.width + 10
                }
                return true
            }
            if let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
            }
            return
        case "settings": view = AnyView(SettingsView(state: state)); size = NSSize(width: 460, height: 520)
        case "popover":
            for p in state.shownProjects where p.isGroup { state.expanded.insert(p.id) }
            view = AnyView(PopoverView(state: state)); size = NSSize(width: PopoverView.width, height: 700)
        case "stacks":
            view = AnyView(StacksSection(state: state).frame(width: PopoverView.width).background(Color(nsColor: .windowBackgroundColor)))
            size = NSSize(width: PopoverView.width, height: 160)
        case "cleanup":
            view = AnyView(CleanupSheet(state: state).frame(width: PopoverView.width).background(Color(nsColor: .windowBackgroundColor)))
            size = NSSize(width: PopoverView.width, height: 400)
        case "run":
            let m = RunModel()
            if let f = ProcessInfo.processInfo.environment["PIER_DEBUG_RUN"] { m.setFolder(f) }
            view = AnyView(RunView(model: m, close: {}, window: { nil }).background(Color(nsColor: .windowBackgroundColor)))
            size = NSSize(width: 520, height: 420)
        case "detail":
            guard let s = state.services.first else { return }
            view = AnyView(DetailView(state: state, service: s).frame(width: PopoverView.width).background(Color(nsColor: .windowBackgroundColor)))
            size = NSSize(width: PopoverView.width, height: 560)
        default: return
        }
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
    }
}
#endif
