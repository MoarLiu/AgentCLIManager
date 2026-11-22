import Darwin
import Foundation

/// 只读扫描：找出候选项，给每一项下结论。不移动、不删除、不写任何文件。
///
/// 结论分四种：`cleanup`（有生成依据、闲置、没被占用）、`keep`（最新版本的安装包）、
/// `review`（证据不够或最近还在写）、`blocked`（有保护条件拦着）。
public enum SweepScanner {

    public static func scan(
        root rootValue: String,
        policy: SweepPolicy = SweepPolicy(),
        env: HostEnvironment,
        probes: SweepProbes = .live,
        now: Date? = nil
    ) throws -> SweepPlan {
        try scan(
            root: rootValue, policy: policy, env: env, probes: probes, now: now, hashes: SweepContentHashCache()
        )
    }

    static func scan(
        root rootValue: String,
        policy: SweepPolicy = SweepPolicy(),
        env: HostEnvironment,
        probes: SweepProbes = .live,
        now: Date? = nil,
        hashes: SweepContentHashCache
    ) throws -> SweepPlan {
        guard policy.idleHours.isFinite, policy.idleHours >= 0 else {
            throw SweepError("invalid_policy", "闲置时间必须是非负有限数值。")
        }
        guard (1...2_000_000).contains(policy.maxEntries) else {
            throw SweepError("invalid_policy", "条目上限必须在 1 至 2000000 之间。")
        }
        let root = try SweepPath.normalizedRoot(rootValue, env: env)
        let rootIdentity = try SweepPath.rootIdentity(root)
        let rootDevice = SweepFS.stat(root)?.st_dev

        let excludes = policy.excludes.map(SweepPath.resolveLenient)
        // 本 App 自己的程序、数据目录（回执和计划都在里面）永远不是候选项。
        let protected = excludes + (env.selfPaths + [env.ownSupportDir]).map(SweepPath.resolveLenient)

        var warnings: [SweepWarning] = []
        var records: [SweepOpenPath] = []
        do {
            records = try probes.openPaths()
        } catch let error as SweepError {
            warnings.append(SweepWarning(code: error.code, message: error.message))
        } catch {
            warnings.append(SweepWarning(code: "process_probe_failed", message: "进程占用检查未完成。"))
        }

        var discovery = Discovery(
            root: root, rootDevice: rootDevice, protected: protected, maxEntries: policy.maxEntries, hashes: hashes
        )
        try discovery.walk(root, depth: 0)
        var items = discovery.items

        for index in items.indices
        where items[index].snapshot != nil
            && items[index].category != .installer && items[index].category != .unrecognizedCache {
            items[index].status = .cleanup
        }
        finalizeVersions(&items)

        let moment = (now ?? env.now).timeIntervalSince1970
        let prepared = preparedOpenPaths(records)
        var git = ScanGitCache(probes: probes)
        for index in items.indices where items[index].status == .cleanup {
            let item = items[index]
            let path = SweepPath.join(root, item.path)
            let project = item.project.map { SweepPath.join(root, $0) }
            if let reason = trackedReason(path, cache: &git) {
                items[index].status = .blocked
                items[index].reason = reason
                continue
            }
            if !warnings.isEmpty {
                items[index].status = .blocked
                items[index].reason = "进程检查未完成。"
                continue
            }
            let users = processUsers(
                path: SweepPath.Parts(path), project: project.map(SweepPath.Parts.init), records: prepared
            )
            if !users.isEmpty {
                items[index].status = .blocked
                items[index].reason = "有进程正在使用该目录或项目。"
                items[index].processes = users
                continue
            }
            let latest = Double(item.snapshot?.latestMtimeNs ?? 0) / 1e9
            if moment - latest < policy.idleHours * 3600 {
                items[index].status = .review
                items[index].reason = "最近仍有写入，暂不自动清理。"
            }
        }

        let staging = SweepPath.join(root, SweepState.stagingName)
        if let info = SweepFS.lstat(staging), SweepFS.isDirectory(info), !SweepFS.isSymlink(info) {
            warnings.append(SweepWarning(
                code: "staging_residue",
                message: "发现未完成的永久删除暂存。它不会被当作缓存清理；可在界面里查看残留，或按回执放回。 \(staging)"
            ))
        }

        return SweepPlan(
            schemaVersion: SweepEngine.schemaVersion,
            toolVersion: SweepEngine.toolVersion,
            root: root,
            rootIdentity: rootIdentity,
            createdAt: moment,
            policy: SweepPolicy(idleHours: policy.idleHours, maxEntries: policy.maxEntries, excludes: excludes),
            items: items,
            summary: SweepSummary(items),
            warnings: warnings,
            planFile: nil
        )
    }

