import AppKit
import SwiftUI
import PierCore

struct PopoverView: View {
    @ObservedObject var state: AppState
    @FocusState private var searchFocused: Bool

    static let width: CGFloat = 380
    static let maxHeight: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let s = state.detailService {
                    DetailView(state: state, service: s)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    listPane
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if let q = state.qrService {
                    QRSheet(service: q) { state.qrService = nil }
                        .transition(.opacity)
                }
                if state.cleanup != nil {
                    CleanupSheet(state: state).transition(.opacity)
                }
                if state.showWelcome {
                    WelcomeSheet(hotkey: state.config.hotkey) { state.dismissWelcome() }
                        .transition(.opacity)
                }
            }
            .clipped()
            if let b = state.banner { BannerView(banner: b).transition(.move(edge: .bottom).combined(with: .opacity)) }
            Divider()
            FooterView(state: state)
        }
        .frame(width: Self.width)
        // MenuBarExtra's window is translucent; whatever is behind it bleeds through. Paint a (near) opaque base.
        .background {
            ZStack {
                Rectangle().fill(.thickMaterial)
                Color(nsColor: .windowBackgroundColor).opacity(0.94)
            }
            .ignoresSafeArea()
        }
        .animation(.easeInOut(duration: 0.15), value: state.showWelcome)
        .animation(.easeInOut(duration: 0.18), value: state.detailID)
        .animation(.easeInOut(duration: 0.18), value: state.banner)
        .animation(.easeInOut(duration: 0.15), value: state.qrService?.id)
        .animation(.easeInOut(duration: 0.15), value: state.cleanup != nil)
        .background(WindowReader { win in
            state.popoverWindow = win
            Observers.shared.attach(to: win)
            if win.isKeyWindow { state.popoverOpened() }
        })
        .onChange(of: state.focusSearchToken) { _, _ in searchFocused = true }
        .onAppear { searchFocused = true; KeyRouter.shared.install() }
    }

    // MARK: List

    private var listPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search services, ports, projects", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onChange(of: state.query) { _, _ in state.ensureSelection() }
                    .onSubmit { state.activateSelection() }
                if !state.query.isEmpty {
                    Button { state.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 20, height: 20)
                    }
                    .buttonStyle(.pier(.icon)).help("Clear search (esc)")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            list
        }
    }

    @ViewBuilder private var list: some View {
        let filtered = state.filtered
        let sections = state.sections
        if !state.loadedOnce {
            LoadingState()
        } else if let filtered {
            if filtered.isEmpty {
                MascotEmptyState(pose: .thinking, title: "No service matches “\(state.query)”",
                                 hint: "Try a port, a project name or a framework.")
            } else {
                scroller { VStack(spacing: 0) { ForEach(filtered) { projectView($0) } }.padding(.vertical, 4) }
            }
        } else {
            VStack(spacing: 0) {
                scroller {
                    VStack(spacing: 0) {
                        if sections.isEmpty {
                            MascotEmptyState(pose: .sleeping, title: "Nothing listening right now",
                                             hint: "Start a dev server, or run `pier run` in a project")
                        }
                        ForEach(sections) { sec in sectionView(sec) }
                        if !state.stackStatuses.isEmpty { StacksSection(state: state) }
                    }.padding(.vertical, 4)
                }
                if state.staleCount > 0 { staleStrip }
            }
        }
    }

    /// "3 idle for days  Clean up 3 stale…"
    private var staleStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("\(state.staleCount) idle for 3+ days").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("Clean up \(state.staleCount) stale…") { state.openCleanup() }
                .buttonStyle(.pier(.bordered)).font(.system(size: 11))
                .help("Review and stop forgotten dev servers (up 3+ days, idle)")
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .top) { Divider() }
    }

    private func scroller<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        let c = content()
        return ScrollViewReader { proxy in
            FittingScroll(maxHeight: Self.maxHeight - 90) { c }
                .onChange(of: state.selectedID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id) } }
                }
        }
    }

    private func sectionView(_ sec: AppModel.ProjectSection) -> some View {
        let collapsed = state.collapsed.contains(sec.group)
        let header = HStack(spacing: 4) {
            if sec.group == .system {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 8, weight: .bold))
            }
            Text(sec.group.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.5)
            Text("\(sec.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 3)
        .contentShape(Rectangle())
        return VStack(spacing: 0) {
            if sec.group == .system {
                Button { state.toggleGroup(.system) } label: { header }
                    .buttonStyle(.pier(.plain)).padding(.top, 4)
                    .help(collapsed ? "Show system services" : "Hide system services")
            } else {
                header.padding(.horizontal, 6)
            }
            if !collapsed {
                ForEach(sec.crashed) { CrashedRow(state: state, manifest: $0) }
                ForEach(sec.projects) { projectView($0) }
            }
        }
    }

    @ViewBuilder private func projectView(_ p: AppModel.Project) -> some View {
        ProjectRow(state: state, project: p)
        if p.isGroup, state.expanded.contains(p.id) {
            ForEach(p.services) { MemberRow(state: state, project: p, service: $0) }
        }
    }
}

