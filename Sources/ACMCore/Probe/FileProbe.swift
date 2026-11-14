import Foundation

/// 对文件系统的只读访问，集中在这里，方便看清引擎到底读了什么。
enum FileProbe {
    struct Info {
        var isDirectory: Bool
        var isSymlink: Bool
        var mtime: Date?
        var ownerUID: Int?
        var size: Int64
        /// inode 号。同一卷内移动（包括移到废纸篓）不会变，用来确认「还是那一个」。
        var fileID: UInt64?
    }

    /// 不跟随软链：软链本身的属性。
    static func lstat(_ path: String) -> Info? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let type = attrs[.type] as? FileAttributeType
        return Info(
            isDirectory: type == .typeDirectory,
            isSymlink: type == .typeSymbolicLink,
            mtime: attrs[.modificationDate] as? Date,
            ownerUID: (attrs[.ownerAccountID] as? NSNumber)?.intValue,
            size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
            fileID: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    /// 跟随软链：悬空软链返回 false。
    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 普通文件且当前用户可以执行（跟随软链）。
    static func isExecutableFile(_ path: String) -> Bool {
        !isDirectory(path) && FileManager.default.isExecutableFile(atPath: path)
    }

    /// 内核眼里的真实路径（`realpath(3)`）。进程表里的路径是这种写法：
    /// `/var/folders/…` 在那里是 `/private/var/folders/…`。解析不了时原样返回。
    static func kernelPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func list(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
    }

    static func symlinkDestination(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    static func readHead(_ path: String, max: Int = 16_384) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: max)
    }

    static func readText(_ path: String, max: Int = 262_144) -> String? {
        guard let data = readHead(path, max: max) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// 目录自身与第一层子项里最晚的修改时间。
    ///
    /// 目录自己的 mtime 只在增删直接子项时才变，深处的写入反映不出来，
    /// 所以多看一层；仍可能漏掉更深的写入，因此「最近没动过」只算推测而不是证明。
    static func latestActivity(_ path: String) -> Date? {
        guard let info = lstat(path) else { return nil }
        var latest = info.mtime
        if info.isDirectory {
            for child in list(path).prefix(500) {
                if let m = lstat(path + "/" + child)?.mtime, latest == nil || m > latest! {
                    latest = m
                }
            }
        }
        return latest
    }

    static func hasExecutable(in dir: String) -> Bool {
        for name in list(dir).prefix(200) {
            let p = dir + "/" + name
            guard let info = lstat(p), !info.isDirectory else { continue }
            if info.isSymlink || FileManager.default.isExecutableFile(atPath: p) { return true }
        }
        return false
    }
}
