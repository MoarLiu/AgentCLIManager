import Darwin
import Foundation

/// 按回执把还在暂存目录里的内容放回原处。
///
/// 回执是不可信输入。放回的来源只能是那次执行自己的暂存目录，去向只能是
/// 回执抬头里那个扫描根之内、并且和条目标识对得上的原路径；
/// 原路径上已经有东西时不覆盖，暂存的内容和移走时不一样时不放回。
public enum SweepRestorer {

    /// - Parameter confinedTo: 演练用：回执里的扫描根必须在这个目录之内。
    public static func restore(
        receipt source: String,
        execute: Bool = false,
        env: HostEnvironment,
        confinedTo: String? = nil
    ) throws -> SweepRestoreResult {
        let receipt = try SweepReceipt.read(source, env: env)
        let root = receipt.root
        if let confinedTo { try SweepPath.requireInside(root, home: confinedTo) }
        guard try SweepPath.rootIdentity(root) == receipt.rootIdentity else {
            throw SweepError("root_changed", "原扫描根目录已被替换。")
        }

        // 同一个条目有多条记录时以最后一条为准，顺序按第一次出现。
        var order: [String] = []
        var intents: [String: SweepJournalRecord] = [:]
        var finished = Set<String>()
        for record in receipt.records {
            guard let id = record.id else { continue }
            switch record.event {
            case "intent":
                if intents[id] == nil { order.append(id) }
                intents[id] = record
            case "deleted", "restored":
                finished.insert(id)
            default:
                continue
            }
        }

        var outcomes: [SweepOutcome] = []
        var snapshots: [String: SweepSnapshot] = [:]
        for id in order where !finished.contains(id) {
            guard let intent = intents[id], let relative = intent.path, let expected = intent.snapshot else {
                throw SweepError("invalid_receipt", "回执包含无效恢复路径。")
            }
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !relative.hasPrefix("/"), !parts.isEmpty,
                  !parts.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." })
            else {
                throw SweepError("invalid_receipt", "回执包含无效恢复路径。")
            }
            let destination = receipt.stage + "/" + id
            guard intent.destination == destination, id == SweepScanner.candidateID(root: root, relative: relative) else {
                throw SweepError("invalid_receipt", "回执包含无效暂存项目。")
            }
            snapshots[id] = expected

            var outcome = SweepOutcome(id: id, path: relative, status: .ready)
            let original = SweepPath.join(root, relative)
            if SweepFS.lstat(destination) == nil {
                if let info = SweepFS.lstat(original), !SweepFS.isSymlink(info),
                   Int64(info.st_dev) == expected.device, UInt64(info.st_ino) == expected.inode {
                    outcome.status = .alreadyRestored
                } else {
                    outcome.status = .missing
                    outcome.reason = "暂存内容已不存在。"
                }
            } else if SweepFS.lstat(original) != nil {
                outcome.status = .blocked
                outcome.reason = "原路径已有内容，恢复不会覆盖。"
                outcome.recoveryPath = destination
            } else if !matches(expected, stage: receipt.stage, id: id) {
                outcome.status = .blocked
                outcome.reason = "暂存内容已发生变化。"
                outcome.recoveryPath = destination
            }
            outcomes.append(outcome)
        }

        var result = SweepRestoreResult(executed: false, receipt: receipt.path, root: root, items: outcomes)
        guard execute, outcomes.contains(where: { $0.status == .ready }) else { return result }

        return try SweepState.withRootLock(root, env: env) {
            let fd = open(receipt.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw SweepError.posix("无法打开回执文件", errno) }
            defer { close(fd) }
            var current = stat()
            guard fstat(fd, &current) == 0, SweepReceipt.identity(of: current) == receipt.identity else {
                throw SweepError("receipt_changed", "回执在恢复前发生变化，请重新预演。")
            }
            // 上次写到一半的尾巴先截掉，免得新记录接在半行后面。
            if Int(current.st_size) != receipt.validBytes {
                guard ftruncate(fd, off_t(receipt.validBytes)) == 0, fsync(fd) == 0 else {
                    throw SweepError.posix("无法修复回执文件", errno)
                }
            }
            if receipt.needsNewline {
                try SweepJournal.write(Data([0x0A]), to: fd, what: "无法修复回执文件")
            }

            for index in outcomes.indices where outcomes[index].status == .ready {
                let id = outcomes[index].id
                guard let expected = snapshots[id] else { continue }
                do {
                    guard try SweepPath.rootIdentity(root) == receipt.rootIdentity else {
                        throw SweepError("root_changed", "恢复前根目录发生变化。")
                    }
                    guard matches(expected, stage: receipt.stage, id: id) else {
                        throw SweepError("changed_item", "恢复前暂存内容发生变化。")
                    }
                    let stageFD = open(receipt.stage, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard stageFD >= 0 else { throw SweepError.posix("无法打开暂存目录", errno) }
                    defer { close(stageFD) }
                    let (parentFD, name) = try SweepFS.openParent(root: root, relative: outcomes[index].path)
                    defer { close(parentFD) }
                    try SweepState.renameExclusive(fromFD: stageFD, id, toFD: parentFD, name)
                    outcomes[index].status = .restored
                    try SweepJournal.write(
                        try SweepJournalRecord(event: "restored", id: id).line(), to: fd, what: "无法更新回执"
                    )
                } catch {
                    let staged = receipt.stage + "/" + id
                    if SweepFS.lstat(staged) != nil {
                        outcomes[index].recoveryPath = staged
                    }
                    if outcomes[index].status == .restored {
                        outcomes[index].status = .restoredReceiptFailed
                        outcomes[index].reason = "内容已恢复，回执更新失败。"
                        for later in outcomes.indices where later > index && outcomes[later].status == .ready {
                            outcomes[later].status = .notAttempted
                            outcomes[later].reason = "回执没能更新，后面的项目没有执行。"
                            let laterStaged = receipt.stage + "/" + outcomes[later].id
                            if SweepFS.lstat(laterStaged) != nil {
                                outcomes[later].recoveryPath = laterStaged
                            }
                        }
                        break
                    }
                    outcomes[index].status = .blocked
                    outcomes[index].reason = (error as? SweepError)?.message ?? error.localizedDescription
                }
            }

            // 暂存目录空了就收掉；里面还有东西时删不掉，正好留着。
            rmdir(receipt.stage)
            if receipt.mode == .permanent {
                rmdir(SweepPath.parent(receipt.stage))
            }
            result.items = outcomes
            result.executed = true
            return result
        }
    }

    /// 本 App 留下的回执里，还有东西等着放回的那些，新的在前。
    ///
    /// 只看回执和暂存位置上有没有东西，不核对内容（那要把整棵树走一遍）；
    /// 真正放回时 `restore` 会逐项核对。读不懂的回执、扫描目录已经不在的回执都略过。
    public static func pendingRuns(env: HostEnvironment) -> [SweepPendingRun] {
        let directory = SweepState.runs(env)
        guard let info = SweepFS.lstat(directory), SweepFS.isDirectory(info),
              let listing = try? SweepFS.list(directory)
        else { return [] }
        var runs: [SweepPendingRun] = []
        for name in listing.names where name.hasSuffix(".jsonl") {
            guard let receipt = try? SweepReceipt.read(directory + "/" + name, env: env),
                  name == receipt.runID + ".jsonl"
            else { continue }
            var order: [String] = []
            var intents: [String: SweepJournalRecord] = [:]
            var finished = Set<String>()
            for record in receipt.records {
                guard let id = record.id else { continue }
                if record.event == "intent" {
                    if intents[id] == nil { order.append(id) }
                    intents[id] = record
                } else if record.event == "deleted" || record.event == "restored" {
                    finished.insert(id)
                }
            }
            let items = order.compactMap { id -> SweepPendingRun.Item? in
                guard !finished.contains(id), let intent = intents[id], let path = intent.path,
                      SweepFS.lstat(receipt.stage + "/" + id) != nil
                else { return nil }
                return SweepPendingRun.Item(id: id, path: path, bytes: intent.snapshot?.allocatedBytes ?? 0)
            }
            guard !items.isEmpty else { continue }
            runs.append(SweepPendingRun(
                runID: receipt.runID, receipt: receipt.path, root: receipt.root, mode: receipt.mode,
                createdAt: Date(timeIntervalSince1970: receipt.records.first?.createdAt ?? 0), items: items
            ))
        }
        return runs.sorted { ($0.createdAt, $0.runID) > ($1.createdAt, $1.runID) }
    }

    /// 后台一次性读回执，并列出这些文件夹里的永久删除暂存。
    public static func recoveryIndex(env: HostEnvironment, folders: [String]) -> SweepRecoveryIndex {
        let runs = pendingRuns(env: env)
        var residue: [String: [SweepStagingResidue]] = [:]
        for folder in folders {
            let found = stagingResidue(root: folder, runs: runs)
            if !found.isEmpty { residue[folder] = found }
        }
        return SweepRecoveryIndex(runs: runs, residue: residue)
    }

    /// 扫描根里 `.acm-sweep-staging` 下还在的目录。软链不跟随。
    public static func stagingResidue(root: String, env: HostEnvironment) -> [SweepStagingResidue] {
        stagingResidue(root: root, runs: pendingRuns(env: env))
    }

    /// 只看磁盘上的暂存目录，不读回执。只读截图模式用。
    public static func stagingResidueOnDisk(root: String) -> [SweepStagingResidue] {
        stagingResidue(root: root, runs: [])
    }

    static func stagingResidue(root: String, runs: [SweepPendingRun]) -> [SweepStagingResidue] {
        let base = root + "/" + SweepState.stagingName
        guard let info = SweepFS.lstat(base), SweepFS.isDirectory(info), !SweepFS.isSymlink(info),
              let listing = try? SweepFS.list(base)
        else { return [] }
        let matched = runs.filter { $0.root == root }
        return listing.names.compactMap { name in
            let path = base + "/" + name
            guard let info = SweepFS.lstat(path), SweepFS.isDirectory(info), !SweepFS.isSymlink(info) else { return nil }
            let runID = name.hasPrefix(SweepState.stagePrefix) ? String(name.dropFirst(SweepState.stagePrefix.count)) : name
            return SweepStagingResidue(id: name, path: path, run: matched.first { $0.runID == runID })
        }
    }

    /// 暂存目录里的这一项是否还和移走时一模一样。读不出来也算不一样。
    private static func matches(_ expected: SweepSnapshot, stage: String, id: String) -> Bool {
        (try? SweepSnapshotter.snapshot(
            root: stage, relative: id, maxEntries: 2_000_000, contentHash: expected.contentSHA256 != nil
        )) == expected
    }
}
