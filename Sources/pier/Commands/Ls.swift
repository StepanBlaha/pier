import ArgumentParser
import Foundation
import PierCore

struct Ls: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List services listening on localhost.")

    @Flag(help: "Output JSON.") var json = false
    @Flag(name: .shortAndLong, help: "Include system noise (AirPlay, rapportd, ...).") var all = false
    @Flag(name: .customLong("no-probe"), help: "Skip HTTP probing (faster; no titles or health).") var noProbe = false

    func run() async throws {
        let config = ConfigStore.load()
        let services = ConfigDisplay.ordered(await ServiceCatalog.snapshot(.init(includeNoise: all, probe: !noProbe)), config: config)
        if json {
            Term.out(try Output.json(services.map { ServiceEntry($0, config: config) }))
            return
        }
        guard !services.isEmpty else {
            if !MascotUI.show(.sleeping, text: ["No services listening.", MascotUI.hint("start one with `pier run`")]) {
                Term.out("No services listening.")
            }
            return
        }
        Term.out(Output.table(services, config: config).joined(separator: "\n"))
    }
}

/// A service plus the user's pin / rename state, for JSON (Service's own Codable stays untouched).
/// `displayName` stays the automatic name; `customName` is the user's override (null when none).
struct ServiceEntry: Encodable {
    let service: Service
    let pinned: Bool
    let customName: String?

    init(_ service: Service, config: PierConfig) {
        self.service = service
        pinned = ConfigDisplay.isPinned(service, config: config)
        customName = ConfigDisplay.customName(service, config: config)
    }

    private enum Extra: String, CodingKey { case pinned, customName }

    func encode(to encoder: Encoder) throws {
        try service.encode(to: encoder)
        var c = encoder.container(keyedBy: Extra.self)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(customName, forKey: .customName)
    }
}

enum Output {
    static func json<T: Encodable>(_ value: T) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return String(decoding: try enc.encode(value), as: UTF8.self)
    }

    static func healthText(_ s: Service, glyphs: Glyphs = Term.glyphs) -> String {
        let b = glyphs.bullet
        switch s.probe?.health ?? .unknown {
        case .ok: return b + " ok"
        case .error: return b + " error"
        case .timeout: return b + " timeout"
        case .unknown: return b
        }
    }

    /// nil = no color (the word next to the dot already says it).
    static func healthStyle(_ h: Health) -> Term.Style? {
        switch h {
        case .ok: .green
        case .error: .red
        case .timeout: .yellow
        case .unknown: nil
        }
    }

    /// Paints just the leading dot of a health cell ("* ok" / "● ok").
    static func paintHealth(_ text: String, _ h: Health, glyphs: Glyphs = Term.glyphs, enabled: Bool = Term.color) -> String {
        guard enabled, let style = healthStyle(h), text.hasPrefix(glyphs.bullet) else { return text }
        return Term.paint(glyphs.bullet, style, enabled: true) + String(text.dropFirst(glyphs.bullet.count))
    }

    static func table(_ services: [Service], width: Int = Term.tableWidth, color: Bool = Term.color,
                      glyphs: Glyphs = Term.glyphs, asciiOnly: Bool = Term.asciiOnly,
                      config: PierConfig = PierConfig()) -> [String] {
        let star = glyphs == .unicode ? "★ " : "* "
        let rows = services.map { s in
            [String(s.port), (ConfigDisplay.isPinned(s, config: config) ? star : "") + ConfigDisplay.name(s, config: config), s.projectName ?? "-", s.framework?.name ?? s.infraName ?? "-",
             healthText(s, glyphs: glyphs), Format.bindLabel(s.bindScope), Format.uptime(s.process) ?? "-", String(s.process.pid)]
        }
        var table = TextTable(headers: ["PORT", "NAME", "PROJECT", "FRAMEWORK/INFRA", "HEALTH", "BIND", "UPTIME", "PID"],
                              rows: rows, shrinkable: [1, 2, 3], dropOrder: [7, 6, 3, 2, 5])
        table.ellipsis = glyphs.ellipsis
        table.asciiOnly = asciiOnly
        return table.render(maxWidth: width) { row, col, text in
            guard color else { return text }
            guard let row else { return Term.paint(text, .bold) }
            switch col {
            case 0: return Term.paint(text, .bold)
            case 4: return paintHealth(text, services[row].probe?.health ?? .unknown, glyphs: glyphs, enabled: true)
            case 5 where services[row].bindScope != .loopback: return Term.paint(text, .yellow)
            default: return text
            }
        }
    }
}
