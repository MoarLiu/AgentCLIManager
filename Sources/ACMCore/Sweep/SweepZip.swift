import Compression
import Darwin
import Foundation

/// 只够用来回答一个问题的 ZIP 读取器：「这个压缩包里是不是恰好装着一个 App？」
///
/// 普通 ZIP 可能是源码备份、设计稿或者个人文件，不能凭扩展名当成安装包。
/// 只有压缩包顶层恰好有一个 `<名字>.app/Contents/Info.plist`、读得出来、
/// 并且带 bundle id 时才算。任何读不懂的地方都回答「不是」——那样它就不会成为候选项。
enum SweepZip {

    static let maxEntries = 100_000
    static let maxPlistBytes = 1024 * 1024
    private static let maxDirectoryBytes: UInt64 = 64 * 1024 * 1024

    private struct Entry {
        var name: [UInt8]
        var flags: UInt16
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var size: UInt64
        var localOffset: UInt64
    }

    /// 压缩包里唯一那个 App 的 Info.plist；不满足条件时返回 nil。
    static func soleAppInfo(_ path: String) -> [String: Any]? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let fileSize = UInt64(info.st_size)

        guard let (entries, shift) = centralDirectory(fd: fd, fileSize: fileSize) else { return nil }
        let suffix = Array(".app/Contents/Info.plist".utf8)
        let apps = entries.filter { entry in
            guard entry.name.count > suffix.count, entry.name.suffix(suffix.count).elementsEqual(suffix) else {
                return false
            }
            return !entry.name.dropLast(suffix.count).contains(UInt8(ascii: "/"))
        }
        guard apps.count == 1, apps[0].size <= UInt64(maxPlistBytes) else { return nil }
        guard let data = extract(apps[0], fd: fd, fileSize: fileSize, shift: shift) else { return nil }

        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
              format != .openStep, let plist = value as? [String: Any]
        else { return nil }
        return plist
    }

    // MARK: - 中央目录

    private static func centralDirectory(fd: Int32, fileSize: UInt64) -> (entries: [Entry], shift: UInt64)? {
        // 结尾记录固定 22 字节，后面最多跟 65535 字节的注释。
        let tailLength = min(fileSize, 22 + 65_535)
        guard tailLength >= 22, let tail = pread(fd, at: fileSize - tailLength, count: Int(tailLength)) else {
            return nil
        }
        var position = tail.count - 22
        while position >= 0, u32(tail, position) != 0x0605_4b50 { position -= 1 }
        guard position >= 0 else { return nil }
        let recordOffset = fileSize - tailLength + UInt64(position)

        var size = UInt64(u32(tail, position + 12))
        var offset = UInt64(u32(tail, position + 16))
        var directoryEnd = recordOffset

        // ZIP64：定位记录紧贴在结尾记录之前，再往前是 56 字节的 ZIP64 结尾记录。
        if recordOffset >= 20 + 56,
           let locator = pread(fd, at: recordOffset - 20, count: 20), u32(locator, 0) == 0x0706_4b50,
           let record = pread(fd, at: recordOffset - 20 - 56, count: 56), u32(record, 0) == 0x0606_4b50 {
            size = u64(record, 40)
            offset = u64(record, 48)
            directoryEnd = recordOffset - 20 - 56
        }

        // 压缩包前面可能垫着别的数据（自解压程序），记录里的偏移都要整体平移。
        guard size <= directoryEnd, size <= maxDirectoryBytes else { return nil }
        let start = directoryEnd - size
        guard start >= offset else { return nil }
        let shift = start - offset
        guard let directory = pread(fd, at: start, count: Int(size)) else { return nil }

        var entries: [Entry] = []
        var cursor = 0
        while cursor < directory.count {
            guard cursor + 46 <= directory.count, u32(directory, cursor) == 0x0201_4b50 else { return nil }
            let nameLength = Int(u16(directory, cursor + 28))
            let extraLength = Int(u16(directory, cursor + 30))
            let commentLength = Int(u16(directory, cursor + 32))
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= directory.count else { return nil }

            var entry = Entry(
                name: Array(directory[(cursor + 46)..<(cursor + 46 + nameLength)]),
                flags: u16(directory, cursor + 8),
                method: u16(directory, cursor + 10),
                crc: u32(directory, cursor + 16),
                compressedSize: UInt64(u32(directory, cursor + 20)),
                size: UInt64(u32(directory, cursor + 24)),
                localOffset: UInt64(u32(directory, cursor + 42))
            )
            // 标了 UTF-8 的名字必须真的是 UTF-8，否则整个压缩包按损坏处理。
            if entry.flags & 0x0800 != 0, String(bytes: entry.name, encoding: .utf8) == nil { return nil }
            if let zero = entry.name.firstIndex(of: 0) { entry.name = Array(entry.name[..<zero]) }
            let extraStart = cursor + 46 + nameLength
            guard applyZip64(&entry, extra: directory[extraStart..<(extraStart + extraLength)]) else { return nil }

            entries.append(entry)
            guard entries.count <= maxEntries else { return nil }
            cursor = next
        }
        return (entries, shift)
    }

    /// 32 位字段写满（0xFFFFFFFF）时，真实值按固定顺序放在 ZIP64 扩展字段里。
    private static func applyZip64(_ entry: inout Entry, extra: ArraySlice<UInt8>) -> Bool {
        let needs = entry.size == 0xFFFF_FFFF || entry.compressedSize == 0xFFFF_FFFF
            || entry.localOffset == 0xFFFF_FFFF
        guard needs else { return true }
        let bytes = Array(extra)
        var cursor = 0
        while cursor + 4 <= bytes.count {
            let id = u16(bytes, cursor)
            let length = Int(u16(bytes, cursor + 2))
            guard cursor + 4 + length <= bytes.count else { return false }
            if id == 0x0001 {
                var field = cursor + 4
                let end = cursor + 4 + length
                func take() -> UInt64? {
                    guard field + 8 <= end else { return nil }
                    defer { field += 8 }
                    return u64(bytes, field)
                }
                if entry.size == 0xFFFF_FFFF {
                    guard let value = take() else { return false }
                    entry.size = value
                }
                if entry.compressedSize == 0xFFFF_FFFF {
                    guard let value = take() else { return false }
                    entry.compressedSize = value
                }
                if entry.localOffset == 0xFFFF_FFFF {
                    guard let value = take() else { return false }
                    entry.localOffset = value
                }
                return true
            }
            cursor += 4 + length
        }
        return false
    }

    // MARK: - 取出一个文件

    private static func extract(_ entry: Entry, fd: Int32, fileSize: UInt64, shift: UInt64) -> Data? {
        // 加密的、用了不认识的压缩方式的，一律不读。
        guard entry.flags & 0x0041 == 0, entry.method == 0 || entry.method == 8,
              entry.compressedSize <= 8 * 1024 * 1024
        else { return nil }
        let headerOffset = entry.localOffset &+ shift
        guard headerOffset >= entry.localOffset,
              let header = pread(fd, at: headerOffset, count: 30), u32(header, 0) == 0x0403_4b50
        else { return nil }
        let nameLength = UInt64(u16(header, 26))
        let extraLength = UInt64(u16(header, 28))
        // 本地文件头里的名字要和中央目录一致。
        guard let localName = pread(fd, at: headerOffset + 30, count: Int(nameLength)) else { return nil }
        var name = localName
        if let zero = name.firstIndex(of: 0) { name = Array(name[..<zero]) }
        guard name == entry.name else { return nil }

        let dataOffset = headerOffset + 30 + nameLength + extraLength
        guard dataOffset + entry.compressedSize <= fileSize,
              let compressed = pread(fd, at: dataOffset, count: Int(entry.compressedSize))
        else { return nil }

        let output: [UInt8]
        if entry.method == 0 {
            output = compressed
        } else {
            // 多留一个字节：解出来比声明的长，说明大小对不上。
            var buffer = [UInt8](repeating: 0, count: Int(entry.size) + 1)
            let written = compressed.withUnsafeBufferPointer { source -> Int in
                guard let base = source.baseAddress else { return 0 }
                return compression_decode_buffer(&buffer, buffer.count, base, source.count, nil, COMPRESSION_ZLIB)
            }
            output = Array(buffer[..<written])
        }
        guard UInt64(output.count) == entry.size, crc32(output) == entry.crc else { return nil }
        return Data(output)
    }

    // MARK: - 读取与校验

    private static func pread(_ fd: Int32, at offset: UInt64, count: Int) -> [UInt8]? {
        guard count >= 0, offset <= UInt64(Int64.max) else { return nil }
        var buffer = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let got = buffer.withUnsafeMutableBytes { raw in
                Darwin.pread(fd, raw.baseAddress! + done, count - done, off_t(offset) + off_t(done))
            }
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { return nil }
            done += got
        }
        return buffer
    }

    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(u16(bytes, at)) | UInt32(u16(bytes, at + 2)) << 16
    }

    private static func u64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        UInt64(u32(bytes, at)) | UInt64(u32(bytes, at + 4)) << 32
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        return value ^ 0xFFFF_FFFF
    }
}
