import AppKit
import SwiftUI
import PierCore

/// Owns the auxiliary windows (Settings, Logs). The popover is dismissed by the system when these take focus.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()
    private var settings: NSWindow?
    private var logWindows: [String: (NSWindow, LogsModel)] = [:]
    private var runWindow: NSWindow?
    private var runModel: RunModel?

    func showSettings() {
        if let w = settings { reveal(w); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Pier Settings"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView(state: AppState.shared))
        w.center()
        w.delegate = self
        settings = w
        reveal(w)
    }

    /// "Run…": folder picker + detected command + optional name. A real window (not part of the popover) because the
    /// open panel would take key status away from the popover and dismiss it.
    @discardableResult
    func showRun(folder: String? = nil) -> RunModel {
        if let w = runWindow, let m = runModel {
            if let folder { m.setFolder(folder) }
            reveal(w); return m
        }
        let model = RunModel()
        var hostWindow: NSWindow?
        let view = RunView(model: model, close: { [weak self] in self?.runWindow?.close() }, window: { hostWindow })
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable]
        w.title = "Run…"
        w.isReleasedWhenClosed = false
        w.center()
        w.delegate = self
        hostWindow = w
        runWindow = w; runModel = model
        if let folder { model.setFolder(folder) }
        reveal(w)
        if folder == nil, model.folder == nil {
            DispatchQueue.main.async { model.choose(from: w) }
        }
        return model
    }

    func showLogs(for manifest: ManagedManifest, title: String) {
        if let (w, model) = logWindows[manifest.id] { model.restartIfNeeded(); reveal(w); return }
        let model = LogsModel(manifest: manifest)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Logs · \(title)"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: LogsView(model: model))
        w.setFrameAutosaveName("PierLogs")
        w.center()
        w.delegate = self
        logWindows[manifest.id] = (w, model)
        model.start()
        reveal(w)
    }

    private func reveal(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow else { return }
        if w === settings { settings = nil }
        if w === runWindow { runWindow = nil; runModel = nil }
        if let (id, entry) = logWindows.first(where: { $0.value.0 === w }) {
            entry.1.stop()
            logWindows[id] = nil
        }
    }
}
