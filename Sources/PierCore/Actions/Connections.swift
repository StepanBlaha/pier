import Foundation
import Darwin

/// Live TCP connection counting via libproc (no lsof).
public enum Connections {
    /// Number of ESTABLISHED TCP connections whose local port is `port` in process `pid`
    /// (i.e. clients currently connected to that server). nil when the fd table is unreadable
    /// (other user / root), so callers can treat "unknown" differently from "zero".
    public static func established(pid: Int32, port: UInt16) -> Int? {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return nil }

        var count = 0
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard r == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }
            let si = info.psi
            guard si.soi_kind == Int32(SOCKINFO_TCP), si.soi_protocol == IPPROTO_TCP else { continue }
            let tcp = si.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_ESTABLISHED else { continue }
            let local = UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport).bigEndian
            if local == port { count += 1 }
        }
        return count
    }
}
