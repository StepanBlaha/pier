import Foundation

public enum ConfigError: Error, LocalizedError, Equatable {
    case unknownKey(String)
    case invalidValue(key: String, reason: String)
    case invalidFile(String)

    public var errorDescription: String? {
        switch self {
        case .unknownKey(let k):
            "unknown config key '\(k)' (keys: \(ConfigKey.allCases.map(\.rawValue).joined(separator: ", ")))"
        case .invalidValue(let key, let reason): "invalid value for \(key): \(reason)"
        case .invalidFile(let path): "\(path) is not valid JSON; fix it with `pier config edit` (or delete it) first"
        }
    }
}

/// The scalar settings of `PierConfig` that `pier config` can read and write (pins / renames have their own commands).
public enum ConfigKey: String, CaseIterable, Sendable {
    case hotkey, editor, browser, notifyCrash, notifyNewService, showNoise, launchAtLogin

    /// Case-insensitive; `-`, `_` and `.` are ignored so `notify-crash` and `notify_crash` work.
    public static func parse(_ text: String) -> ConfigKey? {
        let n = text.lowercased().filter { $0 != "-" && $0 != "_" && $0 != "." }
        return allCases.first { $0.rawValue.lowercased() == n }
    }

    public var isBool: Bool {
        switch self {
        case .notifyCrash, .notifyNewService, .showNoise, .launchAtLogin: true
        case .hotkey, .editor, .browser: false
        }
    }

    public var summary: String {
        switch self {
        case .hotkey: "global shortcut that opens the menu bar app (e.g. opt+cmd+p)"
        case .editor: "editor for \"open project\": vscode, cursor, zed, windsurf, finder, an app name or a bundle id"
        case .browser: "browser bundle id (or chrome, arc, brave, edge, safari, firefox); \"default\" = system default"
        case .notifyCrash: "notify when a managed service crashes"
        case .notifyNewService: "notify when a new service starts listening"
        case .showNoise: "show system / app-helper services in the menu bar app"
        case .launchAtLogin: "start the menu bar app at login (only takes effect through the app)"
        }
    }

    /// Short value hint for help and completion.
    public var valueHint: String {
        switch self {
        case .hotkey: "opt+cmd+p"
        case .editor: "vscode|cursor|zed|windsurf|finder|<app>"
        case .browser: "default|<bundle id>"
        case .notifyCrash, .notifyNewService, .showNoise, .launchAtLogin: "true|false"
        }
    }

    /// Values worth offering in shell completion for `config set <key> <TAB>`.
    public var completionValues: [String] {
        switch self {
        case .hotkey: []
        case .editor: ConfigEditing.editorNames
        case .browser: ["default"] + ConfigEditing.browserAliases.keys.sorted()
        case .notifyCrash, .notifyNewService, .showNoise, .launchAtLogin: ["true", "false"]
        }
    }
}

/// JSON-friendly value of a config key.
public enum ConfigValue: Encodable, Equatable, Sendable {
    case string(String), bool(Bool), null

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }
}

/// Pure get / set / unset logic for `pier config`, plus pin / rename helpers shared by the CLI (and tests).
public enum ConfigEditing {
    public static let editorNames = ["vscode", "cursor", "zed", "windsurf", "finder"]
    static let editorAliases = ["code": "vscode", "vs code": "vscode", "visual studio code": "vscode"]

    public static let browserAliases: [String: String] = [
        "chrome": "com.google.Chrome", "arc": "company.thebrowser.Browser", "brave": "com.brave.Browser",
        "edge": "com.microsoft.edgemac", "safari": "com.apple.Safari", "firefox": "org.mozilla.firefox",
    ]

    public static let maxNameLength = 80

    // MARK: Read

    /// Text form, as `pier config get` prints it.
    public static func value(_ key: ConfigKey, in c: PierConfig) -> String {
        switch key {
        case .hotkey: c.hotkey
        case .editor: c.editor
        case .browser: c.browser ?? "default"
        case .notifyCrash: String(c.notifyCrash)
        case .notifyNewService: String(c.notifyNewService)
        case .showNoise: String(c.showNoise)
        case .launchAtLogin: String(c.launchAtLogin)
        }
    }

    public static func jsonValue(_ key: ConfigKey, in c: PierConfig) -> ConfigValue {
        switch key {
        case .hotkey: .string(c.hotkey)
        case .editor: .string(c.editor)
        case .browser: c.browser.map(ConfigValue.string) ?? .null
        case .notifyCrash: .bool(c.notifyCrash)
        case .notifyNewService: .bool(c.notifyNewService)
        case .showNoise: .bool(c.showNoise)
        case .launchAtLogin: .bool(c.launchAtLogin)
        }
    }

    public static func isDefault(_ key: ConfigKey, in c: PierConfig) -> Bool {
        value(key, in: c) == value(key, in: PierConfig())
    }

    // MARK: Write

