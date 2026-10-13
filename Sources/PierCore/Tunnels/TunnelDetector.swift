import Foundation

public enum TunnelDetector {
    public struct Options: Sendable {
        /// Total wall-clock budget; sources that haven't answered by then are dropped.
        public var budget: TimeInterval = 0.3
        public var ngrokPorts: [UInt16] = [4040, 4041, 4042, 4043]
        public var includeRegistry = true
        public var includeCloudflaredProcesses = true
        public var includeTailscale = true
        public init() {}
    }

    /// Local port → public URL for active tunnels (ngrok local API, cloudflared processes/expose registry, tailscale funnel).
    public static func activeTunnels() async -> [UInt16: String] { await activeTunnels(options: Options()) }

    public static func activeTunnels(options: Options) async -> [UInt16: String] {
        // Priority order (first source wins per port).
        var sources: [@Sendable () -> [UInt16: String]] = []
        if options.includeRegistry {
            sources.append { Dictionary(TunnelRegistry.load().map { ($0.port, $0.url) }, uniquingKeysWith: { a, _ in a }) }
        }
        if options.includeCloudflaredProcesses { sources.append { TunnelSources.cloudflaredProcesses(budget: 0.2) } }
        if !options.ngrokPorts.isEmpty { let ports = options.ngrokPorts; sources.append { TunnelSources.ngrok(ports: ports, budget: 0.2) } }
        if options.includeTailscale { sources.append { TunnelSources.tailscaleFunnel(timeout: 0.25) } }
        guard !sources.isEmpty else { return [:] }

        let collector = Collector(count: sources.count)
        return await withCheckedContinuation { cont in
            collector.onFinish = { cont.resume(returning: $0) }
            for (i, src) in sources.enumerated() {
                DispatchQueue.global(qos: .userInitiated).async { collector.deliver(i, src()) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + options.budget) { collector.finish() }
        }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [[UInt16: String]?]
        private var pending: Int
        private var finished = false
        var onFinish: (([UInt16: String]) -> Void)?

        init(count: Int) { results = Array(repeating: nil, count: count); pending = count }

        func deliver(_ i: Int, _ r: [UInt16: String]) {
            lock.lock()
            results[i] = r
            pending -= 1
            let last = pending == 0
            lock.unlock()
            if last { finish() }
        }

        func finish() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            var merged: [UInt16: String] = [:]
            for r in results { for (p, u) in r ?? [:] where merged[p] == nil { merged[p] = u } }
            let cb = onFinish
            onFinish = nil
            lock.unlock()
            cb?(merged)
        }
    }
}
