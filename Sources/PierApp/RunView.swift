import AppKit
import SwiftUI
import PierCore

// MARK: - Login-shell PATH

/// A menu bar app is launched by launchd with a minimal PATH, so `pnpm` / `node` (nvm, fnm, volta, homebrew) would not
/// resolve for services it starts. The login-shell PATH is resolved once and handed to the services as `PATH`.
actor ShellEnvironment {
    static let shared = ShellEnvironment()
    private var cached: String??

    static func path() async -> String? { await shared.resolve() }

    private func resolve() async -> String? {
        if let c = cached { return c }
        let value = await Task.detached(priority: .utility) { Self.queryLoginShell() }.value
        cached = .some(value)
        return value
    }

    nonisolated static func queryLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lic", "printf '__PIER_PATH__%s__PIER_PATH__' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(4)
        // Read on a side thread so a chatty shell cannot fill the pipe while we wait.
        var data = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async { data = out.fileHandleForReading.readDataToEndOfFile(); reader.leave() }
        while p.isRunning, Date() < deadline { usleep(30_000) }
        if p.isRunning { p.terminate() }
        _ = reader.wait(timeout: .now() + 1)
        let text = String(decoding: data, as: UTF8.self)
        guard let a = text.range(of: "__PIER_PATH__"), let b = text.range(of: "__PIER_PATH__", range: a.upperBound..<text.endIndex) else { return nil }
        let path = String(text[a.upperBound..<b.lowerBound])
        return path.isEmpty ? nil : path
    }
}

/// `LiveStackBackend` that gives spawned services the login-shell PATH.
struct AppStackBackend: StackBackend {
    var path: String?
    private let live = LiveStackBackend()

    init(path: String?) { self.path = path }

    func runningManifests() -> [ManagedManifest] { live.runningManifests() }
    func spawn(command: [String], cwd: String, env: [String: String]?, name: String, stack: String) async throws -> ManagedManifest {
        var e = env ?? [:]
        if let path, e["PATH"] == nil { e["PATH"] = path }
        return try await live.spawn(command: command, cwd: cwd, env: e.isEmpty ? nil : e, name: name, stack: stack)
    }
    func status(_ m: ManagedManifest) async throws -> ManagedManifest { try await live.status(m) }
    func logs(_ m: ManagedManifest, tail: Int) async throws -> String { try await live.logs(m, tail: tail) }
    func stop(_ m: ManagedManifest) async throws { try await live.stop(m) }
    func portHolder(_ port: UInt16) -> StackPortHolder? { live.portHolder(port) }
    func isListening(_ port: UInt16) async -> Bool { await live.isListening(port) }
    func httpHealthy(_ port: UInt16) async -> Bool { await live.httpHealthy(port) }
}

// MARK: - Run… model

enum RunRecents {
    static let key = "pier.runRecents"
    static func load() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func push(_ path: String) {
        UserDefaults.standard.set(AppModel.pushRecent(path, into: load(), limit: 5), forKey: key)
    }
}

@MainActor
final class RunModel: ObservableObject {
    enum Phase: Equatable { case idle, starting, started(id: String, name: String, port: String?), failed(String) }

    @Published var folder: String?
    @Published var command = ""
    @Published var name = ""
    @Published var note: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var recents = RunRecents.load().filter { FileManager.default.fileExists(atPath: $0) }
    private(set) var manifest: ManagedManifest?

    var namePlaceholder: String { folder.map { ManagedDefaults.projectName(cwd: $0) } ?? "project name" }
    var canStart: Bool {
        if case .starting = phase { return false }
        return folder != nil && !command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Picks a folder and detects its default command (package.json dev script with the lockfile's package manager).
    func setFolder(_ path: String) {
        folder = path
        phase = .idle
        manifest = nil
        switch ManagedDefaults.defaultCommand(cwd: path) {
        case .success(let argv):
            command = argv.joined(separator: " ")
            note = "Detected from package.json (\(argv[0]) run dev). Edit it if you want something else."
        case .failure:
            command = ""
            note = "No dev script found in package.json. Type the command to run, e.g. python3 -m http.server 8000"
        }
    }

    func choose(from window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the project folder to run"
        if let f = folder { panel.directoryURL = URL(fileURLWithPath: f) }
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.setFolder(url.path) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    func start() {
        guard canStart, let folder else { return }
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let argv: [String]
        do { argv = try StackShell.command(for: text) } catch { phase = .failed("Command: \(error)"); return }
        guard !argv.isEmpty else { phase = .failed("Command is empty"); return }
        let given = name.trimmingCharacters(in: .whitespaces)
        phase = .starting
        Task {
            let path = await ShellEnvironment.path()
            do {
                let m = try await ManagedLauncher.spawnDetached(command: argv, cwd: folder, env: path.map { ["PATH": $0] },
                                                                name: given.isEmpty ? nil : given)
                manifest = m
                RunRecents.push(folder)
                recents = RunRecents.load()
                phase = .started(id: m.id, name: m.name, port: nil)
                await AppState.shared.refresh(full: true)
            } catch {
                phase = .failed("\(error)")
            }
        }
    }
}

// MARK: - Run… window

struct RunView: View {
    @ObservedObject var model: RunModel
    var close: () -> Void
    var window: () -> NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                MascotView(pose: .walking, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run a project").font(.system(size: 15, weight: .semibold))
                    Text("Starts it under pier, so it shows up under Managed with live logs.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            field("Folder") {
                HStack(spacing: 6) {
                    Text(model.folder.map(Self.tilde) ?? "No folder chosen")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(model.folder == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                        .help(model.folder ?? "Choose a folder")
                    Button("Choose…") { model.choose(from: window()) }
                        .buttonStyle(.pier(.bordered)).help("Choose the project folder")
                    if !model.recents.isEmpty {
                        Menu {
                            ForEach(model.recents, id: \.self) { path in
                                Button(Self.tilde(path)) { model.setFolder(path) }
                            }
                        } label: { Image(systemName: "clock.arrow.circlepath") }
                            .menuStyle(.borderlessButton).fixedSize().help("Recent folders")
                    }
                }
            }

            field("Command") {
                TextField("npm run dev", text: $model.command)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    .onSubmit { model.start() }
            }
            if let n = model.note {
                Text(n).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            field("Name (optional)") {
                TextField(model.namePlaceholder, text: $model.name).textFieldStyle(.roundedBorder).font(.system(size: 12))
            }

            statusLine

            HStack {
                Spacer()
                switch model.phase {
                case .started:
                    if let m = model.manifest {
                        Button("Show logs") { WindowManager.shared.showLogs(for: m, title: m.name) }
                            .buttonStyle(.pier(.bordered)).help("Open the live logs")
                    }
                    Button("Done", action: close).buttonStyle(.pier(.prominent)).keyboardShortcut(.defaultAction).help("Close")
                default:
                    Button("Cancel", action: close).buttonStyle(.pier(.bordered)).keyboardShortcut(.cancelAction).help("Close without starting")
                    Button(model.phase == .starting ? "Starting…" : "Start") { model.start() }
                        .buttonStyle(.pier(.prominent)).disabled(!model.canStart)
                        .help("Start the command in this folder")
                }
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    @ViewBuilder private var statusLine: some View {
        switch model.phase {
        case .started(_, let name, _):
            Label("Started \(name). It appears under Managed in the menu.", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5)).foregroundStyle(.green)
        case .failed(let msg):
            Text(msg).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case .starting:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Starting…").font(.system(size: 11.5)).foregroundStyle(.secondary) }
        case .idle: EmptyView()
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
            content()
        }
    }

    static func tilde(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
