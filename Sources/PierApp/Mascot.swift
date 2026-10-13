import AppKit
import SwiftUI
import PierCore

// MARK: - Image loading

enum Pose: String, CaseIterable {
    case sleeping, thinking, walking, standing, waving, saluting, surprised
}

/// Loads the mascot PNGs from pier_PierApp.bundle (SwiftPM resource bundle). Never calls `Bundle.module`: its
/// generated accessor `fatalError`s when the bundle is missing, and a bundle at the .app root breaks codesign.
/// Lookup order: Pier.app/Contents/Resources, the directory of the executable (dev builds), else nothing — views
/// that need a mascot then just omit it.
enum MascotImages {
    static let bundleName = "pier_PierApp.bundle"

    static let bundle: Bundle? = {
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent(bundleName)) }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent(bundleName))
        }
        for c in candidates where FileManager.default.fileExists(atPath: c.path) {
            if let b = Bundle(url: c) { return b }
        }
        return nil
    }()

    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(named name: String, template: Bool = false) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let bundle else { return nil }
        func rep(_ file: String) -> NSBitmapImageRep? {
            let url = bundle.url(forResource: file, withExtension: "png", subdirectory: "Mascot")
                ?? bundle.url(forResource: file, withExtension: "png")
            return url.flatMap { try? Data(contentsOf: $0) }.flatMap { NSBitmapImageRep(data: $0) }
        }
        guard let r1 = rep(name) else { return nil }
        let size = NSSize(width: r1.pixelsWide, height: r1.pixelsHigh)
        let img = NSImage(size: size)
        r1.size = size
        img.addRepresentation(r1)
        if let r2 = rep(name + "@2x") { r2.size = size; img.addRepresentation(r2) }
        img.isTemplate = template
        cache[name] = img
        return img
    }

    @MainActor static func image(_ pose: Pose) -> NSImage? { image(named: pose.rawValue) }
}

/// The mascot at a given height; renders nothing when the resources are missing.
struct MascotView: View {
    let pose: Pose
    var height: CGFloat = 80
    var body: some View {
        if let img = MascotImages.image(pose) {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(height: height).accessibilityHidden(true)
        }
    }
}

/// Small rounded avatar of the surprised gull for error surfaces; falls back to the warning triangle.
struct MascotBadge: View {
    var size: CGFloat = 24
    var body: some View {
        if let img = MascotImages.image(.surprised) {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).stroke(Color.orange.opacity(0.7), lineWidth: 1))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: size)
        }
    }
}

// MARK: - Empty / loading states

struct MascotEmptyState: View {
    let pose: Pose
    let title: String
    var hint: LocalizedStringKey?
    var body: some View {
        VStack(spacing: 6) {
            MascotView(pose: pose, height: 84)
            Text(title).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center)
            if let hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .frame(maxWidth: .infinity)
    }
}

struct LoadingState: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false
    var body: some View {
        VStack(spacing: 6) {
            MascotView(pose: .walking, height: 64)
                .offset(y: up && !reduceMotion ? -4 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: up)
            Text("Scanning…").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 24).frame(maxWidth: .infinity)
        .onAppear { up = true }
    }
}

// MARK: - First-launch welcome

enum Welcome {
    static let key = "pier.welcomeSeen"
    static var seen: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

struct WelcomeSheet: View {
    let hotkey: String
    var onDismiss: () -> Void
    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
            VStack(spacing: 10) {
                MascotView(pose: .waving, height: 110)
                Text("Welcome aboard").font(.system(size: 15, weight: .semibold))
                VStack(alignment: .leading, spacing: 8) {
                    line("keyboard", "**\(HotkeyParser.display(hotkey))** opens Pier from anywhere.")
                    line("pin", "Open a service with ▸ to pin or rename it.")
                    line("terminal", "In a terminal: `pier ls`, `pier watch`, `pier completions`.")
                }
                .padding(.vertical, 6)
                Button("Got it", action: onDismiss)
                    .buttonStyle(.pier(.prominent)).keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(minHeight: 340)
    }

