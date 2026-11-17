import Foundation

/// 「项目清理」：在用户指定的目录里找闲置的开发依赖、构建缓存和旧安装包。
///
/// 这一块和「工具」模块的范围正好互补：那边只管家目录的点条目和 `~/Library`，
/// 这边只管普通文件夹，所以不经过 `PathSafety`，自带一套以扫描根为界的护栏。
public enum SweepEngine {
    public static let schemaVersion = 1
    public static let toolVersion = "acm-sweep-1"
    /// 一次扫描最多收下的候选项。
    public static let maxItems = 10_000
    /// 发现阶段和指纹阶段各自允许的目录层数。
    public static let maxDepth = 64
    /// 发现阶段最多看多少个目录项。
    public static let maxVisited = 500_000
    /// 计划文件的大小上限。
    public static let maxPlanBytes = 32 * 1024 * 1024
}

public struct SweepError: Error, Sendable, Equatable, CustomStringConvertible {
    public var code: String
    public var message: String
    public var details: [String: String]

    public init(_ code: String, _ message: String, details: [String: String] = [:]) {
        self.code = code
        self.message = message
        self.details = details
    }

    public var description: String { message }

    /// 属于「调用方式不对」的错误，命令行按用法错误（退出码 2）处理。
    public var isUsage: Bool {
        [
            "usage", "invalid_policy", "invalid_pagination", "invalid_root", "broad_root",
            "system_root", "managed_root", "plan_exists", "unsafe_plan_path",
        ].contains(code)
    }

    static func posix(_ what: String, _ number: Int32) -> SweepError {
        SweepError("io_error", "\(what)（\(String(cString: strerror(number)))）")
    }
}

public enum SweepStatus: String, Codable, Sendable, CaseIterable {
    /// 有生成依据、闲置、没被占用：可以清理
    case cleanup
    /// 该留着的（最新版本的安装包）
    case keep
    /// 证据不够，交给人判断
    case review
    /// 有保护条件拦着，不会动
    case blocked

    public var displayName: String {
        switch self {
        case .cleanup: return "可清理"
        case .keep: return "保留"
        case .review: return "需复核"
        case .blocked: return "跳过"
        }
    }
}

public enum SweepCategory: String, Codable, Sendable {
    case swiftCache = "swift_cache"
    case nodeDependencies = "node_dependencies"
    case orphanNodeDependencies = "orphan_node_dependencies"
    case pythonCache = "python_cache"
    case webCache = "web_cache"
    case unrecognizedCache = "unrecognized_cache"
    case installer
}

public struct SweepVersion: Codable, Sendable, Hashable {
    /// 文件名或 Info.plist 里匹配到的原文
    public var text: String
    public var base: [Int]
    /// 预览版（alpha、beta、rc…）
    public var pre: Bool
    /// 用于比较新旧：主.次.修订，再加阶段和序号
    public var rank: [Int]
}

public struct SweepInstaller: Codable, Sendable, Hashable {
    public var recognized: Bool
    /// 没认出来时的原因
    public var reason: String?
    public var version: SweepVersion?
    public var product: String?
    public var architecture: String?
    public var format: String?
    public var build: String?

    static func unrecognized(_ reason: String) -> SweepInstaller {
        SweepInstaller(recognized: false, reason: reason)
    }
}

/// 一个候选项在某一刻的完整身份。计划生成时记一份，执行前必须仍然一致。
public struct SweepSnapshot: Codable, Sendable, Hashable {
    /// 整棵目录树元数据的摘要（不读文件内容）
    public var digest: String
    public var device: Int64
    public var inode: UInt64
    public var entries: Int
    /// 按分配块统计的占用；硬链接只算一次
    public var allocatedBytes: Int64
    public var latestMtimeNs: Int64
    /// `directory` 或 `file`
    public var kind: String
    /// 只有认出来的单文件安装包才算内容摘要
    public var contentSHA256: String?

    private enum CodingKeys: String, CodingKey {
        case digest, device, inode, entries, kind
        case allocatedBytes = "allocated_bytes"
        case latestMtimeNs = "latest_mtime_ns"
        case contentSHA256 = "content_sha256"
    }
}

public struct SweepProcessUser: Codable, Sendable, Hashable {
    public var pid: Int32
    public var command: String
}

