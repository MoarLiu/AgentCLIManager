import Foundation

public struct PlanStep: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var kind: ArtifactKind
    public var size: SizeResult?
    public var isDirectory: Bool
    /// 这一步实际包含程序本体。父目录合并后 kind 仍是 .data，不能再用 kind 判断依赖。
    public var containsProgram: Bool = false
    /// 启动链接依赖的步骤路径；其中任何一步没移走，这个链接就要保留。
    public var dependsOn: [String] = []
    public var id: String { path }

    public init(
        path: String,
        kind: ArtifactKind,
        size: SizeResult? = nil,
        isDirectory: Bool,
        containsProgram: Bool = false,
        dependsOn: [String] = []
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.isDirectory = isDirectory
        self.containsProgram = containsProgram
        self.dependsOn = dependsOn
    }

    private enum CodingKeys: String, CodingKey {
        case path, kind, size, isDirectory, containsProgram, dependsOn
    }

    /// 旧计划没有依赖字段；解成「没有记录」而不是让整份计划读不出来。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try values.decode(String.self, forKey: .path),
            kind: try values.decode(ArtifactKind.self, forKey: .kind),
            size: try values.decodeIfPresent(SizeResult.self, forKey: .size),
            isDirectory: try values.decode(Bool.self, forKey: .isDirectory),
            containsProgram: try values.decodeIfPresent(Bool.self, forKey: .containsProgram) ?? false,
            dependsOn: try values.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        )
    }
}

public struct SkippedItem: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var reason: String
    public var id: String { path }

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// 一份可以先看、再确认、然后才执行的卸载计划。
public struct UninstallPlan: Codable, Sendable {
    public var groupID: String
    public var groupName: String
    /// 将移到废纸篓的条目，已按执行顺序排好
    public var steps: [PlanStep]
    /// 勾选了但不会动的条目及原因
    public var skipped: [SkippedItem]
    /// 需要用户自己在终端执行的命令
    public var manualCommands: [String]
    public var warnings: [String]
    /// 清空废纸篓后能释放的空间；有没量全的条目时只是下界
    public var reclaimable: SizeResult?
    /// 这份计划的身份。界面用它判断「确认单换了一份计划」，要求用户重新确认风险。
    public var token: String = UUID().uuidString
    /// 执行前要复查有没有进程在用的位置（工具的程序与链路）
    public var watchPaths: [String] = []
    /// 生成计划时已经在运行、并且已经写进 warnings 让用户确认过的进程
    public var acknowledgedPIDs: [Int32] = []

    public var isEmpty: Bool { steps.isEmpty }

    public init(
        groupID: String,
        groupName: String,
        steps: [PlanStep],
        skipped: [SkippedItem],
        manualCommands: [String],
        warnings: [String],
        reclaimable: SizeResult?,
        token: String = UUID().uuidString,
        watchPaths: [String] = [],
        acknowledgedPIDs: [Int32] = []
    ) {
        self.groupID = groupID
        self.groupName = groupName
        self.steps = steps
        self.skipped = skipped
        self.manualCommands = manualCommands
        self.warnings = warnings
        self.reclaimable = reclaimable
        self.token = token
        self.watchPaths = watchPaths
        self.acknowledgedPIDs = acknowledgedPIDs
    }

    private enum CodingKeys: String, CodingKey {
        case groupID, groupName, steps, skipped, manualCommands, warnings, reclaimable
        case token, watchPaths, acknowledgedPIDs
    }

    /// 没有新字段的旧计划仍可读取。旧计划没有保存复查位置，为空时不做进程匹配。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            groupID: try values.decode(String.self, forKey: .groupID),
            groupName: try values.decode(String.self, forKey: .groupName),
            steps: try values.decode([PlanStep].self, forKey: .steps),
            skipped: try values.decode([SkippedItem].self, forKey: .skipped),
            manualCommands: try values.decode([String].self, forKey: .manualCommands),
            warnings: try values.decode([String].self, forKey: .warnings),
            reclaimable: try values.decodeIfPresent(SizeResult.self, forKey: .reclaimable),
            token: try values.decodeIfPresent(String.self, forKey: .token) ?? UUID().uuidString,
            watchPaths: try values.decodeIfPresent([String].self, forKey: .watchPaths) ?? [],
            acknowledgedPIDs: try values.decodeIfPresent([Int32].self, forKey: .acknowledgedPIDs) ?? []
        )
    }
}

public enum UninstallPlanner {

