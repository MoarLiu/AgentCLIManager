import Foundation

/// 归属结论。这是「这个路径是谁的」的唯一表达。
public enum Claim: String, Codable, Sendable {
    /// 属于某个已安装 CLI 的组成部分
    case ownedByCLI
    /// 被 CLI 和同厂桌面 App 共用
    case shared
    /// 由已安装的桌面 App 使用（不在管理范围）
    case usedByApp
    /// 主人已经不在了，只剩文件
    case residue
    /// 有证据但不够确定，交给用户判断
    case candidate
    /// 没有可靠证据
    case unknown

    public var displayName: String {
        switch self {
        case .ownedByCLI: return "已装 CLI 的组成部分"
        case .shared: return "与桌面 App 共用"
        case .usedByApp: return "由桌面 App 使用"
        case .residue: return "残留"
        case .candidate: return "疑似"
        case .unknown: return "未知"
        }
    }
}

/// 证据强度。只有 `certain` 才可能让条目被默认勾选。
public enum Strength: String, Codable, Sendable, Comparable {
    case speculative
    case probable
    case certain

    private var rank: Int {
        switch self {
        case .speculative: return 0
        case .probable: return 1
        case .certain: return 2
        }
    }

    public static func < (a: Strength, b: Strength) -> Bool { a.rank < b.rank }
}

public struct Evidence: Codable, Sendable, Hashable {
    public var kind: String
    public var detail: String
    public var strength: Strength

    public init(_ kind: String, _ detail: String, _ strength: Strength) {
        self.kind = kind
        self.detail = detail
        self.strength = strength
    }
}

public enum ArtifactFlag: String, Codable, Sendable, CaseIterable {
    /// 与已装的桌面 App 共用
    case shared
    /// 正被进程使用
    case inUse
    /// 含登录凭据
    case credentials
    /// 最近有写入
    case recentlyModified
    /// 家目录顶层的目录
    case topLevelRoot
    /// 属主是 root，需要管理员
    case rootOwned
    /// 悬空软链
    case danglingSymlink
    /// 启动脚本指向的程序已不存在
    case brokenShim
    /// 入口指向的不是可执行程序（例如指向一个目录）
    case invalidLauncher
    /// 别的工具的命令也通过这个程序启动
    case usedByOthers
    /// 由包管理器托管，应交给包管理器卸载
    case packageManaged
    /// 只给命令，不由本 App 删除
    case manualOnly
    /// 路径护栏拒绝删除
    case notRemovable
    /// 大小没量全（有读不到的子目录）
    case partialSize

    public var displayName: String {
        switch self {
        case .shared: return "与桌面 App 共用"
        case .inUse: return "正在使用"
        case .credentials: return "含登录凭据"
        case .recentlyModified: return "最近有写入"
        case .topLevelRoot: return "顶层目录"
        case .rootOwned: return "需要管理员"
        case .danglingSymlink: return "悬空软链"
        case .brokenShim: return "启动脚本已失效"
        case .invalidLauncher: return "入口异常"
        case .usedByOthers: return "其他命令也在用"
        case .packageManaged: return "由包管理器托管"
        case .manualOnly: return "需手工卸载"
        case .notRemovable: return "不可删除"
        case .partialSize: return "大小未量全"
        }
    }
}

public struct SizeResult: Codable, Sendable, Hashable {
    public var bytes: Int64
    /// false 表示有读不到的子目录，数字只是下界。
    public var accurate: Bool

    public init(bytes: Int64, accurate: Bool) {
        self.bytes = bytes
        self.accurate = accurate
    }

    public var display: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        let s = formatter.string(fromByteCount: bytes)
        return accurate ? s : "≥ " + s
    }
}

/// 位于某个条目之内、却属于另一个组的东西。移走外层目录会把它一并带走，
/// 所以要让规划器和界面都看得见。
public struct ForeignChild: Codable, Sendable, Hashable {
    public var path: String
    /// 它属于谁：桌面 App 的名字，或另一个工具组的名字
    public var owner: String
    /// 由已安装的桌面 App 使用
    public var usedByApp: Bool
    /// 归属是确定的（否则只是推测）
    public var certain: Bool

    public init(path: String, owner: String, usedByApp: Bool, certain: Bool) {
        self.path = path
        self.owner = owner
        self.usedByApp = usedByApp
        self.certain = certain
    }

    /// 确定由桌面 App 使用：外层目录不允许整个移走。
    public var blocksRemoval: Bool { usedByApp && certain }
}

public struct Artifact: Codable, Sendable, Identifiable, Hashable {
    public var path: String
    public var kind: ArtifactKind
    public var claim: Claim
    public var strength: Strength
    public var evidence: [Evidence]
    public var flags: Set<ArtifactFlag>
    public var lastModified: Date?
    public var isDirectory: Bool
    public var isSymlink: Bool
    /// 目录可展开一层查看子项。
    public var expandable: Bool
    public var size: SizeResult?
    public var defaultSelected: Bool
    public var notRemovableReason: String?
    /// `claim == .usedByApp` 时是哪个 App。
    public var ownerAppName: String?
    /// 目录清单里声明的原始写法（`~/.claude`），有的话显示这个。
    public var declaredPath: String?
    public var productID: String?
    public var note: String?
    /// 目录清单声明该路径由这个产品独占。
    public var declaredExclusive: Bool = false
    /// 由界面「展开一层」产生的子项，指向它的上级条目。
    public var parentPath: String?
    /// 这个目录里属于其他组的条目（见 `ForeignChild`）。
    public var foreignChildren: [ForeignChild] = []
    /// `usedByOthers` 时：还有哪些别的命令靠它启动。
    public var alsoUsedBy: [String] = []

    public var id: String { path }

    public init(
        path: String,
        kind: ArtifactKind,
        claim: Claim,
        strength: Strength,
        evidence: [Evidence] = [],
        flags: Set<ArtifactFlag> = [],
        lastModified: Date? = nil,
        isDirectory: Bool = false,
        isSymlink: Bool = false,
        expandable: Bool = false,
        size: SizeResult? = nil,
        defaultSelected: Bool = false,
        notRemovableReason: String? = nil,
        ownerAppName: String? = nil,
        declaredPath: String? = nil,
        productID: String? = nil,
        note: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.claim = claim
        self.strength = strength
        self.evidence = evidence
        self.flags = flags
        self.lastModified = lastModified
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.expandable = expandable
        self.size = size
        self.defaultSelected = defaultSelected
        self.notRemovableReason = notRemovableReason
        self.ownerAppName = ownerAppName
        self.declaredPath = declaredPath
        self.productID = productID
        self.note = note
    }

    public func display(home: String) -> String {
        declaredPath ?? PathUtil.display(path, home: home)
    }
}
