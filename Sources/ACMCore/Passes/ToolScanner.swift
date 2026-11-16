import Foundation

public struct ScanOptions: Sendable {
    public var env: HostEnvironment
    public var catalog: Catalog
    /// 进程探测；置空则不判断「正在运行」。
    public var processProbe: (@Sendable () -> [RunningProcess])?

    public init(
        env: HostEnvironment,
        catalog: Catalog,
        processProbe: (@Sendable () -> [RunningProcess])? = nil
    ) {
        self.env = env
        self.catalog = catalog
        self.processProbe = processProbe
    }
}

public enum ToolScanner {

    /// 只读扫描。不启动子进程，不修改任何东西。
    public static func scan(_ options: ScanOptions) -> ScanReport {
        ScanBuilder(options).run()
    }

    /// 报告里所有条目的路径，去重。
    public static func artifactPaths(_ report: ScanReport) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for group in report.groups {
            for a in group.artifacts where seen.insert(a.path).inserted { out.append(a.path) }
        }
        return out
    }

    /// 并发量大小，每量完一个回调一次（回调可能来自任意线程）。
    public static func measure(
        paths: [String],
        probe: any SizeProbe,
        onResult: @escaping @Sendable (String, SizeResult?) -> Void
    ) {
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            onResult(paths[index], probe.measure(paths[index]))
        }
    }

    public static func apply(sizes: [String: SizeResult], to report: ScanReport) -> ScanReport {
        var out = report
        for g in out.groups.indices {
            for a in out.groups[g].artifacts.indices {
                guard let size = sizes[out.groups[g].artifacts[a].path] else { continue }
                out.groups[g].artifacts[a].size = size
                if !size.accurate { out.groups[g].artifacts[a].flags.insert(.partialSize) }
            }
        }
        return out
    }

    /// 哪些进程正在使用这个工具的程序。执行卸载前会用它再查一遍。
    public static func runningPIDs(for group: ToolGroup, in processes: [RunningProcess]) -> [Int32] {
        runningPIDs(usingAnyOf: group.watchPaths, in: processes)
    }

    /// 哪些进程正在使用这些位置里的东西。
    ///
    /// 进程表里的路径是内核的写法（`/private/var/…`），所以每个位置同时按原样和
    /// `realpath` 之后的写法各比一次，否则经过软链的位置永远对不上。
    public static func runningPIDs(usingAnyOf roots: [String], in processes: [RunningProcess]) -> [Int32] {
        var variants = Set<String>()
        for root in roots where !root.isEmpty {
            variants.insert(PathUtil.standardize(root))
            variants.insert(PathUtil.standardize(FileProbe.kernelPath(root)))
        }
        let pids = processes.filter { p in variants.contains { p.uses($0) } }.map(\.pid)
        return Array(Set(pids)).sorted()
    }

    /// 目录条目的第一层子项，作为可以单独勾选的条目。
    ///
    /// 用来「留着工具、只清里面的旧版本或备份」。子项的归属随上级，默认都不勾选。
    public static func children(of parent: Artifact, in group: ToolGroup, env: HostEnvironment, limit: Int = 300) -> [Artifact] {
        guard parent.isDirectory, !parent.isSymlink,
              !parent.flags.contains(.invalidLauncher) else { return [] }
        let existing = Set(group.artifacts.map { PathUtil.key($0.path) })
        var out: [Artifact] = []
        for name in FileProbe.list(parent.path).prefix(limit) where name != ".DS_Store" {
            let path = parent.path + "/" + name
            guard !existing.contains(PathUtil.key(path)) else { continue }
            var child = Artifact(path: path, kind: parent.kind, claim: parent.claim, strength: parent.strength)
            child.parentPath = parent.path
            child.productID = parent.productID
            child.ownerAppName = parent.ownerAppName
            child.evidence = [Evidence(
                "上级目录", "位于 \(PathUtil.lastComponent(parent.path)) 之内，归属随上级", parent.strength
            )]
            child.flags = parent.flags.intersection([.shared, .inUse])
            if parent.claim == .usedByApp {
                child.flags.insert(.notRemovable)
                child.notRemovableReason = parent.notRemovableReason
                    ?? "由 \(parent.ownerAppName ?? "桌面 App") 使用，不在管理范围内"
            }
            child.foreignChildren = parent.foreignChildren.filter {
                PathUtil.isInside($0.path, path) || PathUtil.isInside(path, $0.path)
            }
            EvidenceRules.applyFlags(&child, env: env)
            child.flags.remove(.topLevelRoot)
            child.defaultSelected = false
            out.append(child)
        }
        return out
    }

    /// 同步量完所有大小（CLI 用）。
    public static func measured(_ report: ScanReport, probe: any SizeProbe) -> ScanReport {
        let table = SizeTable()
        measure(paths: artifactPaths(report), probe: probe) { path, size in
            if let size { table.set(path, size) }
        }
        return apply(sizes: table.snapshot(), to: report)
    }
}

final class SizeTable: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: SizeResult] = [:]

    func set(_ path: String, _ size: SizeResult) {
        lock.lock(); defer { lock.unlock() }
        values[path] = size
    }

    func snapshot() -> [String: SizeResult] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

/// 把各个探测器的结果汇总成「哪些工具、各自有哪些文件、每个文件归谁」。
///
/// 顺序就是证据的优先级：
///   1. 二进制链路 → 已装的 CLI
///   2. 目录清单声明的路径
///   3. 包含关系（程序就在这个目录里）
///   4. 名称与已装的桌面 App 相似 → 保守地当成 App 在用
///   5. 名称与已发现的命令相同
///   6. 悬空软链
///   7. 内容标记 → 仅列入「未识别」
/// 先到先得：一个路径一旦被归组，后面的规则不再改判。
final class ScanBuilder {
    let options: ScanOptions
    let env: HostEnvironment
    let catalog: Catalog

