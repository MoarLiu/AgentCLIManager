import Darwin
import Foundation

/// 判断一个目录是不是「有生成依据的缓存」，以及一个文件是不是安装包。
///
/// 原则和「工具」模块一样：名字像不算数。`build`、`dist`、`.cache` 这类目录
/// 不会仅凭名字被整个清理；要有工具自己留下的标记（SwiftPM 的工作区状态、
/// npm 的隐藏锁文件…）才认。名字像而没有标记的，只列出来请人判断。
enum SweepRecognizer {

    /// 这些目录不往里找候选项：源码、文档、设计、数据、备份和常见的敏感位置。
    static let protectedNames: Set<String> = [
        ".git", ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker",
        ".config", ".buildsweep", ".Trash", ".buildsweep-staging", SweepState.stagingName,
        "Library", "Applications", "src", "Sources", "Tests", "tests",
        "fixtures", "assets", "Resources", "resources", "design", "docs",
        "data", ".data", "backup", "backups", "node_modules",
    ]

    static let manifests = ["Package.swift", "package.json", "pyproject.toml", "requirements.txt"]

    static let cacheNames: Set<String> = [
        ".build", "node_modules", ".next", ".turbo", "__pycache__",
        ".pytest_cache", ".mypy_cache", ".ruff_cache",
    ]

    /// 从 `directory` 往上找到扫描根为止，第一个带项目清单或 `.git` 的目录。
    static func ownerProject(_ directory: String, root: String) -> String? {
        var current = directory
        while SweepPath.isInside(current, root) {
            if manifests.contains(where: { SweepFS.isFile(current + "/" + $0) })
                || SweepFS.exists(current + "/.git") {
                return current
            }
            if current == root { break }
            current = SweepPath.parent(current)
        }
        return nil
    }

    struct Kind {
        var category: SweepCategory
        var reason: String
    }

    static func cacheKind(_ path: String, project: String?) throws -> Kind? {
        let name = SweepPath.name(path)

        if SweepFS.isFile(path + "/workspace-state.json"),
           ["artifacts", "manifest.pif", "CACHEDIR.TAG"].contains(where: { SweepFS.exists(path + "/" + $0) }) {
            return Kind(category: .swiftCache, reason: "SwiftPM 工作区和编译缓存。")
        }
        if name == "node_modules" {
            let installed = SweepFS.isFile(path + "/.package-lock.json")
                || SweepFS.isFile(path + "/.modules.yaml")
                || SweepFS.isDirectory(path + "/.pnpm")
            if installed, let project, SweepFS.isFile(project + "/package.json") {
                return Kind(category: .nodeDependencies, reason: "可由项目依赖清单重新安装的 Node 依赖。")
            }
            if installed {
                let listing = try SweepFS.list(SweepPath.parent(path))
                let siblings = listing.names.filter { $0 != name && !SweepSnapshotter.noise.contains($0) }
                if siblings.isEmpty, !listing.hasUndecodable {
                    return Kind(category: .orphanNodeDependencies, reason: "父目录仅剩安装依赖，原项目文件已缺失。")
                }
            }
        }
        if name == "__pycache__" {
            let listing = try SweepFS.list(path)
            let onlyBytecode = !listing.hasUndecodable && listing.names.allSatisfy { child in
                SweepFS.isFile(path + "/" + child)
                    && (SweepSnapshotter.noise.contains(child) || (child.hasSuffix(".pyc") && child.count > 4))
            }
            if onlyBytecode {
                return Kind(category: .pythonCache, reason: "Python 自动生成的字节码缓存。")
            }
        }
        if name == ".next", let project,
           try SweepFS.list(project).names.contains(where: { $0.hasPrefix("next.config.") }) {
            return Kind(category: .webCache, reason: "Next.js 编译缓存。")
        }
        if name == ".turbo", let project,
           ([project] + SweepPath.ancestors(of: project)).contains(where: { SweepFS.isFile(SweepPath.join($0, "turbo.json")) }) {
            return Kind(category: .webCache, reason: "Turborepo 任务缓存。")
        }
        if cacheNames.contains(name) || name.hasPrefix(".build-") {
            return Kind(category: .unrecognizedCache, reason: "名称类似缓存，但缺少足够的生成依据。")
        }
        return nil
    }

    // MARK: - 版本

