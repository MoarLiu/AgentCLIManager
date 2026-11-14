import Foundation

public enum Section: String, Codable, Sendable, CaseIterable {
    case installed
    case residue
    case unidentified
    case otherCLI
    case managedByApp

    public var displayName: String {
        switch self {
        case .installed: return "已安装"
        case .residue: return "仅残留"
        case .unidentified: return "未识别"
        case .otherCLI: return "其他 CLI"
        case .managedByApp: return "由桌面 App 使用"
        }
    }

    public var order: Int {
        switch self {
        case .installed: return 0
        case .residue: return 1
        case .unidentified: return 2
        case .otherCLI: return 3
        case .managedByApp: return 4
        }
    }
}

/// 安装渠道，决定程序本体该由谁卸载。
public enum Channel: String, Codable, Sendable {
    /// 厂商自己的安装器，装在厂商自己的目录里
    case vendor
    case npm
    case pnpm
    case bun
    case brew
    case uv
    case pipx
    case cargo
    case go
    /// 随桌面 App 提供
    case appProvided
    /// 直接放在 bin 目录里的单个二进制
    case standalone
    case unknown

    public var displayName: String {
        switch self {
        case .vendor: return "厂商安装器"
        case .npm: return "npm"
        case .pnpm: return "pnpm"
        case .bun: return "bun"
        case .brew: return "Homebrew"
        case .uv: return "uv"
        case .pipx: return "pipx"
        case .cargo: return "cargo"
        case .go: return "go install"
        case .appProvided: return "随 App 提供"
        case .standalone: return "独立二进制"
        case .unknown: return "未知渠道"
        }
    }
}

public struct BinaryInfo: Codable, Sendable, Hashable {
    public var name: String
    /// bin 目录里的那个入口
    public var path: String
    /// 从入口到最终目标的完整链路，含首尾
    public var chain: [String]
    public var finalTarget: String?
    public var isDangling: Bool
    /// 启动脚本里 exec 的那个已不存在的目标
    public var brokenShimTarget: String?
    public var signIdentifier: String?
    public var teamID: String?
    public var payloadRoot: String?
    public var channel: Channel
    public var version: String?
    public var packageName: String?
    public var inSystemDir: Bool
    public var binDirSource: String
    /// 入口最终指向的不是可执行程序时，说明它是什么（「一个目录」等）
    public var invalidTarget: String? = nil

    public var isBroken: Bool { isDangling || brokenShimTarget != nil || invalidTarget != nil }
}

public struct RcLine: Codable, Sendable, Hashable {
    public var file: String
    public var line: Int
    public var text: String
}

public struct AppInfo: Codable, Sendable, Hashable {
    public var name: String
    public var bundleID: String
    public var path: String
}

public struct ToolGroup: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var vendor: String?
    public var section: Section
    public var productID: String?
    public var binaries: [BinaryInfo]
    public var version: String?
    public var channel: Channel?
    public var artifacts: [Artifact]
    public var rcLines: [RcLine]
    /// 交给用户自己执行的命令（brew 卸载、需要 sudo 的清理等）
    public var manualCommands: [String]
    public var notes: [String]
    /// `section == .managedByApp` 时是占用它的 App
    public var ownerApps: [AppInfo]
    public var runningPIDs: [Int32]
    public var docs: String?
    public var homepage: String?
    public var installMethods: [InstallMethod]
    public var uninstallCommand: String?

    public init(
        id: String,
        name: String,
        vendor: String? = nil,
        section: Section,
        productID: String? = nil,
        binaries: [BinaryInfo] = [],
        version: String? = nil,
        channel: Channel? = nil,
        artifacts: [Artifact] = [],
        rcLines: [RcLine] = [],
        manualCommands: [String] = [],
        notes: [String] = [],
        ownerApps: [AppInfo] = [],
        runningPIDs: [Int32] = [],
        docs: String? = nil,
        homepage: String? = nil,
        installMethods: [InstallMethod] = [],
        uninstallCommand: String? = nil
    ) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.section = section
        self.productID = productID
        self.binaries = binaries
        self.version = version
        self.channel = channel
        self.artifacts = artifacts
        self.rcLines = rcLines
        self.manualCommands = manualCommands
        self.notes = notes
        self.ownerApps = ownerApps
        self.runningPIDs = runningPIDs
        self.docs = docs
        self.homepage = homepage
        self.installMethods = installMethods
        self.uninstallCommand = uninstallCommand
    }

    public var isRunning: Bool { !runningPIDs.isEmpty }

    /// 可勾选、会被真正移走的条目。
    public var removableArtifacts: [Artifact] {
        artifacts.filter { !$0.flags.contains(.notRemovable) }
    }

    /// 不被同组其他条目包含的条目。算总量时只数这些，否则 `~/.grok` 和
    /// `~/.grok/downloads` 会被重复计数。
    public var outermostArtifacts: [Artifact] {
        ToolGroup.outermost(artifacts)
    }

    public static func outermost(_ items: [Artifact]) -> [Artifact] {
        items.filter { a in
            !items.contains { b in b.path != a.path && PathUtil.isStrictlyInside(a.path, b.path) }
        }
    }

    /// 总占用。有任何一项没量全时 `accurate == false`，数字只是下界。
    public var totalSize: SizeResult? {
        ToolGroup.totalSize(of: artifacts)
    }

    public static func totalSize(of items: [Artifact]) -> SizeResult? {
        let outer = outermost(items)
        guard outer.contains(where: { $0.size != nil }) else { return nil }
        var bytes: Int64 = 0
        var accurate = true
        for a in outer {
            guard let s = a.size else { accurate = false; continue }
            bytes += s.bytes
            if !s.accurate { accurate = false }
        }
        return SizeResult(bytes: bytes, accurate: accurate)
    }
}

public struct ScanReport: Codable, Sendable {
    public var scannedAt: Date
    public var groups: [ToolGroup]
    public var binDirs: [String]
    public var notes: [String]
    public var diskFreeBytes: Int64?
    public var diskTotalBytes: Int64?

    public init(
        scannedAt: Date,
        groups: [ToolGroup],
        binDirs: [String] = [],
        notes: [String] = [],
        diskFreeBytes: Int64? = nil,
        diskTotalBytes: Int64? = nil
    ) {
        self.scannedAt = scannedAt
        self.groups = groups
        self.binDirs = binDirs
        self.notes = notes
        self.diskFreeBytes = diskFreeBytes
        self.diskTotalBytes = diskTotalBytes
    }

    public func groups(in section: Section) -> [ToolGroup] {
        groups.filter { $0.section == section }
    }
}
