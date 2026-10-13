import Foundation

/// A decoded key press.
public enum Key: Equatable, Sendable {
    case char(Character)
    case up, down, left, right
    case home, end, pageUp, pageDown
    case enter, escape, backspace, tab, delete
    /// Ctrl + letter (lowercase), e.g. `.ctrl("c")`.
    case ctrl(Character)
    /// Text delivered inside a bracketed paste (ESC [ 200~ ... ESC [ 201~). Never interpreted as commands.
    case paste(String)
    case unknown
}

/// Incremental decoder from raw terminal bytes to `Key`s.
///
/// A lone ESC is ambiguous (the Escape key vs. the start of `ESC [ A`), so it stays buffered until
/// either more bytes arrive or the caller decides enough time has passed and calls `flush()`.
public struct KeyDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var inPaste = false
    private static let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]     // ESC [ 200 ~
    private static let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]       // ESC [ 201 ~
    private static let maxPaste = 1 << 16

    public init() {}

    /// Drop everything buffered (used when a sequence never completes, e.g. a paste with no end marker).
    public mutating func reset() { buffer.removeAll(); inPaste = false }

    /// True when bytes are held back waiting for the rest of a sequence (caller should poll with a short timeout, then `flush()`).
    public var hasPending: Bool { !buffer.isEmpty }
    /// Inside a bracketed paste: waiting is expected, so callers should not flush on a short timeout.
    public var isPasting: Bool { inPaste }

    public mutating func feed(_ bytes: [UInt8]) -> [Key] {
        buffer += bytes
        var keys: [Key] = []
        while !buffer.isEmpty {
            if inPaste {
                if let r = Self.find(Self.pasteEnd, in: buffer) {
                    keys.append(.paste(String(decoding: buffer[0..<r], as: UTF8.self)))
                    buffer.removeFirst(r + Self.pasteEnd.count)
                    inPaste = false
                    continue
                }
                if buffer.count > Self.maxPaste {      // runaway: hand over what we have and keep swallowing
                    keys.append(.paste(String(decoding: buffer, as: UTF8.self)))
                    buffer.removeAll()
                }
                break
            }
            if buffer.starts(with: Self.pasteStart) {
                buffer.removeFirst(Self.pasteStart.count)
                inPaste = true
                continue
            }
            if buffer.count < Self.pasteStart.count, Self.pasteStart.starts(with: buffer) { break }   // maybe a paste start
            guard let (key, used) = decodeOne() else { break }
            buffer.removeFirst(used)
            if let key { keys.append(key) }
        }
        return keys
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && hay[i..<(i + needle.count)].elementsEqual(needle) { return i }
        return nil
    }

    /// Resolve whatever is pending as-is (a lone ESC becomes `.escape`; partial sequences are dropped).
    public mutating func flush() -> [Key] {
        if inPaste { return [] }
        defer { buffer.removeAll() }
        guard let first = buffer.first else { return [] }
        return first == 0x1B ? [.escape] : []
    }

    /// nil = need more bytes. `(nil, n)` = consume n bytes, emit nothing.
    private func decodeOne() -> (Key?, Int)? {
        guard let b = buffer.first else { return nil }
        switch b {
        case 0x1B: return decodeEscape()
        case 0x0D, 0x0A: return (.enter, 1)
        case 0x09: return (.tab, 1)
        case 0x7F, 0x08: return (.backspace, 1)
        case 0x01...0x1A: return (.ctrl(Character(UnicodeScalar(b + 0x60))), 1)
        case 0x00, 0x1C...0x1F: return (.unknown, 1)
        case 0x20...0x7E: return (.char(Character(UnicodeScalar(b))), 1)
        default: return decodeUTF8()
        }
    }

    private func decodeUTF8() -> (Key?, Int)? {
        let b = buffer[0]
        let need: Int
        switch b {
        case 0xC0...0xDF: need = 2
        case 0xE0...0xEF: need = 3
        case 0xF0...0xF7: need = 4
        default: return (.unknown, 1)
        }
        if buffer.count < need { return nil }
        if let s = String(bytes: buffer[0..<need], encoding: .utf8), let c = s.first { return (.char(c), need) }
        return (.unknown, 1)
    }

    private func decodeEscape() -> (Key?, Int)? {
        guard buffer.count >= 2 else { return nil }               // lone ESC: wait
        let second = buffer[1]
        switch second {
        case UInt8(ascii: "["):
            // CSI: ESC [ params... final(0x40-0x7E)
            var i = 2
            while i < buffer.count, (0x20...0x3F).contains(buffer[i]) { i += 1 }      // parameters + intermediates
            guard i < buffer.count else { return nil }
            guard (0x40...0x7E).contains(buffer[i]) else { return (nil, i) }          // malformed: drop what we saw
            let params = String(decoding: buffer[2..<i], as: UTF8.self)
            return (csiKey(params: params, final: buffer[i]), i + 1)
        case UInt8(ascii: "O"):
            // SS3: ESC O A (application cursor keys)
            guard buffer.count >= 3 else { return nil }
            return (csiKey(params: "", final: buffer[2]), 3)
        case 0x1B:
            return (.escape, 1)                                    // ESC ESC: first one is a bare Escape
        default:
            // Alt+key: ignore the modifier, treat as the plain key.
            return (nil, 2)
        }
    }

    private func csiKey(params: String, final: UInt8) -> Key {
        switch final {
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        case UInt8(ascii: "C"): return .right
        case UInt8(ascii: "D"): return .left
        case UInt8(ascii: "H"): return .home
        case UInt8(ascii: "F"): return .end
        case UInt8(ascii: "~"):
            let parts = params.split(separator: ";")
            if parts.first == "27", parts.count == 3, let code = UInt32(parts[2]), let m = Int(parts[1]) {   // xterm modifyOtherKeys
                return Self.key(code: code, shift: (m - 1) & 1 != 0, ctrl: (m - 1) & 4 != 0)
            }
            switch parts.first.map(String.init) {
            case "1", "7": return .home
            case "4", "8": return .end
            case "3": return .delete
            case "5": return .pageUp
            case "6": return .pageDown
            default: return .unknown
            }
        case UInt8(ascii: "Z"): return .tab                                  // Shift-Tab
        case UInt8(ascii: "u"): return kittyKey(params)                      // CSI u (kitty / fixterms)
        default: return .unknown
        }
    }

    /// `CSI code ; modifiers u` (also the first sub-parameter form `code:alt`). Modifiers are 1 + bitmask.
    private func kittyKey(_ params: String) -> Key {
        let parts = params.split(separator: ";", omittingEmptySubsequences: false)
        guard let codeText = parts.first?.split(separator: ":").first, let code = UInt32(codeText) else { return .unknown }
        let mods = parts.count > 1 ? (parts[1].split(separator: ":").first.flatMap { Int($0) } ?? 1) - 1 : 0
        return Self.key(code: code, shift: mods & 1 != 0, ctrl: mods & 4 != 0)
    }

    static func key(code: UInt32, shift: Bool, ctrl: Bool) -> Key {
        switch code {
        case 13: return .enter
        case 27: return .escape
        case 9: return .tab
        case 127, 8: return .backspace
        default:
            guard let sc = Unicode.Scalar(code), code >= 0x20 else { return .unknown }
            let ch = Character(sc)
            if ctrl, let a = ch.asciiValue, (0x61...0x7A).contains(a) { return .ctrl(ch) }
            if shift, ch.isLetter { return .char(Character(ch.uppercased())) }
            return ctrl ? .unknown : .char(ch)
        }
    }
}
