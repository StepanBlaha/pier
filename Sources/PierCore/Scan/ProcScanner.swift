import Foundation
import Darwin

/// Native libproc-based process / socket enumeration.
public enum ProcScanner {
    // MARK: Listening sockets

    /// All listening TCP sockets (v4 + v6) for every visible process.
    public static func listeningSockets() -> [ListeningSocket] {
        var result = Set<ListeningSocket>()
        for pid in allPids() where pid > 0 {
            for socket in listeningSockets(pid: pid) { result.insert(socket) }
        }
        return result.sorted { ($0.port, $0.pid, $0.address) < ($1.port, $1.pid, $1.address) }
    }

    private static func allPids() -> [Int32] {
        // With a nil buffer the return value is a pid count (not bytes); pad for processes spawned meanwhile.
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 256)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n)))
    }

    private static func listeningSockets(pid: Int32) -> [ListeningSocket] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }

        var out: [ListeningSocket] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard r == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }
            if let s = listeningSocket(from: info, pid: pid) { out.append(s) }
        }
        return out
    }

    private static func listeningSocket(from info: socket_fdinfo, pid: Int32) -> ListeningSocket? {
        let si = info.psi
        guard si.soi_kind == Int32(SOCKINFO_TCP), si.soi_protocol == IPPROTO_TCP else { return nil }
        let tcp = si.soi_proto.pri_tcp
        guard tcp.tcpsi_state == TSI_S_LISTEN else { return nil }
        let ini = tcp.tcpsi_ini
        let port = UInt16(truncatingIfNeeded: ini.insi_lport).bigEndian
        guard port != 0 else { return nil }

        var local = ini.insi_laddr
        let vflag = Int32(ini.insi_vflag)
        // Dual-stack sockets carry both flags; the v6 address is authoritative then.
        if vflag & INI_IPV6 != 0 {
            let bytes = withUnsafeBytes(of: &local.ina_6) { Array($0) }
            // IPv4-mapped (::ffff:a.b.c.d) is really a v4 bind.
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return ListeningSocket(port: port, pid: pid, address: ntop(AF_INET, Array(bytes[12...])), family: .v4)
            }
            return ListeningSocket(port: port, pid: pid, address: ntop(AF_INET6, bytes), family: .v6)
        }
        guard vflag & INI_IPV4 != 0 else { return nil }
        let bytes = withUnsafeBytes(of: &local.ina_46.i46a_addr4) { Array($0) }
        return ListeningSocket(port: port, pid: pid, address: ntop(AF_INET, bytes), family: .v4)
    }

    private static func ntop(_ family: Int32, _ bytes: [UInt8]) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN) + 1)
        guard bytes.withUnsafeBytes({ inet_ntop(family, $0.baseAddress, &buf, socklen_t(buf.count)) }) != nil else { return "" }
        return String(cString: buf)
    }

    // MARK: Process info

    /// Single process info, no CPU sampling.
    public static func processInfo(pid: Int32) -> ProcInfo? {
        var bsd = proc_bsdinfo()
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard r == Int32(MemoryLayout<proc_bsdinfo>.size) else { return kernelProcInfo(pid: pid) }

        var name = [CChar](repeating: 0, count: 256)
        let nlen = proc_name(pid, &name, UInt32(name.count))
        var procName = nlen > 0 ? String(cString: name) : ""
        if procName.isEmpty {
            procName = withUnsafeBytes(of: bsd.pbi_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
        if procName.isEmpty {
            procName = withUnsafeBytes(of: bsd.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }

        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let plen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
        let exe = plen > 0 ? String(cString: pathBuf) : nil

        let args = procArgs(pid: pid)
        let cwd = currentDirectory(pid: pid)

        var task = proc_taskinfo()
        let tr = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
        let rss: UInt64? = tr == Int32(MemoryLayout<proc_taskinfo>.size) ? task.pti_resident_size : nil

        let start = Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)

        return ProcInfo(pid: pid, ppid: Int32(bitPattern: bsd.pbi_ppid), uid: bsd.pbi_uid, name: procName,
                        executablePath: exe, arguments: (args ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, cwd: cwd, startTime: start,
                        cpuPercent: nil, rssBytes: rss, isAccessible: args != nil && cwd != nil)
    }

    /// Batch process info. Samples CPU twice (~150ms apart) to fill cpuPercent.
    public static func processInfos(pids: [Int32]) -> [Int32: ProcInfo] {
        let unique = Array(Set(pids))
        var infos: [Int32: ProcInfo] = [:]
        for pid in unique { if let i = processInfo(pid: pid) { infos[pid] = i } }

        let first = cpuTimes(pids: Array(infos.keys))
        let t0 = DispatchTime.now().uptimeNanoseconds
        Thread.sleep(forTimeInterval: 0.15)
        let second = cpuTimes(pids: Array(first.keys))
        let wallNs = Double(DispatchTime.now().uptimeNanoseconds - t0)

        for (pid, a) in first {
            guard let b = second[pid], b >= a, wallNs > 0 else { continue }
            infos[pid]?.cpuPercent = Double(b - a) / wallNs * 100
        }
        return infos
    }

    /// Cumulative user+system CPU time per pid, in nanoseconds.
    private static func cpuTimes(pids: [Int32]) -> [Int32: UInt64] {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        var out: [Int32: UInt64] = [:]
        for pid in pids {
            var task = proc_taskinfo()
            let r = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
            guard r == Int32(MemoryLayout<proc_taskinfo>.size) else { continue }
            let ticks = task.pti_total_user &+ task.pti_total_system
            out[pid] = ticks &* UInt64(tb.numer) / UInt64(max(tb.denom, 1))
        }
        return out
    }

    /// Ancestors of pid, nearest parent first, excluding pid itself, stopping at pid 1 (included) or maxDepth.
    public static func parentChain(of pid: Int32, maxDepth: Int = 16) -> [ProcInfo] {
        var chain: [ProcInfo] = []
        var seen: Set<Int32> = [pid]
        var current = pid
        while chain.count < maxDepth, current > 1, let me = processInfo(pid: current) {
            let parent = me.ppid
            guard parent > 0, seen.insert(parent).inserted, let p = processInfo(pid: parent) else { break }
            chain.append(p)
            current = parent
        }
        return chain
    }

    // MARK: Helpers

    /// Fallback for processes libproc refuses to describe (e.g. launchd, EPERM): sysctl KERN_PROC_PID still works.
    private static func kernelProcInfo(pid: Int32) -> ProcInfo? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0, kp.kp_proc.p_pid == pid else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        let nlen = proc_name(pid, &name, UInt32(name.count))
        let procName = nlen > 0 ? String(cString: name)
            : withUnsafeBytes(of: kp.kp_proc.p_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let exe = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 ? String(cString: pathBuf) : nil
        let st = kp.kp_proc.p_starttime
        return ProcInfo(pid: pid, ppid: kp.kp_eproc.e_ppid, uid: kp.kp_eproc.e_ucred.cr_uid, name: procName,
                        executablePath: exe, startTime: Date(timeIntervalSince1970: TimeInterval(st.tv_sec) + TimeInterval(st.tv_usec) / 1_000_000),
                        isAccessible: false)
    }

    private static func currentDirectory(pid: Int32) -> String? {
        var vpi = proc_vnodepathinfo()
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard r == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }
        let path = withUnsafeBytes(of: vpi.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    /// argv via KERN_PROCARGS2: [argc:int32][exec_path\0][\0 padding][argv0\0 argv1\0 ...][env...]
    private static func procArgs(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        buf.removeLast(buf.count - size)

        let argc = buf.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        while i < buf.count, buf[i] != 0 { i += 1 }      // exec path
        while i < buf.count, buf[i] == 0 { i += 1 }      // padding
        var args: [String] = []
        while args.count < argc, i < buf.count {
            var j = i
            while j < buf.count, buf[j] != 0 { j += 1 }
            args.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args
    }
}