    private var apps: [AppInfo] = []
    private var appIndex = AppKeyIndex(apps: [])
    private var groups: [String: ToolGroup] = [:]
    private var groupOrder: [String] = []
    /// 路径比较键 → 所属组
    private var owner: [String: String] = [:]
    /// 名称键 → 有命令的组（已装、其他、损坏）
    private var cliKeys: [String: String] = [:]
    /// 名称键 → 由目录清单产生的组：只按整名匹配，避免通用名字误挂
    private var strictKeys: [String: String] = [:]
    /// 名称键 → 由家目录里的条目推出来的组（残留、未识别）：名字本身来自目录，可以放宽匹配
    private var looseKeys: [String: String] = [:]
    private var binDirs: [BinDir] = []
    /// 各命令的链路里，被两个以上不同名命令经过的那些环：volta-shim、mise 这类调度程序，
    /// 以及通往它们的软链。只有没有自己程序目录的命令才算「借用」它们，见 `borrows`。
    private var sharedHops: Set<String> = []

    private struct Bucket {
        var groupID: String
        var bins: [BinaryInfo]
    }

    init(_ options: ScanOptions) {
        self.options = options
        self.env = options.env
        self.catalog = options.catalog
    }

    func run() -> ScanReport {
        apps = AppRegistry.scan(env)
        appIndex = AppKeyIndex(apps: apps)
        binDirs = PathProbe.binDirs(env: env)
        let binaries = BinaryRegistry.scan(env: env, catalog: catalog, binDirs: binDirs)

        let buckets = buildCLIGroups(binaries)
        claimCatalogPaths()
        addBinaryArtifacts(buckets)
        attributeDotEntries(DotRootScanner.scan(env: env))
        if env.includeLibrary {
            attributeLibraryEntries(LibraryScanner.scan(env: env))
        }
        attachRcLines()
        markRunning()
        annotateCrossGroupReferences()

        let disk = DiskSpace.volume(at: env.home)
        return ScanReport(
            scannedAt: env.now,
            groups: finalize(),
            binDirs: binDirs.map(\.path),
            diskFreeBytes: disk?.free,
            diskTotalBytes: disk?.total
        )
    }

    // MARK: - 1. 命令 → 工具

    private func buildCLIGroups(_ binaries: [BinaryInfo]) -> [Bucket] {
        // 先给每个入口独立认定身份，再合并。绝不能先按目录分桶、再用桶里任意一个
        // 命令决定整桶是谁的——共享 shim 目录里往往同时有 node、npm 和 Agent CLI。
        var buckets: [Bucket] = []
        var bucketIndex: [String: Int] = [:]
        // 所有命令都要数，包括有自己程序目录的：`~/.local/bin/mise` 是个普通命令，
        // 但它和指向它的那个 shim 是两个名字，哪怕 shim 只有一个。
        var hopUsers: [String: Set<String>] = [:]
        for binary in binaries where binary.invalidTarget == nil {
            for hop in binary.chain {
                hopUsers[PathUtil.key(hop), default: []].insert(PathUtil.nameKey(binary.name))
            }
        }
        sharedHops = Set(hopUsers.filter { $0.value.count > 1 }.keys)
        for var binary in binaries {
            let borrowed = binary.chain.filter { borrows(binary, $0) }
            if !borrowed.isEmpty { binary.borrowedHops = borrowed }
            let root = binary.payloadRoot ?? binary.finalTarget ?? binary.path
            let product = matchProduct([binary], root: root)
            let identity: String
            if let product {
                identity = "product:" + product.id
            } else if let root = binary.payloadRoot {
                identity = "root:" + PathUtil.key(root)
            } else if let target = ownTarget(binary) {
                // 没有程序目录（工具管理器里的命令）时按它自己的最后一环认。不能一路走到
                // 链尾：管理器的 shim 是所有命令共用的，按它合并会把 node、npm 并到一起。
                identity = "target:" + PathUtil.key(target)
            } else {
                identity = "entry:" + PathUtil.key(binary.path)
            }
            if let index = bucketIndex[identity] {
                buckets[index].bins.append(binary)
            } else {
                bucketIndex[identity] = buckets.count
                buckets.append(Bucket(groupID: "", bins: [binary]))
            }
        }

        for bucketIndex in buckets.indices {
            let bins = buckets[bucketIndex].bins
            let root = bins.compactMap(\.payloadRoot).first ?? bins[0].finalTarget ?? bins[0].path
            let product = bins.compactMap { matchProduct([$0], root: $0.payloadRoot ?? $0.finalTarget ?? $0.path) }.first
            let primary = bins.map(\.name).min { ($0.count, $0) < ($1.count, $1) } ?? "?"
            let working = bins.filter { !$0.isBroken }
            // 「其他命令」的组 id 和成组身份落在同一处，否则这里会把分开的桶再合并一次。
            let otherID = "other:" + PathUtil.key(
                bins.compactMap(\.payloadRoot).first ?? ownTarget(bins[0]) ?? bins[0].path)

            var notes: [String] = []
            let section: Section
            let id: String

            if working.isEmpty {
                section = .residue
                // 入口指向目录/不可执行文件时，仍保留产品的稳定 id 供报告和定位，
                // 但 section 是残留，且 invalidLauncher 会否决一切默认勾选。
                let invalidOnly = product != nil && bins.allSatisfy { $0.invalidTarget != nil }
                id = (invalidOnly ? "cli:" : "residue:") + (product?.id ?? PathUtil.nameKey(primary))
                for b in bins {
                    if let target = b.brokenShimTarget {
                        notes.append("启动脚本 \(show(b.path)) 要执行的 \(target) 已不存在")
                    } else if let what = b.invalidTarget {
                        notes.append("\(show(b.path)) 指向\(what)，不是可执行程序；只报告异常入口，不把它当作程序本体")
                    } else {
                        notes.append("\(show(b.path)) 是悬空软链，它指向的程序已不存在")
                    }
                }
            } else if let product {
                section = .installed
                id = "cli:" + product.id
                for b in working {
                    if let identifier = b.signIdentifier, let expected = product.codeIdentifiers, !expected.isEmpty,
                       (product.binaries ?? []).contains(b.name), !expected.contains(identifier) {
                        notes.append("\(b.name) 的签名标识是 \(identifier)，与目录清单登记的 \(expected.joined(separator: "、")) 不一致")
                    }
                }
            } else if working.allSatisfy({ $0.channel == .appProvided }) {
                section = .otherCLI
                id = otherID
                notes.append("随桌面 App 提供的命令，不单独管理")
            } else {
                let markers = agentMarkers(root: root)
                if markers.isAgentLike {
                    section = .installed
                    id = "cli:" + PathUtil.nameKey(primary)
                    let why = markers.hits.isEmpty ? "名称" : "目录里有 " + markers.hits.prefix(4).joined(separator: "、")
                    notes.append("目录清单没有收录，按\(why)判断为 Agent 工具")
                } else {
                    section = .otherCLI
                    id = otherID
                }
            }

            if var existing = groups[id] {
                existing.binaries += bins
                if section == .installed {
                    existing.notes.append("经多个位置重复安装，PATH 上靠前的那个生效")
                }
                existing.notes += notes
                existing.manualCommands = UninstallPlanner.unique(existing.manualCommands + manualCommands(for: working))
                groups[id] = existing
            } else {
                var group = ToolGroup(
                    id: id,
                    name: product?.name ?? primary,
                    vendor: product?.vendor,
                    section: section,
                    productID: product?.id,
                    binaries: bins,
                    // 借共用调度程序启动的命令，链尾路径里的版本号是调度程序的。
                    version: working.filter { bin in bin.finalTarget.map { !borrows(bin, $0) } ?? true }
                        .compactMap(\.version).first ?? versionFromFile(product),
                    channel: working.first?.channel ?? bins.first?.channel,
                    notes: notes,
                    docs: product?.docs,
                    homepage: product?.homepage,
                    installMethods: product?.install ?? [],
                    uninstallCommand: product?.uninstallCommand
                )
                group.manualCommands = manualCommands(for: working)
                groups[id] = group
                groupOrder.append(id)
            }

            var keys = bins.map { PathUtil.nameKey($0.name) }
            if let product { keys += productKeys(product) }
            for k in keys where k.count >= 2 && cliKeys[k] == nil { cliKeys[k] = id }
            buckets[bucketIndex].groupID = id
        }
        return buckets
    }