    /// 候选项的稳定标识：扫描根加相对路径的摘要，前 16 位。
    public static func candidateID(root: String, relative: String) -> String {
        String(SweepCanonical.sha256(Data((root + "\0" + relative).utf8)).prefix(16))
    }

    // MARK: - 发现

    private struct Discovery {
        let root: String
        let rootDevice: dev_t?
        let protected: [String]
        let maxEntries: Int
        var hashes: SweepContentHashCache
        var items: [SweepItem] = []
        var visited = 0

        mutating func walk(_ directory: String, depth: Int) throws {
            if depth > SweepEngine.maxDepth {
                throw SweepError("discovery_depth", "扫描层级过深，请缩小目录。")
            }
            let listing: SweepFS.Listing
            do {
                listing = try SweepFS.list(directory)
            } catch {
                throw SweepError(
                    "discovery_permission", "存在无法读取的目录，请排除后重试。", details: ["path": directory]
                )
            }
            // 同一个目录下的条目共用一个「所属项目」，只算一次。
            let project = SweepRecognizer.ownerProject(directory, root: root)

            for name in listing.names {
                visited += 1
                if visited > SweepEngine.maxVisited {
                    throw SweepError("discovery_limit", "发现条目超过上限，请缩小扫描目录。")
                }
                let path = SweepPath.join(directory, name)
                guard let info = SweepFS.lstat(path), !SweepFS.isSymlink(info),
                      !protected.contains(where: { SweepPath.isInside(path, $0) }),
                      info.st_dev == rootDevice
                else { continue }

                if SweepFS.isDirectory(info) {
                    if name.hasSuffix(".app") {
                        if let metadata = SweepRecognizer.installer(path, isDirectory: true) {
                            try add(path, .installer, metadata.reason ?? "应用版本候选。", project: project, installer: metadata)
                        }
                        continue
                    }
                    if SweepRecognizer.protectedNames.contains(name) { continue }
                    let kind: SweepRecognizer.Kind?
                    do {
                        kind = try SweepRecognizer.cacheKind(path, project: project)
                    } catch {
                        throw SweepError(
                            "discovery_permission", "存在无法读取的目录，请排除后重试。", details: ["path": path]
                        )
                    }
                    if let kind {
                        try add(path, kind.category, kind.reason, project: project, installer: nil)
                        continue
                    }
                    try walk(path, depth: depth + 1)
                } else if SweepFS.isRegular(info) {
                    if let metadata = SweepRecognizer.installer(path, isDirectory: false) {
                        try add(path, .installer, metadata.reason ?? "安装包版本候选。", project: project, installer: metadata)
                    }
                }
            }
        }

        private mutating func add(
            _ path: String, _ category: SweepCategory, _ reason: String,
            project: String?, installer: SweepInstaller?
        ) throws {
            let relative = SweepPath.relative(path, to: root)
            var item = SweepItem(
                id: SweepScanner.candidateID(root: root, relative: relative),
                path: relative,
                parent: SweepPath.relative(SweepPath.parent(path), to: root),
                project: project.map { SweepPath.relative($0, to: root) },
                category: category,
                status: .review,
                reason: reason,
                installer: installer
            )
            if protected.contains(where: { SweepPath.isInside($0, path) }) {
                item.status = .blocked
                item.reason = "目录内部包含排除路径或工具自身文件。"
            } else {
                do {
                    let isFile = SweepFS.lstat(path).map(SweepFS.isRegular) ?? false
                    // 对拍脚本比较整个 snapshot，其中包含 content_sha256。
                    // 所以每个认出来的单文件安装包仍计算摘要；同一轮按文件身份复用，不重复读。
                    item.snapshot = try SweepSnapshotter.snapshot(
                        root: root, relative: relative, maxEntries: maxEntries,
                        contentHash: installer?.recognized == true && isFile, hashes: hashes
                    )
                } catch let error as SweepError {
                    item.status = .blocked
                    item.reason = error.message
                }
            }
            items.append(item)
            if items.count > SweepEngine.maxItems {
                throw SweepError("item_limit", "候选项过多，请缩小扫描目录。")
            }
        }
    }

    // MARK: - 安装包的版本保留

