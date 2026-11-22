import Compression
import Foundation
@testable import ACMCore

/// 「项目清理」测试用的工作区：假家目录旁边的一个普通文件夹。
/// 和其他测试一样，所有读写都在临时目录里。
final class SweepWorkspace {
    let fx: Fixture
    /// 解析过软链的工作区根，和扫描结果里的 `root` 写法一致。
    let root: String

    init() throws {
        fx = try Fixture()
        let unresolved = fx.root + "/workspace"
        try FileManager.default.createDirectory(atPath: unresolved, withIntermediateDirectories: true)
        root = SweepPath.realpath(unresolved) ?? unresolved
    }

    func path(_ relative: String) -> String { relative.isEmpty ? root : root + "/" + relative }

    @discardableResult
    func dir(_ relative: String) -> String {
        try! FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
        return relative
    }

    @discardableResult
    func file(_ relative: String, _ content: String = "data") -> String {
        file(relative, Data(content.utf8))
    }

    @discardableResult
    func file(_ relative: String, _ content: Data) -> String {
        let target = path(relative)
        try! FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: target, contents: content)
        return relative
    }

    func link(_ relative: String, to target: String) {
        let location = path(relative)
        try! FileManager.default.createDirectory(
            atPath: (location as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try! FileManager.default.createSymbolicLink(atPath: location, withDestinationPath: target)
    }

    /// 一个带 SwiftPM 构建缓存的项目。返回缓存目录的相对路径。
    @discardableResult
    func swiftProject(_ project: String = "") -> String {
        let prefix = project.isEmpty ? "" : project + "/"
        file(prefix + "Package.swift", "// swift-tools-version: 6.0\n")
        dir(prefix + ".build/artifacts")
        file(prefix + ".build/workspace-state.json", "{}")
        file(prefix + ".build/object.o", "rebuildable object")
        return prefix + ".build"
    }

    @discardableResult
    func package(_ filename: String, _ content: String = "installer", folder: String = "release") -> String {
        file(folder + "/" + filename, content)
    }

    /// 一个最小的应用包：Info.plist 加上一个 arm64 的 Mach-O 头。
    @discardableResult
    func app(_ relative: String, identifier: String, version: String) -> String {
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "Product",
        ]
        file(relative + "/Contents/Info.plist", try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ))
        file(relative + "/Contents/MacOS/Product", Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01]))
        return relative
    }

    func env(selfPaths: [String] = []) -> HostEnvironment {
        fx.env(selfPaths: selfPaths)
    }

    /// 默认用安静的探针（没有进程、没有 Git 跟踪），并把「现在」拨到 60 天后，
    /// 让刚建好的文件算作闲置。
    func scan(
        policy: SweepPolicy = SweepPolicy(),
        probes: SweepProbes = SweepWorkspace.quiet,
        selfPaths: [String] = [],
        now: Date? = nil
    ) throws -> SweepPlan {
        try SweepScanner.scan(root: root, policy: policy, env: env(selfPaths: selfPaths), probes: probes, now: now)
    }

    static let quiet = SweepProbes(openPaths: { [] }, gitTracked: { _, _ in .untracked })

    static func probes(
        open: [SweepOpenPath] = [],
        git: SweepGitAnswer = .untracked
    ) -> SweepProbes {
        SweepProbes(openPaths: { open }, gitTracked: { _, _ in git })
    }
}

extension SweepPlan {
    func item(_ path: String) -> SweepItem? {
        items.first { $0.path == path }
    }
}

/// 抛出的应该是带这个错误码的 `SweepError`；不是的话返回实际情况，方便断言时看。
func sweepErrorCode(_ body: () throws -> Void) -> String {
    do {
        try body()
        return "没有抛错"
    } catch let error as SweepError {
        return error.code
    } catch {
        return "其他错误：\(error)"
    }
}

func sweepErrorText(_ body: () throws -> Void) throws -> String {
    do {
        try body()
        return ""
    } catch let error as SweepError {
        return error.message
    }
}

// MARK: - 手工拼 ZIP

