import AppKit
import SwiftUI
import PierCore

// MARK: - Favicon

actor FaviconLoader {
    static let shared = FaviconLoader()
    private let cache = NSCache<NSString, NSImage>()
    private var misses: Set<String> = []
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 1.5
        c.timeoutIntervalForResource = 3
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func image(for urlString: String) async -> NSImage? {
        if let hit = cache.object(forKey: urlString as NSString) { return hit }
        if misses.contains(urlString) { return nil }
        // ATS exempts IP literals but may block "localhost"; try the literal loopbacks as fallbacks.
        var candidates = [urlString]
        if let u = URL(string: urlString), u.host == "localhost" {
            for host in ["127.0.0.1", "[::1]"] {
                candidates.append(urlString.replacingOccurrences(of: "://localhost", with: "://\(host)"))
            }
        }
        for c in candidates {
            guard let url = URL(string: c) else { continue }
            if let (data, resp) = try? await session.data(from: url),
               (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
               data.count < 1_000_000, let img = NSImage(data: data), img.isValid, img.size.width > 0 {
                cache.setObject(img, forKey: urlString as NSString)
                return img
            }
        }
        misses.insert(urlString)
        return nil
    }
}

struct ServiceIcon: View {
    let service: Service
    var size: CGFloat = 24
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .task(id: service.probe?.faviconURL) {
            image = nil
            guard let url = service.probe?.faviconURL else { return }
            image = await FaviconLoader.shared.image(for: url)
        }
    }

    @ViewBuilder private var fallback: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        switch AppModel.fallbackGlyph(service) {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: size, height: size).background(shape.fill(Color.primary.opacity(0.07)))
        case .letter(let l):
            Text(l).font(.system(size: size * 0.5, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                .frame(width: size, height: size).background(shape.fill(Self.color(for: service)))
        }
    }

    static func color(for s: Service) -> Color {
        let key = s.framework?.id ?? s.projectName ?? s.process.name
        let hue = Double(abs(key.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }) % 360) / 360
        return Color(hue: hue, saturation: 0.45, brightness: 0.72)
    }
}

// MARK: - Small pieces

struct HealthDot: View {
    let health: Health
    var body: some View {
        Circle()
            .fill(color)
            .overlay(Circle().stroke(Color.secondary.opacity(health == .unknown ? 0.6 : 0), lineWidth: 1))
            .frame(width: 7, height: 7)
            .help(label)
    }
    private var color: Color {
        switch health {
        case .ok: .green
        case .error: .red
        case .timeout: .gray
        case .unknown: .clear
        }
    }
    private var label: String {
        switch health { case .ok: "Healthy"; case .error: "Server error (5xx)"; case .timeout: "No response"; case .unknown: "Not probed" }
    }
}

struct BadgeView: View {
    let badge: AppModel.Badge
    var body: some View {
        Text(badge.rawValue)
            .font(.system(size: 9, weight: .semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
    private var tint: Color {
        switch badge { case .lan: .blue; case .managed: .purple; case .tunnel: .teal }
    }
}

/// Measures content height so the popover hugs short lists and scrolls long ones.
struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct FittingScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var h: CGFloat = 0
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            content.background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
        }
        .onPreferenceChange(HeightKey.self) { h = $0 }
        .frame(height: min(max(h, 40), maxHeight))
    }
}

/// Reports the hosting NSWindow (the MenuBarExtra panel) so open/close can be observed.
struct WindowReader: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = Probe()
        v.onWindow = onWindow
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window { DispatchQueue.main.async { self.onWindow?(w) } }
        }
    }
}

struct IconButton: View {
    let systemName: String
    let help: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24)
        }
        .buttonStyle(.pier(.icon))
        .help(help)
        .accessibilityLabel(help)
    }
}