    /// 同一项目、产品、架构和格式的安装包放在一起比：留最新的稳定版，
    /// 以及比它更新的预览版；其余标为可清理。同版本的重复件只有内容完全一样才去重。
    static func finalizeVersions(_ items: inout [SweepItem]) {
        struct Key: Hashable {
            var scope: String
            var product: String
            var architecture: String
            var format: String
        }
        var groups: [Key: [Int]] = [:]
        var order: [Key] = []
        for (index, item) in items.enumerated() {
            guard let metadata = item.installer, metadata.recognized, item.snapshot != nil,
                  let product = metadata.product, let architecture = metadata.architecture,
                  let format = metadata.format, metadata.version != nil
            else { continue }
            let key = Key(scope: item.project ?? item.parent, product: product, architecture: architecture, format: format)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(index)
        }

        func rank(_ index: Int) -> [Int] { items[index].installer?.version?.rank ?? [] }
        func isPreview(_ index: Int) -> Bool { items[index].installer?.version?.pre ?? false }

        for key in order {
            let group = groups[key] ?? []
            let newestStable = group.filter { !isPreview($0) }.map(rank).max(by: precedes)
            let newestPreview = group.filter(isPreview).map(rank).max(by: precedes)
            var latest: [[Int]] = []
            if let newestStable { latest.append(newestStable) }
            if let newestPreview {
                if let newestStable {
                    if precedes(Array(newestStable.prefix(3)), Array(newestPreview.prefix(3))) {
                        latest.append(newestPreview)
                    }
                } else {
                    latest.append(newestPreview)
                }
            }
            let keepers = group.filter { latest.contains(rank($0)) }
            for index in keepers {
                items[index].status = .keep
                items[index].reason = "保留该产品、架构和格式的最新版本。"
            }
            for index in group where !keepers.contains(index) {
                items[index].status = .cleanup
                items[index].reason = "已有同产品、架构和格式的更新版本。"
                items[index].retainedIDs = keepers.map { items[$0].id }
            }

            for version in latest {
                let sameVersion = keepers.filter { rank($0) == version }
                var byHash: [String: [Int]] = [:]
                var hashOrder: [String] = []
                for index in sameVersion {
                    guard let content = items[index].snapshot?.contentSHA256 else { continue }
                    if byHash[content] == nil { hashOrder.append(content) }
                    byHash[content, default: []].append(index)
                }
                for content in hashOrder {
                    // 留哪一份：优先不在下载、验收这类临时目录里的，其次路径浅的。
                    let duplicates = (byHash[content] ?? []).sorted {
                        preference(items[$0].path) < preference(items[$1].path)
                    }
                    for index in duplicates.dropFirst() {
                        items[index].status = .cleanup
                        items[index].reason = "与保留安装包的 SHA-256 完全一致。"
                        items[index].retainedIDs = [items[duplicates[0]].id]
                    }
                }
                if byHash.count > 1 {
                    for index in sameVersion where items[index].status == .keep {
                        items[index].reason = "同版本存在不同内容，保留这些副本供人工判断。"
                    }
                }
            }

            let retained = Set(group.filter { items[$0].status == .keep }.map { items[$0].id })
            for index in group where items[index].status == .cleanup {
                items[index].retainedIDs = items[index].retainedIDs.filter(retained.contains)
            }
        }
    }

    private static func precedes(_ a: [Int], _ b: [Int]) -> Bool {
        a.lexicographicallyPrecedes(b)
    }

    private struct Preference: Comparable {
        var temporary: Int
        var depth: Int
        var path: String

        static func < (a: Preference, b: Preference) -> Bool {
            if a.temporary != b.temporary { return a.temporary < b.temporary }
            if a.depth != b.depth { return a.depth < b.depth }
            return a.path.utf8.lexicographicallyPrecedes(b.path.utf8)
        }
    }

    private static func preference(_ path: String) -> Preference {
        let parts = SweepPath.components(path)
        let words = ["download", "acceptance", "validation", "verify"]
        let temporary = parts.filter { part in
            let lower = part.lowercased()
            return words.contains(where: lower.contains)
        }.count
        return Preference(temporary: temporary, depth: parts.count, path: path)
    }

    // MARK: - 保护条件

    /// 找到最近的 Git 仓库，问它这个路径下有没有被跟踪的文件。
    /// 执行前的复核走这条：每次都问 Git，不用扫描轮次里的索引缓存。
    static func trackedReason(_ path: String, probes: SweepProbes) -> String? {
        guard let repository = repository(containing: path) else { return nil }
        return reason(for: probes.gitTracked(repository, SweepPath.relative(path, to: repository)))
    }