    private func line(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Debug aids (headless screenshots)

/// PIER_DEBUG_* environment switches. They exist ONLY in DEBUG builds: in release every flag is a constant false, so a
/// stray variable in a user's environment can never change how Pier.app behaves (the names are not even compiled in).
enum DebugFlags {
    #if DEBUG
    static func isSet(_ name: String) -> Bool { ProcessInfo.processInfo.environment[name] != nil }
    static var forceEmpty: Bool { isSet("PIER_DEBUG_EMPTY") }
    static var forceLoading: Bool { isSet("PIER_DEBUG_LOADING") }
    static var forceWelcome: Bool { isSet("PIER_DEBUG_WELCOME") }
    /// Show the hover quick actions on the selected row without a real mouse hover.
    static var forceHover: Bool { isSet("PIER_DEBUG_HOVER") }
    /// Replace the live scan with made-up services (README screenshots without real project names).
    static var demo: Bool { isSet("PIER_DEBUG_DEMO") }
    #else
    static var forceEmpty: Bool { false }
    static var forceLoading: Bool { false }
    static var forceWelcome: Bool { false }
    static var forceHover: Bool { false }
    static var demo: Bool { false }
    #endif
}

// MARK: - Hover-aware button style

/// One button style for the whole app: hover tint + pointing-hand cursor, darker when pressed, 40% when disabled.
struct PierButtonStyle: ButtonStyle {
    enum Kind {
        case plain        // text-only link-like button (footer)
        case icon         // 22pt icon button
        case iconDestructive  // icon button, red tint on hover (stop / kill)
        case bordered     // resting fill + hairline border (actions)
        case prominent    // accent fill (primary call to action)
        case destructive  // like bordered, red tint on hover
    }
    var kind: Kind = .plain

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, kind: kind)
    }

    struct StyledBody: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        @State private var pushed = false

        var body: some View {
            let pressed = configuration.isPressed
            let shape = RoundedRectangle(cornerRadius: kind == .icon || kind == .iconDestructive ? 6 : 7, style: .continuous)
            configuration.label
                .foregroundStyle(foreground)
                .padding(padding)
                .background(shape.fill(fill(pressed: pressed)))
                .overlay { if kind == .bordered || kind == .destructive { shape.stroke(stroke, lineWidth: 0.5) } }
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.4)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovering)
                .onHover { inside in
                    hovering = inside && enabled
                    setCursor(inside && enabled)
                }
                .onDisappear { setCursor(false); hovering = false }
        }

        private func setCursor(_ on: Bool) {
            if on, !pushed { NSCursor.pointingHand.push(); pushed = true }
            else if !on, pushed { NSCursor.pop(); pushed = false }
        }

        private var padding: EdgeInsets {
            switch kind {
            case .plain: EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6)
            case .icon, .iconDestructive: EdgeInsets()
            case .bordered, .destructive: EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)
            case .prominent: EdgeInsets(top: 6, leading: 18, bottom: 6, trailing: 18)
            }
        }

        private var foreground: Color {
            switch kind {
            case .prominent: .white
            case .destructive, .iconDestructive: hovering ? .red : .primary
            case .plain: hovering ? .primary : .secondary
            default: .primary
            }
        }

        private func fill(pressed: Bool) -> Color {
            switch kind {
            case .plain, .icon:
                return Color.primary.opacity(pressed ? 0.16 : hovering ? 0.09 : 0)
            case .bordered:
                return Color.primary.opacity(pressed ? 0.18 : hovering ? 0.12 : 0.05)
            case .iconDestructive:
                return Color.red.opacity(pressed ? 0.28 : hovering ? 0.16 : 0)
            case .destructive:
                return pressed ? Color.red.opacity(0.28) : hovering ? Color.red.opacity(0.16) : Color.primary.opacity(0.05)
            case .prominent:
                return Color.accentColor.opacity(pressed ? 0.7 : hovering ? 0.88 : 1)
            }
        }

        private var stroke: Color {
            kind == .destructive && hovering ? Color.red.opacity(0.45) : Color.primary.opacity(0.1)
        }
    }
}

extension ButtonStyle where Self == PierButtonStyle {
    static func pier(_ kind: PierButtonStyle.Kind = .plain) -> PierButtonStyle { PierButtonStyle(kind: kind) }
}

/// Pointing-hand cursor while hovering (for tappable rows that are not Buttons).
struct PointerCursor: ViewModifier {
    @State private var pushed = false
    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed { NSCursor.pointingHand.push(); pushed = true }
                else if !inside, pushed { NSCursor.pop(); pushed = false }
            }
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
    }
}

extension View { func pointerCursor() -> some View { modifier(PointerCursor()) } }