// MARK: - Rows

/// "idle 11d" marker for rows Staleness considers forgotten.
struct StaleBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .foregroundStyle(Color.secondary)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .help("Up for days and idle (no CPU use). See “Clean up stale…” at the bottom of the list.")
    }
}

/// ":4200 :4201 :4202 +2" chips of a group row.
struct PortChips: View {
    let ports: [UInt16]
    var body: some View {
        let (shown, more) = AppModel.portChips(ports)
        HStack(spacing: 3) {
            ForEach(shown, id: \.self) { Chip(text: ":\($0)") }
            if more > 0 { Chip(text: "+\(more)").help(ports.map { ":\($0)" }.joined(separator: " ")) }
        }
    }
    struct Chip: View {
        let text: String
        var body: some View {
            Text(text).font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 0.5)
                .foregroundStyle(.secondary)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.07)))
        }
    }
}

/// Icon buttons shown at the right of a hovered row, in place of the health dot.
struct QuickActions: View {
    var openHelp = "Open in browser (↩)"
    var copyHelp = "Copy URL (⌘C)"
    var onOpen: () -> Void
    var onCopy: () -> Void
    var onLogs: (() -> Void)?
    var canRestart: Bool
    var restarting: Bool
    var restartHelp = "Restart"
    var onRestart: () -> Void
    var canStop: Bool
    var stopping: Bool
    var stopHelp = "Stop (⌘⌫)"
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("arrow.up.right.square", openHelp, onOpen)
            button("doc.on.doc", copyHelp, onCopy)
            if let onLogs { button("text.alignleft", "Live logs", onLogs) }
            button(restarting ? "hourglass" : "arrow.clockwise", canRestart ? restartHelp : "Restart isn’t available for this service",
                   onRestart, enabled: canRestart && !restarting)
            button(stopping ? "hourglass" : "xmark.octagon", canStop ? stopHelp : "Stop isn’t offered for system services",
                   onStop, enabled: canStop && !stopping, kind: .iconDestructive)
        }
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void, enabled: Bool = true,
                        kind: PierButtonStyle.Kind = .icon) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 22, height: 24)
        }
        .buttonStyle(.pier(kind))
        .help(help)
        .accessibilityLabel(help)
        .disabled(!enabled)
    }
}

/// One project row: a single service, or a group of services of the same project.
struct ProjectRow: View {
    @ObservedObject var state: AppState
    let project: AppModel.Project
    @State private var hovering = false

    private var selected: Bool { state.selectedID == project.id }
    private var expanded: Bool { state.expanded.contains(project.id) }
    private var showActions: Bool { hovering || (DebugFlags.forceHover && selected) }
    private var s: Service { project.main }

