import Foundation

/// Resolves a user-typed target (port number or fuzzy name) to services.
public enum Matcher {
    public struct Candidate: Sendable {
        public let service: Service
        public let score: Int
    }

    public enum Resolution: Sendable {
        /// Unambiguous: one service, or several pids sharing the requested port.
        case found([Service])
        /// Several services tie for best score; the caller must ask for a more specific target.
        case ambiguous([Service])
        case none
    }

    static let portScore = 1000, exact = 100, prefix = 80, substring = 60, subsequence = 30

    /// All matches, best first (ties broken by port).
    public static func rank(_ query: String, in services: [Service]) -> [Candidate] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        if let port = UInt16(q) {
            let byPort = services.filter { $0.port == port }
            if !byPort.isEmpty { return byPort.map { Candidate(service: $0, score: portScore) } }
        }
        return services
            .compactMap { s -> Candidate? in
                let best = fields(of: s).map { score(q, $0.lowercased()) }.max() ?? 0
                return best > 0 ? Candidate(service: s, score: best) : nil
            }
            .sorted { ($1.score, $0.service.port, $0.service.process.pid) < ($0.score, $1.service.port, $1.service.process.pid) }
    }

    public static func resolve(_ query: String, in services: [Service]) -> Resolution {
        let ranked = rank(query, in: services)
        guard let top = ranked.first else { return .none }
        let tied = ranked.prefix { $0.score == top.score }.map(\.service)
        if top.score == portScore { return .found(tied) }
        return tied.count == 1 ? .found(tied) : .ambiguous(tied)
    }

    static func fields(of s: Service) -> [String] {
        [s.displayName, s.projectName, s.infraName, s.framework?.name, s.framework?.id, s.process.name].compactMap { $0 }
    }

    /// exact > prefix > substring > subsequence; 0 = no match. Both inputs lowercased.
    static func score(_ q: String, _ field: String) -> Int {
        if field == q { return exact }
        if field.hasPrefix(q) { return prefix }
        if field.contains(q) { return substring }
        if q.count >= 2, isSubsequence(q, of: field) { return subsequence }
        return 0
    }

    static func isSubsequence(_ q: String, of field: String) -> Bool {
        var it = field.makeIterator()
        return q.allSatisfy { c in
            while let n = it.next() { if n == c { return true } }
            return false
        }
    }
}