    /// 归到目录清单里的哪个产品。签名标识最可信，其次包名，再次命令名，最后看程序所在位置。
    /// 调用方按单个入口调用，避免同目录的其他命令污染身份。
    private func matchProduct(_ bins: [BinaryInfo], root: String) -> CatalogProduct? {
        for b in bins {
            if let identifier = b.signIdentifier,
               let p = catalog.product(matchingCodeIdentifier: identifier), p.kind == .cli { return p }
        }
        for b in bins {
            if let package = b.packageName,
               let p = catalog.products.first(where: { $0.kind == .cli && ($0.packages ?? []).contains(package) }) {
                return p
            }
        }
        for b in bins {
            if let p = catalog.product(matchingBinary: b.name), p.kind == .cli { return p }
        }
        if let claim = catalog.claim(for: root, home: env.home),
           claim.product.kind == .cli, claim.declared.kind == .program {
            return claim.product
        }
        return nil
    }

    private func agentMarkers(root: String) -> ContentMarkers.Result {
        guard PathUtil.isStrictlyInside(root, env.home), FileProbe.isDirectory(root),
              !DotRootScanner.ignoredTopLevel.contains(PathUtil.lastComponent(root))
        else {
            return ContentMarkers.Result(hits: [], nameHint: nil, isAgentLike: false)
        }
        return ContentMarkers.evaluate(name: PathUtil.lastComponent(root), children: FileProbe.list(root))
    }

