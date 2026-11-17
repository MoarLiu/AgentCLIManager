import ACMCore
import Foundation
import Observation

/// 「项目清理」的外部输入。和 `AppDependencies` 一样，测试必须逐项给出。
struct SweepDependencies {
    /// 查进程占用和 Git 跟踪
    var probes: SweepProbes
    /// 读、写「扫描过的文件夹」清单；路径由调用方给出
    var loadFolders: (String) -> [String]
    var saveFolders: ([String], String) throws -> Void
    /// 现在几点。计划 24 小时后过期、闲置多久都按它算。
    var now: @Sendable () -> Date = { Date() }

    static var live: SweepDependencies {
        SweepDependencies(
            probes: .live,
            loadFolders: { path in
                guard let data = FileManager.default.contents(atPath: path),
                      let folders = try? JSONDecoder().decode([String].self, from: data)
                else { return [] }
                return folders
            },
            saveFolders: { folders, path in
                try FileManager.default.createDirectory(
                    atPath: PathUtil.parent(path), withIntermediateDirectories: true
                )
                try JSONEncoder().encode(folders).write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        )
    }
}

/// 「至少闲置多久才算可清理」的三档。
enum SweepIdle: Double, CaseIterable, Identifiable {
    case day = 24
    case week = 168
    case any = 0

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .day: return "闲置 1 天以上"
        case .week: return "闲置 7 天以上"
        case .any: return "不看闲置时间"
        }
    }
}

/// 等用户确认的一次清理。里面的预演结果就是确认单上列出来的东西。
struct SweepConfirmation: Identifiable {
    let id = UUID()
    var folder: String
    var mode: SweepMode
    var plan: SweepPlan
    /// 预演：每个勾选项现在是可执行、已跳过还是已不存在
    var preview: SweepApplyResult

    /// 确认之后真正会去动的那些
    var readyIDs: [String] { preview.items.filter { $0.status == .ready }.map(\.id) }
    var readyItems: [SweepItem] {
        let ready = Set(readyIDs)
        return plan.items.filter { ready.contains($0.id) }
    }
    var readyBytes: Int64 { readyItems.reduce(0) { $0 + ($1.snapshot?.allocatedBytes ?? 0) } }
    var notReady: [SweepOutcome] { preview.items.filter { $0.status != .ready } }
}

/// 「项目清理」的界面状态：扫描过的文件夹、每个文件夹的扫描结果和勾选、
/// 等待确认的清理、可放回的回执。会动文件的只有 `execute` 和 `restore`。
@MainActor
@Observable
final class SweepSession {
    var env: HostEnvironment
    private let dependencies: SweepDependencies
    /// 只读截图模式：不读写文件夹清单，不执行，不放回。
    private let readOnly: Bool
    /// 往全局横幅里送一句话（第二个参数：是不是出错）
    var onMessage: (String, Bool) -> Void = { _, _ in }

    private(set) var folders: [String] = []
    var selectedFolder: String?
    private(set) var plans: [String: SweepPlan] = [:]
    private(set) var errors: [String: SweepError] = [:]
    private var scanning: Set<String> = []
    private var generations: [String: Int] = [:]
    /// 文件夹 → 勾选的候选项 id
    private(set) var selection: [String: Set<String>] = [:]

    private(set) var idle: SweepIdle = .day

    private(set) var isPreparing = false
    var confirmation: SweepConfirmation?
    /// 确认单里显示的执行错误（计划过期、同目录已有操作等）
    private(set) var confirmationError: String?
    private(set) var isApplying = false
    var result: SweepApplyResult?
    /// 结果对应的文件夹，用来把相对路径显示成完整路径
    private(set) var resultFolder: String?

    private(set) var pendingRuns: [SweepPendingRun] = []
    private(set) var isRestoring = false
    var showRecovery = false

    var isBusy: Bool { isApplying || isRestoring }

    init(env: HostEnvironment, dependencies: SweepDependencies, readOnly: Bool) {
        self.env = env
        self.dependencies = dependencies
        self.readOnly = readOnly
        if !readOnly {
            folders = dependencies.loadFolders(foldersPath)
            selectedFolder = folders.first
            refreshPending()
        }
    }

