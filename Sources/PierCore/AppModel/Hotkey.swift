import Foundation

/// Parses config hotkey strings like "opt+cmd+p" into Carbon-compatible (keyCode, modifiers).
public enum HotkeyParser {
    public struct Spec: Equatable, Sendable {
        public var keyCode: UInt32
        /// Carbon modifier mask (cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000).
        public var modifiers: UInt32
    }

    public static let cmd: UInt32 = 0x100, shift: UInt32 = 0x200, option: UInt32 = 0x800, control: UInt32 = 0x1000

    /// ANSI-layout virtual key codes.
    static let keys: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "esc": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
        "f10": 109, "f11": 103, "f12": 111,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    public enum ParseError: Error, Equatable, LocalizedError {
        case empty, noKey, multipleKeys, unknownKey(String), noModifier
        public var errorDescription: String? {
            switch self {
            case .empty: "Enter a shortcut like opt+cmd+p"
            case .noKey: "Missing key (e.g. opt+cmd+p)"
            case .multipleKeys: "Only one non-modifier key allowed"
            case .unknownKey(let k): "Unknown key \"\(k)\""
            case .noModifier: "Add at least one modifier (opt, cmd, ctrl, shift)"
            }
        }
    }

    public static func parse(_ text: String) -> Result<Spec, ParseError> {
        let parts = text.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " }).map(String.init)
        guard !parts.isEmpty else { return .failure(.empty) }
        var mods: UInt32 = 0
        var key: String?
        for p in parts {
            switch p {
            case "opt", "alt", "option", "⌥": mods |= option
            case "cmd", "command", "⌘": mods |= cmd
            case "ctrl", "control", "⌃": mods |= control
            case "shift", "⇧": mods |= shift
            default:
                if key != nil { return .failure(.multipleKeys) }
                key = p
            }
        }
        guard let k = key else { return .failure(.noKey) }
        guard let code = keys[k] else { return .failure(.unknownKey(k)) }
        if mods == 0, !k.hasPrefix("f") || k.count < 2 { return .failure(.noModifier) }
        return .success(Spec(keyCode: code, modifiers: mods))
    }

    /// Human glyph form, e.g. "opt+cmd+p" → "⌥⌘P".
    public static func display(_ text: String) -> String {
        guard case .success(let s) = parse(text) else { return text }
        var out = ""
        if s.modifiers & control != 0 { out += "⌃" }
        if s.modifiers & option != 0 { out += "⌥" }
        if s.modifiers & shift != 0 { out += "⇧" }
        if s.modifiers & cmd != 0 { out += "⌘" }
        let name = text.lowercased().split(whereSeparator: { $0 == "+" || $0 == " " }).last.map(String.init) ?? ""
        return out + name.uppercased()
    }
}
