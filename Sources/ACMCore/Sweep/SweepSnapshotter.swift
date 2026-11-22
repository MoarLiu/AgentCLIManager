import CryptoKit
import Darwin
import Foundation

/// 给一个候选项（目录或单个文件）算指纹。
///
/// 只读元数据，不读文件内容：每个条目的相对路径、设备、inode、权限、属主、大小、
/// 修改时间、状态变更时间和软链目标都进摘要，任何一处变了摘要就变。执行前重新算一遍，
/// 和计划里的不一致就不动。
///
/// 全程通过「不跟随软链」的目录描述符往下走，软链只记录它指向哪里，绝不进去。
///
/// 摘要的写法与 BuildSweep 逐字节一致（同样的条目顺序和 JSON 写法），
/// 这样两边能直接对拍。
/// 一轮扫描里按文件身份记住安装包摘要。只在扫描阶段复用，移动后的复核不走这里。
final class SweepContentHashCache: @unchecked Sendable {
    struct Key: Hashable {
        var device: Int64
        var inode: UInt64
        var size: Int64
        var mtimeNs: Int64
        var ctimeNs: Int64
    }

    private let lock = NSLock()
    private var values: [Key: String] = [:]

    func value(for key: Key) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func store(_ value: String, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}

public enum SweepSnapshotter {

    static let noise: Set<String> = [".DS_Store", ".localized"]

    public static func snapshot(
        root: String,
        relative: String,
        maxEntries: Int = 500_000,
        contentHash: Bool = false
    ) throws -> SweepSnapshot {
        try snapshot(root: root, relative: relative, maxEntries: maxEntries, contentHash: contentHash, hashes: nil)
    }

    static func snapshot(
        root: String,
        relative: String,
        maxEntries: Int = 500_000,
        contentHash: Bool = false,
        hashes: SweepContentHashCache?
    ) throws -> SweepSnapshot {
        guard SweepPath.realpath(root) == root else {
            throw SweepError("unsafe_path", "目标或其父目录包含符号链接，或超出扫描范围。")
        }
        guard let rootInfo = SweepFS.stat(root) else {
            throw SweepError.posix("无法读取扫描根目录", errno)
        }
        let (parentFD, leaf) = try SweepFS.openParent(root: root, relative: relative)
        defer { close(parentFD) }

        var initial = stat()
        guard fstatat(parentFD, leaf, &initial, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw SweepError.posix("无法读取目标", errno)
        }
        if SweepFS.isSymlink(initial) || initial.st_dev != rootInfo.st_dev {
            throw SweepError("unsafe_path", "符号链接或其他文件系统上的目标会跳过。")
        }
        let isDirectory = SweepFS.isDirectory(initial)
        guard isDirectory || SweepFS.isRegular(initial) else {
            throw SweepError("special_file", "特殊文件不会自动清理。")
        }

        let walker = Walker(device: initial.st_dev, maxEntries: maxEntries)
        try walker.add(relative: "", name: "", info: initial, link: nil)
        if isDirectory {
            let fd = openat(parentFD, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw SweepError.posix("无法打开目录", errno) }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_dev == initial.st_dev, opened.st_ino == initial.st_ino else {
                throw SweepError("changed_during_scan", "扫描期间目录被替换。")
            }
            try walker.visit(fd: fd, relative: "", depth: 0)
        }

        var result = SweepSnapshot(
            digest: SweepCanonical.hex(walker.hasher.finalize()),
            device: Int64(initial.st_dev),
            inode: UInt64(initial.st_ino),
            entries: walker.count,
            allocatedBytes: walker.allocated,
            latestMtimeNs: walker.latest,
            kind: isDirectory ? "directory" : "file",
            contentSHA256: nil
        )
        if contentHash, !isDirectory {
            let key = SweepContentHashCache.Key(
                device: Int64(initial.st_dev), inode: UInt64(initial.st_ino), size: Int64(initial.st_size),
                mtimeNs: SweepFS.mtimeNs(initial), ctimeNs: SweepFS.ctimeNs(initial)
            )
            if let cached = hashes?.value(for: key) {
                result.contentSHA256 = cached
            } else {
                let digest = try digestFile(parentFD: parentFD, name: leaf)
                hashes?.store(digest, for: key)
                result.contentSHA256 = digest
            }
        }

        var final = stat()
        guard fstatat(parentFD, leaf, &final, AT_SYMLINK_NOFOLLOW) == 0,
              final.st_dev == initial.st_dev, final.st_ino == initial.st_ino,
              SweepFS.mtimeNs(final) == SweepFS.mtimeNs(initial),
              SweepFS.ctimeNs(final) == SweepFS.ctimeNs(initial)
        else {
            throw SweepError("changed_during_scan", "扫描期间目标发生变化。")
        }
        return result
    }

    /// 读整个文件算 SHA-256；读的前后文件身份必须一致。
    private static func digestFile(parentFD: Int32, name: String) throws -> String {
        let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SweepError.posix("无法读取安装包", errno) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw SweepError.posix("无法读取安装包", errno) }

        var hasher = SHA256()
        let capacity = 1024 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let count = read(fd, buffer, capacity)
            if count < 0 {
                if errno == EINTR { continue }
                throw SweepError.posix("无法读取安装包", errno)
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
        }

