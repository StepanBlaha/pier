import Foundation

/// Candidate generation for `<port|name>` shell completion.
public enum Completion {
    public struct Candidate: Equatable, Sendable {
        public var value: String
        public var detail: String
        public init(value: String, detail: String) { self.value = value; self.detail = detail }
    }

    /// Lowercased, spaces → '-': projectName, else infraName, else framework id, else process name.
    public static func nameToken(_ s: Service) -> String {
        let raw = s.projectName ?? s.infraName ?? s.framework?.id ?? s.process.name
        return raw.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
    }

    /// Ports first (ascending), then name tokens (alphabetical), deduped, filtered by case-insensitive prefix.
    public static func candidates(prefix: String, services: [Service]) -> [Candidate] {
        let p = prefix.lowercased()
        var seen = Set<String>(), ports: [Candidate] = [], names: [String: [UInt16]] = [:]
        for s in services.sorted(by: { ($0.port, $0.process.pid) < ($1.port, $1.process.pid) }) {
            let port = String(s.port)
            if seen.insert(port).inserted, p.isEmpty || port.hasPrefix(p) {
                let extra = [s.framework?.name ?? s.infraName].compactMap { $0 }
                let detail = ([s.displayName] + extra.filter { $0 != s.displayName }).joined(separator: " · ")
                ports.append(Candidate(value: port, detail: detail))
            }
            let token = nameToken(s)
            if !token.isEmpty { names[token, default: []].append(s.port) }
        }
        let nameCandidates = names.keys.sorted().compactMap { token -> Candidate? in
            guard seen.insert(token).inserted, p.isEmpty || token.hasPrefix(p) else { return nil }
            let ports = Array(Set(names[token] ?? [])).sorted().map(String.init)
            return Candidate(value: token, detail: (ports.count == 1 ? "port " : "ports ") + ports.joined(separator: " "))
        }
        return ports + nameCandidates
    }

    /// Output line for a given shell: zsh `value:description` (colons in value escaped), fish `value<TAB>description`,
    /// anything else (bash) the bare value.
    public static func render(_ c: Candidate, shell: String?) -> String {
        switch shell {
        case "zsh":
            let v = c.value.replacingOccurrences(of: ":", with: "\\:")
            return c.detail.isEmpty ? v : "\(v):\(c.detail)"
        case "fish":
            return c.detail.isEmpty ? c.value : "\(c.value)\t\(c.detail)"
        default:
            return c.value
        }
    }
}