    var body: some View {
        HStack(spacing: 10) {
            ServiceIcon(service: s, size: 26)
            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    if project.isPinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.orange) }
                    Text(project.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !showActions {   // the quick actions need the room
                        ForEach(project.badges, id: \.self) { BadgeView(badge: $0).fixedSize() }
                        if let idle = AppModel.staleLabel(project, ages: state.staleAges) { StaleBadge(text: idle).fixedSize() }
                    }
                }
                subtitle
            }
            Spacer(minLength: 4)
            if showActions {
                QuickActions(
                    onOpen: { state.open(s) },
                    onCopy: { state.copyURL(s) },
                    onLogs: logsAction,
                    canRestart: state.canRestart(project), restarting: state.busy.contains("restart:\(project.id)"),
                    restartHelp: project.isGroup ? "Restart all \(project.services.count) services" : "Restart",
                    onRestart: { state.requestRestart(project) },
                    canStop: project.services.contains(where: state.isStoppable), stopping: state.busy.contains("kill:\(project.id)"),
                    stopHelp: project.isGroup ? "Stop all \(project.services.count) services (⌘⌫)" : "Stop (⌘⌫)",
                    onStop: { state.requestStop(project) })
            } else {
                HealthDot(health: project.health)
            }
            Button {
                if project.isGroup { state.toggleExpanded(project) } else { state.openDetail(s) }
            } label: {
                Image(systemName: project.isGroup ? (expanded ? "chevron.down" : "chevron.right") : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? .primary : .tertiary)
                    .frame(width: 22, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.pier(.icon))
            .help(project.isGroup ? (expanded ? "Hide the \(project.services.count) ports" : "Show the \(project.services.count) ports (→)") : "Details (→)")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.primary.opacity(0.09) : .clear))
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onTapGesture { state.activate(project) }
        .onHover { inside in
            hovering = inside
            if inside { state.selectedID = project.id }
        }
        .pointerCursor()
        .help(project.isGroup ? (expanded ? "Collapse \(project.title) (↩)" : "Show the \(project.services.count) ports of \(project.title) (↩)")
                              : "Open \(project.title) (↩)")
        .id(project.id)
    }

    private var logsAction: (() -> Void)? {
        let managedIDs = Set(project.services.compactMap(\.managedID))
        guard managedIDs.count == 1, let m = project.services.first(where: { $0.isManaged }) else { return nil }
        return { state.showLogs(m) }
    }

    @ViewBuilder private var subtitle: some View {
        if showActions {
            let stats = AppModel.statsLine(project.services, now: state.now)
            Text(stats.isEmpty ? project.subtitle : stats)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        } else if project.isGroup {
            HStack(spacing: 6) {
                if !project.subtitle.isEmpty {
                    Text(project.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .layoutPriority(0)
                }
                PortChips(ports: project.ports).layoutPriority(1).fixedSize()
            }
        } else {
            Text(project.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// A port inside an expanded group: its own actions and detail.
struct MemberRow: View {
    @ObservedObject var state: AppState
    let project: AppModel.Project
    let service: Service
    @State private var hovering = false

    private var selected: Bool { state.selectedID == service.id }
    private var showActions: Bool { hovering || (DebugFlags.forceHover && selected) }

    var body: some View {
        let s = service
        HStack(spacing: 8) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1.5).padding(.vertical, 2)
            ServiceIcon(service: s, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(":\(String(s.port))").font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(AppModel.memberTitle(s)).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                    if !showActions {
                        ForEach(AppModel.badges(s), id: \.self) { BadgeView(badge: $0).fixedSize() }
                        if let idle = AppModel.staleLabel(s, ages: state.staleAges) { StaleBadge(text: idle).fixedSize() }
                    }
                }
                let sub = showActions ? AppModel.statsLine([s], now: state.now) : AppModel.memberSubtitle(s)
                if !sub.isEmpty { Text(sub).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 4)
            if showActions {
                QuickActions(
                    onOpen: { state.open(s) },
                    onCopy: { state.copyURL(s) },
                    onLogs: s.isManaged ? { state.showLogs(s) } : nil,
                    canRestart: state.canRestart(s), restarting: state.busy.contains("restart:\(s.id)"),
                    onRestart: { state.requestRestart(s) },
                    canStop: state.isStoppable(s), stopping: state.busy.contains("kill:\(s.id)"),
                    onStop: { state.requestKill(s) })
            } else {
                HealthDot(health: AppModel.health(s))
            }
            Button { state.openDetail(s) } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? .primary : .tertiary)
                    .frame(width: 22, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.pier(.icon))
            .help("Details (→)")
        }
        .padding(.leading, 22).padding(.trailing, 10).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.primary.opacity(0.09) : .clear))
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onTapGesture { state.open(s) }
        .onHover { inside in
            hovering = inside
            if inside { state.selectedID = s.id }
        }
        .pointerCursor()
        .help("Open :\(String(s.port)) (↩)")
        .id(s.id)
    }
}

