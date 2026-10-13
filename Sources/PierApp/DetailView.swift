import AppKit
import SwiftUI
import PierCore

struct DetailView: View {
    @ObservedObject var state: AppState
    let service: Service
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    private var s: Service { service }
    private var title: String { AppModel.displayName(s, config: state.config) }
    private var tunnel: String? { s.tunnelURL ?? state.exposed[s.port] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            FittingScroll(maxHeight: PopoverView.maxHeight - 60) {
                VStack(alignment: .leading, spacing: 14) {
                    urls
                    actions
                    facts
                }
                .padding(12)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button { state.closeDetail() } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24)
            }
            .buttonStyle(.pier(.icon)).help("Back (←)")
            ServiceIcon(service: s, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                if state.renaming {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.roundedBorder).font(.system(size: 13, weight: .semibold))
                        .focused($nameFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { state.renaming = false; state.focusSearchToken += 1 }
                } else {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        ForEach(AppModel.badges(s), id: \.self) { BadgeView(badge: $0) }
                    }
                }
                Text(AppModel.secondaryLine(s, title: title)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if state.renaming {
                Button("Save") { commitRename() }.buttonStyle(.pier(.bordered)).font(.system(size: 11)).help("Save name")
            } else {
                IconButton(systemName: "pencil", help: "Rename") { draft = title; state.renaming = true; nameFocused = true }
                IconButton(systemName: AppModel.isPinned(s, config: state.config) ? "pin.slash" : "pin",
                           help: AppModel.isPinned(s, config: state.config) ? "Unpin" : "Pin") { state.togglePin(s) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func commitRename() {
        state.rename(s, to: draft)
        state.renaming = false
        state.focusSearchToken += 1
    }

    // MARK: URLs

    private var urls: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("URLs")
            urlRow("Local", s.localURL)
            if let lan = s.lanURL, s.bindScope != .loopback { urlRow("LAN", lan) }
            if let t = tunnel { urlRow("Tunnel", t) }
        }
    }

    private func urlRow(_ label: String, _ url: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
            Text(url).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 0)
            IconButton(systemName: "doc.on.doc", help: "Copy \(label) URL") { state.copy(url, label: "\(label) URL") }
            IconButton(systemName: "arrow.up.right.square", help: "Open") { state.openURL(url) }
        }
    }

    // MARK: Actions

    private var actions: some View {
        let busyExpose = state.busy.contains("expose:\(s.port)")
        let busyRestart = state.busy.contains("restart:\(s.id)")
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Actions")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], alignment: .leading, spacing: 6) {
                action("Open", "safari") { state.open(s) }
                action("Editor", "chevron.left.forwardslash.chevron.right", disabled: s.projectPath == nil && s.process.cwd == nil) { state.openEditor(s) }
                action("Terminal", "terminal", disabled: s.owners.isEmpty) { state.jumpToTerminal(s) }
                action("QR", "qrcode") { state.showQR(s) }
                action("Logs", "text.alignleft", disabled: !s.isManaged) { state.showLogs(s) }
                    .help(s.isManaged ? "Live logs" : "Start via `pier run` for logs")
                action(busyRestart ? "Restarting…" : "Restart", "arrow.clockwise", disabled: !state.canRestart(s) || busyRestart) { state.requestRestart(s) }
                if tunnel == nil {
                    action(busyExpose ? "Starting…" : "Expose", "network", disabled: busyExpose) { state.expose(s) }
                } else {
                    action("Stop tunnel", "network.slash") { state.unexpose(s) }
                }
                action("Kill", "xmark.octagon", role: .destructive, disabled: s.isNoise || s.kind == .system || state.busy.contains("kill:\(s.id)")) { state.requestKill(s) }
            }
            if !s.isManaged {
                Text("Logs: start via `pier run` for logs").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private func action(_ label: String, _ icon: String, role: ButtonRole? = nil, disabled: Bool = false,
                        _ run: @escaping () -> Void) -> some View {
        Button(role: role, action: run) {
            Label(label, systemImage: icon).font(.system(size: 11.5)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.pier(role == .destructive ? .destructive : .bordered))
        .help(label)
        .disabled(disabled)
    }

    // MARK: Facts

    private var facts: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Details")
            let rows = factRows()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(r.0).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                    if r.0 == "Health" {
                        HealthDot(health: AppModel.health(s)).padding(.trailing, -2)
                    }
                    Text(r.1).font(.system(size: 11.5, design: r.2 ? .monospaced : .default))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// (label, value, monospaced)
    private func factRows() -> [(String, String, Bool)] {
        let p = s.process
        var r: [(String, String?, Bool)] = [
            ("Project", s.projectPath ?? s.projectName, true),
            ("Git branch", s.gitBranch, true),
            ("Framework", s.framework?.name, false),
            ("Infra", s.infraName, false),
            ("Runtime", s.runtime, false),
            ("Bind", "\(Format.bindLabel(s.bindScope)) · \(s.addresses.joined(separator: ", "))", false),
            ("Protocol", s.probe.map { $0.protocolKind.rawValue }, false),
            ("Health", s.probe == nil ? "not probed" : ServiceDetail.healthText(s), false),
            ("Page title", s.probe?.title, false),
            ("Owners", s.owners.isEmpty ? nil : Format.ownerChain(s), false),
            ("Uptime", Format.uptime(p, now: state.now), false),
            ("CPU", p.cpuPercent.map { String(format: "%.1f%%", $0) }, false),
            ("Memory", p.rssBytes.map(Format.bytes), false),
            ("PID", "\(p.pid)  (parent \(p.ppid))", false),
            ("Command", p.arguments.isEmpty ? nil : p.arguments.joined(separator: " "), true),
        ]
        if let d = s.docker {
            r.append(("Container", "\(d.containerName) · \(d.image) · :\(d.containerPort)", false))
            if let c = d.composeProject { r.append(("Compose", c + (d.composeService.map { " / \($0)" } ?? ""), false)) }
        }
        if let m = state.manifest(for: s) {
            r.append(("Managed", "\(m.state.rawValue) · restarts \(m.restartCount)", false))
        }
        if !p.isAccessible { r.append(("Note", "limited info (other user or root process)", false)) }
        return r.compactMap { l, v, m in v.flatMap { $0.isEmpty ? nil : (l, $0, m) } }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
    }
}

// MARK: - QR

struct QRSheet: View {
    let service: Service
    var onClose: () -> Void

    private var result: Result<String, Error> { Result { try QR.lanURL(for: service) } }

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).onTapGesture(perform: onClose)
            VStack(spacing: 12) {
                switch result {
                case .success(let url):
                    if let m = QR.matrix(for: url) {
                        Image(nsImage: QRRender.image(m, scale: 6))
                            .interpolation(.none).resizable().frame(width: 220, height: 220)
                            .padding(10).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Text("Could not render QR code").foregroundStyle(.secondary)
                    }
                    Text(url).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Text("Scan with a phone on the same network").font(.caption).foregroundStyle(.secondary)
                case .failure(let e):
                    Image(systemName: "wifi.slash").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(e.localizedDescription).font(.system(size: 12)).multilineTextAlignment(.center)
                        .padding(.horizontal, 24).fixedSize(horizontal: false, vertical: true)
                }
                Button("Done", action: onClose).buttonStyle(.pier(.prominent)).keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .frame(minHeight: 360)
    }
}

enum QRRender {
    /// Renders the module grid with a 4-module quiet zone, crisp at any size.
    static func image(_ m: QRMatrix, scale: Int) -> NSImage {
        let quiet = 4, n = m.size + quiet * 2
        let px = n * scale
        let img = NSImage(size: NSSize(width: px, height: px))
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: px, height: px).fill()
        NSColor.black.setFill()
        for y in 0 ..< m.size {
            for x in 0 ..< m.size where m.isDark(x: x, y: y) {
                NSRect(x: (x + quiet) * scale, y: px - (y + quiet + 1) * scale, width: scale, height: scale).fill()
            }
        }
        img.unlockFocus()
        return img
    }
}