    static func trackedReason(_ path: String, cache: inout ScanGitCache) -> String? {
        guard let repository = repository(containing: path) else { return nil }
        return reason(for: cache.answer(repository: repository, relative: SweepPath.relative(path, to: repository)))
    }

    private static func repository(containing path: String) -> String? {
        SweepPath.ancestors(of: path).first { SweepFS.exists(SweepPath.join($0, ".git")) }
    }

    private static func reason(for answer: SweepGitAnswer) -> String? {
        switch answer {
        case .untracked: return nil
        case .tracked: return "包含 Git 已跟踪文件。"
        case .failed: return "无法完整读取所属仓库的 Git 索引。"
        case .missing: return "没有找到 git，无法确认是否包含已跟踪文件。"
        }
    }

    private static let developmentCommands = [
        "node", "python", "swift", "npm", "pnpm", "bun", "vite", "go",
        "cargo", "rustc", "xcodebuild", "pytest", "java", "ruby",
    ]

    struct PreparedOpenPath: Sendable {
        var pid: Int32
        var command: String
        var isCwd: Bool
        var isDevelopment: Bool
        var parts: SweepPath.Parts
    }

    /// 一轮扫描只拆一次。执行前那次 `lsof` 的结果也在用之前拆好。
    static func preparedOpenPaths(_ records: [SweepOpenPath]) -> [PreparedOpenPath] {
        records.map { record in
            let command = record.command.lowercased()
            return PreparedOpenPath(
                pid: record.pid,
                command: record.command,
                isCwd: record.isCwd,
                isDevelopment: developmentCommands.contains { command.hasPrefix($0) },
                parts: SweepPath.Parts(record.path)
            )
        }
    }

    /// 谁在用这个候选项：直接打开了里面的文件，或者是工作目录在所属项目里的开发工具。
    static func processUsers(path: String, project: String?, records: [SweepOpenPath]) -> [SweepProcessUser] {
        processUsers(
            path: SweepPath.Parts(path), project: project.map(SweepPath.Parts.init), records: preparedOpenPaths(records)
        )
    }

    static func processUsers(
        path: SweepPath.Parts, project: SweepPath.Parts?, records: [PreparedOpenPath]
    ) -> [SweepProcessUser] {
        var users: [SweepProcessUser] = []
        var seen = Set<Int32>()
        for record in records {
            let direct = record.parts.isInside(path)
            let projectUse = project.map { record.isCwd && record.isDevelopment && record.parts.isInside($0) } ?? false
            guard direct || projectUse else { continue }
            if seen.insert(record.pid).inserted {
                users.append(SweepProcessUser(pid: record.pid, command: record.command))
            } else if let index = users.firstIndex(where: { $0.pid == record.pid }) {
                users[index].command = record.command
            }
        }
        return users
    }
}

/// 一轮扫描内的 Git 索引。轮次结束就丢掉，不挂在长寿命的 `SweepProbes` 上。
struct ScanGitCache {
    private struct Entry {
        var answer: SweepGitAnswer?
        var folded: [String] = []
    }

    var probes: SweepProbes
    private var indexes: [String: Entry] = [:]

    mutating func answer(repository: String, relative: String) -> SweepGitAnswer {
        guard probes.gitIndex != nil else {
            return probes.gitTracked(repository, relative)
        }
        if indexes[repository] == nil {
            switch probes.gitIndex?(repository) ?? .failed {
            case .missing:
                indexes[repository] = Entry(answer: .missing)
            case .failed:
                indexes[repository] = Entry(answer: .failed)
            case .files(let files):
                indexes[repository] = Entry(folded: files.map(Self.fold))
            }
        }
        guard let entry = indexes[repository] else { return .failed }
        if let answer = entry.answer { return answer }
        return covers(Self.fold(relative), entry.folded) ? .tracked : .untracked
    }

    /// 大小写和 Unicode 归一化后再比，避免只是大小写不同的已跟踪路径被当成未跟踪。
    private static func fold(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func covers(_ relative: String, _ files: [String]) -> Bool {
        if relative == "." || relative.isEmpty { return !files.isEmpty }
        let prefix = relative + "/"
        return files.contains { $0 == relative || $0.hasPrefix(prefix) }
    }
}
