import Foundation

public enum PortFinder {
    /// True if nothing holds `port` on 127.0.0.1, 0.0.0.0 or ::1 (checked by attempting bind()).
    public static func isFree(_ port: UInt16) -> Bool {
        canBind(AF_INET, "127.0.0.1", port) && canBind(AF_INET, "0.0.0.0", port) && canBind(AF_INET6, "::1", port)
    }

    /// First free port >= `start`, or nil if the range is exhausted.
    public static func nextFree(from start: UInt16 = 3000) -> UInt16? {
        (start...UInt16.max).first(where: isFree)
    }

    private static func canBind(_ family: Int32, _ host: String, _ port: UInt16) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return family == AF_INET6 }   // no IPv6 stack: nothing to conflict with
        defer { close(fd) }
        // Deliberately no SO_REUSEADDR: we want a strict "is anything bound here" answer.
        let rc: Int32
        if family == AF_INET {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            inet_pton(AF_INET, host, &a.sin_addr)
            rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        } else {
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = port.bigEndian
            inet_pton(AF_INET6, host, &a.sin6_addr)
            rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        }
        if rc == 0 { return true }
        return family == AF_INET6 && errno == EADDRNOTAVAIL
    }
}