    public static func plan(group: ToolGroup, selected: Set<String>, env: HostEnvironment) -> UninstallPlan {
        var skipped: [SkippedItem] = []
        var skippedReasons: [String: String] = [:]
        var warnings: [String] = []
        var manual = group.manualCommands
        var chosen: [Artifact] = []

        func show(_ path: String) -> String { PathUtil.display(path, home: env.home) }
        func skip(_ artifact: Artifact, _ reason: String) {
            skipped.append(SkippedItem(path: artifact.path, reason: reason))
            skippedReasons[PathUtil.key(artifact.path)] = reason
        }

        // 先评估整组的硬性拒绝，而不是只评估勾选项：没有勾选的子项也可能
        // 被上级目录带走。保留存在性，避免已经消失的旧条目误挡住父目录。
        var existing = Set<String>()
        var directories = Set<String>()
        var denials: [String: String] = [:]
        for a in group.artifacts {
            let key = PathUtil.key(a.path)
            let info = FileProbe.lstat(a.path)
            let exists = info != nil
            if exists { existing.insert(key) }
            if info?.isDirectory == true { directories.insert(key) }
            if let reason = removalDenial(for: a, in: group, env: env, exists: exists) {
                denials[key] = reason
            }
        }

        for a in group.artifacts where selected.contains(a.path) {
            if a.flags.contains(.usedByOthers) {
                let names = unique(a.alsoUsedBy).joined(separator: "、")
                let commands = names.isEmpty ? "其他命令" : "「" + names + "」"
                warnings.append("\(show(a.path)) 仍被\(commands)使用，移走后这些命令会失效")
            }
            for child in foreignRelations(for: a, in: group) where !child.blocksRemoval {
                let ownership = child.certain ? "属于另一组「\(child.owner)」" : "可能属于「\(child.owner)」（归属尚未确定）"
                warnings.append("\(show(a.path)) 涉及 \(show(child.path))，该位置\(ownership)，移走会把它一并带走")
            }
            if let reason = denials[PathUtil.key(a.path)] {
                skip(a, reason)
                if reason == rootOwnedReason {
                    manual.append("sudo rm -rf -- " + shellQuote(a.path))
                }
                continue
            }
            chosen.append(a)
        }

        // 硬性排除要约束最终的移动范围。任何仍存在的受保护后代都否决其
        // 每个选中祖先；不能显示“子项不会动”，却把整个父目录移走。
        let movable = chosen.filter { a in
            guard FileProbe.lstat(a.path)?.isDirectory == true else { return true }
            guard let blocked = group.artifacts.first(where: {
                PathUtil.isStrictlyInside($0.path, a.path)
                    && existing.contains(PathUtil.key($0.path))
                    && denials[PathUtil.key($0.path)] != nil
            }) else { return true }
            let reason = denials[PathUtil.key(blocked.path)] ?? "受保护的子项"
            skip(a, "包含不能移走的 \(show(blocked.path))：\(reason)；请取消父目录，单独选择其余子项")
            return false
        }

        // 只有通过整棵子树保护检查后，才折叠被父目录覆盖的步骤。
        let outer = ToolGroup.outermost(movable)

        // 依赖以实际启动链为准，不看展示类型：一个标为 .program 的 bin 目录，
        // 也可能装着指向另一个目录的入口。目录步骤要承担其内部所有入口的依赖。
        func covers(_ artifact: Artifact, _ path: String) -> Bool {
            let key = PathUtil.key(artifact.path)
            return key == PathUtil.key(path)
                || (directories.contains(key) && PathUtil.isStrictlyInside(path, artifact.path))
        }
        let chains = startupChains(in: group)
        let selectedArtifacts = group.artifacts.filter { selected.contains($0.path) }
        var planned: [Artifact] = []
        var stepDependencies: [String: [String]] = [:]
        for a in outer {
            var downstream = Set<String>()
            for chain in chains {
                for index in 0..<(chain.count - 1) where covers(a, chain[index]) {
                    for target in chain.dropFirst(index + 1) where !covers(a, target) {
                        downstream.insert(target)
                    }
                }
            }
            var dependencies = Set<String>()
            var blockedReason: String?
            for target in downstream.sorted() {
                // 若用户另外明确选中了安全的程序子项，它能替代被拒绝的宽泛父目录。
                if let dependency = outer.first(where: { covers($0, target) }) {
                    dependencies.insert(dependency.path)
                } else if let blocked = selectedArtifacts.first(where: {
                    covers($0, target) && skippedReasons[PathUtil.key($0.path)] != nil
                }), let reason = skippedReasons[PathUtil.key(blocked.path)] {
                    blockedReason = "依赖的 \(show(blocked.path)) 没能纳入计划：\(reason)；保留入口及其所在目录"
                    break
                }
                // 没有选择目标或其父目录，表示用户只想清理入口，不强行扩大操作范围。
            }
            if let blockedReason {
                skip(a, blockedReason)
            } else {
                stepDependencies[PathUtil.key(a.path)] = dependencies.sorted()
                planned.append(a)
            }
        }

        // 一个步骤被挡住后，依赖它的其他入口也要递归保留，不依赖遍历顺序。
        while true {
            let active = Set(planned.map { PathUtil.key($0.path) })
            let retained = planned.filter { a in
                let unavailable = (stepDependencies[PathUtil.key(a.path)] ?? []).first {
                    !active.contains(PathUtil.key($0))
                }
                guard let unavailable else { return true }
                skip(a, "依赖的 \(show(unavailable)) 无法移走；保留入口及其所在目录")
                return false
            }
            if retained.count == planned.count { break }
            planned = retained
        }

        // 先按原有规则稳定排序，再按依赖选择可执行步骤。互相包含对方入口的目录
        // 可能形成环；这种情况不能随便选一个先移走，需保留整个环及依赖它的步骤。
        var pending = planned.sorted { lhs, rhs in
            let ll = lhs.kind == .launcher, rl = rhs.kind == .launcher
            if ll != rl { return !ll }
            if ll && rl {
                let li = chainIndex(lhs.path, in: group), ri = chainIndex(rhs.path, in: group)
                if li != ri { return li > ri }
            }
            let ld = PathUtil.components(lhs.path).count, rd = PathUtil.components(rhs.path).count
            if ld != rd { return ld > rd }
            return lhs.path < rhs.path
        }
        var ordered: [Artifact] = []
        var scheduled = Set<String>()
        while !pending.isEmpty {
            guard let ready = pending.firstIndex(where: { a in
                (stepDependencies[PathUtil.key(a.path)] ?? []).allSatisfy { scheduled.contains(PathUtil.key($0)) }
            }) else {
                for a in pending {
                    skip(a, "启动依赖存在循环，无法安全安排此项；请单独选择程序和入口")
                }
                break
            }
            let next = pending.remove(at: ready)
            ordered.append(next)
            scheduled.insert(PathUtil.key(next.path))
        }
        planned = ordered

        if group.isRunning {
            let pids = group.runningPIDs.map(String.init).joined(separator: "、")
            warnings.append("\(group.name) 正在运行（PID \(pids)），移走文件可能让它出错")
        }
        for a in planned {
            if a.flags.contains(.shared) {
                warnings.append("\(show(a.path)) 与 \(a.ownerAppName ?? "桌面 App") 共用，移走后那个 App 也会失去这些数据")
            }
            if a.flags.contains(.credentials) {
                warnings.append("\(show(a.path)) 含登录凭据：移到废纸篓后仍可读取，也可能已进入 Time Machine，建议先到厂商处吊销")
            }
            if a.strength != .certain {
                warnings.append("\(show(a.path)) 的归属只是推测，请确认它确实不再需要")
            }
            if a.flags.contains(.recentlyModified), group.section != .installed {
                warnings.append("\(show(a.path)) 最近还有写入，可能仍有程序在用")
            }
            // 凭据即使被显式勾选，也不能因父目录折叠而失去风险提示。
            for inner in group.artifacts
            where directories.contains(PathUtil.key(a.path))
                && PathUtil.isStrictlyInside(inner.path, a.path) {
                if inner.flags.contains(.credentials) {
                    warnings.append("\(show(a.path)) 里包含登录凭据 \(show(inner.path))：移走目录会把它一并带走，移到废纸篓后仍可读取，也可能已进入 Time Machine，建议先到厂商处吊销")
                } else if inner.flags.contains(.shared), !selected.contains(inner.path) {
                    warnings.append("\(show(a.path)) 里包含你没有勾选的「\(inner.kind.displayName)」\(show(inner.path))，移走目录会把它一并带走")
                }
            }
        }

        let steps = planned.map {
            PlanStep(
                path: $0.path,
                kind: $0.kind,
                size: $0.size,
                isDirectory: $0.isDirectory,
                containsProgram: stepContainsProgram($0, in: group),
                dependsOn: stepDependencies[PathUtil.key($0.path)] ?? []
            )
        }

        var result = UninstallPlan(
            groupID: group.id,
            groupName: group.name,
            steps: steps,
            skipped: skipped,
            manualCommands: unique(manual),
            warnings: unique(warnings),
            reclaimable: ToolGroup.totalSize(of: planned)
        )
        // 与 ToolScanner.runningPIDs(for:in:) 使用同一批位置，执行前按实时进程表重查。
        result.watchPaths = unique(group.watchPaths)
        result.acknowledgedPIDs = Array(Set(group.runningPIDs)).sorted()
        return result
    }

