import Foundation

public struct DotEntry: Sendable, Hashable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var isDangling: Bool
    public var symlinkTarget: String?
    /// 第一层子项的名字，用于内容标记判断
    public var children: [String]
    /// 是否直接位于家目录下
    public var topLevel: Bool
    /// 所在容器的家目录相对路径：`""`、`.config`、`.cache`、`.local/share`、`.local/state`
    public var container: String
}

/// 列出可能属于 Agent 工具的位置：家目录顶层的点条目，以及 XDG 目录的直接子项。
public enum DotRootScanner {
    public static let xdgContainers = [".config", ".cache", ".local/share", ".local/state"]

    /// 明确不是 Agent 工具的条目。列在这里的即使内容碰巧像，也不会出现在界面上。
    public static let ignoredTopLevel: Set<String> = [
        ".Trash", ".DS_Store", ".CFUserTextEncoding", ".localized",
        ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".netrc",
        ".config", ".cache", ".local",
        ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".zsh_history", ".zsh_sessions",
        ".zcompdump", ".profile", ".bashrc", ".bash_profile", ".bash_login", ".bash_history",
        ".bash_sessions", ".tcshrc", ".cshrc", ".inputrc", ".hushlogin", ".oh-my-zsh", ".p10k.zsh",
        ".gitconfig", ".gitignore", ".gitignore_global", ".git-credentials", ".gitattributes",
        ".npm", ".npmrc", ".nvm", ".node_repl_history", ".yarn", ".yarnrc", ".pnpm-state", ".bun",
        ".deno", ".volta", ".cargo", ".rustup", ".swiftpm", ".cocoapods", ".gradle", ".m2",
        ".android", ".pyenv", ".rbenv", ".gem", ".bundle", ".conda", ".condarc", ".ipython",
        ".jupyter", ".python_history", ".matplotlib", ".keras", ".terraform.d", ".vagrant.d",
        ".vscode", ".vim", ".viminfo", ".vimrc", ".emacs.d", ".lesshst", ".wget-hsts", ".tmux.conf",
        ".sqlite_history", ".psql_history", ".mysql_history", ".rediscli_history", ".cups",
        ".agents",
    ]

    public static func scan(env: HostEnvironment) -> [DotEntry] {
        var out: [DotEntry] = []

        for name in FileProbe.list(env.home) where name.hasPrefix(".") {
            if ignoredTopLevel.contains(name) || name.hasPrefix(".zcompdump") || name.hasPrefix(".zshrc.") { continue }
            if let entry = makeEntry(env.home + "/" + name, name: name, topLevel: true, container: "") {
                out.append(entry)
            }
        }

        for container in xdgContainers {
            let dir = env.home + "/" + container
            for name in FileProbe.list(dir) where name != ".DS_Store" {
                if let entry = makeEntry(dir + "/" + name, name: name, topLevel: false, container: container) {
                    out.append(entry)
                }
            }
        }
        return out
    }

    static func makeEntry(_ path: String, name: String, topLevel: Bool, container: String) -> DotEntry? {
        guard let info = FileProbe.lstat(path) else { return nil }
        let target = info.isSymlink ? FileProbe.symlinkDestination(path) : nil
        let dangling = info.isSymlink && !FileProbe.exists(path)
        let isDir = info.isDirectory || (info.isSymlink && FileProbe.isDirectory(path))
        return DotEntry(
            path: path,
            name: name,
            isDirectory: isDir,
            isSymlink: info.isSymlink,
            isDangling: dangling,
            symlinkTarget: target,
            children: isDir && !dangling ? Array(FileProbe.list(path).prefix(300)) : [],
            topLevel: topLevel,
            container: container
        )
    }
}

public struct LibraryEntry: Sendable, Hashable {
    public var path: String
    public var name: String
    public var category: String
    public var kind: ArtifactKind
    /// 由名字推出的 bundle id 候选（去掉 `.plist`、`.savedState`、`.ShipIt` 等后缀）
    public var bundleIDCandidates: [String]
}

/// 列出 ~/Library 里按 App 或工具命名的条目。
///
/// 只扫不会触发系统授权弹窗的几类。`Containers` 和 `Group Containers` 首次访问会弹
/// 「想访问其他 App 的数据」，所以不在自动扫描范围内。
public enum LibraryScanner {
    public static let categories: [(name: String, kind: ArtifactKind)] = [
        ("Application Support", .data),
        ("Caches", .cache),
        ("Logs", .logs),
        ("Preferences", .config),
        ("WebKit", .data),
        ("HTTPStorages", .cache),
        ("Saved Application State", .data),
    ]

    static let suffixes = [".plist", ".savedState", ".binarycookies"]
    static let helperSuffixes = [".ShipIt", ".helper", ".Helper"]

    public static func scan(env: HostEnvironment) -> [LibraryEntry] {
        var out: [LibraryEntry] = []
        for (category, kind) in categories {
            let dir = env.library + "/" + category
            for name in FileProbe.list(dir) where !name.hasPrefix(".") && name != "ByHost" {
                out.append(LibraryEntry(
                    path: dir + "/" + name,
                    name: name,
                    category: category,
                    kind: kind,
                    bundleIDCandidates: bundleIDCandidates(name)
                ))
            }
        }
        return out
    }

    static func bundleIDCandidates(_ name: String) -> [String] {
        var base = name
        for suffix in suffixes where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        var out = [base]
        for suffix in helperSuffixes where base.hasSuffix(suffix) {
            out.append(String(base.dropLast(suffix.count)))
        }
        return out
    }

    /// 名字本身看起来像 bundle id（至少两个点分段）。
    static func looksLikeBundleID(_ name: String) -> Bool {
        name.split(separator: ".").count >= 3 && !name.contains(" ")
    }
}

/// 在 rc 文件里找出提到某个工具目录的行。只读；本版不改 rc 文件。
public enum RcMarkerScanner {
    public static func lines(mentioning dirNames: [String], env: HostEnvironment) -> [RcLine] {
        guard !dirNames.isEmpty else { return [] }
        let alternatives = dirNames.map { NSRegularExpression.escapedPattern(for: "/" + $0) }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "(?:" + alternatives + ")(?![A-Za-z0-9_-])") else { return [] }

        var out: [RcLine] = []
        for file in PathProbe.rcFiles(home: env.home) {
            guard let text = FileProbe.readText(file) else { continue }
            for (index, raw) in text.components(separatedBy: "\n").enumerated() {
                let range = NSRange(raw.startIndex..., in: raw)
                if regex.firstMatch(in: raw, range: range) != nil {
                    out.append(RcLine(file: file, line: index + 1, text: raw.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        return out
    }
}
