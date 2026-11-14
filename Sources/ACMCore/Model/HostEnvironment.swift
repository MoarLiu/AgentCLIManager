import Foundation

/// 签名信息。厂商二进制通常带稳定的标识符与团队 ID，是比文件名可靠的归属证据。
public struct CodeSignInfo: Sendable, Codable, Hashable {
    public var identifier: String?
    public var teamID: String?
    public init(identifier: String?, teamID: String?) {
        self.identifier = identifier
        self.teamID = teamID
    }
}

/// 扫描所需的全部外部输入。引擎不直接读取真实环境，测试时注入一个临时目录即可。
public struct HostEnvironment: Sendable {
    public var home: String
    /// 应用所在目录，只用于识别已装的桌面 App（不属于管理范围，只用来判断归属）。
    public var appDirs: [String]
    /// 系统级 bin 目录：只按目录清单里的名字收录，避免把几百个 brew 工具都列出来。
    public var systemBinDirs: [String]
    /// 当前日期，用于「最近有无写入」的判断。
    public var now: Date
    /// 本 App 自身的路径，路径护栏会拒绝任何与它相关的位置。
    public var selfPaths: [String]
    /// 最近写入窗口：窗口内改动过的目录不会被判成残留。
    public var recentWindow: TimeInterval
    /// 是否扫描 ~/Library 下的数据（Containers 类目录另需用户手动加载，永不自动扫）。
    public var includeLibrary: Bool
    /// 签名探测；测试里置空。
    public var signProbe: (@Sendable (String) -> CodeSignInfo?)?
    /// 废纸篓所在的目录。「放回原处」只接受来源确实在这些目录里的回执。
    public var trashDirs: [String]

    public init(
        home: String,
        appDirs: [String] = [],
        systemBinDirs: [String] = ["/opt/homebrew/bin", "/usr/local/bin"],
        now: Date = Date(),
        selfPaths: [String] = [],
        recentWindow: TimeInterval = 14 * 24 * 3600,
        includeLibrary: Bool = true,
        signProbe: (@Sendable (String) -> CodeSignInfo?)? = nil,
        trashDirs: [String]? = nil
    ) {
        self.home = PathUtil.standardize(home)
        self.appDirs = appDirs.map { PathUtil.standardize($0) }
        self.systemBinDirs = systemBinDirs.map { PathUtil.standardize($0) }
        self.now = now
        self.selfPaths = selfPaths.map { PathUtil.standardize($0) }
        self.recentWindow = recentWindow
        self.includeLibrary = includeLibrary
        self.signProbe = signProbe
        self.trashDirs = (trashDirs ?? [PathUtil.standardize(home) + "/.Trash"]).map { PathUtil.standardize($0) }
    }

    public var library: String { home + "/Library" }
    public var appSupport: String { library + "/Application Support" }

    /// 本 App 自己的数据目录。
    public var ownSupportDir: String { appSupport + "/AgentCLIManager" }
    public var userCatalogPath: String { ownSupportDir + "/catalog.json" }

    // MARK: - 组装真实环境
    //
    // 这是唯一允许接触真实家目录的地方，单元测试会检查其他文件不出现同类调用。

    public static func live() -> HostEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let selfPaths = [
            Bundle.main.bundleURL.path,
            home + "/Library/Application Support/AgentCLIManager",
        ]
        return HostEnvironment(
            home: home,
            appDirs: ["/Applications", "/Applications/Utilities", home + "/Applications"],
            systemBinDirs: ["/opt/homebrew/bin", "/usr/local/bin"],
            now: Date(),
            selfPaths: selfPaths,
            signProbe: CodeSignProbe.probe
        )
    }
}
