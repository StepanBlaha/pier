import Foundation

/// What the tools need from the outside world. Injectable so tests can run on fake services.
public struct MCPContext: Sendable {
    /// Scan + identify (+ probe). `includeNoise` keeps system noise in the result.
    public var snapshot: @Sendable (_ includeNoise: Bool, _ probe: Bool) async -> [Service]
    public var managed: @Sendable () -> [ManagedManifest]

    public init(snapshot: @escaping @Sendable (Bool, Bool) async -> [Service],
                managed: @escaping @Sendable () -> [ManagedManifest]) {
        self.snapshot = snapshot
        self.managed = managed
    }

    public static let live = MCPContext(
        snapshot: { includeNoise, probe in
            await ServiceCatalog.snapshot(.init(includeNoise: includeNoise, probe: probe))
        },
        managed: { ManagedRegistry.all() }
    )
}

/// Outcome of a tool call, rendered as an MCP `CallToolResult`.
public struct MCPToolResult: Sendable {
    public var text: String
    public var structured: JSON?
    public var isError: Bool

    public init(text: String, structured: JSON? = nil, isError: Bool = false) {
        self.text = text; self.structured = structured; self.isError = isError
    }

    /// Success with a JSON payload: pretty JSON as text, plus structuredContent (arrays get wrapped under `wrapKey`).
    public static func json(_ value: JSON, wrapKey: String = "result") -> MCPToolResult {
        let structured: JSON = value.objectValue != nil ? value : .object([wrapKey: value])
        return MCPToolResult(text: value.pretty, structured: structured)
    }

    public static func error(_ message: String) -> MCPToolResult { MCPToolResult(text: message, isError: true) }

    var rpcValue: JSON {
        var o: [String: JSON] = ["content": [["type": "text", "text": .string(text)]]]
        if let s = structured { o["structuredContent"] = s }
        if isError { o["isError"] = true }
        return .object(o)
    }
}

/// Bad tool arguments (reported as a tool error so the model can correct itself).
struct MCPArgError: Error { let message: String }

/// Lenient typed access to a tool's `arguments` object.
struct MCPArgs {
    let values: [String: JSON]

    init(_ json: JSON?) { values = json?.objectValue ?? [:] }

    private func raw(_ key: String) -> JSON? {
        guard let v = values[key], !v.isNull else { return nil }
        return v
    }

    func string(_ key: String) throws -> String? {
        guard let v = raw(key) else { return nil }
        switch v {
        case .string(let s): return s
        case .int(let i): return String(i)   // `target: 3000` instead of "3000"
        default: throw MCPArgError(message: "'\(key)' must be a string")
        }
    }

    func requiredString(_ key: String) throws -> String {
        guard let s = try string(key), !s.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MCPArgError(message: "'\(key)' is required")
        }
        return s
    }

    func int(_ key: String) throws -> Int? {
        guard let v = raw(key) else { return nil }
        if let i = v.intValue { return i }
        if case .string(let s) = v, let i = Int(s.trimmingCharacters(in: .whitespaces)) { return i }
        throw MCPArgError(message: "'\(key)' must be an integer")
    }

    func requiredInt(_ key: String) throws -> Int {
        guard let i = try int(key) else { throw MCPArgError(message: "'\(key)' is required") }
        return i
    }

    func double(_ key: String) throws -> Double? {
        guard let v = raw(key) else { return nil }
        if let d = v.doubleValue { return d }
        if case .string(let s) = v, let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
        throw MCPArgError(message: "'\(key)' must be a number")
    }

    func bool(_ key: String) throws -> Bool? {
        guard let v = raw(key) else { return nil }
        if let b = v.boolValue { return b }
        if case .string(let s) = v {
            switch s.lowercased() {
            case "true": return true
            case "false": return false
            default: break
            }
        }
        throw MCPArgError(message: "'\(key)' must be a boolean")
    }

    func port(_ key: String) throws -> UInt16 {
        let p = try requiredInt(key)
        guard (1...65535).contains(p) else { throw MCPArgError(message: "'\(key)' must be between 1 and 65535") }
        return UInt16(p)
    }
}

/// Target resolution shared by every tool that takes `target` (port or fuzzy name). Mirrors the CLI's `Resolver`.
public enum MCPTarget {
    public enum Resolution: Sendable {
        case found([Service])
        case ambiguous([Service])
        case none
    }

    /// Prefers real services; falls back to system noise only if nothing else matches.
    public static func resolve(_ target: String, in all: [Service]) -> Resolution {
        var result = Matcher.resolve(target, in: all.filter { !$0.isNoise })
        if case .none = result { result = Matcher.resolve(target, in: all) }
        switch result {
        case .found(let s): return .found(s)
        case .ambiguous(let s): return .ambiguous(s)
        case .none: return .none
        }
    }

    public static func describe(_ s: Service) -> String {
        let detail = [s.projectName, s.framework?.name ?? s.infraName].compactMap { $0 }.joined(separator: ", ")
        return ":\(s.port) \(s.displayName)\(detail.isEmpty ? "" : " (\(detail))") pid \(s.process.pid)"
    }

    public static func ambiguousError(_ target: String, _ candidates: [Service]) -> MCPToolResult {
        let lines = candidates.map { "  - " + describe($0) }.joined(separator: "\n")
        return .error("'\(target)' matches \(candidates.count) services; retry with a port number to be specific:\n\(lines)")
    }

    public static func notFoundError(_ target: String) -> MCPToolResult {
        .error("no service matches '\(target)'. Call list_services to see what is running.")
    }

    /// Scan and resolve; `.failure` already carries the error result.
    static func services(for target: String, ctx: MCPContext, probe: Bool = true) async -> Result<[Service], MCPFailure> {
        let all = await ctx.snapshot(true, probe)
        switch resolve(target, in: all) {
        case .found(let s): return .success(s)
        case .ambiguous(let c): return .failure(MCPFailure(result: ambiguousError(target, c)))
        case .none: return .failure(MCPFailure(result: notFoundError(target)))
        }
    }
}

struct MCPFailure: Error { let result: MCPToolResult }

enum MCPManifestMatch {
    case one(ManagedManifest)
    case many([ManagedManifest])
    case none
}

enum MCPText {
    /// Removes ANSI escape sequences (CSI, OSC, single-char escapes).
    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        let patterns = [
            "\u{1B}\\[[0-?]*[ -/]*[@-~]",                       // CSI
            "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)",   // OSC ... BEL / ST
            "\u{1B}[@-Z\\\\-_]",                                // two-char escapes
        ]
        var out = s
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        return out
    }

    static func lastLines(_ s: String, _ n: Int) -> String {
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.suffix(n).joined(separator: "\n")
    }
}
