import Darwin
import Foundation

/// 按计划执行清理。计划只是「当时看到的样子」，动手之前每一项都对着磁盘重新核对。
///
/// 两种方式：
/// - 废纸篓：把条目移进废纸篓里本次执行自己的暂存目录，之后可以按回执放回。
/// - 永久：先移进扫描根里的暂存目录，复核无误后再删除。删掉的不可恢复；
///   中途失败时还留在暂存目录里的内容仍可按回执放回。
///
/// 无论哪种，移动都是「目标位置没有东西才移」的原子改名，
/// 移动前写回执、移动后再核对一遍指纹，任何一步不对就停在可恢复的状态。
public enum SweepExecutor {

    public static func apply(
        _ plan: SweepPlan,
        execute: Bool = false,
        mode: SweepMode = .trash,
        identifiers: [String] = [],
        includeOldVersions: Bool = false,
        env: HostEnvironment,
        probes: SweepProbes = .live,
        now: Date? = nil
    ) throws -> SweepApplyResult {
        try apply(
            plan, execute: execute, mode: mode, identifiers: identifiers,
            includeOldVersions: includeOldVersions, env: env, probes: probes, now: now, journalFault: nil
        )
    }

    static func apply(
        _ plan: SweepPlan,
        execute: Bool,
        mode: SweepMode,
        identifiers: [String],
        includeOldVersions: Bool,
        env: HostEnvironment,
        probes: SweepProbes,
        now: Date?,
        journalFault: SweepJournal.Fault?
    ) throws -> SweepApplyResult {
        let (chosen, unselected) = try choose(plan, identifiers: identifiers, includeOldVersions: includeOldVersions)
        let hashes = SweepContentHashCache()
        var (root, outcomes) = try revalidate(
            plan, chosen: chosen, env: env, probes: probes, now: now, hashes: hashes
        )
        var result = SweepApplyResult(
            executed: false, mode: mode, root: root, receipt: nil, items: outcomes, unselectedIDs: unselected
        )
        guard execute, outcomes.contains(where: { $0.status == .ready }) else { return result }

        return try SweepState.withRootLock(root, env: env) {
            // 拿到锁之后再核对一遍：另一次执行可能刚刚结束。
            (root, outcomes) = try revalidate(
                plan, chosen: chosen, env: env, probes: probes, now: now, hashes: hashes
            )
            result.items = outcomes
            guard outcomes.contains(where: { $0.status == .ready }) else { return result }

            let runID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let runs = try SweepState.privateDirectory(SweepState.runs(env))
            let base = try SweepState.privateDirectory(
                SweepState.stageBase(mode: mode, root: root, env: env),
                what: mode == .trash ? "废纸篓" : "暂存目录"
            )
            // 收尾时只删得掉空目录：里面还有东西，说明有条目等着恢复。
            defer { if mode == .permanent { rmdir(base) } }
            let stage = SweepState.stage(mode: mode, root: root, runID: runID, env: env)
            guard mkdir(stage, 0o700) == 0 else {
                throw SweepError.posix(mode == .trash ? "无法在废纸篓里创建暂存目录" : "无法创建暂存目录", errno)
            }
            defer { rmdir(stage) }
            guard let stageInfo = SweepFS.lstat(stage), let rootInfo = SweepFS.stat(root),
                  stageInfo.st_dev == rootInfo.st_dev
            else {
                throw SweepError("different_volume", "废纸篓与扫描目录不在同一卷，请改用永久模式或手动处理。")
            }

            let journal = try SweepJournal(creating: runs + "/" + runID + ".jsonl", fault: journalFault)
            result.receipt = journal.path
            let stageFD = open(stage, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard stageFD >= 0 else { throw SweepError.posix("无法打开暂存目录", errno) }
            defer { close(stageFD) }
            let freeBefore = freeBytes(root)

            var header = SweepJournalRecord(event: "run")
            header.schemaVersion = SweepEngine.schemaVersion
            header.runID = runID
            header.root = root
            header.rootIdentity = plan.rootIdentity
            header.mode = mode
            header.stage = stage
            header.createdAt = (now ?? env.now).timeIntervalSince1970
            try journal.append(header)

            let originals = Dictionary(plan.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for index in outcomes.indices where outcomes[index].status == .ready {
                guard let item = originals[outcomes[index].id], let expected = item.snapshot else { continue }
                let path = SweepPath.join(root, item.path)
                let destination = stage + "/" + item.id
                var moved = false
                do {
                    try precheck(item, expected: expected, plan: plan, root: root, originals: originals, probes: probes)

                    var intent = SweepJournalRecord(event: "intent", id: item.id)
                    intent.path = item.path
                    intent.destination = destination
                    intent.snapshot = expected
                    try journal.append(intent)

                    do {
                        let (parentFD, name) = try SweepFS.openParent(root: root, relative: item.path)
                        defer { close(parentFD) }
                        var opened = stat()
                        guard let parent = SweepFS.lstat(SweepPath.parent(path)), fstat(parentFD, &opened) == 0,
                              parent.st_dev == opened.st_dev, parent.st_ino == opened.st_ino
                        else { throw SweepError("parent_changed", "目标父目录发生变化。") }
                        var current = stat()
                        guard fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0 else {
                            throw SweepError.posix("无法读取目标", errno)
                        }
                        guard Int64(current.st_dev) == expected.device, UInt64(current.st_ino) == expected.inode else {
                            throw SweepError("changed_item", "目标已被替换。")
                        }
                        try SweepState.renameExclusive(fromFD: parentFD, name, toFD: stageFD, item.id)
                    }
                    moved = true
                    outcomes[index].recoveryPath = destination

                    guard try SweepSnapshotter.snapshot(
                        root: stage, relative: item.id, maxEntries: plan.policy.maxEntries,
                        contentHash: expected.contentSHA256 != nil
                    ) == expected else {
                        throw SweepError("changed_after_move", "移动后复核未通过，已保留暂存内容。")
                    }
                    try journal.append(SweepJournalRecord(event: "staged", id: item.id))

                    if mode == .permanent {
                        try purge(parentFD: stageFD, name: item.id, device: dev_t(truncatingIfNeeded: expected.device))
                        try journal.append(SweepJournalRecord(event: "deleted", id: item.id))
                        outcomes[index].recoveryPath = nil
                        outcomes[index].status = .deleted
                    } else {
                        try journal.append(SweepJournalRecord(event: "trashed", id: item.id))
                        outcomes[index].status = .trashed
                    }
                } catch {
                    outcomes[index].status = moved ? .recoveryRequired : .blocked
                    outcomes[index].reason = (error as? SweepError)?.message ?? error.localizedDescription
                    // 已经移走却没走完：回执可能写不进去了，剩下的一项都不再动。
                    if moved {
                        markNotAttempted(&outcomes, after: index, reason: "前一项没有走完，这一项没有执行。")
                        break
                    }
                }
            }

            result.items = outcomes
            result.executed = true
            if let freeBefore, let freeAfter = freeBytes(root) {
                result.freeSpaceDeltaBytes = freeAfter - freeBefore
            }
            result.requiresEmptyingTrash = mode == .trash && outcomes.contains { $0.status == .trashed }
            return result
        }
    }

    // MARK: - 选择

    /// 点了名的照点名来；没点名就是全部可清理项，但不含「已有更新版本」的旧安装包——
    /// 那是凭文件名里的版本号推测的，要么点名，要么明确说连它们一起。
    static func choose(
        _ plan: SweepPlan, identifiers: [String], includeOldVersions: Bool
    ) throws -> (chosen: [SweepItem], unselected: [String]) {
        if !identifiers.isEmpty {
            let byID = Dictionary(plan.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let unknown = Set(identifiers).subtracting(byID.keys).sorted()
            guard unknown.isEmpty else {
                throw SweepError("unknown_item", "计划中没有指定项目。", details: ["ids": unknown.joined(separator: ",")])
            }
            var seen = Set<String>()
            let chosen = identifiers.filter { seen.insert($0).inserted }.compactMap { byID[$0] }
            guard chosen.allSatisfy({ $0.status == .cleanup }) else {
                throw SweepError("protected_item", "只能执行计划中标为 cleanup 的项目。")
            }
            return (chosen, [])
        }
        let cleanup = plan.items.filter { $0.status == .cleanup }
        if includeOldVersions { return (cleanup, []) }
        let old = Set(cleanup.filter(plan.isSupersededVersion).map(\.id))
        return (cleanup.filter { !old.contains($0.id) }, cleanup.map(\.id).filter(old.contains))
    }

    // MARK: - 复核

    /// 重新扫描一遍，看选中的每一项是否还和计划里一模一样。
    static func revalidate(
        _ plan: SweepPlan, chosen: [SweepItem], env: HostEnvironment, probes: SweepProbes, now: Date?,
        hashes: SweepContentHashCache
    ) throws -> (root: String, outcomes: [SweepOutcome]) {
        let root = try SweepPath.normalizedRoot(plan.root, env: env)
        guard root == plan.root, try SweepPath.rootIdentity(root) == plan.rootIdentity else {
            throw SweepError("root_changed", "扫描根目录已被替换，请重新扫描。")
        }
        let age = (now ?? env.now).timeIntervalSince1970 - plan.createdAt
        guard (0...24 * 3600).contains(age) else {
            throw SweepError("expired_plan", "计划超过 24 小时或时间异常，请重新扫描。")
        }
        let current = try SweepScanner.scan(
            root: root, policy: plan.policy, env: env, probes: probes, now: now, hashes: hashes
        )
        let fresh = Dictionary(current.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let original = Dictionary(plan.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let outcomes = chosen.map { item -> SweepOutcome in
            func blocked(_ reason: String) -> SweepOutcome {
                SweepOutcome(id: item.id, path: item.path, status: .blocked, reason: reason)
            }
            guard SweepFS.lstat(SweepPath.join(root, item.path)) != nil else {
                return SweepOutcome(id: item.id, path: item.path, status: .alreadyAbsent)
            }
            guard let latest = fresh[item.id] else {
                return blocked("重新扫描后不再满足自动清理条件。")
            }
            guard latest.status == .cleanup else {
                return blocked("重新扫描后不再满足自动清理条件：\(latest.reason)")
            }
            guard latest.snapshot == item.snapshot else {
                return blocked("内容自计划生成后发生变化。")
            }
            let keepersIntact = Set(item.retainedIDs).union(latest.retainedIDs).allSatisfy { id in
                guard let before = original[id], let after = fresh[id] else { return false }
                return before.snapshot == after.snapshot && after.status == .keep
            }
            guard keepersIntact else { return blocked("应保留的安装包发生变化。") }
            return SweepOutcome(id: item.id, path: item.path, status: .ready)
        }
        return (root, outcomes)
    }

    /// 移动某一项之前的最后一轮核对。重新扫描到这里之间隔着别的条目的移动和删除，
    /// 这段时间里什么都可能发生。
    private static func precheck(
        _ item: SweepItem, expected: SweepSnapshot, plan: SweepPlan, root: String,
        originals: [String: SweepItem], probes: SweepProbes
    ) throws {
        guard try SweepPath.rootIdentity(root) == plan.rootIdentity else {
            throw SweepError("root_changed", "扫描根目录发生变化。")
        }
        guard try SweepSnapshotter.snapshot(
            root: root, relative: item.path, maxEntries: plan.policy.maxEntries,
            contentHash: expected.contentSHA256 != nil
        ) == expected else {
            throw SweepError("changed_item", "执行前目标发生变化。")
        }
        let path = SweepPath.join(root, item.path)
        if let reason = SweepScanner.trackedReason(path, probes: probes) {
            throw SweepError("tracked_files", reason)
        }
        let project = SweepRecognizer.ownerProject(SweepPath.parent(path), root: root)
        guard SweepScanner.processUsers(path: path, project: project, records: try probes.openPaths()).isEmpty else {
            throw SweepError("running_process", "有进程在执行前开始使用此项目。")
        }
        for id in item.retainedIDs {
            guard let keeper = originals[id], let snapshot = keeper.snapshot,
                  (try? SweepSnapshotter.snapshot(
                      root: root, relative: keeper.path, maxEntries: plan.policy.maxEntries,
                      contentHash: snapshot.contentSHA256 != nil
                  )) == snapshot
            else {
                throw SweepError("keeper_changed", "保留的安装包发生变化。")
            }
        }
    }

    // MARK: - 删除

    /// 删除暂存目录里的一项。全程通过钉住的目录描述符操作：
    /// 软链只删链接本身，绝不进去；途中任何一级被换掉就停下。
    static func purge(parentFD: Int32, name: String, device: dev_t) throws {
        var info = stat()
        guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw SweepError.posix("无法读取暂存内容", errno)
        }
        guard info.st_dev == device, info.st_uid == getuid() else {
            throw SweepError("purge_boundary", "暂存内容的归属或文件系统发生变化。")
        }
        guard SweepFS.isDirectory(info) else {
            guard unlinkat(parentFD, name, 0) == 0 else { throw SweepError.posix("无法删除暂存内容", errno) }
            return
        }
        do {
            let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw SweepError.posix("无法打开暂存目录", errno) }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
                throw SweepError("purge_changed", "暂存目录被替换。")
            }
            let listing = try SweepFS.list(fd: fd)
            guard !listing.hasUndecodable else {
                throw SweepError("purge_boundary", "暂存目录里出现了无法识别的条目。")
            }
            for child in listing.names {
                try purge(parentFD: fd, name: child, device: device)
            }
        }
        var current = stat()
        guard fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == info.st_dev, current.st_ino == info.st_ino
        else {
            throw SweepError("purge_changed", "暂存目录在删除前被替换。")
        }
        guard unlinkat(parentFD, name, AT_REMOVEDIR) == 0 else {
            throw SweepError.posix("无法删除暂存目录", errno)
        }
    }

    private static func markNotAttempted(_ outcomes: inout [SweepOutcome], after index: Int, reason: String) {
        for later in outcomes.indices where later > index && outcomes[later].status == .ready {
            outcomes[later].status = .notAttempted
            outcomes[later].reason = reason
        }
    }

    private static func freeBytes(_ path: String) -> Int64? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return Int64(info.f_bavail) * Int64(info.f_bsize)
    }
}