public struct SweepItem: Codable, Sendable, Hashable, Identifiable {
    /// 由扫描根和相对路径算出，重新扫描后不变
    public var id: String
    /// 相对于扫描根
    public var path: String
    public var parent: String
    /// 所属项目（相对于扫描根，根本身是 `.`）；找不到项目时为 nil
    public var project: String?
    public var category: SweepCategory
    public var status: SweepStatus
    public var reason: String
    /// 这一项能清理，是因为这些条目被保留着
    public var retainedIDs: [String]
    public var installer: SweepInstaller?
    public var snapshot: SweepSnapshot?
    public var processes: [SweepProcessUser]?

    private enum CodingKeys: String, CodingKey {
        case id, path, parent, project, category, status, reason, installer, snapshot, processes
        case retainedIDs = "retained_ids"
    }

    public init(
        id: String, path: String, parent: String, project: String?, category: SweepCategory,
        status: SweepStatus, reason: String, retainedIDs: [String] = [],
        installer: SweepInstaller? = nil, snapshot: SweepSnapshot? = nil,
        processes: [SweepProcessUser]? = nil
    ) {
        self.id = id
        self.path = path
        self.parent = parent
        self.project = project
        self.category = category
        self.status = status
        self.reason = reason
        self.retainedIDs = retainedIDs
        self.installer = installer
        self.snapshot = snapshot
        self.processes = processes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            path: try values.decode(String.self, forKey: .path),
            parent: try values.decode(String.self, forKey: .parent),
            project: try values.decodeIfPresent(String.self, forKey: .project),
            category: try values.decode(SweepCategory.self, forKey: .category),
            status: try values.decode(SweepStatus.self, forKey: .status),
            reason: try values.decode(String.self, forKey: .reason),
            retainedIDs: try values.decodeIfPresent([String].self, forKey: .retainedIDs) ?? [],
            installer: try values.decodeIfPresent(SweepInstaller.self, forKey: .installer),
            snapshot: try values.decodeIfPresent(SweepSnapshot.self, forKey: .snapshot),
            processes: try values.decodeIfPresent([SweepProcessUser].self, forKey: .processes)
        )
    }

    /// `project` 没有时写成 null 而不是省略：读 JSON 的脚本可以直接取这个键。
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(path, forKey: .path)
        try values.encode(parent, forKey: .parent)
        try values.encode(project, forKey: .project)
        try values.encode(category, forKey: .category)
        try values.encode(status, forKey: .status)
        try values.encode(reason, forKey: .reason)
        try values.encode(retainedIDs, forKey: .retainedIDs)
        try values.encodeIfPresent(installer, forKey: .installer)
        try values.encodeIfPresent(snapshot, forKey: .snapshot)
        try values.encodeIfPresent(processes, forKey: .processes)
    }
}

public struct SweepPolicy: Codable, Sendable, Hashable {
    /// 候选项至少闲置这么久才算可清理
    public var idleHours: Double
    /// 单个候选目录的条目上限，超过就不自动清理
    public var maxEntries: Int
    /// 用户排除的路径（已解析成绝对路径）
    public var excludes: [String]

    public init(idleHours: Double = 24, maxEntries: Int = 500_000, excludes: [String] = []) {
        self.idleHours = idleHours
        self.maxEntries = maxEntries
        self.excludes = excludes
    }

    private enum CodingKeys: String, CodingKey {
        case excludes
        case idleHours = "idle_hours"
        case maxEntries = "max_entries"
    }
}

public struct SweepSummary: Codable, Sendable, Hashable {
    public var cleanup = 0
    public var keep = 0
    public var review = 0
    public var blocked = 0
    /// 可清理项的占用合计，只是估计：硬链接、APFS 克隆都会让实际释放量不同
    public var estimatedCleanupBytes: Int64 = 0

    private enum CodingKeys: String, CodingKey {
        case cleanup, keep, review, blocked
        case estimatedCleanupBytes = "estimated_cleanup_bytes"
    }

    public init(_ items: [SweepItem]) {
        for item in items {
            switch item.status {
            case .cleanup:
                cleanup += 1
                estimatedCleanupBytes += item.snapshot?.allocatedBytes ?? 0
            case .keep: keep += 1
            case .review: review += 1
            case .blocked: blocked += 1
            }
        }
    }
}

public struct SweepWarning: Codable, Sendable, Hashable {
    public var code: String
    public var message: String
}

