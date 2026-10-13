import Foundation
import Network

/// Thin deadline-aware wrapper over `NWConnection`.
///
/// All mutable state lives on `queue`. A background receive loop accumulates bytes in `buffer`,
/// so a timed-out `read` never loses data that arrives later.
final class ProbeWire: @unchecked Sendable {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "pier.probe.wire")
    private var buffer = Data()
    private var closed = false
    private var waiter: (() -> Void)?

    enum Host { case v4, v6 }

    init(port: UInt16, host: Host, tls: Bool) {
        let endpoint = NWEndpoint.hostPort(
            host: host == .v4 ? .ipv4(.loopback) : .ipv6(.loopback),
            port: NWEndpoint.Port(rawValue: port) ?? .any)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params: NWParameters
        if tls {
            let opts = NWProtocolTLS.Options()
            let sec = opts.securityProtocolOptions
            // Dev servers use self-signed certificates: accept anything.
            sec_protocol_options_set_verify_block(sec, { _, _, complete in complete(true) }, DispatchQueue(label: "pier.probe.verify"))
            sec_protocol_options_set_tls_server_name(sec, "localhost")
            sec_protocol_options_add_tls_application_protocol(sec, "http/1.1")
            params = NWParameters(tls: opts, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        conn = NWConnection(to: endpoint, using: params)
    }

    /// Connects (and completes the TLS handshake if configured). False on refusal, failure or timeout.
    func open(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resumed = false
            let finish: (Bool) -> Void = { ok in
                if !resumed { resumed = true; cont.resume(returning: ok) }
            }
            conn.stateUpdateHandler = { [self] state in
                switch state {
                case .ready: finish(true); pump()
                case .waiting, .failed, .cancelled: finish(false); markClosed()
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
            conn.start(queue: queue)
        }
    }

    private func pump() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty { buffer.append(data) }
            if isComplete || error != nil { closed = true } else if buffer.count < 262_144 { pump() }
            waiter?()
        }
    }

    private func markClosed() {
        closed = true
        waiter?()
    }

    func send(_ data: Data) async -> Bool {
        await withCheckedContinuation { cont in
            conn.send(content: data, completion: .contentProcessed { cont.resume(returning: $0 == nil) })
        }
    }

    /// Waits until `stop(buffer)` is true, the peer closes, or `timeout` elapses. Returns everything received so far.
    func read(timeout: TimeInterval, until stop: @escaping @Sendable (Data) -> Bool) async -> (data: Data, closed: Bool) {
        await withCheckedContinuation { (cont: CheckedContinuation<(data: Data, closed: Bool), Never>) in
            queue.async { [self] in
                var finished = false
                var timedOut = false
                let check: () -> Void = { [self] in
                    guard !finished, timedOut || closed || stop(buffer) else { return }
                    finished = true
                    waiter = nil
                    cont.resume(returning: (buffer, closed))
                }
                waiter = check
                queue.asyncAfter(deadline: .now() + max(0, timeout)) { timedOut = true; check() }
                check()
            }
        }
    }

    func close() {
        conn.stateUpdateHandler = nil
        conn.cancel()
    }
}