    private var foldersPath: String { env.ownSupportDir + "/sweep-folders.json" }

    // MARK: - 文件夹

    /// 加一个要清理的文件夹。不合规矩的（家目录本身、系统目录、隐藏目录…）当场拒绝并说明原因。
    @discardableResult
    func addFolder(_ path: String) -> Bool {
        let root: String
        do {
            root = try SweepPath.normalizedRoot(path, env: env)
        } catch {
            onMessage("不能清理这个文件夹：\((error as? SweepError)?.message ?? error.localizedDescription)", true)
            return false
        }
        if !folders.contains(root) {
            folders.append(root)
            persistFolders()
        }
        select(root)
        return true
    }

    /// 只是从清单里拿掉，不动文件夹本身。
    func removeFolder(_ folder: String) {
        guard !isBusy else { return }
        folders.removeAll { $0 == folder }
        plans[folder] = nil
        errors[folder] = nil
        selection[folder] = nil
        generations[folder, default: 0] += 1
        scanning.remove(folder)
        if selectedFolder == folder { selectedFolder = folders.first }
        persistFolders()
        ensureScanned()
    }

    func select(_ folder: String) {
        selectedFolder = folder
        ensureScanned()
    }

    /// 选中的文件夹还没有结果就扫一遍。
    func ensureScanned() {
        guard let folder = selectedFolder, plans[folder] == nil, errors[folder] == nil,
              !scanning.contains(folder)
        else { return }
        Task { await scan(folder) }
    }

    private func persistFolders() {
        guard !readOnly else { return }
        do {
            try dependencies.saveFolders(folders, foldersPath)
        } catch {
            onMessage("没能保存文件夹清单：\(error.localizedDescription)", true)
        }
    }

    // MARK: - 扫描

    var plan: SweepPlan? { selectedFolder.flatMap { plans[$0] } }
    var error: SweepError? { selectedFolder.flatMap { errors[$0] } }
    var isScanning: Bool { selectedFolder.map(scanning.contains) ?? false }
    var isScanningAny: Bool { !scanning.isEmpty }

    func isScanning(_ folder: String) -> Bool { scanning.contains(folder) }

    func rescan() {
        guard let folder = selectedFolder else { return }
        Task { await scan(folder) }
    }

    /// 换一档闲置时间：之前的结论都作废，重新扫描。
    func setIdle(_ value: SweepIdle) {
        guard value != idle else { return }
        idle = value
        for folder in folders { generations[folder, default: 0] += 1 }
        scanning = []
        plans = [:]
        errors = [:]
        ensureScanned()
    }