/// 一次只读扫描的结果，也是之后执行所依据的计划。
public struct SweepPlan: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var toolVersion: String
    /// 解析过软链的扫描根
    public var root: String
    /// 扫描根的设备号和 inode，用来发现「目录被换掉了」
    public var rootIdentity: [UInt64]
    /// 生成时间（Unix 秒）
    public var createdAt: Double
    public var policy: SweepPolicy
    public var items: [SweepItem]
    public var summary: SweepSummary
    public var warnings: [SweepWarning]
    /// 计划保存到了哪里；不属于计划内容，不参与完整性校验
    public var planFile: String?

    private enum CodingKeys: String, CodingKey {
        case root, policy, items, summary, warnings
        case schemaVersion = "schema_version"
        case toolVersion = "tool_version"
        case rootIdentity = "root_identity"
        case createdAt = "created_at"
        case planFile = "plan_file"
    }

    /// 按 id 或相对路径找一项；找不到或不唯一都算失败，不替调用方挑。
    public func item(matching needle: String) throws -> SweepItem {
        let matches = items.filter { $0.id == needle || $0.path == needle }
        guard matches.count == 1 else {
            throw SweepError("unknown_item", "无法唯一定位计划项目。")
        }
        return matches[0]
    }

    public func absolutePath(of item: SweepItem) -> String {
        SweepPath.join(root, item.path)
    }

    /// 判为可清理的安装包里，「已有更新版本」的那一类。
    ///
    /// 版本号是从文件名里读出来的，新旧只是推测；内容和保留的那份完全一样的重复件不算在内，
    /// 那是确定的。执行时这一类不会被顺带清掉，要明确点名。
    public func isSupersededVersion(_ item: SweepItem) -> Bool {
        guard item.category == .installer, item.status == .cleanup else { return false }
        guard let content = item.snapshot?.contentSHA256 else { return true }
        let retained = Set(item.retainedIDs)
        return !items.contains { retained.contains($0.id) && $0.snapshot?.contentSHA256 == content }
    }
}

/// `items` 子命令的一页结果。
public struct SweepPage: Sendable {
    public var total: Int
    public var offset: Int
    public var nextOffset: Int?
    public var items: [SweepItem]

    public init(plan: SweepPlan, status: SweepStatus?, limit: Int, offset: Int) throws {
        guard (1...1000).contains(limit), offset >= 0 else {
            throw SweepError("invalid_pagination", "limit 必须为 1 至 1000，offset 不能小于零。")
        }
        let filtered = plan.items.filter { status == nil || $0.status == status }
        let end = offset.addingReportingOverflow(limit).overflow ? Int.max : offset + limit
        total = filtered.count
        self.offset = offset
        nextOffset = end < filtered.count ? end : nil
        items = Array(filtered.dropFirst(offset).prefix(limit))
    }
}

extension SweepPage: Encodable {
    private enum CodingKeys: String, CodingKey {
        case total, offset, items
        case nextOffset = "next_offset"
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(total, forKey: .total)
        try values.encode(offset, forKey: .offset)
        try values.encode(nextOffset, forKey: .nextOffset)
        try values.encode(items, forKey: .items)
    }
}

// MARK: - 执行与恢复

public enum SweepMode: String, Codable, Sendable {
    /// 移到废纸篓里本工具自己的暂存目录，可以按回执放回
    case trash
    /// 先移到扫描根里的暂存目录，复核后直接删除，不可恢复
    case permanent
}

public enum SweepOutcomeStatus: String, Codable, Sendable {
    /// 复核通过，可以执行（预演时的结论）
    case ready
    /// 有条件拦着，没有动
    case blocked
    /// 计划里的东西已经不在了
    case alreadyAbsent = "already_absent"
    case trashed
    case deleted
    /// 已经移进暂存目录，但后面的步骤失败了；内容还在 `recoveryPath`
    case recoveryRequired = "recovery_required"
    case restored
    case alreadyRestored = "already_restored"
    /// 暂存的内容找不到了
    case missing
    /// 内容已经放回，但回执没能更新
    case restoredReceiptFailed = "restored_receipt_failed"

    /// 这一项没有按预期完成。
    public var isFailure: Bool {
        [.blocked, .missing, .recoveryRequired, .restoredReceiptFailed].contains(self)
    }

