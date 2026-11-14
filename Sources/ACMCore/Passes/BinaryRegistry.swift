import Foundation

/// 以二进制为起点的检测：扫 bin 目录 → 解析整条软链链路 → 反推出程序放在哪、
/// 是谁装的。不读包管理器清单，也不调用包管理器。
public enum BinaryRegistry {

    public static func scan(env: HostEnvironment, catalog: Catalog, binDirs: [BinDir]) -> [BinaryInfo] {
        var out: [BinaryInfo] = []
        var seen = Set<String>()

        for dir in binDirs {
            for name in FileProbe.list(dir.path) where !name.hasPrefix(".") {
                let path = dir.path + "/" + name
                guard let info = FileProbe.lstat(path), !info.isDirectory else { continue }
                if !info.isSymlink && !FileProbe.isExecutableFile(path) { continue }
                guard seen.insert(PathUtil.key(path)).inserted else { continue }

                let (chain, finalTarget) = resolveChain(path)
                let known = catalog.product(matchingBinary: name) != nil

                if dir.mode == .selective {
                    let globalPackage = chain.contains { isGlobalPackagePath($0) && !isNodeRuntimePath($0) }
                    if !known && !globalPackage { continue }
                }

                // 链尾必须是能执行的普通文件。软链指向目录（或不可执行的文件）时，
                // 它不是命令：目标绝不能被当成「程序本体」。
                // 名字不认识的直接略过（`~/bin/scripts -> ~/dotfiles/scripts` 很常见）；
                // 名字是目录清单里的命令时，作为异常入口报告出来，但不替用户下结论。
                var invalid: String?
                if let finalTarget {
                    if FileProbe.isDirectory(finalTarget) {
                        invalid = "一个目录"
                    } else if !FileProbe.isExecutableFile(finalTarget) {
                        invalid = "一个不可执行的文件"
                    }
                }
                if invalid != nil && !known { continue }

                let target = finalTarget ?? chain.last ?? path
                let payload = invalid == nil
                    ? resolvePayload(target: target, env: env)
                    : Payload(root: nil, channel: .unknown, version: nil, package: nil)
                var broken: String?
                var sign: CodeSignInfo?
                if let finalTarget, invalid == nil {
                    if let shim = shimInfo(finalTarget, home: env.home) {
                        broken = shim.missingTarget
                    } else {
                        sign = env.signProbe?(finalTarget)
                    }
                }

                out.append(BinaryInfo(
                    name: name,
                    path: path,
                    chain: chain,
                    finalTarget: finalTarget,
                    isDangling: finalTarget == nil,
                    brokenShimTarget: broken,
                    signIdentifier: sign?.identifier,
                    teamID: sign?.teamID,
                    payloadRoot: payload.root,
                    channel: payload.channel,
                    version: payload.version,
                    packageName: payload.package,
                    inSystemDir: !PathUtil.isInside(path, env.home),
                    binDirSource: dir.source,
                    invalidTarget: invalid
                ))
            }
        }
        return out
    }

    // MARK: - 链路

    /// 逐级解析软链，返回完整链路；末端不存在（悬空或成环）时 final 为 nil。
    static func resolveChain(_ path: String) -> (chain: [String], final: String?) {
        var chain = [path]
        var current = path
        var hops = 0
        while hops < 32, let destination = FileProbe.symlinkDestination(current) {
            let next = destination.hasPrefix("/")
                ? destination
                : PathUtil.parent(current) + "/" + destination
            current = PathUtil.standardize(next)
            if chain.contains(where: { PathUtil.key($0) == PathUtil.key(current) }) { return (chain, nil) }
            chain.append(current)
            hops += 1
        }
        if hops >= 32 { return (chain, nil) }
        return (chain, FileProbe.lstat(current) != nil ? current : nil)
    }

    static func isGlobalPackagePath(_ path: String) -> Bool {
        path.contains("/lib/node_modules/") || path.contains("/install/global/node_modules/")
    }

    static func isNodeRuntimePath(_ path: String) -> Bool {
        path.contains("/lib/node_modules/npm/") || path.contains("/lib/node_modules/corepack/")
    }

    // MARK: - 启动脚本

    struct ShimInfo { var missingTarget: String? }

