import Foundation
import AppKit
import SwiftUI
import Testing
@testable import ACMCore
@testable import AgentCLIManager

/// 原生 executable target 的真实 AppModel；所有外部输入来自临时目录或内存。
@Suite @MainActor struct P2AppModelTests {
    @Test func visibleResultReleasesExecutionLockBeforeRefresh() async throws {
        let fixture = try GUIFixture()
        let gate = ScanGate()
        let model = fixture.model(scan: { _ in
            await gate.suspend()
            return fixture.emptyReport
        })
        let plan = try fixture.plan(model: model)
        let execution = Task { await model.execute(plan) }
        await gate.waitUntilEntered()
        #expect(model.result?.receipts.count == 1)
        #expect(!model.isExecuting, "结果已可见时，移动操作必须已释放锁")
        await gate.release()
        await execution.value
    }

    @Test func resultRestoresOnlyItsBatch() async throws {
        let fixture = try GUIFixture()
        let older = fixture.receipt("older")
        let model = fixture.model(ledger: UndoLedger(receipts: [older], groupName: "older"))
        let plan = try fixture.plan(model: model)
        await model.execute(plan)
        let current = try #require(model.result?.receipts.first)
        #expect(model.canUndoResult)
        #expect(await model.undoResult())
        #expect(fixture.remover.restored == [current.original])
        #expect(model.undoReceipts == [older])
        #expect(model.result == nil)
        #expect(!model.canUndoResult)
    }

    @Test func partialResultRestoreKeepsOlderBatchAndCurrentFailure() async throws {
        let fixture = try GUIFixture()
        let older = fixture.receipt("older")
        let model = fixture.model(ledger: UndoLedger(receipts: [older], groupName: "older"))
        var plan = try fixture.plan(model: model)
        let second = try fixture.plan(model: model, name: "second")
        plan.steps += second.steps
        // 同一组的计划；上面的 helper 换了报告，重新放回对应组。
        model.report = ScanReport(scannedAt: Date(), groups: [ToolGroup(id: plan.groupID, name: plan.groupName, section: .installed)])
        await model.execute(plan)
        let receipts = try #require(model.result?.receipts)
        fixture.remover.fail(receipts[0].original)
        #expect(await model.undoResult())
        #expect(fixture.remover.restored == receipts.reversed().map(\.original))
        #expect(model.undoReceipts == [older, receipts[0]])
        #expect(model.undoFailures.map(\.path) == [receipts[0].original])
        #expect(model.undoGroupName == "older、current")
    }

    @Test func resultUndoDuringBlockedRefreshIsAccepted() async throws {
        let fixture = try GUIFixture()
        let gate = ScanGate()
        let model = fixture.model(scan: { _ in
            await gate.suspend()
            return fixture.emptyReport
        })
        let plan = try fixture.plan(model: model)
        let execution = Task { await model.execute(plan) }
        await gate.waitUntilEntered()
        #expect(model.canUndoResult)
        // 不释放刷新 gate 就直接等待恢复返回，证明刷新不持有操作锁。
        #expect(await model.undoResult())
        #expect(model.isScanning)
        #expect(fixture.remover.restored == plan.steps.map(\.path))
        #expect(model.result == nil)
        await gate.release()
        await execution.value
    }

    @Test func resultUndoIsAllowedWhileMeasurementIsPending() async throws {
        let fixture = try GUIFixture()
        let gate = ScanGate()
        let measuredGroup = ToolGroup(id: "measure", name: "测量中", section: .residue, artifacts: [
            Artifact(path: fixture.home + "/.cache/tool", kind: .cache, claim: .ownedByCLI, strength: .certain)
        ])
        let model = fixture.model(
            scan: { _ in ScanReport(scannedAt: Date(), groups: [measuredGroup]) },
            measure: { _ in AsyncStream { continuation in
                Task {
                    await gate.suspend()
                    continuation.finish()
                }
            } }
        )
        await model.execute(try fixture.plan(model: model))
        await gate.waitUntilEntered()
        #expect(model.isMeasuring)
        #expect(!model.isExecuting)
        #expect(model.canUndoResult)
        #expect(await model.undoResult())
        #expect(fixture.remover.restored.count == 1)
        await gate.release()
    }