    public static func parseBool(_ text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "on", "yes", "1", "y": true
        case "false", "off", "no", "0", "n": false
        default: nil
        }
    }

    /// Validates `raw` for `key` and stores the normalized value. Throws `ConfigError.invalidValue`.
    public static func set(_ key: ConfigKey, to raw: String, in c: inout PierConfig) throws {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func bad(_ why: String) -> ConfigError { .invalidValue(key: key.rawValue, reason: why) }
        switch key {
        case .hotkey:
            if case .failure(let e) = HotkeyParser.parse(text) { throw bad(e.errorDescription ?? "not a shortcut") }
            // Canonical spelling: lowercase, "+" separated (spaces allowed on input).
            c.hotkey = text.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " }).joined(separator: "+")
        case .editor:
            guard !text.isEmpty else { throw bad("expected vscode, cursor, zed, windsurf, finder, an app name or a bundle id") }
            guard text.count <= 200, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw bad("not a usable app name")
            }
            let lower = text.lowercased()
            let canonical = editorAliases[lower] ?? lower
            c.editor = editorNames.contains(canonical) ? canonical : text
        case .browser:
            let lower = text.lowercased()
            if lower == "default" || lower == "system" || lower.isEmpty { c.browser = nil }
            else if let id = browserAliases[lower] { c.browser = id }
            else if isBundleID(text) { c.browser = text }
            else { throw bad("expected a bundle id like com.google.Chrome, a name (\(browserAliases.keys.sorted().joined(separator: ", "))) or \"default\"") }
        case .notifyCrash, .notifyNewService, .showNoise, .launchAtLogin:
            guard let b = parseBool(text) else { throw bad("expected true/false (also on/off, yes/no)") }
            switch key {
            case .notifyCrash: c.notifyCrash = b
            case .notifyNewService: c.notifyNewService = b
            case .showNoise: c.showNoise = b
            default: c.launchAtLogin = b
            }
        }
    }

    /// Resets one key to its default.
    public static func unset(_ key: ConfigKey, in c: inout PierConfig) {
        let d = PierConfig()
        switch key {
        case .hotkey: c.hotkey = d.hotkey
        case .editor: c.editor = d.editor
        case .browser: c.browser = d.browser
        case .notifyCrash: c.notifyCrash = d.notifyCrash
        case .notifyNewService: c.notifyNewService = d.notifyNewService
        case .showNoise: c.showNoise = d.showNoise
        case .launchAtLogin: c.launchAtLogin = d.launchAtLogin
        }
    }

    static func isBundleID(_ s: String) -> Bool {
        guard s.contains("."), !s.hasPrefix("."), !s.hasSuffix(".") else { return false }
        return s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2E || $0 == 0x2D || $0 == 0x5F }
    }

    // MARK: Pins & renames

    /// Adds the service's stable key to the pins (end of the list). false = it was already pinned.
    @discardableResult
    public static func pin(_ s: Service, in c: inout PierConfig) -> Bool {
        guard !c.pins.contains(s.stableKey) else { return false }
        c.pins.append(s.stableKey)
        return true
    }

    /// false = it was not pinned.
    @discardableResult
    public static func unpin(key: String, in c: inout PierConfig) -> Bool {
        guard let i = c.pins.firstIndex(of: key) else { return false }
        c.pins.remove(at: i)
        return true
    }

    /// Pin keys matching free text (exact key, last path component, or substring), for unpinning services that are not running.
    public static func pinKeys(matching target: String, in c: PierConfig) -> [String] {
        let t = target.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return [] }
        if let exact = c.pins.first(where: { $0.lowercased() == t }) { return [exact] }
        let tail = c.pins.filter { key in
            let body = key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? key
            return (body as NSString).lastPathComponent.lowercased() == t || body.lowercased() == t
        }
        if !tail.isEmpty { return tail }
        return c.pins.filter { $0.lowercased().contains(t) }
    }

    public enum RenameOutcome: Equatable, Sendable { case set(String), cleared }

    /// Validates and stores a custom display name. An empty name, or one equal to the automatic name, clears it.
    public static func rename(_ s: Service, to raw: String, in c: inout PierConfig) throws -> RenameOutcome {
        let name = Sanitize.line(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count <= maxNameLength else {
            throw ConfigError.invalidValue(key: "name", reason: "at most \(maxNameLength) characters")
        }
        if name.isEmpty || name == s.displayName {
            c.renames.removeValue(forKey: s.stableKey)
            return .cleared
        }
        c.renames[s.stableKey] = name
        return .set(name)
    }

    /// true = a rename existed.
    @discardableResult
    public static func resetRename(_ s: Service, in c: inout PierConfig) -> Bool {
        c.renames.removeValue(forKey: s.stableKey) != nil
    }
}

/// Display helpers for list output (CLI `ls`, `info`).
public enum ConfigDisplay {
    /// Custom name if set, else the automatic one.
    public static func name(_ s: Service, config: PierConfig) -> String { AppModel.displayName(s, config: config) }

    public static func customName(_ s: Service, config: PierConfig) -> String? {
        guard let r = config.renames[s.stableKey]?.trimmingCharacters(in: .whitespaces), !r.isEmpty else { return nil }
        return r
    }

    public static func isPinned(_ s: Service, config: PierConfig) -> Bool { config.pins.contains(s.stableKey) }

    /// Pinned services first (in pin order), then the rest; both groups by port (then pid).
    public static func ordered(_ services: [Service], config: PierConfig) -> [Service] {
        let order = Dictionary(config.pins.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        func byPort(_ a: Service, _ b: Service) -> Bool { (a.port, a.process.pid) < (b.port, b.process.pid) }
        let pinned = services.filter { order[$0.stableKey] != nil }.sorted { a, b in
            let (ia, ib) = (order[a.stableKey]!, order[b.stableKey]!)
            return ia != ib ? ia < ib : byPort(a, b)
        }
        let rest = services.filter { order[$0.stableKey] == nil }.sorted(by: byPort)
        return pinned + rest
    }
}