    private static let versionPattern = try! NSRegularExpression(
        pattern: #"(?<![0-9.])v?([0-9]+)\.([0-9]+)\.([0-9]+)(?:[-_.]((?:alpha|beta|rc|preview|dev)[-_.]?[0-9]*))?"#,
        options: [.caseInsensitive]
    )
    private static let architecturePattern = try! NSRegularExpression(
        pattern: #"(?:^|[-_. ])(arm64|aarch64|x86_64|x64|amd64|universal)(?=$|[-_. ])"#,
        options: [.caseInsensitive]
    )
    private static let platformPattern = try! NSRegularExpression(
        pattern: #"(?:^|[-_. ])(?:macos|darwin|mac|windows|win|linux)(?=$|[-_. ])"#,
        options: [.caseInsensitive]
    )
    private static let separatorPattern = try! NSRegularExpression(pattern: #"[-_. ]+"#)
    private static let stages = ["dev": 0, "alpha": 1, "preview": 2, "beta": 3, "rc": 4]

    struct VersionMatch {
        var version: SweepVersion
        var range: NSRange
    }

    /// 在一段文字里找第一个「主.次.修订」版本号；没有或数字离谱时返回 nil。
    static func findVersion(_ text: String) -> VersionMatch? {
        let source = text as NSString
        guard let match = versionPattern.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else {
            return nil
        }
        var base: [Int] = []
        for group in 1...3 {
            guard let number = Int(source.substring(with: match.range(at: group))) else { return nil }
            base.append(number)
        }
        let whole = source.substring(with: match.range)
        guard match.range(at: 4).location != NSNotFound else {
            return VersionMatch(
                version: SweepVersion(text: whole, base: base, pre: false, rank: base + [5, 0]),
                range: match.range
            )
        }
        let label = source.substring(with: match.range(at: 4)).lowercased()
            .replacingOccurrences(of: "_", with: ".").replacingOccurrences(of: "-", with: ".")
        guard let stage = stages.keys.first(where: { label.hasPrefix($0) }), let priority = stages[stage] else {
            return nil
        }
        var digits = label.dropFirst(stage.count)
        if digits.hasPrefix(".") { digits = digits.dropFirst() }
        let serialText = digits.prefix(while: { $0.isASCII && $0.isNumber })
        guard let serial = serialText.isEmpty ? 0 : Int(serialText) else { return nil }
        return VersionMatch(
            version: SweepVersion(text: whole, base: base, pre: true, rank: base + [priority, serial]),
            range: match.range
        )
    }

    // MARK: - 安装包

    private static let extensions = [".app.zip", ".dmg", ".pkg", ".msi", ".exe", ".apk", ".zip"]

    /// 返回 nil 表示「这不是安装包」；返回 `recognized == false` 表示
    /// 「看着是安装包，但定不了版本或产品」，需要人来判断。
    static func installer(_ path: String, isDirectory: Bool) -> SweepInstaller? {
        let name = SweepPath.name(path)
        if name.hasSuffix(".app"), isDirectory {
            return bundle(path)
        }
        let lower = name.lowercased()
        guard let ext = extensions.first(where: { lower.hasSuffix($0) }) else { return nil }
        if ext == ".zip" {
            guard let info = SweepZip.soleAppInfo(path),
                  let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty
            else { return nil }
        }

        let stem = String(name.dropLast(ext.count))
        guard let found = findVersion(stem) else {
            // 区分「压根没有版本号」和「有，但解析不了」没有意义：都要人来看。
            return .unrecognized("安装文件名没有明确的语义版本，需人工复核。")
        }
        let source = stem as NSString
        let whole = NSRange(location: 0, length: source.length)

        var architecture = "unknown"
        if let match = architecturePattern.firstMatch(in: stem, range: whole) {
            architecture = source.substring(with: match.range(at: 1)).lowercased()
        }
        architecture = ["aarch64": "arm64", "amd64": "x86_64", "x64": "x86_64"][architecture] ?? architecture

        let trim = CharacterSet(charactersIn: "-_. ")
        let prefix = source.substring(to: found.range.location).trimmingCharacters(in: trim).lowercased()
        guard !prefix.isEmpty else {
            return .unrecognized("文件名缺少明确的产品名。")
        }
        var suffix = source.substring(from: found.range.location + found.range.length)
        for pattern in [architecturePattern, platformPattern, separatorPattern] {
            suffix = pattern.stringByReplacingMatches(
                in: suffix, range: NSRange(location: 0, length: (suffix as NSString).length), withTemplate: "-"
            )
        }
        suffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return SweepInstaller(
            recognized: true,
            version: found.version,
            product: prefix + (suffix.isEmpty ? "" : "/" + suffix.lowercased()),
            architecture: architecture,
            format: String(ext.dropFirst())
        )
    }

    /// 应用包按 Info.plist 里的身份和版本识别，不看文件名。
    private static func bundle(_ path: String) -> SweepInstaller? {
        let plistPath = path + "/Contents/Info.plist"
        guard let link = SweepFS.lstat(plistPath), !SweepFS.isSymlink(link),
              let info = SweepFS.stat(plistPath), info.st_size <= off_t(SweepZip.maxPlistBytes),
              let data = FileManager.default.contents(atPath: plistPath)
        else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
              format != .openStep, let plist = value as? [String: Any]
        else { return nil }

        let identifier = plist["CFBundleIdentifier"] as? String ?? ""
        guard !identifier.isEmpty,
              let found = findVersion(text(plist["CFBundleShortVersionString"]))
        else {
            return .unrecognized("应用缺少可识别的版本或身份。")
        }
        return SweepInstaller(
            recognized: true,
            version: found.version,
            product: identifier,
            architecture: architecture(bundle: path, executable: text(plist["CFBundleExecutable"])),
            format: "app",
            build: text(plist["CFBundleVersion"])
        )
    }

    private static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    /// 读主程序的 Mach-O 头，看它是给哪种 CPU 编的。
    private static func architecture(bundle: String, executable: String) -> String {
        let fd = open(bundle + "/Contents/MacOS/" + executable, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return "unknown" }
        defer { close(fd) }
        var header = [UInt8](repeating: 0, count: 8)
        guard read(fd, &header, 8) == 8 else { return "unknown" }
        let magic = Array(header[0..<4])
        if [[0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA], [0xCA, 0xFE, 0xBA, 0xBF]].contains(magic) {
            return "universal"
        }
        let little = [[0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE]].contains(magic)
        let field = little ? Array(header[4..<8].reversed()) : Array(header[4..<8])
        let cpu = field.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        switch cpu {
        case 0x0100_000C: return "arm64"
        case 0x0100_0007: return "x86_64"
        default: return "unknown"
        }
    }
}