    @Test func busyResultUndoDoesNotDismissSheetOrReenter() async throws {
        let fixture = try GUIFixture()
        let model = fixture.model()
        await model.execute(try fixture.plan(model: model))
        model.isUndoing = true
        #expect(!model.canUndoResult)
        #expect(!(await model.undoResult()))
        #expect(model.result != nil)
        #expect(fixture.remover.restored.isEmpty)
        model.isUndoing = false
        #expect(await model.undoResult())
        #expect(fixture.remover.restored.count == 1)
    }

    @Test func emptyReportStillPresentsGlobalUndoAndError() async throws {
        let fixture = try GUIFixture()
        let receipt = fixture.receipt("older")
        let model = fixture.model(ledger: UndoLedger(receipts: [receipt], groupName: "older"))
        await model.scan()
        model.banner = "没能保存撤销回执"
        model.bannerIsError = true
        #expect(model.selectedGroup == nil)
        #expect(model.operationStatus.showsUndo)
        #expect(model.operationStatus.banner == model.banner)
        #expect(model.operationStatus.bannerIsError)
        #expect(model.operationStatus.canUndoAll)
        await model.undoLast()
        #expect(!model.operationStatus.showsUndo)
        #expect(model.operationStatus.banner?.contains("已把") == true)
    }

    @Test func globalRestoreAttemptsAllBatchesNewestFirst() async throws {
        let fixture = try GUIFixture()
        let first = fixture.receipt("first"), second = fixture.receipt("second")
        let third = fixture.receipt("third")
        var ledger = UndoLedger(receipts: [first, second], groupName: "old")
        ledger.merge([third], groupName: "new")
        let model = fixture.model(ledger: ledger)
        fixture.remover.fail(second.original)
        await model.undoLast()
        #expect(fixture.remover.restored == [third.original, second.original, first.original])
        #expect(model.undoReceipts == [second])
        #expect(model.undoGroupName == "old")
    }

    @Test func snapshotDemoNeverLoadsOrSavesLedgerOrRestores() async throws {
        let fixture = try GUIFixture()
        var loads = 0, saves = 0
        let env = HostEnvironment(home: fixture.home, systemBinDirs: [], includeLibrary: false)
        let model = AppModel(snapshot: SnapshotOptions(path: fixture.root.appendingPathComponent("demo.png").path),
                             dependencies: AppDependencies(
            environment: { env }, catalog: { _ in Catalog(products: []) },
            scan: { _ in ScanReport(scannedAt: Date(), groups: []) },
            measure: { _ in AsyncStream { $0.finish() } },
            remover: fixture.remover, processProbe: { [] },
            loadLedger: { _ in loads += 1; return nil },
            saveLedger: { _, _ in saves += 1 }
        ))
        model.undoReceipts = [fixture.receipt("demo")]
        model.undoGroupName = "只读演示"
        model.result = UninstallResult(receipts: model.undoReceipts, failures: [])
        model.banner = "只读横幅"
        await model.undoLast()
        #expect(!(await model.undoResult()))
        await model.execute(try fixture.plan(model: model))
        #expect(model.operationStatus.showsUndo)
        #expect(!model.canUndoAll)
        #expect(!model.canUndoResult)
        #expect(model.undoGroupName == "只读演示")
        #expect(model.result != nil)
        #expect(fixture.remover.restored.isEmpty)
        model.dismissUndo()
        #expect(loads == 0)
        #expect(saves == 0)
    }

