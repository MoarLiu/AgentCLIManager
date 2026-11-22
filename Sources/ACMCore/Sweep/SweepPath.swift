import Darwin
import Foundation

/// 「项目清理」用的路径工具。
///
/// 和 `PathUtil` 不同，这里按原样逐段比较，不折叠大小写：扫描根来自 `realpath`，
/// 其余路径都是从目录里读出来的真实名字，写法本来就一致；放宽比较只会让边界判断变松。
public enum SweepPath {

    /// 预先拆好的路径。比较时不再分配。
    struct Parts: Sendable, Hashable {
        var values: [String]

        init(_ path: String) {
            values = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }

        /// 自己等于 `parent`，或者位于它之下。
        func isInside(_ parent: Parts) -> Bool {
            guard values.count >= parent.values.count else { return false }
            for index in parent.values.indices where values[index] != parent.values[index] {
                return false
            }
            return true
        }
    }

    static func components(_ path: String) -> [String] {
        Parts(path).values
    }

    /// `path` 等于 `parent` 或位于它之下。
    static func isInside(_ path: String, _ parent: String) -> Bool {
        Parts(path).isInside(Parts(parent))
    }

    /// 命令行拿到的路径不能是空的，也不能只含空白。空字符串以前会被拼成当前目录。
    public static func rejectBlank(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SweepError("usage", "路径不能为空。")
        }
    }

    /// 相对于扫描根的写法；根本身写成 `.`。调用方保证 `path` 在 `root` 之内。
    static func relative(_ path: String, to root: String) -> String {
        let rest = components(path).dropFirst(components(root).count)
        return rest.isEmpty ? "." : rest.joined(separator: "/")
    }

    public static func join(_ root: String, _ relative: String) -> String {
        if relative == "." || relative.isEmpty { return root }
        return root == "/" ? "/" + relative : root + "/" + relative
    }

    static func parent(_ path: String) -> String {
        let parts = components(path).dropLast()
        return "/" + parts.joined(separator: "/")
    }

    static func name(_ path: String) -> String {
        components(path).last ?? ""
    }

    /// 从 `path` 的上级开始，一路到 `/` 的所有目录。
    static func ancestors(of path: String) -> [String] {
        var out: [String] = []
        var parts = components(path)
        while !parts.isEmpty {
            parts.removeLast()
            out.append("/" + parts.joined(separator: "/"))
        }
        return out
    }

    /// 内核眼里的真实路径：软链解析掉，大小写换成磁盘上的写法。不存在时返回 nil。
    static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 尽量解析：存在的那一段用 `realpath`，后面不存在的部分原样接上。
    /// 用于排除路径——排除一个还不存在的位置是允许的。
    static func resolveLenient(_ path: String) -> String {
        var existing = components(PathUtil.standardize(path))
        var rest: [String] = []
        while true {
            let candidate = "/" + existing.joined(separator: "/")
            if let resolved = realpath(candidate) {
                return rest.isEmpty ? resolved : join(resolved, rest.reversed().joined(separator: "/"))
            }
            guard let last = existing.popLast() else { return "/" + rest.reversed().joined(separator: "/") }
            rest.append(last)
        }
    }

    /// 把命令行或界面给的路径变成绝对路径：展开开头的 `~`，相对路径接到 `cwd` 上。
    /// 不解析软链，也不折叠 `..`——那是 `realpath` 的事，它按磁盘上的真实结构算。
    public static func absolute(_ value: String, home: String, cwd: String) -> String {
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home + String(value.dropFirst(1)) }
        if value.hasPrefix("/") { return value }
        return cwd == "/" ? "/" + value : cwd + "/" + value
    }

    /// 对着假家目录演练时的额外限制：扫描根必须在那个目录之内。
    ///
    /// 换了家目录之后，真实的家目录不再被当成「家」，上面那些「范围太大」的判断
    /// 对它就失效了；演练不应该有机会碰到假家目录之外的东西。
    /// 路径不存在时不在这里报错，留给后面给出更准确的原因。
    public static func requireInside(_ path: String, home: String) throws {
        guard let resolved = realpath(path) else { return }
        guard let base = realpath(home), resolved != base, isInside(resolved, base) else {
            throw SweepError("usage", "带 --home 时，扫描目录必须在该目录之内。")
        }
    }

    // MARK: - 扫描根

    /// 校验并解析扫描根。范围太大的、系统的、归「工具」模块管的位置都拒绝。
    public static func normalizedRoot(_ value: String, env: HostEnvironment) throws -> String {
        guard value.hasPrefix("/"), let root = realpath(value) else {
            throw SweepError("invalid_root", "扫描目录不存在或无法访问。")
        }
        guard SweepFS.isDirectory(root) else {
            throw SweepError("invalid_root", "扫描目标必须是目录。")
        }
        let home = realpath(env.home) ?? env.home
        let broad: [String] = [
            "/", home, "/Users", realpath("/tmp") ?? "/private/tmp", "/private",
            realpath("/var") ?? "/private/var", "/Volumes",
        ]
        if broad.contains(root) || ancestors(of: home).contains(root) || isMountPoint(root) {
            throw SweepError("broad_root", "请选择 Downloads 或某个具体项目目录。")
        }
        if isPackageManagerRoot(root) {
            throw SweepError("broad_root", "请选择具体项目目录，不要选包管理器前缀。")
        }
        var systems = [
            "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/dev",
            "/cores", "/etc", "/private/etc", "/tftpboot", "/private/tftpboot",
        ]
        for name in ["/cores", "/etc", "/private/etc", "/tftpboot", "/private/tftpboot"] {
            if let resolved = realpath(name) { systems.append(resolved) }
        }
        for system in systems where isInside(root, system) {
            throw SweepError("system_root", "系统目录不在清理范围内。")
        }
        // 家目录的点条目和 ~/Library 是「工具」模块的范围：那里的 node_modules
        // 多半是某个已装工具的程序本体，不是能重新安装的项目依赖。
        if isInside(root, home) {
            let first = components(root)[components(home).count]
            if first.hasPrefix(".") || first == "Library" {
                throw SweepError("managed_root", "家目录的隐藏目录和 ~/Library 由「工具」部分管理，不在项目清理范围内。")
            }
        }
        return root
    }

    static func rootIdentity(_ root: String) throws -> [UInt64] {
        guard let info = SweepFS.stat(root) else {
            throw SweepError.posix("无法读取扫描根目录", errno)
        }
        return [UInt64(truncatingIfNeeded: Int64(info.st_dev)), UInt64(info.st_ino)]
    }

    /// `/opt` 本身，以及 Homebrew 前缀（含它下面的子目录）。`/opt/work/…` 这种具体项目仍允许。
    private static func isPackageManagerRoot(_ root: String) -> Bool {
        if root == "/opt" { return true }
        if let opt = realpath("/opt"), root == opt { return true }
        if isInside(root, "/opt/homebrew") { return true }
        if let brew = realpath("/opt/homebrew"), isInside(root, brew) { return true }
        return false
    }

    private static func isMountPoint(_ path: String) -> Bool {
        guard let own = SweepFS.lstat(path), let above = SweepFS.lstat(path + "/..") else { return false }
        return own.st_dev != above.st_dev || own.st_ino == above.st_ino
    }
}

