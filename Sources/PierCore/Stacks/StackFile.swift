import Foundation

/// Key of a service inside a `pier.yml` `services:` map.
public typealias ServiceName = String

/// How `pier up` decides a service is ready for its dependents.
public enum StackReadyCheck: Equatable, Sendable, Codable {
    /// The service answers HTTP on its `port` (any 2xx-4xx response).
    case http
    /// Something accepts TCP connections on `port`.
    case port
    /// Started == ready.
    case none
    /// The managed log output matches this regular expression.
    case log(String)

    public var label: String {
        switch self {
        case .http: return "http"
        case .port: return "port"
        case .none: return "none"
        case .log(let r): return "log:\(r)"
        }
    }
}

public struct StackService: Equatable, Sendable {
    public var name: ServiceName
    /// argv to spawn. For strings with shell operators this is `["/bin/sh", "-c", run]`.
    public var command: [String]
    /// What the user wrote (string as-is, array joined), for display.
    public var display: String
    /// Absolute working directory.
    public var cwd: String
    public var port: UInt16?
    public var env: [String: String]
    public var dependsOn: [ServiceName]
    public var ready: StackReadyCheck
    public var readyTimeout: TimeInterval
    /// 1-based line of the service key in the YAML source (for messages).
    public var line: Int?

    public init(name: ServiceName, command: [String], display: String? = nil, cwd: String, port: UInt16? = nil,
                env: [String: String] = [:], dependsOn: [ServiceName] = [], ready: StackReadyCheck? = nil,
                readyTimeout: TimeInterval = 60, line: Int? = nil) {
        self.name = name; self.command = command
        self.display = display ?? command.joined(separator: " ")
        self.cwd = cwd; self.port = port; self.env = env; self.dependsOn = dependsOn
        self.ready = ready ?? (port != nil ? .port : .none)
        self.readyTimeout = readyTimeout; self.line = line
    }
}

public struct StackFile: Equatable, Sendable {
    public var name: String
    /// Absolute path of the pier.yml (empty for in-memory stacks).
    public var path: String
    /// Services in declaration order.
    public var services: [StackService]
    /// Non-fatal findings (unknown keys, ...), already formatted with file:line.
    public var warnings: [String]

    public init(name: String, path: String = "", services: [StackService], warnings: [String] = []) {
        self.name = name; self.path = path; self.services = services; self.warnings = warnings
    }

    public var directory: String { path.isEmpty ? "" : (path as NSString).deletingLastPathComponent }
    public func service(_ name: ServiceName) -> StackService? { services.first { $0.name == name } }
    public var serviceNames: [ServiceName] { services.map(\.name) }
}

/// One validation finding. `keyPath` is e.g. "services.web.port".
public struct StackIssue: Equatable, Sendable, CustomStringConvertible {
    public var file: String
    public var line: Int?
    public var keyPath: String
    public var message: String
    public init(file: String, line: Int? = nil, keyPath: String, message: String) {
        self.file = file; self.line = line; self.keyPath = keyPath; self.message = message
    }
    public var description: String {
        var loc = file
        if let line { loc += ":\(line)" }
        return keyPath.isEmpty ? "\(loc): \(message)" : "\(loc): \(keyPath): \(message)"
    }
}

public enum StackError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case unreadable(String)
    case syntax(String)
    case invalid([StackIssue])
    case unknownService(String, known: [String])
    case cycle([String])

    public var description: String {
        switch self {
        case .notFound(let s): return s
        case .unreadable(let s): return s
        case .syntax(let s): return s
        case .invalid(let issues): return issues.map(\.description).joined(separator: "\n")
        case .unknownService(let n, let known):
            return "unknown service '\(n)'" + (known.isEmpty ? "" : " (known: \(known.joined(separator: ", ")))")
        case .cycle(let path): return "dependency cycle: \(path.joined(separator: " -> "))"
        }
    }
}

// MARK: - run string handling

public enum StackShell {
    /// Result of analysing a `run:` string.
    public struct Parsed: Equatable, Sendable {
        public var argv: [String]
        public var needsShell: Bool
    }

    /// Splits like a POSIX shell (quotes, backslashes) and detects whether `/bin/sh -c` is required
    /// (unquoted `& | ; < > ( ) \``, `$` anywhere outside single quotes, leading `VAR=value` assignments).
    /// Throws a message on unterminated quotes.
    public static func parse(_ s: String) throws -> Parsed {
        var words: [String] = []
        var cur = ""
        var inWord = false
        var needsShell = false
        enum Q { case none, single, double }
        var q = Q.none
        let chars = Array(s)
        var i = 0
        func flush() { if inWord { words.append(cur); cur = ""; inWord = false } }
        while i < chars.count {
            let c = chars[i]
            switch q {
            case .single:
                if c == "'" { q = .none } else { cur.append(c) }
            case .double:
                if c == "\"" { q = .none }
                else if c == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) { i += 1; cur.append(chars[i]) }
                else {
                    if c == "$" || c == "`" { needsShell = true }
                    cur.append(c)
                }
            case .none:
                if c == "'" { q = .single; inWord = true }
                else if c == "\"" { q = .double; inWord = true }
                else if c == "\\" {
                    if i + 1 < chars.count { i += 1; cur.append(chars[i]); inWord = true }
                    else { cur.append(c); inWord = true }
                }
                else if c == " " || c == "\t" || c == "\n" { flush() }
                else if "&|;<>()`$".contains(c) { needsShell = true; cur.append(c); inWord = true }
                else { cur.append(c); inWord = true }
            }
            i += 1
        }
        if q != .none { throw StackShellError.unterminatedQuote }
        flush()
        if let first = words.first, isAssignment(first) { needsShell = true }
        return Parsed(argv: words, needsShell: needsShell)
    }

    static func isAssignment(_ w: String) -> Bool {
        guard let eq = w.firstIndex(of: "="), eq != w.startIndex else { return false }
        let key = w[w.startIndex..<eq]
        guard let f = key.first, f.isLetter || f == "_" else { return false }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// argv to run for a `run:` string.
    public static func command(for run: String) throws -> [String] {
        let p = try parse(run)
        if p.argv.isEmpty { return [] }
        return p.needsShell ? ["/bin/sh", "-c", run] : p.argv
    }
}

public enum StackShellError: Error, CustomStringConvertible {
    case unterminatedQuote
    public var description: String { "unterminated quote" }
}
