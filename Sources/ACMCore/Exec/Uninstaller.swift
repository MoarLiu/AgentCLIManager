import Foundation

/// 「移走」的实现。真实环境用废纸篓；测试用记录器，只记下会动什么。
public protocol Remover: Sendable {
    /// 把路径移到废纸篓，返回它在废纸篓里的位置。系统有时不给位置，nil 也算成功。
    func trash(_ path: String) throws -> String?
    /// 从废纸篓放回原处。
    func restore(from trashed: String, to original: String) throws
}

public enum RemoverError: Error, CustomStringConvertible {
    case originalOccupied(String)
    case trashedMissing(String)

    public var description: String {
        switch self {
        case .originalOccupied(let p): return "原位置已有同名条目：\(p)"
        case .trashedMissing(let p): return "废纸篓里找不到：\(p)"
        }
    }
}

/// 只用废纸篓，不做真正的删除。
public struct TrashRemover: Remover {
    public init() {}

    public func trash(_ path: String) throws -> String? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        return resulting?.path
    }

    public func restore(from trashed: String, to original: String) throws {
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: trashed)) != nil else {
            throw RemoverError.trashedMissing(trashed)
        }
        guard (try? fm.attributesOfItem(atPath: original)) == nil else {
            throw RemoverError.originalOccupied(original)
        }
        let parent = (original as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try fm.moveItem(atPath: trashed, toPath: original)
    }
}

/// 测试用：不碰文件系统，只记录调用顺序。
public final class RecordingRemover: Remover, @unchecked Sendable {
    private let lock = NSLock()
    private var _trashed: [String] = []
    private var _restored: [String] = []
    public var failing: Set<String>

    public init(failing: Set<String> = []) { self.failing = failing }

    public var trashed: [String] { lock.lock(); defer { lock.unlock() }; return _trashed }
    public var restored: [String] { lock.lock(); defer { lock.unlock() }; return _restored }

    public func trash(_ path: String) throws -> String? {
        if failing.contains(path) { throw CocoaError(.fileWriteNoPermission) }
        lock.lock(); defer { lock.unlock() }
        _trashed.append(path)
        return "/fake-trash/" + (path as NSString).lastPathComponent
    }

    public func restore(from trashed: String, to original: String) throws {
        lock.lock(); defer { lock.unlock() }
        _restored.append(original)
    }
}

public struct TrashReceipt: Codable, Sendable, Hashable {
    public var original: String
    /// 在废纸篓里的位置；系统没给时为 nil，那就无法自动放回
    public var trashed: String?
    /// 移走前的 inode。旧回执没有这个字段；有的话放回前必须仍是同一个条目。
    public var fileID: UInt64?

    public init(original: String, trashed: String?, fileID: UInt64? = nil) {
        self.original = original
        self.trashed = trashed
        self.fileID = fileID
    }
}

public struct UninstallResult: Codable, Sendable {
    public var receipts: [TrashReceipt]
    public var failures: [SkippedItem]
    /// 生成计划之后才启动、正在使用这个工具的进程。非空表示执行器拒绝动手，什么都没有移走。
    public var newlyRunningPIDs: [Int32] = []
    public var succeeded: Bool { failures.isEmpty }

    public init(receipts: [TrashReceipt], failures: [SkippedItem], newlyRunningPIDs: [Int32] = []) {
        self.receipts = receipts
        self.failures = failures
        self.newlyRunningPIDs = newlyRunningPIDs
    }

    private enum CodingKeys: String, CodingKey { case receipts, failures, newlyRunningPIDs }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            receipts: try values.decode([TrashReceipt].self, forKey: .receipts),
            failures: try values.decode([SkippedItem].self, forKey: .failures),
            newlyRunningPIDs: try values.decodeIfPresent([Int32].self, forKey: .newlyRunningPIDs) ?? []
        )
    }
}

public struct RestoreResult: Sendable {
    public var restored: [String]
    public var failures: [SkippedItem]
    /// 没能放回的回执，原样保留，处理完冲突后可以再试一次。
    public var remaining: [TrashReceipt]
    public var succeeded: Bool { failures.isEmpty }
}

public enum Uninstaller {

