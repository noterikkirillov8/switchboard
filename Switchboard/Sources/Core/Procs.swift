import Darwin
import Foundation

/// A running `claude` or `codex` CLI process.
struct AgentProc: Sendable, Equatable {
    let pid: Int32
    let ppid: Int32
    let tool: Tool
    let cwd: String
    let started: Date?
}

enum Procs {
    /// Decides from the executable path and argv whether this is an agent CLI. Pure, so tests can feed it strings.
    static func classify(exe: String, argv: [String]) -> Tool? {
        func base(_ s: String) -> String { (s as NSString).lastPathComponent }
        let names = [base(exe), argv.first.map(base) ?? "", argv.count > 1 ? base(argv[1]) : ""]
        let joined = argv.joined(separator: " ")
        if names.contains("claude") { return .claude }
        if names.contains("codex"), !["app-server", "exec-server", "code-mode-host", "mcp-server"].contains(where: { joined.contains($0) }) { return .codex }
        return nil
    }

    /// Agent processes of this user, read with libproc only (no subprocess).
    static func scan() -> [AgentProc] {
        let uid = getuid()
        var out: [AgentProc] = []
        for pid in allPids() {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  info.pbi_uid == uid, info.pbi_status != UInt32(SZOMB) else { continue }
            let comm = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            // Cheap filter before reading the command line: our binaries are claude, codex, a version number, or run under node/bun.
            guard comm.hasPrefix("claude") || comm.hasPrefix("codex") || comm.hasPrefix("node") || comm.hasPrefix("bun")
                    || comm.first?.isNumber == true else { continue }
            let exe = exePath(pid)
            guard let argv = args(pid), let tool = classify(exe: exe, argv: argv) else { continue }
            out.append(AgentProc(pid: pid, ppid: Int32(info.pbi_ppid), tool: tool, cwd: cwd(pid),
                                 started: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))))
        }
        return out
    }

    /// Parent chain of a pid (nearest first), for finding the app that hosts a terminal session.
    static func ancestors(of pid: Int32, limit: Int = 16) -> [Int32] {
        var chain: [Int32] = [], cur = pid
        while chain.count < limit {
            var info = proc_bsdinfo()
            guard proc_pidinfo(cur, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { break }
            let parent = Int32(info.pbi_ppid)
            if parent <= 1 { break }
            chain.append(parent); cur = parent
        }
        return chain
    }

    static func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)   // a number of pids, not bytes (newest first)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return got > 0 ? Array(pids.prefix(Int(got))).filter { $0 > 0 } : []
    }

    static func exePath(_ pid: Int32) -> String {
        var buf = [UInt8](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    static func cwd(_ pid: Int32) -> String {
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return "" }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }

    /// argv from KERN_PROCARGS2: Int32 argc, exec path, NUL padding, then argc strings.
    static func args(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parseArgs(Array(buf.prefix(size)))
    }

    static func parseArgs(_ b: [UInt8]) -> [String]? {
        guard b.count > 4 else { return nil }
        let argc = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
        var i = 4
        while i < b.count, b[i] != 0 { i += 1 }
        while i < b.count, b[i] == 0 { i += 1 }
        var out: [String] = []
        while out.count < argc, i < b.count {
            var j = i
            while j < b.count, b[j] != 0 { j += 1 }
            out.append(String(decoding: b[i..<j], as: UTF8.self))
            i = j + 1
        }
        return out.isEmpty ? nil : out
    }
}