    /// 末端是不是一个小的启动脚本；如果是，看它 exec 的目标还在不在。
    ///
    /// 软链悬空一查就知道，但 `~/.local/bin/alma` 这种「普通文件、内容是一行 exec」
    /// 的壳在主程序被删后同样失效，只能读内容判断。
    static func shimInfo(_ path: String, home: String) -> ShimInfo? {
        guard let info = FileProbe.lstat(path), !info.isSymlink, !info.isDirectory, info.size < 16_384,
              let data = FileProbe.readHead(path),
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix("#!")
        else { return nil }

        // 只认「行首（可带环境变量赋值）的 exec」，然后按 shell 的引号规则取出它后面的那个词。
        let pattern = #"(?m)^[ \t]*(?:[A-Za-z_][A-Za-z0-9_]*=\S*[ \t]+)*exec[ \t]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ShimInfo(missingTarget: nil) }

        // 不执行 shell，也不把正则当成完整的 shell 解析器。只有每一条有效行
        // 都是直接 exec、且不含控制操作符时，才允许推断“脚本已损坏”。否则
        // 行内分支、函数、here-document 等可能被漏读或被错当作执行语句。
        let statements = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let directExecOnly = statements.allSatisfy { line in
            let range = NSRange(line.startIndex..., in: line)
            return regex.firstMatch(in: line, range: range)?.range.location == 0
                && !line.contains(where: { ";&|<>`()".contains($0) })
        }
        guard directExecOnly else { return ShimInfo(missingTarget: nil) }

        var missing: [String] = []
        var present = 0
        var hasUnknownTarget = false
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else {
                hasUnknownTarget = true
                continue
            }
            let lineEnd = text[r.upperBound...].firstIndex(where: \.isNewline) ?? text.endIndex
            guard let target = execTarget(String(text[r.upperBound..<lineEnd]), home: home) else {
                // 变量、PATH 命令等仍可能执行成功，不能把未知分支当成不存在。
                hasUnknownTarget = true
                continue
            }
            if FileProbe.exists(target) { present += 1 } else { missing.append(target) }
        }
        // 必须所有识别到的 exec 目标都能确定、且都不存在，才判定启动脚本失效。
        return ShimInfo(missingTarget: present == 0 && !hasUnknownTarget ? missing.first : nil)
    }

    /// 取出 `exec` 后面要执行的那个程序的绝对路径。解不出来（带变量、命令替换、
    /// 引号没配对、不是绝对路径）一律返回 nil——宁可不知道，也不猜成「目标不存在」。
    static func execTarget(_ rest: String, home: String) -> String? {
        var words = ShellWords(rest, home: home)
        while let word = words.next() {
            guard let value = word else { return nil }
            // exec 自己的选项：-a 带一个参数，-c、-l 不带
            if value == "-a" {
                guard case .some(.some) = words.next() else { return nil }
                continue
            }
            if value == "-c" || value == "-l" || value == "--" { continue }
            var target = value
            if target == "~" || target.hasPrefix("~/") { target = home + String(target.dropFirst(1)) }
            return target.hasPrefix("/") ? PathUtil.standardize(target) : nil
        }
        return nil
    }

    /// 极简的 shell 取词器：认单引号、双引号、反斜杠转义，以及 `$HOME` / `${HOME}`。
    /// 遇到其他变量、命令替换、通配符或没配对的引号，`next()` 给出 `.some(nil)`，表示「解不出来」。
    struct ShellWords {
        private let chars: [Character]
        private var index = 0
        private let home: String

        init(_ text: String, home: String) {
            chars = Array(text)
            self.home = home
        }

        mutating func next() -> String?? {
            while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }
            guard index < chars.count, !";&|#<>()".contains(chars[index]) else { return nil }

            var word = ""
            var unknown = false
            scan: while index < chars.count {
                let c = chars[index]
                switch c {
                case " ", "\t", ";", "&", "|", "<", ">", "(", ")":
                    break scan
                case "'":
                    index += 1
                    guard let end = chars[index...].firstIndex(of: "'") else { index = chars.count; return .some(nil) }
                    word += String(chars[index..<end])
                    index = end + 1
                case "\"":
                    index += 1
                    var closed = false
                    while index < chars.count {
                        let d = chars[index]
                        if d == "\"" { closed = true; index += 1; break }
                        if d == "\\", index + 1 < chars.count, "\"\\$`".contains(chars[index + 1]) {
                            word.append(chars[index + 1]); index += 2; continue
                        }
                        if d == "`" { unknown = true; index += 1; continue }
                        if d == "$" { expandVariable(into: &word, unknown: &unknown); continue }
                        word.append(d); index += 1
                    }
                    if !closed { return .some(nil) }
                case "\\":
                    guard index + 1 < chars.count else { index += 1; break scan }
                    word.append(chars[index + 1]); index += 2
                case "$":
                    expandVariable(into: &word, unknown: &unknown)
                case "`", "*", "?", "[", "{":
                    unknown = true; index += 1
                default:
                    word.append(c); index += 1
                }
            }
            return .some(unknown ? nil : word)
        }

        /// 只展开 HOME；其余变量和 `$(…)` 都算解不出来。
        private mutating func expandVariable(into word: inout String, unknown: inout Bool) {
            let rest = String(chars[index...])
            for spelling in ["${HOME}", "$HOME"] where rest.hasPrefix(spelling) {
                let after = index + spelling.count
                let continues = spelling == "$HOME" && after < chars.count
                    && (chars[after].isLetter || chars[after].isNumber || chars[after] == "_")
                if !continues {
                    word += home
                    index = after
                    return
                }
            }
            unknown = true
            index += 1
            // 跳过整个 $(…) / ${…}，否则里面的空格会把一个词切成几段
            if index < chars.count, chars[index] == "(" || chars[index] == "{" {
                let open = chars[index], close: Character = open == "(" ? ")" : "}"
                var depth = 0
                while index < chars.count {
                    if chars[index] == open { depth += 1 }
                    if chars[index] == close { depth -= 1; if depth == 0 { index += 1; break } }
                    index += 1
                }
            }
        }
    }

    // MARK: - 工具管理器

    /// 装着很多互不相干的工具的目录（家目录相对路径）。
    ///
    /// 这些目录不能当成「某个产品的程序目录」：`~/.volta/bin` 里的 codex、node、npm
    /// 各是各的，卸载其中一个不能把整个目录、也不能把别的命令带走。
    /// 位于这里面的命令一律各自成组，除非更具体的规则（npm 全局包、uv tools、pipx 环境）
    /// 能指出它自己的那个包目录。
    static let toolManagerRoots: [(rel: String, name: String)] = [
        (".volta", "Volta"), (".nvm", "nvm"), (".fnm", "fnm"), (".local/share/fnm", "fnm"),
        ("Library/Application Support/fnm", "fnm"), (".n", "n"), (".nodenv", "nodenv"),
        (".bun", "Bun"), (".deno", "Deno"), (".npm-global", "npm"), (".npm", "npm"),
        (".yarn", "Yarn"), (".config/yarn", "Yarn"), ("Library/pnpm", "pnpm"),
        (".local/share/pnpm", "pnpm"), (".pnpm", "pnpm"),
        (".asdf", "asdf"), (".mise", "mise"), (".local/share/mise", "mise"), (".local/share/rtx", "rtx"),
        (".proto", "proto"), (".local/share/aquaproj-aqua", "aqua"), (".nix-profile", "Nix"),
        (".local/state/nix", "Nix"),
        (".pyenv", "pyenv"), (".local/share/uv", "uv"), (".local/share/pipx", "pipx"), (".local/pipx", "pipx"),
        (".conda", "conda"), ("miniconda3", "conda"), ("anaconda3", "conda"), ("miniforge3", "conda"),
        ("mambaforge", "conda"), (".pixi", "pixi"), (".rye", "Rye"), (".local/share/hatch", "Hatch"),
        (".rbenv", "rbenv"), (".rvm", "RVM"), (".gem", "RubyGems"),
        (".cargo", "cargo"), (".rustup", "rustup"), ("go", "go"), (".goenv", "goenv"), (".gvm", "gvm"),
        (".sdkman", "SDKMAN"), (".jenv", "jenv"), (".dotnet", ".NET"), (".ghcup", "GHCup"),
        (".cabal", "Cabal"), (".stack", "Stack"), (".juliaup", "juliaup"), (".swiftly", "swiftly"),
        (".opam", "opam"), (".nimble", "Nimble"), (".pub-cache", "Dart pub"), (".composer", "Composer"),
        (".krew", "krew"),
    ]

    /// `path` 位于哪个工具管理器的目录里（没有则 nil）。
    static func toolManager(for path: String, home: String) -> String? {
        for (rel, name) in toolManagerRoots where PathUtil.isStrictlyInside(path, home + "/" + rel) {
            return name
        }
        return nil
    }

    // MARK: - 载荷

    struct Payload {
        var root: String?
        var channel: Channel
        var version: String?
        var package: String?
    }

    /// 由最终目标的位置反推：程序整体放在哪（root）、哪个渠道装的、版本号。
    static func resolvePayload(target: String, env: HostEnvironment) -> Payload {
        let home = env.home

        // npm / bun 全局包：<前缀>/lib/node_modules/<包>/...
        for marker in ["/lib/node_modules/", "/install/global/node_modules/"] {
            guard let range = target.range(of: marker) else { continue }
            let prefix = String(target[..<range.lowerBound])
            let rest = target[range.upperBound...].split(separator: "/").map(String.init)
            guard let first = rest.first else { continue }
            let package = first.hasPrefix("@") && rest.count >= 2 ? first + "/" + rest[1] : first
            let root = prefix + marker + package
            let channel: Channel = marker.hasPrefix("/install/global") ? .bun : .npm
            return Payload(root: root, channel: channel, version: packageJSONVersion(root), package: package)
        }

        // Homebrew：<前缀>/Cellar/<formula>/<版本>/...
        for marker in ["/Cellar/", "/Caskroom/"] {
            guard let range = target.range(of: marker) else { continue }
            let prefix = String(target[..<range.lowerBound])
            let rest = target[range.upperBound...].split(separator: "/").map(String.init)
            guard let formula = rest.first else { continue }
            return Payload(
                root: prefix + marker + formula,
                channel: .brew,
                version: rest.count >= 2 ? rest[1] : nil,
                package: formula
            )
        }

        // 随 App 提供
        if let range = target.range(of: ".app/"), target.hasPrefix("/Applications/") || target.contains("/Applications/") {
            return Payload(root: String(target[..<range.lowerBound]) + ".app", channel: .appProvided, version: nil, package: nil)
        }

        guard PathUtil.isStrictlyInside(target, home) else {
            return Payload(root: target, channel: .standalone, version: semver(in: target), package: nil)
        }
        let rel = PathUtil.components(String(target.dropFirst(home.count)))
        let version = semver(in: target)

        func under(_ parts: [String]) -> Bool {
            rel.count > parts.count && Array(rel.prefix(parts.count)) == parts
        }
        func rootAt(_ depth: Int) -> String {
            home + "/" + rel.prefix(depth).joined(separator: "/")
        }

        if under([".local", "share", "uv", "tools"]) {
            return Payload(root: rootAt(5), channel: .uv, version: version, package: rel[4])
        }
        // pipx 现在把环境放在 ~/.local/share/pipx/venvs/<包>，旧版在 ~/.local/pipx/venvs/<包>。
        // 以单个环境为单位：整个 pipx 目录是所有 pipx 工具共用的。
        if under([".local", "share", "pipx", "venvs"]) {
            return Payload(root: rootAt(5), channel: .pipx, version: version, package: rel[4])
        }
        if under([".local", "pipx", "venvs"]) {
            return Payload(root: rootAt(4), channel: .pipx, version: version, package: rel[3])
        }
        if under([".cargo", "bin"]) {
            return Payload(root: target, channel: .cargo, version: version, package: nil)
        }
        if under(["go", "bin"]) {
            return Payload(root: target, channel: .go, version: version, package: nil)
        }
        // 工具管理器的目录：不知道这个命令在里面占了哪一块，只认它自己这个文件。
        // root 置空，让每个入口各自成组——管理器的 shim（volta-shim 之类）是所有命令共用的，
        // 按「指向同一个文件」合并会把 node、npm 和某个 Agent CLI 并到一起。
        if toolManager(for: target, home: home) != nil {
            return Payload(root: nil, channel: .standalone, version: version, package: nil)
        }
        // ~/.local/share/<工具>/... —— 厂商安装器的另一种惯用位置
        if under([".local", "share"]), rel.count >= 4 {
            return Payload(root: rootAt(3), channel: .vendor, version: version, package: nil)
        }
        // ~/.<厂商>/... —— 厂商自己的顶层点目录
        if let first = rel.first, first.hasPrefix("."), rel.count >= 2,
           ![".local", ".config", ".cache"].contains(first) {
            return Payload(root: rootAt(1), channel: .vendor, version: version, package: nil)
        }
        return Payload(root: target, channel: .standalone, version: version, package: nil)
    }

    static func packageJSONVersion(_ root: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: root + "/package.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["version"] as? String
    }

    /// 路径里最靠后的 x.y.z。厂商安装器通常把版本号写进文件名或目录名。
    static func semver(in path: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\d+\.\d+\.\d+"#) else { return nil }
        let matches = regex.matches(in: path, range: NSRange(path.startIndex..., in: path))
        guard let last = matches.last, let r = Range(last.range, in: path) else { return nil }
        return String(path[r])
    }
}
