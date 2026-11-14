import Darwin
import Foundation

/// 一次新执行独占的回执文件。创建成功并同步空数组后，调用方才可以移动工具。
/// 保持打开创建时的 fd，提交不按路径重新打开或替换文件，因此不会覆盖后来占据路径的条目。
public final class ReceiptJournal {
    public let path: String
    private let handle: FileHandle
    private var descriptor: Int32 { handle.fileDescriptor }
    private let identity: stat
    private var committed = false
    private let write: (Int32, UnsafeRawPointer, Int, off_t) -> Int

    /// 保存失败仍携带完整 JSON，调用方可以直接输出，不能把残缺目标当作成功回执。
    public struct CommitError: LocalizedError {
        public let recoveryJSON: Data
        public let underlying: Error
        public var errorDescription: String? { underlying.localizedDescription }
    }

    public enum JournalError: LocalizedError {
        case occupied(String)
        case changed(String)
        case alreadyCommitted

        public var errorDescription: String? {
            switch self {
            case .occupied(let path): return "回执路径已存在，拒绝覆盖（包括空回执、目录和软链）：\(path)；请使用新路径"
            case .changed(let path): return "回执预留路径已改变，未覆盖当前条目：\(path)"
            case .alreadyCommitted: return "这次执行的回执已经提交，不能重复写入"
            }
        }
    }

    public static func absolutePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    public convenience init(reserving path: String) throws {
        try self.init(reserving: path, write: { pwrite($0, $1, $2, $3) })
    }

    // 测试用写入接缝：复现短写和磁盘写入失败，不需要改变进程全局资源限制。
    init(reserving path: String, write: @escaping (Int32, UnsafeRawPointer, Int, off_t) -> Int) throws {
        self.path = Self.absolutePath(path)
        self.write = write
        let fd = Darwin.open(self.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            if errno == EEXIST { throw JournalError.occupied(self.path) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        identity = info
        try writeOwned(Data("[]\n".utf8))
    }

    // FileHandle 销毁时只关闭自己持有的 fd。不 unlink 路径，以免删除竞态出现的文件。
    // 执行中止时留下 [] 预留；初始化/写入失败时可能留下未完成文件，调用方必须报告错误。

    public func commit(_ receipts: [TrashReceipt]) throws {
        let data = try Self.encode(receipts)
        do {
            guard !committed else { throw JournalError.alreadyCommitted }
            try writeOwned(data)
            committed = true
        } catch {
            throw CommitError(recoveryJSON: data, underlying: error)
        }
    }

    public static func encode(_ receipts: [TrashReceipt]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(receipts)
    }

    /// undo 已读取的回执允许原子更新：失败时保留原记录，成功时只留下未恢复的条目。
    public static func saveRemaining(_ receipts: [TrashReceipt], to path: String) throws {
        try encode(receipts).write(to: URL(fileURLWithPath: absolutePath(path)), options: .atomic)
    }

    private func validateIdentity() throws {
        var current = stat()
        guard lstat(path, &current) == 0,
              current.st_dev == identity.st_dev,
              current.st_ino == identity.st_ino,
              current.st_mode & S_IFMT == S_IFREG else {
            throw JournalError.changed(path)
        }
        // macOS 对已打开的 fd 可能仍允许写入后来加上 uchg 的文件；不能只依赖 pwrite 报错。
        guard current.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0 else {
            throw POSIXError(.EPERM)
        }
    }

    private func writeOwned(_ data: Data) throws {
        try validateIdentity()
        // pwrite 始终写向自己创建的 inode；即使核对后路径被替换，也不会写到新文件。
        // 新执行尚无旧回执可保护。中途写入失败由 CLI 输出完整恢复 JSON；undo 则使用原子写。
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(count == 0 ? .EIO : (POSIXErrorCode(rawValue: errno) ?? .EIO)) }
                offset += count
            }
        }
        guard ftruncate(descriptor, off_t(data.count)) == 0, fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try validateIdentity()
    }
}