/// 测试用的最小 ZIP 生成器，只支持「不压缩」和 deflate 两种方式。
enum ZipBuilder {
    struct Member {
        var name: String
        var content: Data
        var deflate = false
        /// 故意写错校验值，用来验证损坏的压缩包不被接受。
        var corruptCRC = false
    }

    /// `zip64` 为真时按 ZIP64 的写法：32 位字段写满，真实的大小和偏移放进扩展字段，
    /// 结尾再加 ZIP64 结尾记录和定位记录。小文件这样写也合乎规范。
    static func archive(_ members: [Member], zip64: Bool = false) -> Data {
        var body = Data()
        var directory = Data()
        for member in members {
            let name = Data(member.name.utf8)
            let stored = member.deflate ? deflate(member.content) : member.content
            var crc = SweepZip.crc32(Array(member.content))
            if member.corruptCRC { crc ^= 0xFFFF }
            let method: UInt16 = member.deflate ? 8 : 0
            let offset = UInt64(body.count)
            let size = UInt64(member.content.count), packed = UInt64(stored.count)
            let localExtra = zip64 ? le16(0x0001) + le16(16) + le64(size) + le64(packed) : Data()
            let centralExtra = zip64 ? le16(0x0001) + le16(24) + le64(size) + le64(packed) + le64(offset) : Data()
            let sizes = zip64 ? le32(0xFFFF_FFFF) + le32(0xFFFF_FFFF) : le32(UInt32(packed)) + le32(UInt32(size))

            body += le32(0x0403_4b50) + le16(45) + le16(0) + le16(method) + le16(0) + le16(0)
            body += le32(crc) + sizes
            body += le16(UInt16(name.count)) + le16(UInt16(localExtra.count)) + name + localExtra + stored

            directory += le32(0x0201_4b50) + le16(45) + le16(45) + le16(0) + le16(method) + le16(0) + le16(0)
            directory += le32(crc) + sizes
            directory += le16(UInt16(name.count)) + le16(UInt16(centralExtra.count)) + le16(0) + le16(0) + le16(0)
            directory += le32(0) + le32(zip64 ? 0xFFFF_FFFF : UInt32(offset)) + name + centralExtra
        }
        var end = Data()
        if zip64 {
            let count = UInt64(members.count)
            end += le32(0x0606_4b50) + le64(44) + le16(45) + le16(45) + le32(0) + le32(0)
            end += le64(count) + le64(count) + le64(UInt64(directory.count)) + le64(UInt64(body.count))
            end += le32(0x0706_4b50) + le32(0) + le64(UInt64(body.count + directory.count)) + le32(1)
            end += le32(0x0605_4b50) + le16(0) + le16(0) + le16(0xFFFF) + le16(0xFFFF)
            end += le32(0xFFFF_FFFF) + le32(0xFFFF_FFFF) + le16(0)
        } else {
            end += le32(0x0605_4b50) + le16(0) + le16(0)
            end += le16(UInt16(members.count)) + le16(UInt16(members.count))
            end += le32(UInt32(directory.count)) + le32(UInt32(body.count)) + le16(0)
        }
        return body + directory + end
    }

    static func infoPlist(identifier: String?) -> Data {
        var plist: [String: Any] = ["CFBundleName": "Product"]
        if let identifier { plist["CFBundleIdentifier"] = identifier }
        return try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private static func deflate(_ data: Data) -> Data {
        var output = [UInt8](repeating: 0, count: data.count + 1024)
        let written = data.withUnsafeBytes { source in
            compression_encode_buffer(
                &output, output.count, source.bindMemory(to: UInt8.self).baseAddress!, source.count,
                nil, COMPRESSION_ZLIB
            )
        }
        return Data(output[..<written])
    }

    private static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private static func le32(_ value: UInt32) -> Data {
        le16(UInt16(value & 0xFFFF)) + le16(UInt16(value >> 16))
    }

    private static func le64(_ value: UInt64) -> Data {
        le32(UInt32(value & 0xFFFF_FFFF)) + le32(UInt32(value >> 32))
    }
}