// 放在类型外面：在 `SweepFS` 里面，`stat` 这个名字指的是它自己的方法。
private func systemStat(_ path: String) -> stat? {
    var info = stat()
    return stat(path, &info) == 0 ? info : nil
}

private func systemLstat(_ path: String) -> stat? {
    var info = stat()
    return lstat(path, &info) == 0 ? info : nil
}

/// 只读的文件系统查询。带「跟随软链」语义的和不跟随的分开写，免得用混。
enum SweepFS {
    static func lstat(_ path: String) -> stat? { systemLstat(path) }

    /// 跟随软链。
    static func stat(_ path: String) -> stat? { systemStat(path) }

    static func isDirectory(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFDIR }
    static func isRegular(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFREG }
    static func isSymlink(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFLNK }

    /// 跟随软链：最终是个目录。
    static func isDirectory(_ path: String) -> Bool { stat(path).map(isDirectory) ?? false }
    /// 跟随软链：最终是个普通文件。
    static func isFile(_ path: String) -> Bool { stat(path).map(isRegular) ?? false }
    /// 跟随软链：悬空软链算不存在。
    static func exists(_ path: String) -> Bool { stat(path) != nil }

    static func mtimeNs(_ info: stat) -> Int64 {
        Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }

    static func ctimeNs(_ info: stat) -> Int64 {
        Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec)
    }

    /// 从扫描根逐段打开到 `relative` 的上级目录，返回它的描述符和最后一段名字。
    /// 每一段都不跟随软链：中间任何一段被换成软链都会失败。描述符由调用方关闭。
    static func openParent(root: String, relative: String) throws -> (fd: Int32, leaf: String) {
        let unsafe = SweepError("unsafe_path", "目标或其父目录包含符号链接，或超出扫描范围。")
        let parts = SweepPath.components(relative)
        guard !relative.hasPrefix("/"), let leaf = parts.last, !parts.contains(".."), !parts.contains(".") else {
            throw unsafe
        }
        var fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SweepError.posix("无法打开目录", errno) }
        for component in parts.dropLast() {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                let code = errno
                close(fd)
                throw code == ELOOP || code == ENOTDIR ? unsafe : SweepError.posix("无法打开上级目录", code)
            }
            close(fd)
            fd = next
        }
        return (fd, leaf)
    }

    struct Listing {
        /// 按 UTF-8 字节序排好的名字（等同于按码点排序）
        var names: [String]
        /// 有名字不是合法的 UTF-8，没法用字符串表示，已经略过
        var hasUndecodable: Bool
    }

    static func list(_ directory: String) throws -> Listing {
        guard let handle = opendir(directory) else {
            throw SweepError.posix("无法读取目录", errno)
        }
        defer { closedir(handle) }
        return try read(handle)
    }

    /// 读一个已经打开的目录描述符。描述符本身不会被关掉。
    static func list(fd: Int32) throws -> Listing {
        let copy = dup(fd)
        guard copy >= 0 else { throw SweepError.posix("无法读取目录", errno) }
        guard let handle = fdopendir(copy) else {
            let code = errno
            close(copy)
            throw SweepError.posix("无法读取目录", code)
        }
        defer { closedir(handle) }
        // `dup` 和原描述符共享偏移。调用方可能已经读过这个目录，这里先回到开头。
        rewinddir(handle)
        return try read(handle)
    }

    private static func read(_ handle: UnsafeMutablePointer<DIR>) throws -> Listing {
        var names: [String] = []
        var hasUndecodable = false
        while true {
            errno = 0
            guard let entry = readdir(handle) else {
                if errno != 0 { throw SweepError.posix("无法读取目录", errno) }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            let bytes: [UInt8] = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
                    Array(UnsafeBufferPointer(start: $0, count: length))
                }
            }
            if bytes == [0x2E] || bytes == [0x2E, 0x2E] { continue }
            guard let name = String(bytes: bytes, encoding: .utf8) else {
                hasUndecodable = true
                continue
            }
            names.append(name)
        }
        names.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        return Listing(names: names, hasUndecodable: hasUndecodable)
    }
}
