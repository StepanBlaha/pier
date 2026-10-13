import Foundation

/// ~/Library/Application Support/pier/config.json — shared by CLI and app. Unknown keys tolerated, missing keys defaulted.
public struct PierConfig: Codable, Equatable, Sendable {
    /// Service.stableKey values, in pin order.
    public var pins: [String] = []
    /// Service.stableKey → custom display name.
    public var renames: [String: String] = [:]
    /// e.g. "opt+cmd+p"
    public var hotkey: String = "opt+cmd+p"
    /// "vscode" | "cursor" | "zed" | "finder"
    public var editor: String = "vscode"
    /// Bundle id of preferred browser; nil = system default.
    public var browser: String? = nil
    public var notifyCrash: Bool = true
    public var notifyNewService: Bool = false
    public var showNoise: Bool = false
    public var launchAtLogin: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = PierConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pins = try c.decodeIfPresent([String].self, forKey: .pins) ?? d.pins
        renames = try c.decodeIfPresent([String: String].self, forKey: .renames) ?? d.renames
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        editor = try c.decodeIfPresent(String.self, forKey: .editor) ?? d.editor
        browser = try c.decodeIfPresent(String.self, forKey: .browser) ?? d.browser
        notifyCrash = try c.decodeIfPresent(Bool.self, forKey: .notifyCrash) ?? d.notifyCrash
        notifyNewService = try c.decodeIfPresent(Bool.self, forKey: .notifyNewService) ?? d.notifyNewService
        showNoise = try c.decodeIfPresent(Bool.self, forKey: .showNoise) ?? d.showNoise
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
    }
}

public enum ConfigStore {
    /// Tests (and embedders) can point the store at another file. Takes precedence over $PIER_CONFIG.
    nonisolated(unsafe) public static var overrideURL: URL?

    /// $PIER_CONFIG (a file path) overrides the default location; mostly for tests and sandboxing.
    public static var url: URL {
        if let o = overrideURL { return o }
        if let p = ProcessInfo.processInfo.environment["PIER_CONFIG"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return ManagedPaths.root.appendingPathComponent("config.json")
    }

    public static func load() -> PierConfig {
        guard let data = try? Data(contentsOf: url) else { return PierConfig() }
        return (try? JSONDecoder().decode(PierConfig.self, from: data)) ?? PierConfig()
    }

    /// Like `load`, but a file that exists and cannot be parsed throws instead of silently yielding defaults,
    /// so a command that is about to write never clobbers a hand-edited (broken) file.
    public static func loadStrict() throws -> PierConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return PierConfig() }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return PierConfig() }
        do { return try JSONDecoder().decode(PierConfig.self, from: data) }
        catch { throw ConfigError.invalidFile(url.path) }
    }

    public static func save(_ config: PierConfig) throws {
        let target = url
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: target, options: .atomic)
    }
}
