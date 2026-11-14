import Darwin
import Foundation

public struct RunningProcess: Sendable, Hashable, Codable {
    public var pid: Int32
    public var executable: String?
    public var arguments: [String]
    public var cwd: String?

    public init(pid: Int32, executable: String?, arguments: [String] = [], cwd: String? = nil) {
        self.pid = pid
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
    }

    /// 该进程是否在使用 `root` 之内的东西：可执行文件、参数里的路径或工作目录。
    ///
    /// 参数要看，是因为 node 写的 CLI 可执行文件是 node，脚本路径在 argv[1]。
    public func uses(_ root: String) -> Bool {
        if let executable, PathUtil.isInside(executable, root) { return true }
        if let cwd, PathUtil.isInside(cwd, root) { return true }
        for arg in arguments.prefix(8) where arg.hasPrefix("/") {
            if PathUtil.isInside(arg, root) { return true }
        }
        return false
    }
}

/// 用 libproc 列出当前用户的进程。不启动子进程；别的用户的进程读不到，会被自然跳过。
public enum ProcessProbe {
    public static let live: @Sendable () -> [RunningProcess] = {
        let me = getpid()
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimated) + 128)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        var out: [RunningProcess] = []
        for pid in pids.prefix(Int(count)) where pid > 0 && pid != me {
            guard let exe = executablePath(pid) else { continue }
            out.append(RunningProcess(pid: pid, executable: exe, arguments: arguments(pid), cwd: cwd(pid)))
        }
        return out
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // 跳过可执行文件路径及其后的填充零
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var args: [String] = []
        while index < size, args.count < Int(argc) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }
}
