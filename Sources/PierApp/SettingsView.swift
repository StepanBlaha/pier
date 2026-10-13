import SwiftUI
import PierCore

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var hotkeyText = ""
    @State private var hotkeyError: String?
    @State private var loginError: String?
    @State private var loginOn = LoginItem.isEnabled
    @State private var notifyNote: String?

    private let editors = [("vscode", "VS Code"), ("cursor", "Cursor"), ("zed", "Zed"), ("finder", "Finder")]

    var body: some View {
        VStack(spacing: 0) {
            header
            form
        }
        .frame(width: 460, height: 520)
        .onAppear { hotkeyText = state.config.hotkey; loginOn = LoginItem.isEnabled }
    }

    private var header: some View {
        HStack(spacing: 12) {
            MascotView(pose: .saluting, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pier \(AppBundle.version)").font(.system(size: 16, weight: .semibold))
                Text("Your localhost, at a glance.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 2)
    }

    private var form: some View {
        Form {
            Section("Shortcut") {
                HStack {
                    TextField("Global hotkey", text: $hotkeyText, prompt: Text("opt+cmd+p"))
                        .onSubmit(applyHotkey)
                        .frame(maxWidth: 200)
                    Text(HotkeyParser.display(hotkeyText)).foregroundStyle(.secondary)
                    Button("Apply", action: applyHotkey).buttonStyle(.pier(.bordered)).help("Register this shortcut")
                }
                if let e = hotkeyError { Text(e).font(.caption).foregroundStyle(.red) }
                Text("Modifiers: opt, cmd, ctrl, shift. Example: opt+cmd+p").font(.caption).foregroundStyle(.secondary)
            }
            Section("Open project in") {
                Picker("Editor", selection: Binding(get: { state.config.editor }, set: { v in state.updateConfig { $0.editor = v } })) {
                    ForEach(editors, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Section("Notifications") {
                Toggle("Managed service crashed", isOn: Binding(get: { state.config.notifyCrash },
                                                                set: { v in state.updateConfig { $0.notifyCrash = v }; if v { requestAuth() } }))
                Toggle("New service started", isOn: Binding(get: { state.config.notifyNewService },
                                                            set: { v in state.updateConfig { $0.notifyNewService = v }; if v { requestAuth() } }))
                if !isBundled {
                    Text("Notifications only work from Pier.app (not a bare binary).").font(.caption).foregroundStyle(.secondary)
                } else if let n = notifyNote {
                    Text(n).font(.caption).foregroundStyle(.orange)
                }
            }
            Section("General") {
                Toggle("Show system services (ControlCenter, rapportd…)", isOn: Binding(
                    get: { state.config.showNoise },
                    set: { v in state.updateConfig { $0.showNoise = v }; Task { await state.refresh(full: true) } }))
                Toggle("Launch at login", isOn: Binding(get: { loginOn }, set: setLogin)).disabled(!LoginItem.isAvailable)
                if !LoginItem.isAvailable {
                    Text("Available when running from Pier.app (`pier app install`).").font(.caption).foregroundStyle(.secondary)
                } else if LoginItem.needsApproval {
                    Text("Approve Pier in System Settings → General → Login Items.").font(.caption).foregroundStyle(.orange)
                }
                if let e = loginError { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Section("Command line") {
                Text("Install shell completions with `pier completions --install`.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func applyHotkey() {
        let t = hotkeyText.trimmingCharacters(in: .whitespaces)
        switch HotkeyParser.parse(t) {
        case .failure(let e): hotkeyError = e.localizedDescription
        case .success:
            if let err = HotkeyManager.shared.register(t) {
                hotkeyError = err
                _ = HotkeyManager.shared.register(state.config.hotkey)   // restore previous
            } else {
                hotkeyError = nil
                state.updateConfig { $0.hotkey = t }
            }
        }
    }

    private func setLogin(_ on: Bool) {
        do { try LoginItem.set(on); loginError = nil; state.updateConfig { $0.launchAtLogin = on } }
        catch { loginError = error.localizedDescription }
        loginOn = LoginItem.isEnabled
    }

    private func requestAuth() {
        guard isBundled else { return }
        Task { notifyNote = await Notifier.ensureAuthorization() ? nil : "Notifications are blocked. Enable them in System Settings → Notifications." }
    }
}
