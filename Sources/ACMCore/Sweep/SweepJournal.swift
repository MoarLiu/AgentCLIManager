import Darwin
import Foundation

/// 回执里的一行。回执是 JSONL：第一行是这次执行的抬头（`run`），之后每个候选项
/// 依次留下 `intent`（准备移动）、`staged`（已进暂存目录）、
/// `trashed` 或 `deleted`（完成），放回时再追加 `restored`。
struct SweepJournalRecord: Codable, Equatable {
    var event: String
    // 抬头
    var schemaVersion: Int?
    var runID: String?
    var root: String?
    var rootIdentity: [UInt64]?
    var mode: SweepMode?
    var stage: String?
    var createdAt: Double?
    // 逐项
    var id: String?
    var path: String?
    var destination: String?
    var snapshot: SweepSnapshot?

    init(event: String, id: String? = nil) {
        self.event = event
        self.id = id
    }

    private enum CodingKeys: String, CodingKey {
        case event, root, mode, stage, id, path, destination, snapshot
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case rootIdentity = "root_identity"
        case createdAt = "created_at"
    }

    func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}

/// 一次执行的回执文件。
///
/// 在移动第一个条目之前就建好，之后每一步都先写进回执、同步到磁盘，再往下走。
/// 这样无论在哪一步中断，回执都说得清每个条目现在在哪里。
final class SweepJournal {
    /// 测试用：在写某一行之前插入故障（磁盘写满、只写了半行）。
    typealias Fault = (_ event: String, _ fd: Int32) throws -> Void

    let path: String
    private let fd: Int32
    private let identity: stat
    private let fault: Fault?

    /// 只创建新文件；路径上已经有东西（包括软链）就失败。
    init(creating path: String, fault: Fault? = nil) throws {
        let descriptor = open(
            path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw SweepError.posix("无法创建回执文件", errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            close(descriptor)
            throw SweepError.posix("无法创建回执文件", code)
        }
        self.path = path
        self.fault = fault
        fd = descriptor
        identity = info
    }

    deinit { close(fd) }

    func append(_ record: SweepJournalRecord) throws {
        try fault?(record.event, fd)
        guard let current = SweepFS.lstat(path),
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino
        else {
            throw SweepError("journal_changed", "回执文件被替换，执行已中止。")
        }
        try Self.write(try record.line(), to: fd, what: "无法写入回执")
    }

    /// 写完并同步到磁盘才算数。
    static func write(_ data: Data, to fd: Int32, what: String) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SweepError.posix(what, count == 0 ? EIO : errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw SweepError.posix(what, errno) }
    }
}

/// 读进来并校验过的回执。回执是不可信输入：可能是手写的，也可能被改过。
struct SweepReceipt {
    var path: String
    var root: String
    var rootIdentity: [UInt64]
    var runID: String
    var mode: SweepMode
    var stage: String
    var records: [SweepJournalRecord]
    /// 读的时候文件的身份；放回前必须还是它
    var identity: [Int64]
    /// 完整的行一共多少字节；后面写到一半的尾巴在放回前截掉
    var validBytes: Int
    /// 最后一行完整但没有换行符
    var needsNewline: Bool

    static func identity(of info: stat) -> [Int64] {
        [Int64(info.st_dev), Int64(bitPattern: UInt64(info.st_ino)), Int64(info.st_size),
         SweepFS.mtimeNs(info), SweepFS.ctimeNs(info)]
    }

