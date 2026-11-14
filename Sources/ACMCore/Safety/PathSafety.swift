import Foundation

/// 删除前的最后一道闸。每一个要移走的路径都必须过这里，生成计划时查一次，执行前再查一次。
///
/// 做法是白名单而不是黑名单：只有三类位置允许清理——
///   1. 家目录下的点条目（`~/.foo`）及其内部
///   2. `~/Library/<允许的类别>/` 的子项及其内部
///   3. 以上位置里的任意深度
/// 其余一律拒绝，再叠加一份受保护清单。
public enum PathSafety {

    public struct Decision: Sendable, Equatable {
        public var allowed: Bool
        public var reason: String?

        public static let ok = Decision(allowed: true, reason: nil)
        static func deny(_ reason: String) -> Decision { Decision(allowed: false, reason: reason) }
    }

    /// 本身不可删的位置（家目录相对路径）。它们的上级自然也不可删。
    static let protectedEntries: [String] = [
        ".Trash", ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".netrc",
        ".config", ".cache", ".local", ".local/bin", ".local/share", ".local/state", ".local/lib",
        ".npm", ".nvm", ".cargo", ".rustup", ".agents",
        ".gitconfig", ".git-credentials",
        ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zsh_history", ".zsh_sessions",
        ".profile", ".bashrc", ".bash_profile", ".bash_history",
        ".CFUserTextEncoding",
    ]

    /// 内部任何东西都不可删的位置。
    static let sealedEntries: [String] = [
        ".Trash", ".ssh", ".gnupg", ".aws", ".azure", ".kube",
    ]

    /// `~/Library` 下允许清理其子项的类别。
    static let libraryCategories: [String] = [
        "Application Support", "Caches", "Logs", "Preferences", "WebKit", "HTTPStorages",
        "Saved Application State",
    ]

    public static func check(_ rawPath: String, env: HostEnvironment) -> Decision {
        guard rawPath.hasPrefix("/") else { return .deny("不是绝对路径") }
        if rawPath.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
            return .deny("路径里含有 ..")
        }
        let lexical = PathUtil.stripDataVolumePrefix(PathUtil.standardize(rawPath))
        let leaf = PathUtil.lastComponent(lexical)
        guard !leaf.isEmpty, lexical != "/" else { return .deny("路径为空") }

        // 父目录解析软链，叶子不解析：要移走的是这个条目本身（哪怕它是软链），
        // 但它「实际在哪」必须按真实父目录算，否则软链能把删除引到家目录之外。
        let resolved = PathUtil.standardize(realPath(PathUtil.parent(lexical)) + "/" + leaf)
        let homes = [env.home, realPath(env.home)]

        for candidate in [lexical, resolved] {
            if let reason = violation(candidate, homes: homes, env: env) {
                return .deny(reason)
            }
        }
        return .ok
    }

    static func realPath(_ path: String) -> String {
        PathUtil.stripDataVolumePrefix(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    private static func violation(_ candidate: String, homes: [String], env: HostEnvironment) -> String? {
        guard let home = homes.first(where: { PathUtil.isStrictlyInside(candidate, $0) }) else {
            return "不在家目录之内"
        }
        let rel = PathUtil.components(String(PathUtil.standardize(candidate).dropFirst(PathUtil.standardize(home).count)))
        guard let first = rel.first else { return "不能删除家目录本身" }
        let relKey = rel.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()

        if first.lowercased() == "library" {
            guard rel.count >= 3,
                  libraryCategories.contains(where: { $0.lowercased() == rel[1].lowercased() })
            else { return "~/Library 里只清理 Application Support、Caches 等目录的子项" }
        } else if !first.hasPrefix(".") {
            return "家目录下的普通文件夹不在清理范围内"
        }

        for entry in protectedEntries {
            let key = entry.lowercased()
            if relKey == key || key.hasPrefix(relKey + "/") {
                return "受保护的位置 ~/" + entry
            }
        }
        for entry in sealedEntries {
            if relKey.hasPrefix(entry.lowercased() + "/") {
                return "位于受保护的目录 ~/" + entry + " 之内"
            }
        }
        for own in env.selfPaths {
            for variant in [own, realPath(own)] where !variant.isEmpty && variant != "/" {
                if PathUtil.isInside(variant, candidate) || PathUtil.isInside(candidate, variant) {
                    return "属于本 App 自身"
                }
            }
        }
        return nil
    }
}