    private static let rootOwnedReason = "属主是 root，本 App 不提权；命令已列在下方"

    /// 同一份约束同时用于勾选项和父目录范围检查，避免两条路径的护栏不一致。
    private static func removalDenial(
        for artifact: Artifact, in group: ToolGroup, env: HostEnvironment, exists: Bool
    ) -> String? {
        if group.section == .managedByApp || artifact.claim == .usedByApp {
            return artifact.notRemovableReason
                ?? "由 \(artifact.ownerAppName ?? "桌面 App") 使用，不在管理范围内"
        }
        if artifact.flags.contains(.invalidLauncher) {
            return "入口指向的不是可执行程序，未将其作为卸载目标"
        }
        if let child = foreignRelations(for: artifact, in: group).first(where: { $0.blocksRemoval }) {
            let childPath = PathUtil.display(child.path, home: env.home)
            if PathUtil.isStrictlyInside(child.path, artifact.path) {
                return "里面的 \(childPath) 确定由 \(child.owner) 使用，不能整个移走；请展开后只清理其余子项"
            }
            return "位于 \(child.owner) 使用的 \(childPath) 之内或与之相同，不能移走；请只清理其余子项"
        }
        let decision = PathSafety.check(artifact.path, env: env)
        if !decision.allowed { return decision.reason ?? "路径护栏拒绝" }
        if artifact.flags.contains(.notRemovable) {
            return artifact.notRemovableReason ?? "此条目不可移走"
        }
        if !exists { return "路径已不存在" }
        if artifact.flags.contains(.rootOwned) { return rootOwnedReason }
        return nil
    }