// MARK: - Stacks

struct StacksSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("STACKS").font(.system(size: 10, weight: .semibold)).tracking(0.5)
                Text("\(state.stackStatuses.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 3)
            ForEach(state.stackStatuses) { StackRow(state: state, status: $0) }
        }
    }
}

struct StackRow: View {
    @ObservedObject var state: AppState
    let status: AppModel.StackStatus

    private var k: KnownStack { status.stack }
    private var progress: AppState.StackProgress? { state.stackProgress[k.file] }
    private var working: Bool { progress?.working == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(k.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(status.summary).font(.system(size: 11)).foregroundStyle(status.running > 0 ? Color.green : Color.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if working { ProgressView().controlSize(.small).padding(.trailing, 2) }
                HStack(spacing: 0) {
                    iconButton("play.fill", "Start every service of this stack (pier up)", disabled: working) { state.stackUp(k) }
                    iconButton("stop.fill", "Stop every running service of this stack (pier down)",
                               disabled: working || status.running == 0, kind: .iconDestructive) { state.stackDown(k) }
                    iconButton("doc.text", "Open pier.yml in your editor") { state.openStackFile(k) }
                }
            }
            if let p = progress {
                Text(p.text).font(.system(size: 10.5)).foregroundStyle(p.isError ? Color.red : Color.secondary)
                    .lineLimit(5).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.leading, 36)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 5)
        .help(k.file)
    }

    private func iconButton(_ symbol: String, _ help: String, disabled: Bool = false,
                            kind: PierButtonStyle.Kind = .icon, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24)
        }
        .buttonStyle(.pier(kind)).help(help).accessibilityLabel(help).disabled(disabled)
    }
}

// MARK: - Stale cleanup sheet