    static func read(_ source: String, env: HostEnvironment) throws -> SweepReceipt {
        guard source.hasPrefix("/") else { throw SweepError("invalid_receipt", "回执文件需要绝对路径。") }
        guard let before = SweepFS.lstat(source) else {
            throw SweepError.posix("读不出回执文件", errno)
        }
        guard SweepFS.isRegular(before), before.st_size <= off_t(SweepEngine.maxPlanBytes) else {
            throw SweepError("invalid_receipt", "回执文件无效。")
        }
        guard let content = FileManager.default.contents(atPath: source) else {
            throw SweepError("io_error", "读不出回执文件。")
        }
        guard let after = SweepFS.lstat(source), identity(of: after) == identity(of: before) else {
            throw SweepError("receipt_changed", "读取期间回执发生变化。")
        }

        let bytes = [UInt8](content)
        var records: [SweepJournalRecord] = []
        var validBytes = 0
        var start = 0
        let decoder = JSONDecoder()
        while start < bytes.count {
            let newline = bytes[start...].firstIndex(of: 0x0A)
            let end = newline ?? bytes.count
            if let record = try? decoder.decode(SweepJournalRecord.self, from: Data(bytes[start..<end])) {
                records.append(record)
                validBytes = newline == nil ? end : end + 1
            } else if newline == nil {
                break // 最后一行只写了一半：之前的记录仍然有效
            } else {
                throw SweepError("invalid_receipt", "回执文件损坏。")
            }
            start = end + 1
        }

        guard let header = records.first, header.event == "run" else {
            throw SweepError("invalid_receipt", "缺少清理回执头。")
        }
        guard let runID = header.runID, isRunID(runID),
              header.schemaVersion == SweepEngine.schemaVersion,
              let rootIdentity = header.rootIdentity, rootIdentity.count == 2
        else {
            throw SweepError("invalid_receipt", "回执版本或标识无效。")
        }
        guard let mode = header.mode else {
            throw SweepError("invalid_receipt", "回执操作模式无效。")
        }
        // 扫描根不合规矩时，问题出在回执上，不是调用方式上。
        guard let rootValue = header.root,
              (try? SweepPath.normalizedRoot(rootValue, env: env)) == rootValue
        else {
            throw SweepError("invalid_receipt", "回执里的扫描目录无效。")
        }
        // 暂存目录只能是这次执行自己的那一个，不由回执说了算。
        guard header.stage == SweepState.stage(mode: mode, root: rootValue, runID: runID, env: env) else {
            throw SweepError("invalid_receipt", "回执暂存目录无效。")
        }
        return SweepReceipt(
            path: source, root: rootValue, rootIdentity: rootIdentity, runID: runID, mode: mode,
            stage: header.stage ?? "", records: records, identity: identity(of: before),
            validBytes: validBytes,
            needsNewline: validBytes > 0 && bytes[validBytes - 1] != 0x0A
        )
    }

    static func isRunID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}

/// 执行和恢复共用的位置与约定。
enum SweepState {
    /// 永久模式的暂存目录，建在扫描根里（保证和待清理的东西在同一个卷上）。
    static let stagingName = ".acm-sweep-staging"
    static let stagePrefix = "ACM-Sweep-"

    /// 回执和执行锁放在本 App 自己的数据目录里。
    static func directory(_ env: HostEnvironment) -> String { env.ownSupportDir + "/sweep" }
    static func runs(_ env: HostEnvironment) -> String { directory(env) + "/runs" }

    /// 暂存目录的上级：废纸篓，或扫描根里的暂存目录。
    static func stageBase(mode: SweepMode, root: String, env: HostEnvironment) -> String {
        mode == .permanent ? root + "/" + stagingName : env.home + "/.Trash"
    }

    /// 某次执行的暂存目录。上级解析掉软链，最后一段不解析：它必须是个真目录。
    static func stage(mode: SweepMode, root: String, runID: String, env: HostEnvironment) -> String {
        SweepPath.resolveLenient(stageBase(mode: mode, root: root, env: env)) + "/" + stagePrefix + runID
    }

    /// 确保目录存在、是当前用户的、别人进不来；返回它。
    @discardableResult
    static func privateDirectory(_ path: String, what: String = "工具状态目录") throws -> String {
        let unsafe = SweepError("unsafe_state", "\(what)必须是当前用户独占的真实目录。", details: ["path": path])
        if SweepFS.lstat(path) == nil {
            try FileManager.default.createDirectory(
                atPath: SweepPath.parent(path), withIntermediateDirectories: true
            )
            guard mkdir(path, 0o700) == 0 || errno == EEXIST else {
                throw SweepError.posix("无法创建\(what)", errno)
            }
        }
        guard let info = SweepFS.lstat(path), SweepFS.isDirectory(info),
              info.st_uid == getuid(), info.st_mode & 0o077 == 0
        else { throw unsafe }
        return path
    }

    /// 同一个扫描根同时只允许一个清理或恢复在跑。
    static func withRootLock<T>(_ root: String, env: HostEnvironment, _ body: () throws -> T) throws -> T {
        let directory = try privateDirectory(self.directory(env))
        let key = SweepCanonical.sha256(Data(root.utf8)).prefix(24)
        let fd = open(directory + "/\(key).lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SweepError.posix("无法创建执行锁", errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), SweepFS.isRegular(info), info.st_nlink == 1 else {
            throw SweepError("unsafe_lock", "执行锁文件无效。")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw SweepError("already_running", "同一目录已有清理或恢复操作。") }
            throw SweepError.posix("无法取得执行锁", errno)
        }
        return try body()
    }

    /// 只在目标位置没有东西时才移动，不会覆盖。
    static func renameExclusive(fromFD: Int32, _ from: String, toFD: Int32, _ to: String) throws {
        guard renameatx_np(fromFD, from, toFD, to, UInt32(RENAME_EXCL)) == 0 else {
            throw SweepError.posix("无法移动", errno)
        }
    }
}
