import Foundation

public struct BinDir: Sendable, Hashable {
    public enum Mode: String, Sendable {
        /// 用户自己的 bin 目录：全部收录
        case all
        /// 系统级或 node 前缀目录：只收目录清单认识的名字和全局 npm 包，
        /// 否则几百个 brew 工具和 node/npm 自身都会被列出来
        case selective
    }

    public var path: String
    public var mode: Mode
    public var source: String
}

/// 找出该去哪些目录里找命令。
///
/// 静态推导，不启动登录 shell：`zsh -i` 会写 `~/.zsh_history`，rc 里有交互命令时还会卡住。
public enum PathProbe {
    public static let rcFileNames = [
        ".zshenv", ".zprofile", ".zshrc", ".zlogin", ".profile", ".bash_profile", ".bashrc", ".bash_login",
    ]

    public static func rcFiles(home: String) -> [String] {
        rcFileNames.map { home + "/" + $0 }.filter { FileProbe.lstat($0) != nil }
    }

    public static func binDirs(env: HostEnvironment) -> [BinDir] {
        let home = env.home
        var out: [BinDir] = []
        var seen = Set<String>()

        func add(_ path: String, _ mode: BinDir.Mode, _ source: String) {
            let p = PathUtil.standardize(path)
            guard FileProbe.isDirectory(p), seen.insert(PathUtil.key(p)).inserted else { return }
            out.append(BinDir(path: p, mode: mode, source: source))
        }

        // 1. rc 文件里写进 PATH 的目录
        for rc in rcFiles(home: home) {
            guard let text = FileProbe.readText(rc) else { continue }
            for dir in pathFragments(in: text, home: home) where PathUtil.isStrictlyInside(dir, home) {
                let name = PathUtil.lastComponent(dir)
                if name == "bin" || name == "entry" || FileProbe.hasExecutable(in: dir) {
                    add(dir, isNodePrefix(dir) ? .selective : .all, "rc:" + PathUtil.lastComponent(rc))
                }
            }
        }

        // 2. 常见的用户级 bin 目录
        for rel in [".local/bin", "bin", ".cargo/bin", "go/bin", ".bun/bin", ".deno/bin", ".volta/bin",
                    ".npm-global/bin", "Library/pnpm"] {
            add(home + "/" + rel, .all, "常见位置")
        }

        // 3. 家目录顶层点目录里的 bin（厂商安装器的惯用位置，如 ~/.grok/bin）
        for name in FileProbe.list(home) where name.hasPrefix(".") && name != ".Trash" {
            // Python 虚拟环境也长这样，但里面是项目依赖，不是装给用户用的命令
            if FileProbe.lstat(home + "/" + name + "/pyvenv.cfg") != nil { continue }
            add(home + "/" + name + "/bin", .all, "厂商目录")
        }

        // 4. 各 node 版本的全局 bin
        for versionsDir in [home + "/.nvm/versions/node",
                            home + "/Library/Application Support/fnm/node-versions",
                            home + "/.local/share/fnm/node-versions"] {
            for v in FileProbe.list(versionsDir) {
                add(versionsDir + "/" + v + "/bin", .selective, "node 版本")
                add(versionsDir + "/" + v + "/installation/bin", .selective, "node 版本")
            }
        }

        // 5. 系统级
        for dir in env.systemBinDirs { add(dir, .selective, "系统") }

        return out
    }

    static func isNodePrefix(_ dir: String) -> Bool {
        dir.contains("/versions/node/") || dir.contains("/node-versions/")
    }

    /// 从 rc 文本里抠出加进 PATH 的家目录路径。
    ///
    /// 只看给 `PATH` / `path` 赋值的行：`export NVM_DIR="$HOME/.nvm"` 也含家目录路径，
    /// 但那不是命令目录——把它当成 bin 目录会把 nvm 仓库里的脚本都当成命令。
    /// `fpath=`（补全脚本目录）同理排除。
    static func pathFragments(in text: String, home: String) -> [String] {
        let homeLiteral = NSRegularExpression.escapedPattern(for: home)
        let pattern = "(?:~|\\$HOME|\\$\\{HOME\\}|" + homeLiteral + ")((?:/[A-Za-z0-9._+@-]+)+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let assignsPath = try? NSRegularExpression(pattern: #"(?<![A-Za-z_])(?:PATH|path)\s*\+?="#)
        else { return [] }
        var out: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard assignsPath.firstMatch(in: line, range: range) != nil else { continue }
            for m in regex.matches(in: line, range: range) {
                guard let r = Range(m.range(at: 1), in: line) else { continue }
                out.append(PathUtil.standardize(home + String(line[r])))
            }
        }
        return out
    }
}