struct CleanupSheet: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            if let c = state.cleanup {
                VStack(spacing: 10) {
                    switch c.phase {
                    case .loading:
                        MascotView(pose: .walking, height: 56)
                        Text("Looking for forgotten servers…").font(.system(size: 12)).foregroundStyle(.secondary)
                    case .ready: ready(c)
                    case .running:
                        ProgressView().controlSize(.regular)
                        Text("Stopping \(c.checked.count) service\(c.checked.count == 1 ? "" : "s")…").font(.system(size: 12)).foregroundStyle(.secondary)
                    case .done: done(c)
                    }
                }
                .padding(16)
            }
        }
        .frame(minHeight: 330)
    }

    @ViewBuilder private func ready(_ c: AppState.CleanupState) -> some View {
        if c.entries.isEmpty {
            MascotEmptyState(pose: .sleeping, title: "Nothing to clean up",
                             hint: c.inUse > 0 ? "\(c.inUse) idle service\(c.inUse == 1 ? " is" : "s are") still in use (open connections)." : "No dev server has been idle for 3+ days.")
            Button("Close") { state.closeCleanup() }.buttonStyle(.pier(.bordered)).keyboardShortcut(.cancelAction).help("Close")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clean up stale services").font(.system(size: 14, weight: .semibold))
                Text("Up for 3+ days, idle, nobody connected. Uncheck what you still need.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            FittingScroll(maxHeight: 250) {
                VStack(spacing: 0) {
                    ForEach(c.entries, id: \.service.id) { e in
                        let on = c.checked.contains(e.service.id)
                        Button { state.toggleCleanup(e.service.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: on ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 14)).foregroundStyle(on ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(AppModel.displayName(e.service, config: state.config)).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    Text(detail(e)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.pier(.plain))
                        .help(on ? "Keep this one" : "Include this one")
                    }
                }
            }
            if c.inUse > 0 {
                Text("\(c.inUse) more look idle but have open connections, so they are left out.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Cancel") { state.closeCleanup() }.buttonStyle(.pier(.bordered)).keyboardShortcut(.cancelAction).help("Close without stopping anything")
                Spacer()
                Button("Stop \(c.checked.count)") { state.runCleanup() }
                    .buttonStyle(.pier(.destructive)).disabled(c.checked.isEmpty)
                    .help("Stop the checked services")
            }
        }
    }

    @ViewBuilder private func done(_ c: AppState.CleanupState) -> some View {
        MascotView(pose: c.failures.isEmpty ? .saluting : .surprised, height: 84)
        Text(c.failures.isEmpty ? "Cleaned up \(c.stopped) service\(c.stopped == 1 ? "" : "s")" : "Stopped \(c.stopped), \(c.failures.count) failed")
            .font(.system(size: 14, weight: .semibold))
        if !c.failures.isEmpty {
            Text(c.failures.joined(separator: "\n")).font(.system(size: 11)).foregroundStyle(.red).multilineTextAlignment(.center)
        } else {
            Text("Ports are free again.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Button("Done") { state.closeCleanup() }.buttonStyle(.pier(.prominent)).keyboardShortcut(.defaultAction).help("Close")
    }

    private func detail(_ e: StaleEntry) -> String {
        var parts = [":\(e.service.port)", "up \(Format.duration(e.uptimeSeconds))"]
        if let r = e.service.process.rssBytes { parts.append(Format.bytes(r)) }
        if let p = e.service.projectPath { parts.append((p as NSString).abbreviatingWithTildeInPath) }
        return parts.joined(separator: " · ")
    }
}

struct CrashedRow: View {
    @ObservedObject var state: AppState
    let manifest: ManagedManifest
    var body: some View {
        HStack(spacing: 10) {
            MascotBadge(size: 26)
            VStack(alignment: .leading, spacing: 1.5) {
                Text(manifest.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("crashed" + (manifest.lastExitCode.map { " · exit \($0)" } ?? "")).font(.system(size: 11)).foregroundStyle(.orange)
            }
            Spacer()
            Button("Logs") { state.showLogs(manifest: manifest) }.buttonStyle(.pier(.bordered)).font(.system(size: 11))
                .help("Show logs")
            Button("Restart") { state.restartCrashed(manifest) }.buttonStyle(.pier(.bordered)).font(.system(size: 11))
                .help("Restart this service")
                .disabled(state.busy.contains("restart:\(manifest.id)"))
        }
        .padding(.horizontal, 15).padding(.vertical, 5)
    }
}

struct EmptyState: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 30)
    }
}

struct BannerView: View {
    let banner: AppState.Banner
    var body: some View {
        HStack(spacing: 6) {
            if banner.isError {
                MascotBadge(size: 22)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(banner.text).font(.system(size: 11)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06))
    }
}

struct FooterView: View {
    @ObservedObject var state: AppState
    var body: some View {
        HStack(spacing: 10) {
            Text(AppModel.footer(count: state.menuBar.count, unit: "project", refreshedAt: state.refreshedAt, now: state.now))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Run…") { WindowManager.shared.showRun() }.buttonStyle(.pier(.plain))
                .font(.system(size: 11)).help("Start a project: pick a folder and a command")
            Button("Settings…") { WindowManager.shared.showSettings() }.buttonStyle(.pier(.plain))
                .font(.system(size: 11)).help("Settings (⌘,)")
            Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.pier(.plain))
                .font(.system(size: 11)).help("Quit Pier (⌘Q)")
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }
}

// MARK: - Open / close observation

@MainActor
final class Observers {
    static let shared = Observers()
    private var attached: ObjectIdentifier?
    private var tokens: [NSObjectProtocol] = []

    func attach(to win: NSWindow) {
        guard attached != ObjectIdentifier(win) else { return }
        attached = ObjectIdentifier(win)
        tokens.forEach(NotificationCenter.default.removeObserver)
        let nc = NotificationCenter.default
        tokens = [
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: win, queue: .main) { _ in
                MainActor.assumeIsolated { AppState.shared.popoverOpened() }
            },
            nc.addObserver(forName: NSWindow.didResignKeyNotification, object: win, queue: .main) { _ in
                MainActor.assumeIsolated { AppState.shared.popoverClosed() }
            },
        ]
    }
}
