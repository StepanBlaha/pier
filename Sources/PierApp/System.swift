import AppKit
import Carbon.HIToolbox
import ServiceManagement
import UserNotifications
import PierCore

/// True when running inside Pier.app (UNUserNotificationCenter / SMAppService need a bundle).
let isBundled: Bool = Bundle.main.bundleIdentifier != nil

// MARK: - Notifications

enum Notifier {
    @MainActor private static var authorized: Bool?

    /// Lazy: asks the system on first use. Returns false when unbundled or denied.
    @MainActor
    static func ensureAuthorization() async -> Bool {
        guard isBundled else { return false }
        if let a = authorized { return a }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        var ok: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: ok = true
        case .denied: ok = false
        default: ok = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        authorized = ok
        return ok
    }

    @MainActor
    static func post(title: String, body: String, id: String) {
        guard isBundled else { return }
        Task {
            guard await ensureAuthorization() else { return }
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
        }
    }
}

// MARK: - Dialogs

enum Dialogs {
    @MainActor
    static func confirm(title: String, message: String, button: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - Status item (SwiftUI owns it; we find its button to toggle the popover)

enum StatusItemBridge {
    @MainActor
    static func button() -> NSButton? {
        func find(_ v: NSView) -> NSButton? {
            if String(describing: type(of: v)).contains("StatusBarButton"), let b = v as? NSButton { return b }
            for s in v.subviews { if let b = find(s) { return b } }
            return nil
        }
        for w in NSApp.windows where String(describing: type(of: w)).contains("StatusBar") {
            if let c = w.contentView, let b = find(c) { return b }
        }
        return nil
    }

    @MainActor
    static func toggle() {
        guard let b = button() else { return }
        NSApp.activate(ignoringOtherApps: true)
        b.performClick(nil)
    }
}

// MARK: - Global hotkey (Carbon)

@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onFire: (() -> Void)?

    /// Registers `text` ("opt+cmd+p"). Returns an error message on failure; keeps nothing registered then.
    @discardableResult
    func register(_ text: String) -> String? {
        unregister()
        let spec: HotkeyParser.Spec
        switch HotkeyParser.parse(text) {
        case .failure(let e): return e.localizedDescription
        case .success(let s): spec = s
        }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotkeyManager.shared.onFire?() }
                return noErr
            }, 1, &type, nil, &handler)
            if status != noErr { return "Could not install hotkey handler (\(status))" }
        }
        let id = EventHotKeyID(signature: OSType(0x5049_4552), id: 1)   // 'PIER'
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { ref = nil; return status == -9878 ? "Shortcut already in use by another app" : "Could not register shortcut (\(status))" }
        return nil
    }

    func unregister() {
        if let r = ref { UnregisterEventHotKey(r); ref = nil }
    }
}

// MARK: - Launch at login

enum LoginItem {
    static var isAvailable: Bool { isBundled }
    static var isEnabled: Bool { isBundled && SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { isBundled && SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) throws {
        guard isBundled else { return }
        if on { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
        else { try SMAppService.mainApp.unregister() }
    }
}

// MARK: - Menu bar icon

/// What the status item shows, debounced so a flapping probe or a service restarting never makes the item blink.
/// `count` and `warning` change only after the new value was seen on 2 consecutive refreshes (or immediately on the
/// first snapshot / while the popover is open); the published value changes only when it really differs.
struct MenuBarShown: Equatable { var count = 0; var warning = false }

@MainActor
final class MenuBarModel: ObservableObject {
    static let shared = MenuBarModel()
    @Published private(set) var shown = MenuBarShown()
    private var seenFirst = false
    /// While the popover is open the status item image must not change: swapping the image of a MenuBarExtra item
    /// dismisses its open window (the system hands focus back to the previous app). Updates are parked in `pending`
    /// and applied by `setHeld(false)` once the popover closed.
    private(set) var held = false
    private var pending: (raw: AppModel.MenuBarState, immediate: Bool)?
    private var countCandidate: (value: Int, streak: Int)?
    private var warnCandidate: (value: Bool, streak: Int)?
    static let requiredStreak = 2

    func setHeld(_ on: Bool) {
        held = on
        if !on, let p = pending { pending = nil; update(p.raw, immediate: true) }
    }

    func update(_ raw: AppModel.MenuBarState, immediate: Bool = false) {
        if held { pending = (raw, immediate); return }
        var next = shown
        if immediate || !seenFirst {
            next = MenuBarShown(count: raw.count, warning: raw.warning); countCandidate = nil; warnCandidate = nil
        } else {
            next.count = Self.settle(raw.count, current: shown.count, candidate: &countCandidate)
            next.warning = Self.settle(raw.warning, current: shown.warning, candidate: &warnCandidate)
        }
        seenFirst = true
        if next != shown { shown = next }
    }

    private static func settle<T: Equatable>(_ raw: T, current: T, candidate: inout (value: T, streak: Int)?) -> T {
        if raw == current { candidate = nil; return current }
        let streak = (candidate?.value == raw ? (candidate?.streak ?? 0) : 0) + 1
        if streak >= requiredStreak { candidate = nil; return raw }
        candidate = (raw, streak)
        return current
    }
}

enum MenuBarIcon {
    /// Gull-head template image (18pt tall; black + alpha). Nil when the mascot resources are missing.
    @MainActor static var gull: NSImage? { MascotImages.image(named: "menubar-gull", template: true) }

    /// Fallback glyph when the mascot resources are missing.
    static let symbolName: String? = {
        ["ferry.fill", "ferry", "sailboat.fill", "sailboat", "water.waves"].first {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        }
    }()

    @MainActor private static var cache: [String: NSImage] = [:]

    /// ONE composed image for every state (gull + count + amber dot slot) so the status item never changes structure
    /// or width: two digits and the dot slot are always reserved. Healthy = template (the menu bar tints it for
    /// light/dark); warning = non-template drawn in the label color so the amber dot keeps its color.
    @MainActor
    static func image(count: Int, warning: Bool) -> NSImage {
        let shownCount = min(max(count, 0), 99)
        let key = "\(shownCount)-\(warning)"
        if let hit = cache[key] { return hit }

        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let slot = ("00" as NSString).size(withAttributes: [.font: font]).width
        let art = gull
        let symbol: NSImage? = art != nil ? nil : symbolName.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        }
        let artSize = art?.size ?? symbol?.size ?? NSSize(width: 14, height: 14)
        let dot: CGFloat = 6
        let gap: CGFloat = 3
        let size = NSSize(width: ceil(artSize.width + gap + slot + gap + dot + 1), height: 18)
        let text = String(shownCount)

        let img = NSImage(size: size, flipped: false) { rect in
            let color: NSColor = warning ? .labelColor : .black
            if let drawable = art ?? symbol {
                let tinted = NSImage(size: drawable.size, flipped: false) { r in
                    drawable.draw(in: r)
                    color.set()
                    r.fill(using: .sourceIn)
                    return true
                }
                tinted.draw(in: NSRect(x: 0, y: (rect.height - artSize.height) / 2, width: artSize.width, height: artSize.height))
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let t = NSAttributedString(string: text, attributes: attrs)
            t.draw(at: NSPoint(x: artSize.width + gap, y: (rect.height - t.size().height) / 2))
            if warning {
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.width - dot - 1, y: rect.height / 2 - dot / 2 + 4, width: dot, height: dot)).fill()
            }
            return true
        }
        img.isTemplate = !warning
        cache[key] = img
        return img
    }
}