    @Test func emptyRootReadOnlySnapshot() async throws {
        let fixture = try GUIFixture()
        let model = fixture.model(ledger: UndoLedger(receipts: [fixture.receipt("older")], groupName: "上次操作"))
        model.report = fixture.emptyReport
        model.banner = "放回了 1 项；没能保存撤销回执。请暂时不要退出 App。"
        model.bannerIsError = true
        #expect(model.selectedGroup == nil)
        #expect(model.operationStatus.showsUndo)
        #expect(model.operationStatus.canUndoAll)
        _ = NSApplication.shared
        let view = NSHostingView(rootView: RootView().environment(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(x: 0, y: 0, width: 1180, height: 780)
        defer { window.close() }
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let target = view.superview ?? view
        let bitmap = try #require(target.bitmapImageRepForCachingDisplay(in: target.bounds))
        target.cacheDisplay(in: target.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(!png.isEmpty)
        // 可选输出仅允许系统临时目录；普通测试只在内存渲染，不留下文件。
        if let directory = ProcessInfo.processInfo.environment["ACM_GUI_TEST_SCREENSHOTS"] {
            let url = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            #expect(url.path.hasPrefix(temporary + "/"))
            guard url.path.hasPrefix(temporary + "/") else { return }
            try png.write(to: url.appendingPathComponent("empty-root-operation-status.png"))
        }
    }

    @Test func persistenceErrorSurvivesSuccessfulRestore() async throws {
        let fixture = try GUIFixture()
        let receipt = fixture.receipt("old")
        let model = fixture.model(ledger: UndoLedger(receipts: [receipt], groupName: "旧工具"), save: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        await model.undoLast()
        #expect(model.undoReceipts.isEmpty)
        #expect(model.banner?.contains("放回") == true)
        #expect(model.banner?.contains("没能保存撤销回执") == true)
        #expect(model.bannerIsError)
    }

    @Test func persistenceErrorKeepsFailedReceiptInMemory() async throws {
        let fixture = try GUIFixture()
        let receipt = TrashReceipt(original: fixture.home + "/.tool/failed", trashed: nil)
        let model = fixture.model(ledger: UndoLedger(receipts: [receipt], groupName: "失败工具"), save: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        await model.undoLast()
        #expect(model.undoReceipts == [receipt])
        #expect(model.undoFailures.count == 1)
        #expect(model.banner?.contains("没能保存撤销回执") == true)
        #expect(model.bannerIsError)
    }

    @Test func groupSelectionIncludesDescendantsButGroupActionOnlyTouchesTopLevel() async throws {
        let fixture = try GUIFixture()
        let model = fixture.model()
        let parent = Artifact(path: fixture.home + "/.tool", kind: .program, claim: .ownedByCLI,
                              strength: .certain, isDirectory: true)
        var child = Artifact(path: fixture.home + "/.tool/versions/2", kind: .program,
                             claim: .ownedByCLI, strength: .certain)
        child.parentPath = parent.path
        let credential = Artifact(path: fixture.home + "/.tool/token", kind: .credentials,
                                  claim: .ownedByCLI, strength: .certain, flags: [.credentials])
        let group = ToolGroup(id: "nested", name: "nested", section: .installed,
                              artifacts: [parent, child, credential])
        model.report = ScanReport(scannedAt: Date(), groups: [group])
        model.selectedGroupID = group.id
        model.setSelected(child, in: group, true)
        #expect(model.selection[group.id]?.contains(child.path) == true)
        #expect(model.kindSelection(.program, in: group) == .partial)
        #expect(!model.isEffectivelySelected(parent, in: group))
        let partialPlan = UninstallPlan(groupID: group.id, groupName: group.name, steps: [], skipped: [],
                                        manualCommands: [], warnings: [], reclaimable: nil)
        #expect(model.preservedTopLevelArtifacts(for: partialPlan).map(\.path) == [credential.path])
        model.toggleKind(.program, in: group)
        #expect(model.kindSelection(.program, in: group) == .all)
        #expect(model.isSelected(parent, in: group))
        #expect(model.isSelected(child, in: group))
        model.toggleKind(.program, in: group)
        #expect(model.kindSelection(.program, in: group) == .none)
        #expect(!model.isSelected(parent, in: group))
        #expect(!model.isSelected(child, in: group))
        model.toggleKind(.credentials, in: group)
        #expect(model.kindSelection(.credentials, in: group) == .protected)
        #expect(!model.isSelected(credential, in: group))
    }

    @Test func confirmationBoundaryOnlyListsCompletelyUntouchedTopLevelPaths() async throws {
        let fixture = try GUIFixture()
        let model = fixture.model()
        let untouched = Artifact(path: fixture.home + "/.keep", kind: .config,
                                 claim: .ownedByCLI, strength: .certain)
        let parent = Artifact(path: fixture.home + "/.tool", kind: .data,
                              claim: .ownedByCLI, strength: .certain, isDirectory: true)
        var child = Artifact(path: fixture.home + "/.tool/old-session", kind: .data,
                             claim: .ownedByCLI, strength: .certain)
        child.parentPath = parent.path
        let group = ToolGroup(id: "boundary", name: "boundary", section: .installed,
                              artifacts: [untouched, parent, child])
        model.report = ScanReport(scannedAt: Date(), groups: [group])
        model.selectedGroupID = group.id
        model.setSelected(child, in: group, true)
        let plan = UninstallPlan(groupID: group.id, groupName: group.name, steps: [], skipped: [],
                                 manualCommands: [], warnings: [], reclaimable: nil)
        let preserved = model.preservedTopLevelArtifacts(for: plan)
        #expect(preserved.map(\.path) == [untouched.path])
        model.setSelected(child, in: group, false)
        #expect(model.preservedTopLevelArtifacts(for: plan).count == 2)
    }

    @Test func desktopAppUsesItsOwnBundleIconAndRejectsMissingApp() async throws {
        let fixture = try GUIFixture()
        let missing = AppInfo(name: "Missing", bundleID: "example.missing",
                              path: fixture.home + "/Missing.app")
        #expect(ToolLogo.appIcon(missing) == nil)
        // 本机集成用例：只在明确的 Claude.app 存在时检查系统图标读取；
        // 不存在时仍然验证了无效路径回退，不依赖开发机器必须安装 Claude。
        let claudePath = "/Applications/Claude.app"
        guard FileManager.default.fileExists(atPath: claudePath + "/Contents/Info.plist") else { return }
        let claude = AppInfo(name: "Claude", bundleID: "com.anthropic.claudefordesktop",
                             path: claudePath)
        #expect(ToolLogo.appIcon(claude) != nil)
        #expect(ToolLogo.lookup(catalog: Catalog(products: []), productID: nil,
                                binaries: [], ownerApps: [claude]) != nil)
    }

    @Test func everyFreshPlanGetsANewConfirmationToken() async throws {
        let fixture = try GUIFixture()
        let model = fixture.model()
        let group = ToolGroup(id: "confirm", name: "confirm", section: .installed)
        model.report = ScanReport(scannedAt: Date(), groups: [group])
        model.selectedGroupID = group.id
        model.preparePlan(for: group)
        let first = model.planConfirmationToken
        #expect(first != nil)
        model.preparePlan(for: group)
        #expect(model.planConfirmationToken != nil)
        #expect(model.planConfirmationToken != first)
    }

    @Test func sidebarNavigationSkipsCollapsedGroupsAndIncludesSearchResults() throws {
        let fixture = try GUIFixture()
        let model = fixture.model()
        let installed = ToolGroup(id: "installed", name: "Installed", section: .installed)
        let other = ToolGroup(id: "other", name: "Other", section: .otherCLI)
        let app = ToolGroup(id: "app", name: "App", section: .managedByApp)
        model.report = ScanReport(scannedAt: Date(), groups: [installed, other, app])
        model.selectedGroupID = installed.id
        let collapsed: Set<ACMCore.Section> = [.otherCLI, .managedByApp]
        #expect(SidebarView.adjacentGroupID(in: model, collapsed: collapsed, direction: 1) == installed.id)
        #expect(SidebarView.adjacentGroupID(in: model, collapsed: [], direction: 1) == other.id)
        model.selectedGroupID = app.id
        #expect(SidebarView.adjacentGroupID(in: model, collapsed: collapsed, direction: -1) == installed.id)
        model.search = "Other"
        #expect(SidebarView.adjacentGroupID(in: model, collapsed: collapsed, direction: 1) == other.id)
        model.search = "missing"
        #expect(SidebarView.adjacentGroupID(in: model, collapsed: collapsed, direction: 1) == nil)
    }

    @Test func confirmationSheetTransitionsToResultWithoutDiscardingIt() async throws {
        let fixture = try GUIFixture()
        let model = fixture.model()
        let plan = try fixture.plan(model: model)
        _ = NSApplication.shared
        let view = NSHostingView(rootView: RootView().environment(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        model.planConfirmationToken = plan.token
        model.plan = plan
        try await Task.sleep(for: .milliseconds(400))
        #expect(window.attachedSheet != nil)
        await model.execute(plan)
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.plan == nil)
        #expect(model.result?.receipts.count == 1)
        #expect(model.canUndoResult)
        #expect(window.attachedSheet != nil)
    }

    @Test func searchDoesNotSilentlyChangeSelectionOrPlan() async throws {
        let fixture = try GUIFixture()
        let model = fixture.model()
        let first = ToolGroup(id: "alpha", name: "Alpha", section: .installed, artifacts: [
            Artifact(path: fixture.home + "/.alpha", kind: .program, claim: .ownedByCLI, strength: .certain)
        ])
        let second = ToolGroup(id: "beta", name: "Beta", section: .residue, artifacts: [
            Artifact(path: fixture.home + "/.beta", kind: .cache, claim: .residue, strength: .certain)
        ])
        model.report = ScanReport(scannedAt: Date(), groups: [first, second])
        model.selectedGroupID = first.id
        model.selectAll(first)
        let before = model.selection[first.id]
        model.search = "Beta"
        #expect(model.groups(in: .installed).isEmpty)
        #expect(model.selectedGroupID == first.id)
        #expect(model.selection[first.id] == before)
        #expect(model.selectedGroup?.name == "Alpha")
    }

}

private actor ScanGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func suspend() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters = []
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class FakeRemover: Remover, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private var failing: Set<String> = []
    func fail(_ path: String) { lock.lock(); defer { lock.unlock() }; failing.insert(path) }
    let trash: String
    init(trash: String) { self.trash = trash }
    var restored: [String] { lock.lock(); defer { lock.unlock() }; return calls }
    func trash(_ path: String) throws -> String? {
        // 只在本测试的临时目录内建硬链接，保留 inode 以通过真实执行器的回执校验。
        let destination = trash + "/" + UUID().uuidString
        try FileManager.default.linkItem(atPath: path, toPath: destination)
        return destination
    }
    func restore(from trashed: String, to original: String) throws {
        lock.lock(); defer { lock.unlock() }
        calls.append(original)
        if failing.contains(original) { throw CocoaError(.fileWriteNoPermission) }
    }
}

private final class GUIFixture: @unchecked Sendable {
    let root: URL
    let home: String
    let remover: FakeRemover
    var emptyReport: ScanReport { ScanReport(scannedAt: Date(), groups: []) }
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("acm-gui-tests-" + UUID().uuidString)
        home = root.appendingPathComponent("home").path
        let trash = home + "/.Trash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        remover = FakeRemover(trash: trash)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func receipt(_ name: String) -> TrashReceipt {
        TrashReceipt(original: home + "/.tool/" + name, trashed: home + "/.Trash/" + name)
    }
    @MainActor func model(
        ledger: UndoLedger = UndoLedger(),
        scan: (@Sendable (ScanOptions) async -> ScanReport)? = nil,
        measure: @escaping @Sendable ([String]) -> AsyncStream<(String, SizeResult?)> = { _ in AsyncStream { $0.finish() } },
        save: @escaping (UndoLedger, String) throws -> Void = { _, _ in }
    ) -> AppModel {
        let env = HostEnvironment(home: home, systemBinDirs: [], includeLibrary: false)
        return AppModel(snapshot: nil, dependencies: AppDependencies(
            environment: { env }, catalog: { _ in Catalog(products: []) },
            scan: scan ?? { _ in ScanReport(scannedAt: Date(), groups: []) },
            measure: measure,
            remover: remover, processProbe: { [] },
            loadLedger: { _ in ledger }, saveLedger: save
        ))
    }
    @MainActor func plan(model: AppModel, name: String = "current") throws -> UninstallPlan {
        let directory = home + "/.tool"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/" + name
        try Data("fixture".utf8).write(to: URL(fileURLWithPath: path))
        let group = ToolGroup(id: name, name: name, section: .installed)
        model.report = ScanReport(scannedAt: Date(), groups: [group])
        model.selectedGroupID = group.id
        return UninstallPlan(groupID: group.id, groupName: group.name,
                             steps: [PlanStep(path: path, kind: .program, isDirectory: false)],
                             skipped: [], manualCommands: [], warnings: [], reclaimable: nil)
    }
}
