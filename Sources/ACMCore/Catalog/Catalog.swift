import Foundation

/// 一个文件/目录在界面上属于哪一类。
public enum ArtifactKind: String, Codable, Sendable, CaseIterable {
    case program
    case launcher
    case config
    case data
    case cache
    case logs
    case credentials
    case other

    public var displayName: String {
        switch self {
        case .program: return "程序本体"
        case .launcher: return "启动链接"
        case .config: return "配置"
        case .data: return "数据"
        case .cache: return "缓存"
        case .logs: return "日志"
        case .credentials: return "登录凭据"
        case .other: return "其他"
        }
    }

    /// 界面上的分节顺序。
    public var order: Int {
        switch self {
        case .program: return 0
        case .launcher: return 1
        case .cache: return 2
        case .logs: return 3
        case .data: return 4
        case .config: return 5
        case .credentials: return 6
        case .other: return 7
        }
    }
}

/// 目录清单里的一条路径声明。
public struct CatalogPath: Codable, Sendable, Hashable {
    public var path: String
    public var kind: ArtifactKind
    /// 该路径同时被厂商的桌面 App 使用。装了那个 App 时不得删除。
    public var shared: Bool?
    /// 该路径由这个产品独占，家目录顶层的目录也只有声明了独占才会被默认勾选。
    public var exclusive: Bool?
    public var note: String?
}

public struct InstallMethod: Codable, Sendable, Hashable {
    public var channel: String
    public var command: String
    public var note: String?
}

public enum ProductKind: String, Codable, Sendable {
    /// 命令行工具，属于管理范围。
    case cli
    /// 桌面 App，不管理；只用来解释它占用的目录为什么不在列表里。
    case app
}

public struct CatalogProduct: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var vendor: String?
    public var homepage: String?
    public var docs: String?
    public var kind: ProductKind
    public var binaries: [String]?
    public var packages: [String]?
    /// `kind == .app` 时是自己的 bundle id；`kind == .cli` 时是共用数据的同厂 App。
    public var companionApps: [String]?
    public var bundleIDs: [String]?
    public var teamIDs: [String]?
    public var codeIdentifiers: [String]?
    /// 读取版本号的文件（有些安装器把当前版本写在一个文件里）。
    public var versionFile: String?
    public var paths: [CatalogPath]?
    public var install: [InstallMethod]?
    public var uninstallCommand: String?
    public var note: String?

    public var allBundleIDs: [String] { (bundleIDs ?? []) + (companionApps ?? []) }
}

public struct Catalog: Codable, Sendable {
    public var schemaVersion: Int
    public var products: [CatalogProduct]

    public static let supportedSchemaVersion = 1

    public init(schemaVersion: Int = Catalog.supportedSchemaVersion, products: [CatalogProduct]) {
        self.schemaVersion = schemaVersion
        self.products = products
    }

    public enum LoadError: Error, CustomStringConvertible {
        case unsupportedSchema(Int)
        case duplicateProductID(String)

        public var description: String {
            switch self {
            case .unsupportedSchema(let v): return "目录清单 schemaVersion \(v) 不是本版支持的 \(Catalog.supportedSchemaVersion)"
            case .duplicateProductID(let id): return "目录清单里出现重复的产品 id：\(id)"
            }
        }
    }

    public static func decode(_ data: Data) throws -> Catalog {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.schemaVersion == supportedSchemaVersion else {
            throw LoadError.unsupportedSchema(catalog.schemaVersion)
        }
        var seen = Set<String>()
        for p in catalog.products {
            guard seen.insert(p.id).inserted else { throw LoadError.duplicateProductID(p.id) }
        }
        return catalog
    }

    /// 先出现的优先；后面的只补充新的产品 id。内置清单在前，用户补充文件在后。
    public static func merge(_ catalogs: [Catalog]) -> Catalog {
        var out: [CatalogProduct] = []
        var seen = Set<String>()
        for c in catalogs {
            for p in c.products where !seen.contains(p.id) {
                seen.insert(p.id)
                out.append(p)
            }
        }
        return Catalog(products: out)
    }

    /// 内置清单（编译进二进制，见 scripts/embed-catalog.sh）。
    public static func loadBuiltin() -> Catalog {
        var parts: [Catalog] = []
        for json in BuiltinCatalogData.jsonParts {
            guard let data = json.data(using: .utf8) else { continue }
            if let c = try? decode(data) { parts.append(c) }
        }
        return merge(parts)
    }

    /// 用户补充文件：`~/Library/Application Support/AgentCLIManager/catalog.json`。
    public static func loadUserOverride(home: String) -> Catalog? {
        let path = PathUtil.expand("~/Library/Application Support/AgentCLIManager/catalog.json", home: home)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? decode(data)
    }

    public static func loadAll(env: HostEnvironment) -> Catalog {
        var parts = [loadBuiltin()]
        if let user = loadUserOverride(home: env.home) { parts.append(user) }
        return merge(parts)
    }

    public func product(id: String) -> CatalogProduct? {
        products.first { $0.id == id }
    }

    public func product(matchingBinary name: String) -> CatalogProduct? {
        products.first { ($0.binaries ?? []).contains(name) }
    }

    public func product(matchingCodeIdentifier identifier: String) -> CatalogProduct? {
        products.first { ($0.codeIdentifiers ?? []).contains(identifier) }
    }

    public func product(matchingBundleID bundleID: String) -> CatalogProduct? {
        products.first { $0.allBundleIDs.contains(bundleID) }
    }

    /// 该路径是否被某条目录声明覆盖（等于它或位于它之下）。
    public func claim(for path: String, home: String) -> (product: CatalogProduct, declared: CatalogPath, exact: Bool)? {
        // 取最具体（最长）的那条声明：`~/.grok/auth.json` 优先于 `~/.grok`。
        var best: (CatalogProduct, CatalogPath, Bool)?
        var bestLength = -1
        for product in products {
            for declared in product.paths ?? [] {
                let root = PathUtil.expand(declared.path, home: home)
                guard PathUtil.isInside(path, root) else { continue }
                let length = PathUtil.key(root).count
                if length > bestLength {
                    bestLength = length
                    best = (product, declared, PathUtil.key(path) == PathUtil.key(root))
                }
            }
        }
        guard let b = best else { return nil }
        return (b.0, b.1, b.2)
    }
}
