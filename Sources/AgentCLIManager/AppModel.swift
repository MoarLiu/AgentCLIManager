import ACMCore
import AppKit
import Observation
import SwiftUI

/// 所有外部输入集中在这里；测试必须显式提供每一项，避免意外访问真实家目录。
@MainActor
struct AppDependencies {
    var environment: () -> HostEnvironment
    var catalog: (HostEnvironment) -> Catalog
    var scan: @Sendable (ScanOptions) async -> ScanReport
    var measure: @Sendable ([String]) -> AsyncStream<(String, SizeResult?)>
    var remover: any Remover
    var processProbe: @Sendable () -> [RunningProcess]
    var loadLedger: (String) throws -> UndoLedger?
    var saveLedger: (UndoLedger, String) throws -> Void

    static var live: AppDependencies {
        AppDependencies(
            environment: HostEnvironment.live,
            catalog: Catalog.loadAll,
            scan: { options in
                await Task.detached(priority: .userInitiated) { ToolScanner.scan(options) }.value
            },
            measure: { paths in
                AsyncStream { continuation in
                    Task.detached(priority: .utility) {
                        ToolScanner.measure(paths: paths, probe: DuSizeProbe()) { path, size in
                            continuation.yield((path, size))
                        }
                        continuation.finish()
                    }
                }
            },
            remover: TrashRemover(),
            processProbe: ProcessProbe.live,
            loadLedger: { path in
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return try JSONDecoder().decode(UndoLedger.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            },
            saveLedger: { ledger, path in
                if ledger.isEmpty {
                    do { try FileManager.default.removeItem(atPath: path) }
                    catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {}
                } else {
                    try FileManager.default.createDirectory(atPath: PathUtil.parent(path), withIntermediateDirectories: true)
                    try JSONEncoder().encode(ledger).write(to: URL(fileURLWithPath: path), options: .atomic)
                }
            }
        )
    }
}

/// 界面状态。所有会动文件的操作都从这里发起，且只有「移到废纸篓」和「放回原处」两种。
@MainActor
@Observable
final class AppModel {
    private(set) var env: HostEnvironment
    private(set) var catalog: Catalog

    var report: ScanReport?
    var isScanning = false
    private var measuringJobs = 0
    var isMeasuring: Bool { measuringJobs > 0 }

    var selectedGroupID: String?
    /// 组 id → 已勾选的路径
    var selection: [String: Set<String>] = [:]
    var expanded: Set<String> = []
    var search = ""

    var plan: UninstallPlan?
    /// 每份新计划都有自己的确认代号；弹窗据此清空上一次「已核对」。
    var planConfirmationToken: String?
    var isExecuting = false
    var result: UninstallResult?
    private(set) var resultBatchID: UUID?
    var resultGroupName = ""
    /// 撤销栏的数据来自账本；外部赋空等同于点「不用了」。
    private var undoLedger = UndoLedger()
    var undoReceipts: [TrashReceipt] {
        get { undoLedger.receipts }
        set {
            if newValue.isEmpty {
                dismissUndo()
            } else {
                undoLedger = UndoLedger(receipts: newValue, groupName: undoGroupName)
                persistUndoLedger()
            }
        }
    }
    var undoGroupName: String {
        get { undoLedger.groupName }
        // 只读截图模式用它来展示一个假撤销栏；正式逻辑的名字由 UndoLedger 维护。
        set { undoLedger = UndoLedger(receipts: undoReceipts, groupName: newValue) }
    }
    var showInstall = false
    var showRecovery = false
    private var operationMessage: String?
    private(set) var persistenceError: String?
    private var operationIsError = false
    /// 操作结果与保存结果分别保存，后续成功消息不能覆盖保存失败。
    var banner: String? {
        get {
            let messages = [operationMessage, persistenceError].compactMap { $0 }
            return messages.isEmpty ? nil : messages.joined(separator: "\n")
        }
        set {
            operationMessage = newValue
            if newValue == nil { persistenceError = nil }
        }
    }
    var bannerIsError: Bool {
        get { operationIsError || persistenceError != nil }
        set { operationIsError = newValue }
    }
    /// 正在放回原处
    var isUndoing = false
    /// 上一次「放回原处」没能放回的条目及原因；对应的回执仍留在 undoReceipts 里，可以重试
    var undoFailures: [SkippedItem] = []
    /// 确认单顶部的提示：执行前复查发现情况变了（例如工具刚被启动），需要用户重新确认
    var planNotice: String?
    /// 卸载或放回任一进行中，视图可用它同时禁用两类操作。
    var isBusy: Bool { isExecuting || isUndoing }
    var canUndoAll: Bool { snapshot == nil && !isBusy && !undoLedger.isEmpty }
    /// 仅供界面显示「N 批未恢复」
    var undoBatchCount: Int { undoLedger.batches.filter { !$0.receipts.isEmpty }.count }
    var canUndoResult: Bool {
        guard result != nil, snapshot == nil, !isBusy, let resultBatchID else { return false }
        return undoLedger.batches.contains { $0.id == resultBatchID && !$0.receipts.isEmpty }
    }
    var operationStatus: OperationStatus {
        OperationStatus(banner: banner, bannerIsError: bannerIsError,
                        showsUndo: !undoLedger.isEmpty, canUndoAll: canUndoAll)
    }