    /// 展开条目也要继承上级记录的跨组约束，并去掉复制产生的重复记录。
    private static func foreignRelations(for artifact: Artifact, in group: ToolGroup) -> [ForeignChild] {
        var relations = artifact.foreignChildren
        if artifact.parentPath != nil {
            for ancestor in group.artifacts where PathUtil.isStrictlyInside(artifact.path, ancestor.path) {
                relations += ancestor.foreignChildren.filter {
                    PathUtil.isInside(artifact.path, $0.path) || PathUtil.isInside($0.path, artifact.path)
                }
            }
        }
        var seen = Set<ForeignChild>()
        return relations.filter { seen.insert($0).inserted }
    }

    /// 从扫描注册表取完整启动链。未登记的单独软链再作一次只读解析；
    /// 不拿厂商根目录当启动目标，也不把损坏或指向目录的入口当作正常依赖。
    private static func startupChains(in group: ToolGroup) -> [[String]] {
        var chains = group.binaries.filter { !$0.isBroken && $0.chain.count > 1 }.map(\.chain)
        var known = Set(chains.flatMap { $0.dropLast().map(PathUtil.key) })
        for artifact in group.artifacts where !known.contains(PathUtil.key(artifact.path)) {
            guard FileProbe.lstat(artifact.path)?.isSymlink == true else { continue }
            let resolved = BinaryRegistry.resolveChain(artifact.path)
            guard resolved.chain.count > 1, let final = resolved.final,
                  FileProbe.isExecutableFile(final) else { continue }
            chains.append(resolved.chain)
            known.formUnion(resolved.chain.dropLast().map(PathUtil.key))
        }
        return chains
    }

    /// 合并后的 .data 父目录也可能装着程序，必须把这个事实带进执行阶段。
    private static func stepContainsProgram(_ artifact: Artifact, in group: ToolGroup) -> Bool {
        if artifact.kind == .program { return true }
        if group.artifacts.contains(where: {
            $0.kind == .program && PathUtil.isInside($0.path, artifact.path)
        }) { return true }
        return group.binaries.contains { binary in
            if let final = binary.finalTarget, PathUtil.isInside(final, artifact.path) { return true }
            if let root = binary.payloadRoot, PathUtil.isInside(root, artifact.path) { return true }
            return false
        }
    }

    /// 某个路径在命令链路里排第几环；越大越靠近程序本体。
    static func chainIndex(_ path: String, in group: ToolGroup) -> Int {
        var best = -1
        let key = PathUtil.key(path)
        for binary in group.binaries {
            if let index = binary.chain.firstIndex(where: { PathUtil.key($0) == key }) {
                best = max(best, index)
            }
        }
        return best
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}