    public var displayName: String {
        switch self {
        case .ready: return "可执行"
        case .blocked: return "已跳过"
        case .alreadyAbsent: return "已不存在"
        case .trashed: return "已移入废纸篓"
        case .deleted: return "已删除"
        case .recoveryRequired: return "需要手工恢复"
        case .restored: return "已放回"
        case .alreadyRestored: return "此前已放回"
        case .missing: return "暂存内容缺失"
        case .restoredReceiptFailed: return "已放回，回执未更新"
        }
    }
}

public struct SweepOutcome: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var path: String
    public var status: SweepOutcomeStatus
    public var reason: String?
    /// 内容现在在哪里：进了废纸篓的暂存位置，或者中途失败后留在暂存目录里的位置
    public var recoveryPath: String?

    public init(id: String, path: String, status: SweepOutcomeStatus, reason: String? = nil, recoveryPath: String? = nil) {
        self.id = id
        self.path = path
        self.status = status
        self.reason = reason
        self.recoveryPath = recoveryPath
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, status, reason
        case recoveryPath = "recovery_path"
    }
}

public struct SweepApplyResult: Sendable {
    /// false 表示这只是预演，或者没有一项可以执行
    public var executed: Bool
    public var mode: SweepMode
    public var root: String
    /// 这次执行的回执；预演时没有
    public var receipt: String?
    public var items: [SweepOutcome]
    /// 执行前后系统可用空间的变化
    public var freeSpaceDeltaBytes: Int64?
    /// 东西进了废纸篓：清空废纸篓之后空间才会释放
    public var requiresEmptyingTrash: Bool?
    /// 没有点名、因此没有列入的旧版本安装包
    public var unselectedIDs: [String]

    public var incomplete: Bool { items.contains { $0.status.isFailure } }

    public init(
        executed: Bool, mode: SweepMode, root: String, receipt: String?, items: [SweepOutcome],
        freeSpaceDeltaBytes: Int64? = nil, requiresEmptyingTrash: Bool? = nil, unselectedIDs: [String] = []
    ) {
        self.executed = executed
        self.mode = mode
        self.root = root
        self.receipt = receipt
        self.items = items
        self.freeSpaceDeltaBytes = freeSpaceDeltaBytes
        self.requiresEmptyingTrash = requiresEmptyingTrash
        self.unselectedIDs = unselectedIDs
    }
}

extension SweepApplyResult: Encodable {
    private enum CodingKeys: String, CodingKey {
        case executed, mode, root, receipt, items
        case freeSpaceDeltaBytes = "free_space_delta_bytes"
        case requiresEmptyingTrash = "requires_emptying_trash"
        case unselectedIDs = "unselected_ids"
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(executed, forKey: .executed)
        try values.encode(mode, forKey: .mode)
        try values.encode(root, forKey: .root)
        try values.encode(receipt, forKey: .receipt)
        try values.encode(items, forKey: .items)
        try values.encodeIfPresent(freeSpaceDeltaBytes, forKey: .freeSpaceDeltaBytes)
        try values.encodeIfPresent(requiresEmptyingTrash, forKey: .requiresEmptyingTrash)
        try values.encode(unselectedIDs, forKey: .unselectedIDs)
    }
}

public struct SweepRestoreResult: Encodable, Sendable {
    public var executed: Bool
    public var receipt: String
    public var root: String
    public var items: [SweepOutcome]

    public var incomplete: Bool { items.contains { $0.status.isFailure } }
}

/// 某一次执行里还留在暂存位置、可以放回的内容。给界面列「可放回」用。
public struct SweepPendingRun: Sendable, Hashable, Identifiable {
    public struct Item: Sendable, Hashable, Identifiable {
        public var id: String
        /// 相对于扫描根的原路径
        public var path: String
        public var bytes: Int64

        public init(id: String, path: String, bytes: Int64) {
            self.id = id
            self.path = path
            self.bytes = bytes
        }
    }

    public var id: String { runID }
    public var runID: String
    /// 回执文件
    public var receipt: String
    public var root: String
    public var mode: SweepMode
    public var createdAt: Date
    public var items: [Item]

    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    public init(runID: String, receipt: String, root: String, mode: SweepMode, createdAt: Date, items: [Item]) {
        self.runID = runID
        self.receipt = receipt
        self.root = root
        self.mode = mode
        self.createdAt = createdAt
        self.items = items
    }
}