    let snapshot: SnapshotOptions?
    private var generation = 0
    /// 生成计划时使用的组，扫描报告尚未刷新时也能据此重建确认单。
    private var plannedGroup: ToolGroup?
    /// 进程探测可注入，方便验证确认期间工具被启动的情况。
    var processProbe: @Sendable () -> [RunningProcess]
    private let dependencies: AppDependencies

    private var undoStorePath: String { env.ownSupportDir + "/undo-receipts.json" }

    convenience init(snapshot: SnapshotOptions?) {
        self.init(snapshot: snapshot, dependencies: .live)
    }

    init(snapshot: SnapshotOptions?, dependencies: AppDependencies) {
        let env = dependencies.environment()
        self.env = env
        self.catalog = dependencies.catalog(env)
        self.snapshot = snapshot
        self.dependencies = dependencies
        self.processProbe = dependencies.processProbe
        loadUndoLedger()
    }

    func start() async {
        await scan()
        if let snapshot { await Snapshotter.run(snapshot, model: self) }
    }

    // MARK: - 扫描

    func rescan() {
        Task { await scan() }
    }

    func scan() async {
        isScanning = true
        generation += 1
        let current = generation

        let env = dependencies.environment()
        let catalog = dependencies.catalog(env)
        self.env = env
        self.catalog = catalog
        let options = ScanOptions(env: env, catalog: catalog, processProbe: processProbe)
        let scanned = await dependencies.scan(options)
        guard current == generation else { return }

        report = scanned
        selection = [:]
        for group in scanned.groups {
            selection[group.id] = Set(group.artifacts.filter(\.defaultSelected).map(\.path))
        }
        expanded = []
        if selectedGroupID == nil || !scanned.groups.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = scanned.groups.first?.id
        }
        isScanning = false

        await measure(paths: ToolScanner.artifactPaths(scanned), generation: current)
    }

    private func measure(paths: [String], generation current: Int) async {
        guard !paths.isEmpty else { return }
        measuringJobs += 1
        defer { measuringJobs -= 1 }

        let stream = dependencies.measure(paths)
        var pending: [String: SizeResult] = [:]
        var lastApply = Date()
        for await (path, size) in stream {
            guard current == generation else { break }
            if let size { pending[path] = size }
            // 量大小可能一次回调几百项；攒一批再换 report，避免每项都复制整份报告。
            if pending.count >= 32 || Date().timeIntervalSince(lastApply) >= 0.08 {
                apply(sizes: pending)
                pending.removeAll()
                lastApply = Date()
            }
        }
        if current == generation, !pending.isEmpty { apply(sizes: pending) }
    }

    private func apply(sizes: [String: SizeResult]) {
        guard let report, !sizes.isEmpty else { return }
        self.report = ToolScanner.apply(sizes: sizes, to: report)
    }

    // MARK: - 列表

    var selectedGroup: ToolGroup? {
        guard let id = selectedGroupID else { return nil }
        return report?.groups.first { $0.id == id }
    }