        var after = stat()
        guard fstat(fd, &after) == 0, before.st_ino == after.st_ino, before.st_size == after.st_size,
              SweepFS.mtimeNs(before) == SweepFS.mtimeNs(after),
              SweepFS.ctimeNs(before) == SweepFS.ctimeNs(after)
        else {
            throw SweepError("changed_during_scan", "读取安装包期间内容发生变化。")
        }
        return SweepCanonical.hex(hasher.finalize())
    }

    private final class Walker {
        let device: dev_t
        let uid = getuid()
        let maxEntries: Int
        var hasher = SHA256()
        var count = 0
        var allocated: Int64 = 0
        var latest: Int64 = 0
        /// 同一设备内，inode 相同就是同一个文件（硬链接），占用只算一次。
        private var seen = Set<UInt64>()
        private var line: [UInt8] = []

        init(device: dev_t, maxEntries: Int) {
            self.device = device
            self.maxEntries = maxEntries
        }

        func add(relative: String, name: String, info: stat, link: String?) throws {
            count += 1
            if count > maxEntries {
                throw SweepError("snapshot_limit", "目录条目超过上限，需要单独复核。")
            }
            if info.st_dev != device || info.st_uid != uid {
                throw SweepError("shared_or_mounted", "存在其他用户或其他文件系统的内容。")
            }
            // 改名会改变根条目自己的状态变更时间，所以根不记它；
            // 内部条目照记，原地写入仍然查得出来。
            line.removeAll(keepingCapacity: true)
            line.append(UInt8(ascii: "["))
            SweepCanonical.append(relative, to: &line)
            for number in [
                String(info.st_dev), String(info.st_ino), String(info.st_mode),
                String(info.st_uid), String(info.st_size), String(SweepFS.mtimeNs(info)),
                relative.isEmpty ? "0" : String(SweepFS.ctimeNs(info)),
            ] {
                line.append(UInt8(ascii: ","))
                line.append(contentsOf: number.utf8)
            }
            line.append(UInt8(ascii: ","))
            if let link {
                SweepCanonical.append(link, to: &line)
            } else {
                line.append(contentsOf: "null".utf8)
            }
            line.append(UInt8(ascii: "]"))
            hasher.update(data: line)

            if seen.insert(UInt64(info.st_ino)).inserted {
                allocated += Int64(info.st_blocks) * 512
            }
            if !SweepSnapshotter.noise.contains(name) {
                latest = max(latest, SweepFS.mtimeNs(info))
            }
        }

        func visit(fd: Int32, relative: String, depth: Int) throws {
            if depth > SweepEngine.maxDepth {
                throw SweepError("snapshot_depth", "目录层级过深，需要单独复核。")
            }
            let listing = try SweepFS.list(fd: fd)
            if listing.hasUndecodable {
                throw SweepError("special_file", "目录中有文件名无法识别的条目，需单独复核。")
            }
            for name in listing.names {
                if name == ".git" {
                    throw SweepError("nested_repository", "目录内部有独立 Git 仓库。")
                }
                let child = relative.isEmpty ? name : relative + "/" + name
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw SweepError.posix("无法读取目录内容", errno)
                }
                var link: String?
                if SweepFS.isSymlink(info) { link = try readLink(fd: fd, name: name) }
                try add(relative: child, name: name, info: info, link: link)
                if SweepFS.isDirectory(info) {
                    let childFD = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard childFD >= 0 else { throw SweepError.posix("无法读取目录内容", errno) }
                    defer { close(childFD) }
                    var opened = stat()
                    guard fstat(childFD, &opened) == 0,
                          opened.st_dev == info.st_dev, opened.st_ino == info.st_ino
                    else {
                        throw SweepError("changed_during_scan", "扫描期间目录发生变化。")
                    }
                    try visit(fd: childFD, relative: child, depth: depth + 1)
                } else if !(SweepFS.isRegular(info) || SweepFS.isSymlink(info)) {
                    throw SweepError("special_file", "目录中有特殊文件，需单独复核。")
                }
            }
        }

        private func readLink(fd: Int32, name: String) throws -> String {
            var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = readlinkat(fd, name, &buffer, buffer.count)
            guard length >= 0 else { throw SweepError.posix("无法读取符号链接", errno) }
            guard let target = String(bytes: buffer[0..<length], encoding: .utf8) else {
                throw SweepError("special_file", "目录中有目标无法识别的符号链接，需单独复核。")
            }
            return target
        }
    }
}

/// 摘要用的 JSON 写法：键排序、不带空格、非 ASCII 字符一律写成 `\uXXXX`。
enum SweepCanonical {

    static func append(_ string: String, to out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x20...0x7E: out.append(UInt8(scalar.value))
            case let value where value > 0xFFFF:
                let offset = value - 0x10000
                appendEscape(0xD800 + (offset >> 10), to: &out)
                appendEscape(0xDC00 + (offset & 0x3FF), to: &out)
            default:
                appendEscape(scalar.value, to: &out)
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    private static let digits = Array("0123456789abcdef".utf8)

    private static func appendEscape(_ unit: UInt32, to out: inout [UInt8]) {
        out.append(0x5C)
        out.append(UInt8(ascii: "u"))
        for shift in [12, 8, 4, 0] {
            out.append(digits[Int((unit >> UInt32(shift)) & 0xF)])
        }
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0xF)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }
}
