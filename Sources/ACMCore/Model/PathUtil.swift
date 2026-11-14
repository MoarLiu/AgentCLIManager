import Foundation

/// 路径字符串工具。引擎内部一律用字符串比较路径，URL 只在真正访问文件系统时使用。
///
/// 所有比较都用「归一化比较键」：小写 + NFC 组合形式，这样在默认的大小写不敏感、
/// 可能存 NFD 中文文件名的 APFS 上不会漏判。
public enum PathUtil {

    /// 展开开头的 `~`，并做词法归一化（去掉 `.`、`..`、重复斜杠）。不解析软链。
    public static func expand(_ path: String, home: String) -> String {
        var p = path
        if p == "~" { p = home }
        else if p.hasPrefix("~/") { p = home + String(p.dropFirst(1)) }
        return standardize(p)
    }

    /// 词法归一化：绝对化、去 `.`/`..`/重复斜杠、去尾部斜杠。不解析软链。
    public static func standardize(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        var out: [String] = []
        let isAbsolute = path.hasPrefix("/")
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." {
                if let last = out.last, last != ".." { out.removeLast() } else if !isAbsolute { out.append("..") }
                continue
            }
            out.append(String(comp))
        }
        let joined = out.joined(separator: "/")
        return isAbsolute ? "/" + joined : joined
    }

    /// 去掉 macOS 数据卷的 firmlink 前缀。带这个前缀的家目录路径与不带的
    /// 指向同一位置，但前者不是软链，`resolvingSymlinksInPath` 也不会折叠它。
    public static func stripDataVolumePrefix(_ path: String) -> String {
        let prefix = "/System/Volumes/Data"
        if path == prefix { return "/" }
        if path.hasPrefix(prefix + "/") { return String(path.dropFirst(prefix.count)) }
        return path
    }

    /// 比较键：小写 + NFC。用于一切「是不是同一个地方」的判断。
    public static func key(_ path: String) -> String {
        stripDataVolumePrefix(standardize(path))
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    /// `path` 是否等于 `root` 或位于 `root` 之下。
    public static func isInside(_ path: String, _ root: String) -> Bool {
        let p = key(path), r = key(root)
        if p == r { return true }
        return p.hasPrefix(r == "/" ? "/" : r + "/")
    }

    /// 是否严格位于 `root` 之下（不含 root 本身）。
    public static func isStrictlyInside(_ path: String, _ root: String) -> Bool {
        let p = key(path), r = key(root)
        return p != r && p.hasPrefix(r == "/" ? "/" : r + "/")
    }

    public static func parent(_ path: String) -> String {
        (standardize(path) as NSString).deletingLastPathComponent
    }

    public static func lastComponent(_ path: String) -> String {
        (standardize(path) as NSString).lastPathComponent
    }

    public static func components(_ path: String) -> [String] {
        standardize(path).split(separator: "/").map(String.init)
    }

    /// 家目录内显示成 `~/...`，否则原样。
    public static func display(_ path: String, home: String) -> String {
        let p = standardize(path)
        if p == home { return "~" }
        if isStrictlyInside(p, home) { return "~" + String(p.dropFirst(home.count)) }
        return p
    }

    /// 归一化名称：只保留字母数字，用于「这个名字像不像那个名字」的推测。
    public static func nameKey(_ name: String) -> String {
        var s = name
        while s.hasPrefix(".") { s = String(s.dropFirst()) }
        if s.hasSuffix(".json") { s = String(s.dropLast(5)) }
        return String(s.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    /// 按 `-` `_` `.` 空格切成词，用于「首词相同」这类较弱但要覆盖 `qoder-cn` 的匹配。
    public static func nameTokens(_ name: String) -> [String] {
        var s = name
        while s.hasPrefix(".") { s = String(s.dropFirst()) }
        if s.hasSuffix(".json") { s = String(s.dropLast(5)) }
        return s.split(whereSeparator: { "-_. ".contains($0) })
            .map { PathUtil.nameKey(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// 去掉 `com.foo.bar` 这类 bundle id 的常见无信息成分，留下可用于比对的词。
    public static let bundleIDStopWords: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "apps", "mac", "macos", "osx", "desktop",
        "stable", "beta", "insider", "www", "global", "client", "core", "main", "work",
        "tool", "tools", "cli", "studio", "ide", "code", "editor", "ai", "inc", "ltd", "tech",
    ]

    /// 从 bundle id 里取出能代表「产品」的词。
    ///
    /// `com.tencent.workbuddy.mac` → `workbuddy`；`dev.zcode.app` → `zcode`。
    /// 厂商那一段（`tencent`、`google`、`openai`）只在后面没有别的有效词时才保留：
    /// 用厂商名去匹配目录会把 `~/.config/google-chrome` 算到 Antigravity 头上。
    public static func bundleIDTokens(_ bundleID: String) -> [String] {
        let parts = bundleID.split(separator: ".").map { nameKey(String($0)) }
        guard parts.count >= 2 else { return [] }
        let meaningful = parts.dropFirst().filter { $0.count >= 3 && !bundleIDStopWords.contains($0) }
        if meaningful.count >= 2 { return Array(meaningful.dropFirst()) }
        return Array(meaningful)
    }
}