    func groups(in section: ACMCore.Section) -> [ToolGroup] {
        guard let report else { return [] }
        let all = report.groups(in: section)
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = needle.isEmpty ? all : all.filter { group in
            group.name.lowercased().contains(needle)
                || group.binaries.contains { $0.name.lowercased().contains(needle) }
                || group.artifacts.contains { $0.path.lowercased().contains(needle) }
        }
        // 大的排前面；还没量完时按名字
        return filtered.sorted { lhs, rhs in
            let l = lhs.totalSize?.bytes ?? -1, r = rhs.totalSize?.bytes ?? -1
            if l != r { return l > r }
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
    }

    /// 管理范围内（已安装 + 残留 + 未识别）一共占了多少。
    var managedFootprint: SizeResult? {
        guard let report else { return nil }
        var bytes: Int64 = 0
        var accurate = true
        var any = false
        for group in report.groups where [.installed, .residue, .unidentified].contains(group.section) {
            guard let size = group.totalSize else { accurate = false; continue }
            any = true
            bytes += size.bytes
            if !size.accurate { accurate = false }
        }
        return any ? SizeResult(bytes: bytes, accurate: accurate) : nil
    }

    // MARK: - 勾选

    func isSelected(_ artifact: Artifact, in group: ToolGroup) -> Bool {
        selection[group.id]?.contains(artifact.path) ?? false
    }

    /// 只给界面用的展示状态。实际计划仍只读 selection，不能用「显示为勾选」扩大删除范围。
    func isEffectivelySelected(_ artifact: Artifact, in group: ToolGroup) -> Bool {
        isSelected(artifact, in: group) || isImplied(artifact, in: group)
    }

    /// 组状态覆盖已展开的子项，否则只勾一个子项会被误显示成全选。
    /// 组动作只处理顶层条目；凭据仍只能逐条勾选。
    enum KindSelection: Equatable {
        case none, partial, all, protected
    }

    struct KindSelectionSummary: Equatable {
        var state: KindSelection
        var picked: Int
        var candidates: Int
    }

    func kindSelectionSummary(_ kind: ArtifactKind, in group: ToolGroup) -> KindSelectionSummary {
        let candidates = group.artifacts.filter {
            canSelect($0, in: group) && !$0.flags.contains(.credentials)
                && ($0.kind == kind || isDescendantOfKind($0, kind: kind, in: group))
        }
        let picked = candidates.filter { isEffectivelySelected($0, in: group) }.count
        let state: KindSelection = candidates.isEmpty ? .protected
            : picked == 0 ? .none : picked == candidates.count ? .all : .partial
        return KindSelectionSummary(state: state, picked: picked, candidates: candidates.count)
    }

    func kindSelection(_ kind: ArtifactKind, in group: ToolGroup) -> KindSelection {
        kindSelectionSummary(kind, in: group).state
    }

    func toggleKind(_ kind: ArtifactKind, in group: ToolGroup) {
        let state = kindSelection(kind, in: group)
        guard state != .protected else { return }
        let turnOn = state != .all
        for item in group.artifacts where item.kind == kind {
            guard canSelect(item, in: group), !item.flags.contains(.credentials) else { continue }
            setSelected(item, in: group, turnOn)
        }
    }

    private func isDescendantOfKind(_ artifact: Artifact, kind: ArtifactKind, in group: ToolGroup) -> Bool {
        guard let parentPath = artifact.parentPath else { return false }
        return group.artifacts.contains { $0.path == parentPath && $0.kind == kind }
    }

    /// 组状态要覆盖「只勾了目录里的一个子项」；行本身仍只显示它自己是否会进入计划。
    private func hasSelectionWithin(_ artifact: Artifact, in group: ToolGroup) -> Bool {
        if isEffectivelySelected(artifact, in: group) { return true }
        return (selection[group.id] ?? []).contains {
            PathUtil.isStrictlyInside($0, artifact.path)
        }
    }

    /// 上级目录已勾选，这一项会被一并带走。
    func isImplied(_ artifact: Artifact, in group: ToolGroup) -> Bool {
        guard let chosen = selection[group.id] else { return false }
        return chosen.contains { $0 != artifact.path && PathUtil.isStrictlyInside(artifact.path, $0) }
    }

    func canSelect(_ artifact: Artifact, in group: ToolGroup) -> Bool {
        group.section != .managedByApp
            && !artifact.flags.contains(.notRemovable)
            && !artifact.flags.contains(.manualOnly)
    }

    func setSelected(_ artifact: Artifact, in group: ToolGroup, _ on: Bool) {
        guard canSelect(artifact, in: group) else { return }
        var chosen = selection[group.id] ?? []
        if on { chosen.insert(artifact.path) } else { chosen.remove(artifact.path) }
        selection[group.id] = chosen
    }

    func selectDefaults(_ group: ToolGroup) {
        selection[group.id] = Set(group.artifacts.filter(\.defaultSelected).map(\.path))
    }

    /// 全选不含登录凭据，也不含展开出来的子项（上级已覆盖）。
    func selectAll(_ group: ToolGroup) {
        selection[group.id] = Set(group.artifacts.filter {
            canSelect($0, in: group) && !$0.flags.contains(.credentials) && $0.parentPath == nil
        }.map(\.path))
    }

    func selectNone(_ group: ToolGroup) {
        selection[group.id] = []
    }

    func selectedArtifacts(_ group: ToolGroup) -> [Artifact] {
        let chosen = selection[group.id] ?? []
        return group.artifacts.filter { chosen.contains($0.path) }
    }

    func selectedSize(_ group: ToolGroup) -> SizeResult? {
        ToolGroup.totalSize(of: selectedArtifacts(group))
    }

    // MARK: - 展开一层

    func toggleExpand(_ artifact: Artifact, in group: ToolGroup) {
        if expanded.contains(artifact.path) {
            expanded.remove(artifact.path)
            return
        }
        expanded.insert(artifact.path)
        guard var report, let index = report.groups.firstIndex(where: { $0.id == group.id }) else { return }
        guard !report.groups[index].artifacts.contains(where: { $0.parentPath == artifact.path }) else { return }

        let children = ToolScanner.children(of: artifact, in: report.groups[index], env: env)
        report.groups[index].artifacts.append(contentsOf: children)
        self.report = report

        let paths = children.map(\.path)
        let current = generation
        Task { await measure(paths: paths, generation: current) }
    }

    func children(of artifact: Artifact, in group: ToolGroup) -> [Artifact] {
        group.artifacts
            .filter { $0.parentPath == artifact.path }
            .sorted { lhs, rhs in
                let l = lhs.size?.bytes ?? -1, r = rhs.size?.bytes ?? -1
                if l != r { return l > r }
                return lhs.path < rhs.path
            }
    }

    // MARK: - 卸载

    /// 给确认单显示「不会动」的真实顶层清单；这只是计划的展示投影，不参与计划生成。
    func preservedTopLevelArtifacts(for plan: UninstallPlan) -> [Artifact] {
        guard let group = executionGroup(for: plan) else { return [] }
        let skipped = Set(plan.skipped.map(\.path))
        return group.artifacts.filter {
            artifact in
            artifact.parentPath == nil && !hasSelectionWithin(artifact, in: group)
                && !plan.steps.contains { $0.path == artifact.path }
                && !skipped.contains(artifact.path)
        }
    }

    /// 生成计划前重新查一遍进程：扫描到现在可能已经过了很久。
    func preparePlan(for group: ToolGroup) {
        guard !isExecuting, !isUndoing, !isScanning else { return }
        planNotice = nil
        let pids = runningPIDs(for: group)
        let fresh = groupWithRunningPIDs(group, pids: pids)
        plannedGroup = fresh
        let newPlan = makePlan(for: fresh, selected: selection[group.id] ?? [])
        planConfirmationToken = newPlan.token
        plan = newPlan
    }

    func execute(_ plan: UninstallPlan) async {
        guard snapshot == nil, !isExecuting, !isUndoing else { return }
        isExecuting = true
        defer { isExecuting = false }

        // 确认单可能开了一会儿。真正动手前再查一次，不能把旧确认当成新风险的授权。
        guard let group = executionGroup(for: plan) else {
            planNotice = "找不到这份计划对应的工具，无法复查运行状态。请关闭确认单后重新扫描。"
            return
        }
        let currentPIDs = await runningPIDsAsync(for: group)
        let decision = PlanRecheck.evaluate(
            groupName: plan.groupName,
            acknowledgedPIDs: plan.acknowledgedPIDs,
            currentPIDs: currentPIDs
        )
        if decision.shouldPause {
            replacePlanAfterRecheck(plan, group: group, currentPIDs: currentPIDs, decision: decision)
            return
        }

        let env = self.env
        let probe = processProbe
        let remover = dependencies.remover
        let outcome = await Task.detached(priority: .userInitiated) {
            Uninstaller.execute(plan, env: env, remover: remover, processProbe: probe)
        }.value

        // 执行器的复查是竞态兜底：它发现新进程时一步都没做，不能显示成卸载结果。
        if !outcome.newlyRunningPIDs.isEmpty {
            let latestPIDs = await runningPIDsAsync(for: group)
            let pids = latestPIDs.isEmpty ? outcome.newlyRunningPIDs : latestPIDs
            let decision = PlanRecheck.evaluate(
                groupName: plan.groupName,
                acknowledgedPIDs: plan.acknowledgedPIDs,
                currentPIDs: pids
            )
            // 以执行器报出的 PID 为准，即使它恰好在第二次探测前退出了也要重新确认。
            let effective = RecheckDecision(
                newlyRunningPIDs: outcome.newlyRunningPIDs,
                notice: decision.notice ?? PlanRecheck.evaluate(
                    groupName: plan.groupName,
                    acknowledgedPIDs: [],
                    currentPIDs: outcome.newlyRunningPIDs
                ).notice
            )
            replacePlanAfterRecheck(plan, group: group, currentPIDs: pids, decision: effective)
            return
        }

        self.plan = nil
        plannedGroup = nil
        planNotice = nil
        resultGroupName = plan.groupName
        // 批次身份先入账，再展示结果。相同回执也不会与历史批次混在一起。
        resultBatchID = undoLedger.merge(outcome.receipts, groupName: plan.groupName)
        if resultBatchID != nil { persistUndoLedger() }
        // 文件操作已经结束。扫描/测量是独立刷新，不能占用恢复操作的锁。
        isExecuting = false
        result = outcome
        rescan()
    }

    /// 全局入口：恢复账本中的全部批次（保留旧方法名供现有调用使用）。
    func undoLast() async {
        guard canUndoAll else { return }
        await restore(batches: undoLedger.batches, name: undoGroupName)
    }

    /// 结果弹窗入口：只恢复该结果对应的批次。拒绝时保留弹窗。
    @discardableResult
    func undoResult() async -> Bool {
        guard canUndoResult, let batch = undoLedger.batches.first(where: { $0.id == resultBatchID }) else {
            return false
        }
        result = nil
        await restore(batches: [batch], name: batch.groupName)
        return true
    }

    private func restore(batches: [UndoBatch], name: String) async {
        isUndoing = true
        let env = self.env
        let remover = dependencies.remover
        // 每批单独核对结果，以免相同回执的失败被归到另一个批次。
        let outcomes = await Task.detached {
            batches.reversed().map { batch in
                (batch.id, Uninstaller.restore(batch.receipts, env: env, remover: remover))
            }
        }.value
        for (batchID, outcome) in outcomes {
            undoLedger.retain(remaining: outcome.remaining, batchID: batchID)
        }
        let failures = outcomes.flatMap { $0.1.failures }
        let restoredCount = outcomes.reduce(0) { $0 + $1.1.restored.count }
        undoFailures = failures
        if failures.isEmpty {
            banner = "已把 \(name) 的 \(restoredCount) 项放回原处"
            bannerIsError = false
        } else {
            banner = "放回了 \(restoredCount) 项，\(failures.count) 项没能放回：" +
                failures.map { "\(PathUtil.display($0.path, home: env.home))（\($0.reason)）" }.joined(separator: "；")
            bannerIsError = true
        }
        persistUndoLedger()
        isUndoing = false
        rescan()
    }

    /// 用户不想放回了：丢掉回执（东西仍在废纸篓里）。
    func dismissUndo() {
        guard !isBusy else { return }
        undoLedger.dismiss()
        undoFailures = []
        persistUndoLedger()
    }

    // MARK: - 执行前复查与回执持久化

    private func runningPIDs(for group: ToolGroup) -> [Int32] {
        ToolScanner.runningPIDs(for: group, in: processProbe())
    }

    private func runningPIDsAsync(for group: ToolGroup) async -> [Int32] {
        let probe = processProbe
        return await Task.detached(priority: .userInitiated) {
            ToolScanner.runningPIDs(for: group, in: probe())
        }.value
    }

    private func executionGroup(for plan: UninstallPlan) -> ToolGroup? {
        if let selectedGroup, selectedGroup.id == plan.groupID { return selectedGroup }
        if let group = report?.groups.first(where: { $0.id == plan.groupID }) { return group }
        return plannedGroup?.id == plan.groupID ? plannedGroup : nil
    }

    private func groupWithRunningPIDs(_ group: ToolGroup, pids: [Int32]) -> ToolGroup {
        var fresh = group
        fresh.runningPIDs = pids
        for i in fresh.artifacts.indices {
            fresh.artifacts[i].flags.remove(.inUse)
            if !pids.isEmpty { fresh.artifacts[i].flags.insert(.inUse) }
        }
        return fresh
    }

    private func makePlan(for group: ToolGroup, selected: Set<String>) -> UninstallPlan {
        var plan = UninstallPlanner.plan(group: group, selected: selected, env: env)
        // 目前规划器只负责列出步骤；这些字段由状态层填上，执行器才能做同样的复查。
        var roots: [String] = []
        for binary in group.binaries where !binary.isBroken {
            if let root = binary.payloadRoot { roots.append(root) }
            roots += binary.chain
        }
        roots += group.artifacts.filter { $0.kind == .program }.map(\.path)
        plan.watchPaths = roots
        plan.acknowledgedPIDs = group.runningPIDs
        return plan
    }

    private func replacePlanAfterRecheck(
        _ oldPlan: UninstallPlan,
        group: ToolGroup,
        currentPIDs: [Int32],
        decision: RecheckDecision
    ) {
        let fresh = groupWithRunningPIDs(group, pids: currentPIDs)
        let selected = selection[oldPlan.groupID] ?? Set(oldPlan.steps.map(\.path))
        plannedGroup = fresh
        let newPlan = makePlan(for: fresh, selected: selected)
        planConfirmationToken = newPlan.token
        plan = newPlan
        planNotice = decision.notice
        result = nil
    }

    private func loadUndoLedger() {
        guard snapshot == nil else { return }
        do {
            undoLedger = try dependencies.loadLedger(undoStorePath) ?? UndoLedger()
        } catch {
            banner = "没能读取上次未放回的回执：\(error.localizedDescription)"
            bannerIsError = true
        }
    }

    @discardableResult
    private func persistUndoLedger() -> Result<Void, Error> {
        guard snapshot == nil else { return .success(()) }
        do {
            try dependencies.saveLedger(undoLedger, undoStorePath)
            persistenceError = nil
            return .success(())
        } catch {
            // 不改内存回执；保存错误独立于操作结果，成功横幅也不能把它盖掉。
            persistenceError = "没能保存撤销回执：\(error.localizedDescription)。请暂时不要退出 App。"
            return .failure(error)
        }
    }

    // MARK: - 与系统交互

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 在「终端」里运行一条命令。本 App 自己不执行安装脚本或包管理器——
    /// 命令在用户自己的 shell 里跑，看得见、停得下。
    func runInTerminal(_ command: String) {
        guard snapshot == nil else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acm-" + UUID().uuidString)
        let script = dir.appendingPathComponent("运行命令.command")
        let body = TerminalScript.body(for: command)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            banner = "没能打开终端：\(error.localizedDescription)"
            bannerIsError = true
        }
    }

    func isInstalled(_ product: CatalogProduct) -> Bool {
        report?.groups.contains { $0.section == .installed && $0.productID == product.id } ?? false
    }

    var installableProducts: [CatalogProduct] {
        catalog.products
            .filter { $0.kind == .cli && !($0.install ?? []).isEmpty }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func show(_ path: String) -> String {
        PathUtil.display(path, home: env.home)
    }
}
