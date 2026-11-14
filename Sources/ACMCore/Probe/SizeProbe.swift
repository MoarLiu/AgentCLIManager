import Foundation

public protocol SizeProbe: Sendable {
    /// 量不出来返回 nil；有读不到的子目录时 `accurate == false`。
    func measure(_ path: String) -> SizeResult?
}

/// 用 `du -skx` 量大小。比逐文件枚举快得多；`-x` 防止越过挂载点。
///
/// 注意：遇到没权限的子目录时 du 照样会输出一个数并以非零退出——那个数只是下界。
/// 把它当成准确值会让一个 7 GB 的目录看起来只有几 KB，所以必须同时看退出码和 stderr。
public struct DuSizeProbe: SizeProbe {
    public init() {}

    public func measure(_ path: String) -> SizeResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-skx", path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { return nil }

        // 两个管道要同时读，否则 stderr 写满缓冲区会和等 stdout 的我们互相卡死。
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()

        guard let text = String(data: outData, encoding: .utf8),
              let lastLine = text.split(separator: "\n").last,
              let field = lastLine.split(whereSeparator: { $0 == "\t" || $0 == " " }).first,
              let kilobytes = Int64(field)
        else { return nil }

        let accurate = process.terminationStatus == 0 && errBox.data.isEmpty
        return SizeResult(bytes: kilobytes * 1024, accurate: accurate)
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// 测试用：按给定表返回大小。
public struct FixedSizeProbe: SizeProbe {
    public var sizes: [String: SizeResult]
    public init(_ sizes: [String: SizeResult]) { self.sizes = sizes }
    public func measure(_ path: String) -> SizeResult? { sizes[path] }
}

public enum DiskSpace {
    public static func volume(at path: String) -> (free: Int64, total: Int64)? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ]),
            let free = values.volumeAvailableCapacityForImportantUsage,
            let total = values.volumeTotalCapacity
        else { return nil }
        return (free, Int64(total))
    }
}