    func scan(_ folder: String) async {
        generations[folder, default: 0] += 1
        let current = generations[folder]
        scanning.insert(folder)
        let env = self.env
        let probes = dependencies.probes
        let policy = SweepPolicy(idleHours: idle.rawValue)
        let now = dependencies.now()
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<SweepPlan, SweepError> in
            do {
                return .success(try SweepScanner.scan(root: folder, policy: policy, env: env, probes: probes, now: now))
            } catch let error as SweepError {
                return .failure(error)
            } catch {
                return .failure(SweepError("io_error", error.localizedDescription))
            }
        }.value
        guard current == generations[folder], folders.contains(folder) else { return }
        scanning.remove(folder)
        switch outcome {
        case .success(let fresh):
            selection[folder] = Self.carriedSelection(old: plans[folder], chosen: selection[folder], fresh: fresh)
            plans[folder] = fresh
            errors[folder] = nil
        case .failure(let error):
            plans[folder] = nil
            selection[folder] = nil
            errors[folder] = error
        }
    }

    /// 默认勾选：有依据的缓存和内容相同的重复安装包。「已有更新版本」的旧安装包不勾——
    /// 新旧是按文件名里的版本号推测的，要用户自己点。
    static func defaultSelection(_ plan: SweepPlan) -> Set<String> {
        Set(plan.items.filter { $0.status == .cleanup && !plan.isSupersededVersion($0) }.map(\.id))
    }

    /// 重新扫描后的勾选：还在的沿用用户原来的选择，新出现的按默认。
    static func carriedSelection(old: SweepPlan?, chosen: Set<String>?, fresh: SweepPlan) -> Set<String> {
        let defaults = defaultSelection(fresh)
        guard let old, let chosen else { return defaults }
        let known = Set(old.items.map(\.id))
        let cleanup = Set(fresh.items.filter { $0.status == .cleanup }.map(\.id))
        return chosen.intersection(cleanup).union(defaults.subtracting(known))
    }

    // MARK: - 勾选

    func isSelected(_ item: SweepItem) -> Bool {
        selectedFolder.flatMap { selection[$0] }?.contains(item.id) ?? false
    }

    func setSelected(_ item: SweepItem, _ on: Bool) {
        guard let folder = selectedFolder, item.status == .cleanup else { return }
        var chosen = selection[folder] ?? []
        if on { chosen.insert(item.id) } else { chosen.remove(item.id) }
        selection[folder] = chosen
    }

    func selectDefaults() {
        guard let folder = selectedFolder, let plan else { return }
        selection[folder] = Self.defaultSelection(plan)
    }

    /// 全部可清理项，连旧版本安装包一起。
    func selectAllCleanup() {
        guard let folder = selectedFolder, let plan else { return }
        selection[folder] = Set(plan.items.filter { $0.status == .cleanup }.map(\.id))
    }

    func selectNone() {
        guard let folder = selectedFolder else { return }
        selection[folder] = []
    }

    /// 全选框：全部勾上了就全部取消，否则全部勾上。
    func toggleAllCleanup() {
        guard let plan else { return }
        let cleanup = plan.items.filter { $0.status == .cleanup }
        if selectedItems.count == cleanup.count { selectNone() } else { selectAllCleanup() }
    }

    var selectedItems: [SweepItem] {
        guard let folder = selectedFolder, let plan, let chosen = selection[folder] else { return [] }
        return plan.items.filter { $0.status == .cleanup && chosen.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + ($1.snapshot?.allocatedBytes ?? 0) }
    }

    // MARK: - 清理

    /// 对着磁盘把勾选的项目重新核对一遍，然后打开确认单。这一步不动任何文件。
    func prepare(mode: SweepMode) async {
        guard !isBusy, !isPreparing, let folder = selectedFolder, let plan else { return }
        // 没有勾选就什么都不做。执行器把「没点名」理解成「全部可清理项」，这里绝不能走到那一步。
        let ids = selectedItems.map(\.id)
        guard !ids.isEmpty else { return }
        isPreparing = true
        defer { isPreparing = false }
        let env = self.env
        let probes = dependencies.probes
        let now = dependencies.now()
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<SweepApplyResult, SweepError> in
            Self.attempt {
                try SweepExecutor.apply(
                    plan, execute: false, mode: mode, identifiers: ids, env: env, probes: probes, now: now
                )
            }
        }.value
        guard selectedFolder == folder, plans[folder] == plan else { return }
        switch outcome {
        case .success(let preview):
            confirmationError = nil
            confirmation = SweepConfirmation(folder: folder, mode: mode, plan: plan, preview: preview)
        case .failure(let error):
            onMessage(Self.explain(error), true)
            if ["expired_plan", "root_changed"].contains(error.code) { await scan(folder) }
        }
    }

    /// 执行确认单上列出的那些——不多也不少。
    func execute(_ confirmation: SweepConfirmation) async {
        guard !readOnly, !isBusy else { return }
        let ids = confirmation.readyIDs
        guard !ids.isEmpty else { return }
        isApplying = true
        confirmationError = nil
        let env = self.env
        let probes = dependencies.probes
        let plan = confirmation.plan
        let mode = confirmation.mode
        let now = dependencies.now()
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<SweepApplyResult, SweepError> in
            Self.attempt {
                try SweepExecutor.apply(
                    plan, execute: true, mode: mode, identifiers: ids, env: env, probes: probes, now: now
                )
            }
        }.value
        isApplying = false
        switch outcome {
        case .success(let applied):
            self.confirmation = nil
            resultFolder = confirmation.folder
            result = applied
            refreshPending()
            await scan(confirmation.folder)
        case .failure(let error):
            // 一步都没做。留在确认单上把原因说清楚。
            confirmationError = Self.explain(error)
        }
    }

    func cancelConfirmation() {
        guard !isApplying else { return }
        confirmation = nil
        confirmationError = nil
    }

    // MARK: - 放回

    func refreshPending() {
        guard !readOnly else { return }
        pendingRuns = SweepRestorer.pendingRuns(env: env)
    }

    /// 结果弹窗对应的那一次执行，如果它还有东西可以放回。
    var resultRun: SweepPendingRun? {
        guard let receipt = result?.receipt else { return nil }
        return pendingRuns.first { $0.receipt == receipt }
    }

    /// 按回执把一次执行移走的东西放回原处。返回是否全部放回。
    @discardableResult
    func restore(_ run: SweepPendingRun) async -> Bool {
        guard !readOnly, !isBusy else { return false }
        isRestoring = true
        let env = self.env
        let receipt = run.receipt
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<SweepRestoreResult, SweepError> in
            Self.attempt { try SweepRestorer.restore(receipt: receipt, execute: true, env: env) }
        }.value
        isRestoring = false
        refreshPending()
        let name = PathUtil.lastComponent(run.root)
        var complete = false
        switch outcome {
        case .success(let restored):
            let done = restored.items.filter { $0.status == .restored }.count
            let failed = restored.items.filter { $0.status.isFailure }
            if failed.isEmpty {
                complete = true
                onMessage("已把「\(name)」的 \(done) 项放回原处", false)
            } else {
                let reasons = failed.map { "\($0.path)（\($0.reason ?? $0.status.displayName)）" }
                onMessage("放回了 \(done) 项，\(failed.count) 项没能放回：" + reasons.joined(separator: "；"), true)
            }
        case .failure(let error):
            onMessage("没能放回「\(name)」：\(Self.explain(error))", true)
        }
        if folders.contains(run.root) { await scan(run.root) }
        return complete
    }

    // MARK: - 辅助

    nonisolated private static func attempt<Value>(_ body: () throws -> Value) -> Result<Value, SweepError> {
        do {
            return .success(try body())
        } catch let error as SweepError {
            return .failure(error)
        } catch {
            return .failure(SweepError("io_error", error.localizedDescription))
        }
    }

    private static func explain(_ error: SweepError) -> String {
        guard let path = error.details["path"] else { return error.message }
        return "\(error.message)（\(path)）"
    }

    // MARK: - 只读截图

    /// 截图模式用：直接摆一个文件夹进来，不读写文件夹清单。
    func showDemoFolder(_ path: String) async {
        guard readOnly, let root = try? SweepPath.normalizedRoot(path, env: env) else { return }
        folders = [root]
        selectedFolder = root
        await scan(root)
    }

    /// 截图模式用：摆一个假的执行结果和一批假的可放回内容。纯内存。
    func showDemoResult(mode: SweepMode) {
        guard readOnly, let folder = selectedFolder, let plan else { return }
        let chosen = selectedItems
        var outcomes = chosen.map {
            SweepOutcome(id: $0.id, path: $0.path, status: mode == .permanent ? .deleted : .trashed)
        }
        if let blocked = plan.items.first(where: { $0.status == .cleanup && !chosen.contains($0) }) {
            outcomes.append(SweepOutcome(
                id: blocked.id, path: blocked.path, status: .blocked, reason: "内容自计划生成后发生变化。"
            ))
        }
        resultFolder = folder
        result = SweepApplyResult(
            executed: true, mode: mode, root: folder, receipt: mode == .trash ? "/demo/receipt.jsonl" : nil,
            items: outcomes, freeSpaceDeltaBytes: mode == .permanent ? selectedBytes : nil,
            requiresEmptyingTrash: mode == .trash
        )
    }

    func showDemoPending() {
        guard readOnly, let folder = selectedFolder else { return }
        let items = selectedItems.prefix(4).map {
            SweepPendingRun.Item(id: $0.id, path: $0.path, bytes: $0.snapshot?.allocatedBytes ?? 0)
        }
        guard !items.isEmpty else { return }
        pendingRuns = [SweepPendingRun(
            runID: "demo", receipt: "/demo/receipt.jsonl", root: folder, mode: .trash,
            createdAt: Date().addingTimeInterval(-1800), items: Array(items)
        )]
    }
}
