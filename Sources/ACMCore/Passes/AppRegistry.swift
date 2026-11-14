import Foundation

/// 已安装的桌面 App。只用于判断归属——桌面 App 本身不在管理范围内。
public enum AppRegistry {
    public static func scan(_ env: HostEnvironment) -> [AppInfo] {
        var out: [AppInfo] = []
        var seen = Set<String>()
        for dir in env.appDirs {
            for entry in FileProbe.list(dir) where entry.hasSuffix(".app") {
                let path = dir + "/" + entry
                guard seen.insert(PathUtil.key(path)).inserted,
                      let info = infoPlist(path),
                      let bundleID = info["CFBundleIdentifier"] as? String
                else { continue }
                out.append(AppInfo(name: String(entry.dropLast(4)), bundleID: bundleID, path: path))
            }
        }
        return out
    }

    /// Info.plist 里登记的其他名字（Finder 里显示的文件名之外）。
    static func declaredNames(_ app: AppInfo) -> [String] {
        guard let info = infoPlist(app.path) else { return [] }
        return ["CFBundleDisplayName", "CFBundleName"].compactMap { info[$0] as? String }
    }

    static func infoPlist(_ appPath: String) -> [String: Any]? {
        let url = URL(fileURLWithPath: appPath + "/Contents/Info.plist")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

/// 按 bundle id 精确查，或按名称推测某个路径是不是已装 App 的。
public struct AppKeyIndex: Sendable {
    private var byBundleID: [String: AppInfo] = [:]
    private var byKey: [String: AppInfo] = [:]

    public init(apps: [AppInfo]) {
        for app in apps {
            byBundleID[app.bundleID.lowercased()] = app
            var keys = [PathUtil.nameKey(app.name)]
            keys += AppRegistry.declaredNames(app).map { PathUtil.nameKey($0) }
            keys += PathUtil.bundleIDTokens(app.bundleID)
            for key in keys where key.count >= 3 && !PathUtil.bundleIDStopWords.contains(key) && byKey[key] == nil {
                byKey[key] = app
            }
        }
    }

    /// 确定的证据：bundle id 完全一致。
    public func exact(bundleID: String) -> AppInfo? {
        byBundleID[bundleID.lowercased()]
    }

    /// 推测的证据：名字像。只用来把条目往「保守」的方向推（当成 App 在用），
    /// 永远不会因此把什么东西判成可删。
    ///
    /// `allowPrefix` 关掉时只认整名相同或首词相同。前缀匹配会把 `codexbar` 算成 `codex`，
    /// 用来推翻目录清单的明确声明就太弱了。
    public func match(name: String, allowPrefix: Bool = true) -> (app: AppInfo, reason: String)? {
        let whole = PathUtil.nameKey(name)
        guard whole.count >= 3 else { return nil }
        if let app = byKey[whole] {
            return (app, "名称与 \(app.name) 一致")
        }
        if let first = PathUtil.nameTokens(name).first, first.count >= 3, let app = byKey[first] {
            return (app, "名称以 \(app.name) 开头")
        }
        guard allowPrefix else { return nil }
        var best: (key: String, app: AppInfo)?
        for (key, app) in byKey where key.count >= 5 && whole.hasPrefix(key) {
            if best == nil || key.count > best!.key.count { best = (key, app) }
        }
        if let best { return (best.app, "名称以 \(best.app.name) 开头") }
        return nil
    }
}