    /// 执行计划。每一步执行前重新核对一遍：路径还在、护栏仍放行。
    ///
    /// `processProbe` 用来在动手前再查一次进程：确认单开着的这段时间里工具可能被启动了。
    /// 默认查真实进程表；传 nil 表示不查（只应在测试里这么做）。
    public static func execute(
        _ plan: UninstallPlan,
        env: HostEnvironment,
        remover: any Remover,
        processProbe: (@Sendable () -> [RunningProcess])? = ProcessProbe.live
    ) -> UninstallResult {
        if let processProbe {
            let running = ToolScanner.runningPIDs(usingAnyOf: plan.watchPaths, in: processProbe())
            let acknowledged = Set(plan.acknowledgedPIDs)
            let newPIDs = running.filter { !acknowledged.contains($0) }
            if !newPIDs.isEmpty {
                let pids = newPIDs.map(String.init).joined(separator: "、")
                let reason = "\(plan.groupName) 在确认之后被启动（PID \(pids)）；请重新生成计划并确认后再执行"
                return UninstallResult(
                    receipts: [],
                    failures: plan.steps.map { SkippedItem(path: $0.path, reason: reason) },
                    newlyRunningPIDs: newPIDs
                )
            }
        }

        var receipts: [TrashReceipt] = []
        var failures: [SkippedItem] = []
        var succeededSteps = Set<String>()

        for step in plan.steps {
            // 不仅要确认依赖“没失败”，还要确认它已经成功；顺序错误或缺步骤的
            // 外部计划也不能先移走入口。目录步骤同样遵守完整启动链的依赖。
            guard step.dependsOn.allSatisfy({ succeededSteps.contains(PathUtil.key($0)) }) else {
                failures.append(SkippedItem(path: step.path, reason: "依赖的程序或启动链路尚未成功移走，保留此项以免留下不一致的状态"))
                continue
            }
            guard let info = FileProbe.lstat(step.path) else {
                failures.append(SkippedItem(path: step.path, reason: "执行时路径已不存在"))
                continue
            }
            let decision = PathSafety.check(step.path, env: env)
            guard decision.allowed else {
                failures.append(SkippedItem(path: step.path, reason: decision.reason ?? "路径护栏拒绝"))
                continue
            }
            do {
                let trashed = try remover.trash(step.path)
                receipts.append(TrashReceipt(original: step.path, trashed: trashed, fileID: info.fileID))
                succeededSteps.insert(PathUtil.key(step.path))
            } catch {
                failures.append(SkippedItem(path: step.path, reason: describe(error)))
            }
        }
        return UninstallResult(receipts: receipts, failures: failures)
    }

    /// 把上一次移走的东西放回原处，按相反顺序。
    ///
    /// 回执是不可信输入（可能来自手写或被改过的文件），`env` 用来校验它。
    public static func restore(_ receipts: [TrashReceipt], env: HostEnvironment, remover: any Remover) -> RestoreResult {
        var restored: [String] = []
        var failures: [SkippedItem] = []
        var remaining: [TrashReceipt] = []
        for receipt in receipts.reversed() {
            if let reason = pathProblem(receipt.original, label: "原位置路径") {
                failRestore(receipt, reason, &failures, &remaining)
                continue
            }
            guard let trashed = receipt.trashed else {
                failRestore(receipt, "系统没有返回它在废纸篓里的位置，请到废纸篓里手工放回", &failures, &remaining)
                continue
            }
            if let reason = pathProblem(trashed, label: "废纸篓里的来源路径") {
                failRestore(receipt, reason, &failures, &remaining)
                continue
            }
            guard isInsideTrash(trashed, env: env) else {
                failRestore(receipt, "来源不严格位于本环境的废纸篓目录之内，拒绝放回", &failures, &remaining)
                continue
            }
            let decision = PathSafety.check(receipt.original, env: env)
            guard decision.allowed else {
                failRestore(receipt, "原位置不允许放回：\(decision.reason ?? "路径护栏拒绝")", &failures, &remaining)
                continue
            }
            if let expected = receipt.fileID {
                guard let actual = FileProbe.lstat(trashed)?.fileID else {
                    failRestore(receipt, "无法核对废纸篓里条目的 inode，拒绝放回", &failures, &remaining)
                    continue
                }
                guard actual == expected else {
                    failRestore(receipt, "废纸篓里条目的 inode 已改变（回执 \(expected)，实际 \(actual)），拒绝放回", &failures, &remaining)
                    continue
                }
            }
            do {
                try remover.restore(from: trashed, to: receipt.original)
                restored.append(receipt.original)
            } catch {
                failRestore(receipt, describe(error), &failures, &remaining)
            }
        }
        return RestoreResult(restored: restored, failures: failures, remaining: remaining.reversed())
    }

    private static func failRestore(
        _ receipt: TrashReceipt,
        _ reason: String,
        _ failures: inout [SkippedItem],
        _ remaining: inout [TrashReceipt]
    ) {
        failures.append(SkippedItem(path: receipt.original, reason: reason))
        remaining.append(receipt)
    }

    private static func pathProblem(_ path: String, label: String) -> String? {
        guard path.hasPrefix("/") else { return "\(label)不是绝对路径" }
        if path.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
            return "\(label)含有 .."
        }
        return nil
    }

    /// 解析来源父目录后的真实位置，覆盖 /var、/private/var 与数据卷前缀的差异。
    /// 叶子本身不解析，软链移回的也应是这个软链。
    private static func isInsideTrash(_ trashed: String, env: HostEnvironment) -> Bool {
        let lexical = PathUtil.stripDataVolumePrefix(PathUtil.standardize(trashed))
        let leaf = PathUtil.lastComponent(lexical)
        guard !leaf.isEmpty, lexical != "/" else { return false }
        let resolved = PathUtil.stripDataVolumePrefix(
            PathUtil.standardize(PathSafety.realPath(PathUtil.parent(lexical)) + "/" + leaf)
        )
        for root in env.trashDirs {
            let base = PathUtil.stripDataVolumePrefix(PathUtil.standardize(root))
            let roots = [base, PathSafety.realPath(base)]
            // 必须以解析后的来源为准；字面上位于废纸篓里的软链父目录可能指向外面。
            if roots.contains(where: { PathUtil.isStrictlyInside(resolved, $0) }) { return true }
        }
        return false
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? RemoverError { return e.description }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return "没有权限（可能需要管理员，或需要在「系统设置 › 隐私与安全性」里授权）"
            case NSFileWriteVolumeReadOnlyError:
                return "所在卷是只读的"
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return "路径不存在"
            default: break
            }
        }
        return ns.localizedDescription
    }
}