    private func versionFromFile(_ product: CatalogProduct?) -> String? {
        guard let file = product?.versionFile,
              let text = FileProbe.readText(PathUtil.expand(file, home: env.home), max: 256)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func manualCommands(for bins: [BinaryInfo]) -> [String] {
        var out: [String] = []
        for b in bins {
            guard let package = b.packageName else { continue }
            switch b.channel {
            case .brew:
                // 包名来自文件系统，即使不符合命名规范也只能作为参数引用，不能拼成 shell 源码。
                out.append("brew uninstall " + ShellText.quote(package))
            case .npm where !PathUtil.isInside(b.payloadRoot ?? b.path, env.home):
                out.append("npm uninstall -g " + ShellText.quote(package))
            default: break
            }
        }
        return UninstallPlanner.unique(out)
    }

    private func productKeys(_ product: CatalogProduct) -> [String] {
        var keys = [PathUtil.nameKey(product.id), PathUtil.nameKey(product.name)]
        keys += (product.binaries ?? []).map { PathUtil.nameKey($0) }
        if let first = PathUtil.nameTokens(product.id).first { keys.append(first) }
        return keys
    }

    // MARK: - 2. 目录清单声明的路径

    private func claimCatalogPaths() {
        for product in catalog.products {
            let cliGroupID = "cli:" + product.id
            let cliInstalled = product.kind == .cli && groups[cliGroupID] != nil
            let companions = (product.companionApps ?? []).compactMap { appIndex.exact(bundleID: $0) }
            let ownApps = (product.bundleIDs ?? []).compactMap { appIndex.exact(bundleID: $0) }

            for declared in product.paths ?? [] {
                let path = PathUtil.expand(declared.path, home: env.home)
                guard FileProbe.lstat(path) != nil else { continue }

                var a = Artifact(path: path, kind: declared.kind, claim: .residue, strength: .certain)
                a.evidence = [Evidence("目录清单", "\(product.name) 使用 \(declared.path)", .certain)]
                a.declaredPath = declared.path
                a.productID = product.id
                a.note = declared.note
                a.declaredExclusive = declared.exclusive ?? false

                // 即使 CLI 存在，也要检查目录里是否有桌面 App 的子目录。
                // 不能因为找到了 gemini 命令，就把 ~/.gemini/antigravity 当成 CLI 独占。
                let nested = nestedAppOwner(path)
                if cliInstalled {
                    if let nested {
                        a.claim = .shared
                        a.flags.insert(.shared)
                        a.ownerAppName = nested.app.name
                        a.evidence.append(Evidence(
                            "目录里还有别人", "里面有 \(nested.child)/，与已安装的 \(nested.app.name) 有关", .certain
                        ))
                    } else if declared.shared == true, let app = companions.first {
                        a.claim = .shared
                        a.flags.insert(.shared)
                        a.ownerAppName = app.name
                        a.evidence.append(Evidence("共用", "已安装的 \(app.name) 也使用这个位置", .certain))
                    } else {
                        a.claim = .ownedByCLI
                    }
                    add(a, to: cliGroupID)
                } else if let app = (product.kind == .app ? ownApps.first : companions.first) {
                    // 命令不在，但同厂的桌面 App 还在：一律当成 App 在用，不列为残留。
                    a.claim = .usedByApp
                    a.strength = (product.kind == .app || declared.shared == true) ? .certain : .probable
                    a.ownerAppName = app.name
                    a.evidence.append(Evidence("主人仍在", "\(app.name)（\(app.bundleID)）已安装", .certain))
                    add(a, to: appGroup(app))
                } else if let similar = appIndex.match(name: PathUtil.lastComponent(path), allowPrefix: false) {
                    // 清单说它是残留，但名字和某个已装的 App 相同——宁可信其有。
                    a.claim = .usedByApp
                    a.strength = .probable
                    a.ownerAppName = similar.app.name
                    a.evidence.append(Evidence("名称相似", similar.reason + "，按保守处理", .probable))
                    add(a, to: appGroup(similar.app))
                } else if let nested {
                    // 清单说这个目录是残留，但里面已经有一个属于已装 App 的子目录了
                    // （例：~/.gemini 里出现 antigravity/，说明 Antigravity.app 也在用这个位置）。
                    // 这种时候不下残留的结论。
                    a.claim = .usedByApp
                    a.strength = .probable
                    a.ownerAppName = nested.app.name
                    a.evidence.append(Evidence(
                        "目录里还有别人", "里面有 \(nested.child)/，与已安装的 \(nested.app.name) 有关", .probable
                    ))
                    add(a, to: appGroup(nested.app))
                } else {
                    a.claim = .residue
                    a.evidence.append(Evidence("主人不在", "没有找到 \(product.name) 的命令或对应的 App", .certain))
                    add(a, to: residueGroup(product))
                }
            }
        }
    }

    // MARK: - 链路上的各环

    private func addBinaryArtifacts(_ buckets: [Bucket]) {
        for bucket in buckets {
            guard let group = groups[bucket.groupID] else { continue }
            let claim: Claim = group.section == .residue ? .residue : .ownedByCLI

            // 一组入口只说明一次，哪怕其中两条都经过同一个共用启动器。
            var explained = false
            for bin in bucket.bins {
                for (index, hop) in bin.chain.enumerated() {
                    guard FileProbe.lstat(hop) != nil else { continue }
                    let isLast = index == bin.chain.count - 1

                    // 共用的调度程序（和通往它的软链）只归它自己那个入口；别的命令只是借它
                    // 启动，把它列进来等于让卸载一个命令带走整条工具链。
                    if borrows(bin, hop) {
                        if !explained {
                            explained = true
                            groups[bucket.groupID]?.notes.append(borrowedNote(bucket.bins, hop))
                        }
                        continue
                    }

                    if isLast, bin.finalTarget != nil, bin.brokenShimTarget == nil, bin.invalidTarget == nil {
                        // 末端：程序本体
                        guard bin.channel != .appProvided else { continue }
                        let unit = programUnit(bin)
                        var a = Artifact(path: unit, kind: .program, claim: claim, strength: .certain)
                        a.evidence = [Evidence("二进制链路", "命令 \(bin.name) 最终执行的就是这里", .certain)]
                        if !PathUtil.isInside(unit, env.home), [.brew, .npm].contains(bin.channel) {
                            a.flags.formUnion([.packageManaged, .manualOnly])
                            a.note = "由 \(bin.channel.displayName) 托管，请用下方命令卸载"
                        }
                        add(a, to: bucket.groupID)
                    } else {
                        var a = Artifact(path: hop, kind: .launcher, claim: claim, strength: .certain)
                        if isLast, let target = bin.brokenShimTarget {
                            a.flags.insert(.brokenShim)
                            a.evidence = [Evidence("启动脚本失效", "脚本要执行的 \(target) 已不存在", .certain)]
                        } else if isLast, let what = bin.invalidTarget {
                            a.flags.insert(.invalidLauncher)
                            a.evidence = [Evidence("入口异常", "链尾是\(what)，不是可执行程序；没有把它当成程序本体", .certain)]
                        } else if bin.isDangling {
                            a.flags.insert(.danglingSymlink)
                            a.evidence = [Evidence("悬空软链", "链路末端 \(show(bin.chain.last ?? hop)) 不存在", .certain)]
                        } else {
                            let what = index == 0 ? "命令 \(bin.name) 的入口" : "链路中间一环"
                            a.evidence = [Evidence("二进制链路", "\(what)，指向 \(show(bin.finalTarget ?? ""))", .certain)]
                        }
                        add(a, to: bucket.groupID)
                    }
                }
            }
        }
    }

    /// `hop` 是不是 `bin` 借来的：它在入口之后，而且别的名字的命令也从这里过。
    private func borrows(_ bin: BinaryInfo, _ hop: String) -> Bool {
        bin.payloadRoot == nil && bin.invalidTarget == nil
            && PathUtil.key(hop) != PathUtil.key(bin.path) && sharedHops.contains(PathUtil.key(hop))
    }

    /// 这个命令自己的最后一环：从入口往下，走到别的名字也经过的那一环之前为止。
    /// 不借用任何东西时就是链尾；链路悬空时没有。
    private func ownTarget(_ bin: BinaryInfo) -> String? {
        guard bin.finalTarget != nil else { return nil }
        return bin.chain.last { !borrows(bin, $0) }
    }

    /// 只写查得到的事实：经哪个文件启动、入口在谁的目录里。「程序由谁管理」不写——
    /// 入口所在目录说明不了这一点（`~/.cargo/bin/rustc` 归 rustup 管）。
    private func borrowedNote(_ bins: [BinaryInfo], _ hop: String) -> String {
        let manager = bins.lazy.compactMap { BinaryRegistry.toolManager(for: $0.path, home: self.env.home) }.first
        let place = manager.map { "（入口在 \($0) 的目录里）" } ?? ""
        return "\(bins[0].name) 经共用的 \(show(hop)) 启动\(place)。这里只列它自己的入口；"
            + "背后的程序不归这个入口所有，要彻底卸载请用安装它的那个工具"
    }

    /// 包管理器装的以整个包目录为单位；厂商安装器装的以最终那个文件为单位。
    private func programUnit(_ bin: BinaryInfo) -> String {
        switch bin.channel {
        case .npm, .pnpm, .bun, .uv, .pipx, .brew:
            return bin.payloadRoot ?? bin.finalTarget ?? bin.path
        default:
            return bin.finalTarget ?? bin.path
        }
    }

    // MARK: - 3–7. 点目录

    private func attributeDotEntries(_ entries: [DotEntry]) {
        for entry in entries {
            if isCovered(entry.path) { continue }
            let kind = guessKind(container: entry.container)
            let nameKey = PathUtil.nameKey(entry.name)
            let firstToken = PathUtil.nameTokens(entry.name).first
            let nested = entry.isDirectory ? nestedAppOwner(entry.path) : nil

            // 3. 包含关系：某个已发现命令的程序就放在这个目录里
            if let groupID = groupWhosePayloadRootIs(entry.path), let group = groups[groupID] {
                let residue = group.section == .residue
                var a = Artifact(
                    path: entry.path, kind: .data,
                    claim: residue ? .residue : .ownedByCLI,
                    strength: residue ? .probable : .certain
                )
                a.evidence = [Evidence(
                    "包含关系",
                    residue ? "失效的命令 \(group.name) 原本指向这个目录里" : "\(group.name) 的程序本体就在这个目录里",
                    a.strength
                )]
                a.note = "厂商目录，程序与数据混放"
                if let nested {
                    a.claim = .shared
                    a.flags.insert(.shared)
                    a.ownerAppName = nested.app.name
                    a.evidence.append(Evidence(
                        "目录里还有别人", "里面有 \(nested.child)/，与已安装的 \(nested.app.name) 有关", .probable
                    ))
                } else if !residue, let similar = appIndex.match(name: entry.name) {
                    a.claim = .shared
                    a.flags.insert(.shared)
                    a.ownerAppName = similar.app.name
                    a.evidence.append(Evidence("名称相似", similar.reason + "，可能共用", .probable))
                }
                add(a, to: groupID)
                continue
            }

            // 清单未收录的目录同样需要保护其中的桌面 App 数据。
            // 子目录名称只能提供推测证据，按保守归属展示。
            if let nested {
                var a = Artifact(path: entry.path, kind: kind, claim: .usedByApp, strength: .probable)
                a.ownerAppName = nested.app.name
                a.evidence = [Evidence(
                    "目录里还有别人", "里面有 \(nested.child)/，与已安装的 \(nested.app.name) 有关", .probable
                )]
                add(a, to: appGroup(nested.app))
                continue
            }

            // 4. 名字像某个已装的桌面 App：当成它在用
            if let similar = appIndex.match(name: entry.name) {
                var a = Artifact(path: entry.path, kind: kind, claim: .usedByApp, strength: .probable)
                a.evidence = [Evidence("名称相似", similar.reason, .probable)]
                a.ownerAppName = similar.app.name
                add(a, to: appGroup(similar.app))
                continue
            }

            // 5. 名字与某个已发现的命令相同
            var cliMatch = cliKeys[nameKey]
            if cliMatch == nil, let firstToken, let id = cliKeys[firstToken], groups[id]?.section == .installed {
                cliMatch = id
            }
            if let groupID = cliMatch, let group = groups[groupID] {
                let residue = group.section == .residue
                var a = Artifact(path: entry.path, kind: kind, claim: residue ? .residue : .ownedByCLI, strength: .probable)
                a.evidence = [Evidence("名称相同", "与命令 \(group.binaries.first?.name ?? group.name) 同名", .probable)]
                add(a, to: groupID)
                continue
            }

            // 6. 悬空软链：指向的东西已经没了，这是客观事实
            if entry.isDangling {
                let key = firstToken ?? nameKey
                let groupID = looseGroup(.residue, key: key, name: stripDot(entry.name))
                var a = Artifact(path: entry.path, kind: .other, claim: .residue, strength: .certain)
                a.flags.insert(.danglingSymlink)
                a.evidence = [Evidence("悬空软链", "指向的 \(entry.symlinkTarget ?? "目标") 已不存在", .certain)]
                add(a, to: groupID)
                continue
            }

            // 7. 内容像 Agent 工具：列出来给人看，不下结论
            let markers = ContentMarkers.evaluate(name: entry.name, children: entry.children)
            guard markers.isAgentLike else { continue }
            let existing = looseKeys[nameKey] ?? firstToken.flatMap { looseKeys[$0] }
            let groupID = existing ?? looseGroup(.unidentified, key: nameKey, name: stripDot(entry.name))
            let residue = groups[groupID]?.section == .residue
            let strong = !markers.hits.isEmpty
            var a = Artifact(
                path: entry.path, kind: kind,
                claim: residue ? .residue : .candidate,
                strength: strong ? .probable : .speculative
            )
            if strong {
                a.evidence.append(Evidence("内容标记", "目录里有 " + markers.hits.prefix(6).joined(separator: "、"), .probable))
            }
            if let hint = markers.nameHint {
                a.evidence.append(Evidence("名称", "名称里含有 \(hint)", .speculative))
            }
            a.evidence.append(Evidence("主人不明", "没有找到同名的命令或已安装的 App", .speculative))
            add(a, to: groupID)
        }
    }

    /// 目录的第一层里，有没有哪个子目录的名字正好属于某个已装的 App。
    ///
    /// 只认「子目录」且「整名一致」：文件名或 `claude-oauth-cache.lock` 这类
    /// 以某个 App 名字开头的名字都不算，否则 `~/.codexbar` 会被算到 Claude 头上。
    private func nestedAppOwner(_ path: String) -> (child: String, app: AppInfo)? {
        guard FileProbe.isDirectory(path) else { return nil }
        for child in FileProbe.list(path) {
            let childPath = path + "/" + child
            guard !child.hasPrefix("."), FileProbe.isDirectory(childPath) else { continue }
            if let match = appIndex.match(name: child, allowPrefix: false) {
                return (child, match.app)
            }
        }
        return nil
    }

    private func guessKind(container: String) -> ArtifactKind {
        switch container {
        case ".cache": return .cache
        case ".config": return .config
        default: return .data
        }
    }

    private func groupWhosePayloadRootIs(_ path: String) -> String? {
        let key = PathUtil.key(path)
        for id in groupOrder {
            guard let group = groups[id] else { continue }
            if group.binaries.contains(where: { $0.payloadRoot.map(PathUtil.key) == key && $0.payloadRoot != $0.path }) {
                return id
            }
        }
        return nil
    }

    // MARK: - Library

    private func attributeLibraryEntries(_ entries: [LibraryEntry]) {
        for entry in entries {
            if isCovered(entry.path) { continue }

            // 已装 App 自己的数据：不列
            if entry.bundleIDCandidates.contains(where: { appIndex.exact(bundleID: $0) != nil }) { continue }

            // bundle id 精确对上目录清单里的产品，而那个 App 不在
            var matched = false
            for candidate in entry.bundleIDCandidates {
                guard let product = catalog.product(matchingBundleID: candidate) else { continue }
                var a = Artifact(path: entry.path, kind: entry.kind, claim: .residue, strength: .certain)
                a.evidence = [
                    Evidence("bundle id", "\(candidate) 在目录清单里属于 \(product.name)", .certain),
                    Evidence("主人不在", "没有安装 bundle id 为 \(candidate) 的 App", .certain),
                ]
                a.productID = product.id
                add(a, to: residueGroup(product))
                matched = true
                break
            }
            if matched { continue }

            // 与已装 App 沾边的：不碰
            if isRelatedToInstalledApp(entry) { continue }

            let base = entry.bundleIDCandidates.first ?? entry.name
            let whole = PathUtil.nameKey(base)

            // 与某个已发现命令同名
            if !LibraryScanner.looksLikeBundleID(base), let groupID = cliKeys[PathUtil.nameKey(base)],
               let group = groups[groupID] {
                let residue = group.section == .residue
                var a = Artifact(path: entry.path, kind: entry.kind, claim: residue ? .residue : .ownedByCLI, strength: .probable)
                a.evidence = [Evidence("名称相同", "与命令 \(group.binaries.first?.name ?? group.name) 同名", .probable)]
                add(a, to: groupID)
                continue
            }

            // 与某个组同名。目录清单那一侧的组（strictKeys）只认整名一致：
            // `Gemini CLI` 这种通用名字按词匹配的话，`com.BZG.Gemini`
            // （另一个同名 App）就会被挂到它下面。
            // 由家目录里的条目推出来的组（looseKeys）才可以放宽到首词和前缀。
            var looseMatch = strictKeys[whole].flatMap { groups[$0] == nil ? nil : $0 }
            if looseMatch == nil, let id = looseKeys[whole] {
                looseMatch = id
            }
            if looseMatch == nil, !LibraryScanner.looksLikeBundleID(base) {
                if let first = PathUtil.nameTokens(base).first, first.count >= 4, let id = looseKeys[first] {
                    looseMatch = id
                }
            }
            if looseMatch == nil {
                for (key, id) in looseKeys where key.count >= 5 && whole.hasPrefix(key) {
                    looseMatch = id
                    break
                }
            }
            if let groupID = looseMatch, let group = groups[groupID] {
                let residue = group.section == .residue
                var a = Artifact(path: entry.path, kind: entry.kind, claim: residue ? .residue : .candidate, strength: .probable)
                a.evidence = [Evidence("名称相同", "名称与「\(group.name)」对得上", .probable)]
                add(a, to: groupID)
            }
        }
    }

    private func isRelatedToInstalledApp(_ entry: LibraryEntry) -> Bool {
        for candidate in entry.bundleIDCandidates {
            if LibraryScanner.looksLikeBundleID(candidate) {
                // com.openai.codex.notifications 这类：前缀是已装 App 的 bundle id
                var parts = candidate.split(separator: ".").map(String.init)
                while parts.count > 2 {
                    parts.removeLast()
                    if appIndex.exact(bundleID: parts.joined(separator: ".")) != nil { return true }
                }
                for token in PathUtil.bundleIDTokens(candidate) where appIndex.match(name: token) != nil {
                    return true
                }
            } else if appIndex.match(name: candidate) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - rc 文件、运行状态

    private func attachRcLines() {
        let generic: Set<String> = [".local", ".config", ".cache", ".cargo", ".nvm", ".npm", ".bun", ".deno"]
        for id in groupOrder {
            guard let group = groups[id], group.section != .managedByApp else { continue }
            var names = Set<String>()
            for path in group.artifacts.map(\.path) + group.binaries.compactMap(\.payloadRoot) {
                guard PathUtil.isStrictlyInside(path, env.home) else { continue }
                let rel = PathUtil.components(String(PathUtil.standardize(path).dropFirst(env.home.count)))
                guard let first = rel.first, first.hasPrefix("."), !generic.contains(first) else { continue }
                if FileProbe.isDirectory(env.home + "/" + first) { names.insert(first) }
            }
            groups[id]?.rcLines = RcMarkerScanner.lines(mentioning: names.sorted(), env: env)
        }
    }

    private func markRunning() {
        guard let probe = options.processProbe else { return }
        let processes = probe()
        guard !processes.isEmpty else { return }

        for id in groupOrder {
            guard let group = groups[id], !group.binaries.isEmpty,
                  group.section == .installed || group.section == .otherCLI
            else { continue }
            groups[id]?.runningPIDs = ToolScanner.runningPIDs(for: group, in: processes)
        }
    }

    // MARK: - 跨组引用与保护

    /// 一个路径可能同时被两个组提到：例如父目录归残留，里面的子目录却归已安装的
    /// 桌面 App；或者两个命令共享一个程序。先把这些关系写回条目，再计算默认勾选，
    /// 让规划器和界面看到同一份事实。
    private func annotateCrossGroupReferences() {
        let all = groupOrder.flatMap { id in
            (groups[id]?.artifacts ?? []).map { (id: id, artifact: $0) }
        }
        for id in groupOrder {
            guard var group = groups[id] else { continue }
            for index in group.artifacts.indices {
                let path = group.artifacts[index].path
                var foreign: [ForeignChild] = []
                for other in all where other.id != id && PathUtil.isStrictlyInside(other.artifact.path, path) {
                    let appOwned = other.artifact.claim == .usedByApp || groups[other.id]?.section == .managedByApp
                    foreign.append(ForeignChild(
                        path: other.artifact.path,
                        owner: other.artifact.ownerAppName ?? groups[other.id]?.name ?? "另一个工具",
                        usedByApp: appOwned,
                        certain: other.artifact.strength == .certain
                    ))
                }
                group.artifacts[index].foreignChildren = foreign.sorted { $0.path < $1.path }

                // 保护也必须从 App 所有的祖先目录向下生效。二进制链路只能证明
                // “会执行这里”，不能推翻 App 对这个目录的归属；只有更具体的
                // CLI 独占声明可以例外，宽泛的厂商根目录声明不算。
                let declared = catalog.claim(for: path, home: env.home)
                let exclusiveCLI = declared?.product.kind == .cli
                    && declared?.product.id == group.productID
                    && declared?.declared.exclusive == true
                    && declared?.declared.shared != true
                if !exclusiveCLI {
                    let appAncestors = all.filter {
                        $0.id != id && PathUtil.isStrictlyInside(path, $0.artifact.path)
                            && ($0.artifact.claim == .usedByApp || groups[$0.id]?.section == .managedByApp)
                    }.sorted {
                        if $0.artifact.strength != $1.artifact.strength {
                            return $0.artifact.strength > $1.artifact.strength
                        }
                        return $0.artifact.path.count > $1.artifact.path.count
                    }
                    if let ancestor = appAncestors.first {
                        let app = ancestor.artifact.ownerAppName ?? groups[ancestor.id]?.name ?? "桌面 App"
                        group.artifacts[index].ownerAppName = app
                        let detail = "位于 \(app) 使用的 \(show(ancestor.artifact.path)) 之内，未声明为 CLI 独占"
                        group.artifacts[index].evidence.append(Evidence("上级 App 归属", detail, ancestor.artifact.strength))
                        if ancestor.artifact.strength == .certain {
                            group.artifacts[index].claim = .usedByApp
                            group.artifacts[index].flags.insert(.notRemovable)
                            group.artifacts[index].notRemovableReason = detail + "，不能移走"
                        } else {
                            group.artifacts[index].claim = .shared
                            group.artifacts[index].flags.insert(.shared)
                        }
                    }
                }

                // 这个程序是否还被别的组的命令使用。按整条链路比对，能覆盖
                // 「程序本体在 A 组、B 组只有一个入口」的情况。
                var names: [String] = []
                // 目录移动覆盖其全部后代；保护必须先落到父目录，不能只留在
                // 随后会被 pruneNested 折叠掉的叶子上。软链本身只按精确路径比较。
                let movesDescendants = FileProbe.lstat(path)?.isDirectory == true
                for otherID in groupOrder where otherID != id {
                    for binary in groups[otherID]?.binaries ?? [] {
                        let references = binary.chain + [binary.payloadRoot].compactMap { $0 }
                        let used = references.contains {
                            movesDescendants ? PathUtil.isInside($0, path) : PathUtil.key($0) == PathUtil.key(path)
                        }
                        if used { names.append(binary.name) }
                    }
                }
                if !names.isEmpty {
                    group.artifacts[index].flags.insert(.usedByOthers)
                    group.artifacts[index].alsoUsedBy = Array(Set(names)).sorted()
                }
            }
            groups[id] = group
        }
    }

    // MARK: - 收尾

    private func finalize() -> [ToolGroup] {
        var out: [ToolGroup] = []
        for id in groupOrder {
            guard var group = groups[id] else { continue }
            group.artifacts = pruneNested(group.artifacts)

            // 厂商目录被判为「可能与桌面 App 共用」时，里面没有被目录清单单独声明的东西
            // 也按共用对待——不能目录不让删、里面的程序却默认勾着。
            let sharedRoots = group.artifacts.filter { $0.flags.contains(.shared) }
            for i in group.artifacts.indices
            where group.artifacts[i].declaredPath == nil
                && group.artifacts[i].claim != .usedByApp
                && !group.artifacts[i].flags.contains(.shared) {
                guard let root = sharedRoots.first(where: {
                    PathUtil.isStrictlyInside(group.artifacts[i].path, $0.path)
                }) else { continue }
                group.artifacts[i].flags.insert(.shared)
                group.artifacts[i].claim = .shared
                group.artifacts[i].ownerAppName = root.ownerAppName
                group.artifacts[i].evidence.append(Evidence(
                    "共用", "位于可能与 \(root.ownerAppName ?? "桌面 App") 共用的目录里", .probable
                ))
            }

            for i in group.artifacts.indices {
                EvidenceRules.applyFlags(&group.artifacts[i], env: env)
                if group.isRunning { group.artifacts[i].flags.insert(.inUse) }
                if group.artifacts[i].flags.contains(.recentlyModified),
                   group.section == .residue || group.section == .unidentified,
                   let modified = group.artifacts[i].lastModified {
                    let days = max(0, Int(env.now.timeIntervalSince(modified) / 86_400))
                    group.artifacts[i].evidence.append(Evidence(
                        "最近写入", days == 0 ? "今天还有改动" : "\(days) 天前还有改动，可能仍有程序在用", .speculative
                    ))
                }
            }
            for i in group.artifacts.indices {
                group.artifacts[i].defaultSelected = EvidenceRules.defaultSelected(group.artifacts[i], in: group.section)
            }
            group.artifacts.sort { ($0.kind.order, $0.path) < ($1.kind.order, $1.path) }

            if group.artifacts.isEmpty && group.binaries.isEmpty { continue }
            out.append(group)
        }
        out.sort { ($0.section.order, $0.name.lowercased()) < ($1.section.order, $1.name.lowercased()) }
        return out
    }

    /// 去掉被同组同类条目包含的条目：`~/.grok/bin/grok` 已在 `~/.grok/bin` 里，不必单列。
    private func pruneNested(_ artifacts: [Artifact]) -> [Artifact] {
        let special: Set<ArtifactFlag> = [.brokenShim, .danglingSymlink]
        return artifacts.filter { a in
            guard a.flags.isDisjoint(with: special) else { return true }
            return !artifacts.contains { b in
                guard b.path != a.path, PathUtil.isStrictlyInside(a.path, b.path) else { return false }
                return a.kind == b.kind || (a.kind == .launcher && b.kind == .program)
            }
        }
    }

    // MARK: - 组与归属登记

    private func add(_ artifact: Artifact, to groupID: String) {
        let key = PathUtil.key(artifact.path)
        guard owner[key] == nil, groups[groupID] != nil else { return }
        owner[key] = groupID
        groups[groupID]?.artifacts.append(artifact)
    }

    /// 该路径是否已被归组（等于某个已归组路径，或在它之内）。
    private func isCovered(_ path: String) -> Bool {
        let key = PathUtil.key(path)
        if owner[key] != nil { return true }
        for existing in owner.keys where key.hasPrefix(existing + "/") { return true }
        return false
    }

    private func appGroup(_ app: AppInfo) -> String {
        let id = "app:" + app.bundleID
        if groups[id] == nil {
            groups[id] = ToolGroup(id: id, name: app.name, section: .managedByApp, ownerApps: [app])
            groupOrder.append(id)
        }
        return id
    }

    private func residueGroup(_ product: CatalogProduct) -> String {
        let id = "residue:" + product.id
        if groups[id] == nil {
            groups[id] = ToolGroup(
                id: id, name: product.name, vendor: product.vendor, section: .residue,
                productID: product.id, docs: product.docs, homepage: product.homepage,
                installMethods: product.install ?? []
            )
            groupOrder.append(id)
        }
        for key in productKeys(product) where key.count >= 3 && strictKeys[key] == nil {
            strictKeys[key] = id
        }
        return id
    }

    private func looseGroup(_ section: Section, key: String, name: String) -> String {
        if let existing = looseKeys[key] { return existing }
        let id = (section == .residue ? "residue:" : "unidentified:") + key
        if groups[id] == nil {
            groups[id] = ToolGroup(id: id, name: name, section: section)
            groupOrder.append(id)
        }
        looseKeys[key] = id
        return id
    }

    private func stripDot(_ name: String) -> String {
        var s = name
        while s.hasPrefix(".") { s = String(s.dropFirst()) }
        return s
    }

    private func show(_ path: String) -> String {
        PathUtil.display(path, home: env.home)
    }
}
