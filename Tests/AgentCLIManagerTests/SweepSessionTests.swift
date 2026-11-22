import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import ACMCore
@testable import AgentCLIManager

/// 「项目清理」的界面状态。真实的扫描器、执行器和回执，只是家目录和被清理的文件夹都在临时目录里。
@Suite @MainActor struct SweepSessionTests {

    // MARK: - 勾选

    @Test func freshCachesAreNotOfferedUntilIdle() async throws {
        let fixture = try SweepGUIFixture()
        let build = fixture.swiftProject("app")
        let session = fixture.session(idle: nil)
        #expect(session.addFolder(fixture.folder))
        await fixture.settle(session)
        #expect(session.plan?.item(build)?.status != .cleanup, "刚生成的缓存默认不算可清理")
        #expect(session.selectedItems.isEmpty)
        await session.prepare(mode: .trash)
        #expect(session.confirmation == nil)

        session.setIdle(.any)
        await fixture.settle(session)
        #expect(session.plan?.item(build)?.status == .cleanup)
        #expect(session.selectedItems.map(\.path) == [build])
    }

    @Test func oldVersionInstallersAreLeftUnchecked() async throws {
        let fixture = try SweepGUIFixture()
        let build = fixture.swiftProject("app")
        let packages = fixture.installers()
        let session = await fixture.scanned()
        let plan = try #require(session.plan)
        #expect(plan.item(packages.old)?.status == .cleanup)
        #expect(Set(session.selectedItems.map(\.path)) == [build, packages.duplicate],
                "按文件名推测出来的旧版本要用户自己勾")

        session.selectAllCleanup()
        #expect(Set(session.selectedItems.map(\.path)) == [build, packages.duplicate, packages.old])
        session.selectDefaults()
        #expect(Set(session.selectedItems.map(\.path)) == [build, packages.duplicate])
        session.toggleAllCleanup()
        #expect(session.selectedItems.count == 3)
        session.toggleAllCleanup()
        #expect(session.selectedItems.isEmpty)
    }

    @Test func onlyCleanupItemsCanBeChecked() async throws {
        let fixture = try SweepGUIFixture()
        fixture.swiftProject("app")
        let packages = fixture.installers()
        let session = await fixture.scanned()
        let keeper = try #require(session.plan?.item(packages.keeper))
        #expect(keeper.status != .cleanup)
        session.setSelected(keeper, true)
        #expect(!session.isSelected(keeper))
        #expect(!session.selectedItems.contains(keeper))
    }

    @Test func rescanKeepsTheUsersChoices() async throws {
        let fixture = try SweepGUIFixture()
        let first = fixture.swiftProject("one")
        let packages = fixture.installers()
        let session = await fixture.scanned()
        let plan = try #require(session.plan)
        session.setSelected(try #require(plan.item(first)), false)
        session.setSelected(try #require(plan.item(packages.old)), true)

        let second = fixture.swiftProject("two")
        await session.scan(fixture.folder)
        #expect(Set(session.selectedItems.map(\.path)) == [packages.duplicate, packages.old, second],
                "取消的还是取消，勾上的还是勾上，新出现的按默认")
    }

    // MARK: - 确认与执行

    @Test func nothingSelectedNeverReachesTheExecutor() async throws {
        let fixture = try SweepGUIFixture()
        let build = fixture.swiftProject("app")
        let session = await fixture.scanned()
        session.selectNone()
        await session.prepare(mode: .permanent)
        #expect(session.confirmation == nil, "执行器把空清单当成「全部」，界面绝不能把空清单交出去")
        #expect(!session.isPreparing)
        #expect(fixture.exists(build))
    }

    @Test func trashMovesExactlyWhatWasConfirmedAndCanPutItBack() async throws {
        let fixture = try SweepGUIFixture()
        let first = fixture.swiftProject("one")
        let second = fixture.swiftProject("two")
        let session = await fixture.scanned()
        session.setSelected(try #require(session.plan?.item(second)), false)

        await session.prepare(mode: .trash)
        let confirmation = try #require(session.confirmation)
        #expect(confirmation.readyItems.map(\.path) == [first])
        #expect(confirmation.notReady.isEmpty)
        #expect(fixture.exists(first), "打开确认单不动任何文件")

        // 确认单开着的时候勾选变了，也只执行确认单上列出的那些。
        session.selectAllCleanup()
        await session.execute(confirmation)
        #expect(session.confirmation == nil)
        #expect(session.result?.items.map(\.status) == [.trashed])
        #expect(!fixture.exists(first))
        #expect(fixture.exists(second))
        #expect(session.plan?.item(first) == nil, "执行后重新扫描")
        #expect(session.pendingRuns.map { $0.items.map(\.path) } == [[first]])
        let run = try #require(session.resultRun)
        #expect(run.mode == .trash)

        #expect(await session.restore(run))
        #expect(fixture.read(first + "/object.o") == "rebuildable object")
        #expect(session.pendingRuns.isEmpty)
        #expect(session.resultRun == nil)
        #expect(session.plan?.item(first)?.status == .cleanup)
        #expect(fixture.messages.last?.isError == false)
    }

    @Test func permanentDeleteLeavesNothingToPutBack() async throws {
        let fixture = try SweepGUIFixture()
        let build = fixture.swiftProject("app")
        let session = await fixture.scanned()
        await session.prepare(mode: .permanent)
        let confirmation = try #require(session.confirmation)
        #expect(confirmation.mode == .permanent)
        await session.execute(confirmation)
        #expect(session.result?.items.map(\.status) == [.deleted])
        #expect(!fixture.exists(build))
        #expect(fixture.exists("app/Package.swift"))
        #expect(session.pendingRuns.isEmpty)
        #expect(session.resultRun == nil)
        #expect(!fixture.exists(SweepState.stagingName), "暂存目录用完就收掉")
        #expect(!FileManager.default.fileExists(atPath: fixture.home + "/.Trash"))
    }

    @Test func itemChangedAfterConfirmationStaysWhereItIs() async throws {
        let fixture = try SweepGUIFixture()
        let changed = fixture.swiftProject("one")
        let untouched = fixture.swiftProject("two")
        let session = await fixture.scanned()
        await session.prepare(mode: .trash)
        let confirmation = try #require(session.confirmation)
        #expect(confirmation.readyItems.count == 2)

        fixture.file(changed + "/new-output.o", "written after the confirmation was shown")
        await session.execute(confirmation)
        let result = try #require(session.result)
        #expect(result.items.first { $0.path == changed }?.status.isFailure == true)
        #expect(result.items.first { $0.path == untouched }?.status == .trashed)
        #expect(fixture.read(changed + "/new-output.o") != nil)
        #expect(!fixture.exists(untouched))
    }

    @Test func itemInUseIsListedAsNotMoving() async throws {
        let fixture = try SweepGUIFixture()
        let build = fixture.swiftProject("one")
        let other = fixture.swiftProject("two")
        let busy = fixture.path(build + "/object.o")
        let probes = ProbeBox()
        let session = await fixture.scanned(probes: probes.probes)
        #expect(session.selectedItems.count == 2)

        probes.open = [SweepOpenPath(pid: 4242, command: "swift-build", path: busy, isCwd: false)]
        await session.prepare(mode: .trash)
        let confirmation = try #require(session.confirmation)
        #expect(confirmation.readyItems.map(\.path) == [other])
        #expect(confirmation.notReady.map(\.path) == [build])
        await session.execute(confirmation)
        #expect(fixture.exists(build))
        #expect(!fixture.exists(other))
    }

    @Test func expiredPlanIsRescannedInsteadOfConfirmed() async throws {
        let fixture = try SweepGUIFixture()
        let build = fixture.swiftProject("app")
        let session = await fixture.scanned()
        let scannedAt = try #require(session.plan?.createdAt)

        fixture.clock.advance(hours: 25)
        await session.prepare(mode: .trash)
        #expect(session.confirmation == nil)
        #expect(fixture.messages.last?.isError == true)
        #expect(try #require(session.plan?.createdAt) > scannedAt, "过期的结果换成新扫描的")

        await session.prepare(mode: .trash)
        let confirmation = try #require(session.confirmation)
        fixture.clock.advance(hours: 25)
        await session.execute(confirmation)
        #expect(session.confirmationError != nil, "确认单放了一天才点：不执行，留在确认单上说明原因")
        #expect(session.confirmation != nil)
        #expect(session.result == nil)
        #expect(fixture.exists(build))
        session.cancelConfirmation()
        #expect(session.confirmation == nil)
        #expect(session.confirmationError == nil)
    }

    // MARK: - 放回

    @Test func restoreNeverOverwritesWhatIsThereNow() async throws {
        let fixture = try SweepGUIFixture()
        let build = fixture.swiftProject("app")
        let session = await fixture.scanned()
        await session.prepare(mode: .trash)
        await session.execute(try #require(session.confirmation))
        let run = try #require(session.resultRun)

        fixture.file(build + "/object.o", "rebuilt in the meantime")
        #expect(!(await session.restore(run)))
        #expect(fixture.read(build + "/object.o") == "rebuilt in the meantime")
        #expect(fixture.messages.last?.isError == true)
        #expect(session.restoreFailures.map(\.path) == [build])
        #expect(session.restoreRunID == run.runID)
        #expect(session.pendingRuns.count == 1, "没放回的还留在可放回清单里")
    }

    @Test func receiptFailureKeepsTheReasonInTheSheetState() async throws {
        let fixture = try SweepGUIFixture()
        let build = fixture.swiftProject("app")
        let session = await fixture.scanned()
        await session.prepare(mode: .trash)
        await session.execute(try #require(session.confirmation))
        let run = try #require(session.resultRun)

        // 回执被删掉：逐项结果都出不来，但弹窗仍要能说明原因。
        try FileManager.default.removeItem(atPath: run.receipt)
        #expect(!(await session.restore(run)))
        #expect(session.restoreError != nil)
        #expect(session.restoreRunID == run.runID)
        #expect(!session.isRestoring)
        #expect(!fixture.exists(build), "回执读不了时不能猜着搬回去")
    }

    @Test func stagingResidueIsListedWithoutAReceipt() async throws {
        let fixture = try SweepGUIFixture()
        fixture.swiftProject("app")
        fixture.file(".acm-sweep-staging/ACM-Sweep-left/leftover/a.o", "left")
        let session = await fixture.scanned()
        await session.refreshPending()
        let residue = session.residue(in: fixture.folder)
        #expect(residue.count == 1)
        #expect(residue.first?.path.hasSuffix("/.acm-sweep-staging/ACM-Sweep-left") == true)
        #expect(residue.first?.run == nil)
        #expect(session.plan?.warnings.contains { $0.code == "staging_residue" } == true)
    }

    @Test func excludingAnUnreadableDirectoryLetsTheScanFinish() async throws {
        let fixture = try SweepGUIFixture()
        let build = fixture.swiftProject("app")
        let secret = fixture.path("secret")
        try FileManager.default.createDirectory(atPath: secret, withIntermediateDirectories: true)
        chmod(secret, 0)
        defer { chmod(secret, 0o755) }
        let session = fixture.session()
        #expect(session.addFolder(fixture.folder))
        await fixture.settle(session)
        let blocked = try #require(session.error?.details["path"])
        #expect(session.error?.code == "discovery_permission")
        session.exclude(blocked)
        await fixture.waitUntil { session.plan != nil }
        #expect(session.error == nil)
        #expect(session.plan?.items.contains { $0.path == build } == true)
        #expect(fixture.savedExcludes.last?.0[fixture.folder]?.contains(blocked) == true)

        session.exclude(fixture.path(build + "/object.o"))
        await fixture.waitUntil { session.plan?.items.first { $0.path == build }?.status == .blocked }
        #expect(session.plan?.items.first { $0.path == build }?.status == .blocked)
    }

    @Test func changedScanDropsTheConfirmationWithAMessage() async throws {
        let fixture = try SweepGUIFixture()
        fixture.swiftProject("app")
        let gate = Gate()
        gate.open()
        let probes = SweepProbes(
            openPaths: { gate.wait(); return [] },
            gitTracked: { _, _ in .untracked }
        )
        let session = await fixture.scanned(probes: probes)
        gate.close()
        let preparing = Task { await session.prepare(mode: .trash) }
        await fixture.waitUntil { session.isPreparing }
        session.rescan()
        session.selectedFolder = fixture.root
        gate.open()
        await preparing.value
        #expect(session.confirmation == nil)
        #expect(fixture.messages.contains { $0.text.contains("扫描结果已更新") })
    }

    @Test func earlierRunsAreFoundOnNextLaunch() async throws {
        let fixture = try SweepGUIFixture()
        let build = fixture.swiftProject("app")
        let first = await fixture.scanned()
        await first.prepare(mode: .trash)
        await first.execute(try #require(first.confirmation))
        #expect(!fixture.exists(build))

        let relaunched = fixture.session(saved: [fixture.folder])
        #expect(relaunched.folders == [fixture.folder])
        #expect(relaunched.selectedFolder == fixture.folder)
        await relaunched.refreshPending()
        let run = try #require(relaunched.pendingRuns.first)
        #expect(run.root == fixture.folder)
        #expect(run.items.map(\.path) == [build])
        #expect(await relaunched.restore(run))
        #expect(fixture.exists(build))
    }

    // MARK: - 文件夹

    @Test func unsuitableFoldersAreRefusedWithAReason() async throws {
        let fixture = try SweepGUIFixture()
        try FileManager.default.createDirectory(atPath: fixture.home + "/.config/tool", withIntermediateDirectories: true)
        let session = fixture.session()
        for path in [fixture.home, fixture.home + "/.config/tool", fixture.folder + "/missing", "/System/Library"] {
            let before = fixture.messages.count
            #expect(!session.addFolder(path), "\(path)")
            #expect(fixture.messages.count == before + 1)
            #expect(fixture.messages.last?.isError == true)
        }
        #expect(session.folders.isEmpty)
        #expect(fixture.saved.isEmpty)
    }

    @Test func folderListIsRememberedAndRemovingKeepsTheFolder() async throws {
        let fixture = try SweepGUIFixture()
        let build = fixture.swiftProject("app")
        let session = fixture.session()
        #expect(session.addFolder(fixture.folder))
        #expect(session.addFolder(fixture.folder), "重复添加只是选中它")
        #expect(session.folders == [fixture.folder])
        #expect(fixture.saved.last?.folders == [fixture.folder])
        #expect(fixture.saved.last?.path == fixture.env.ownSupportDir + "/sweep-folders.json")
        await fixture.settle(session)

        session.removeFolder(fixture.folder)
        #expect(session.folders.isEmpty)
        #expect(session.selectedFolder == nil)
        #expect(session.plan == nil)
        #expect(fixture.saved.last?.folders == [])
        #expect(fixture.exists(build), "从清单里拿掉不动文件夹本身")
    }

    @Test func liveFolderListRoundTripsThroughTheSupportDirectory() async throws {
        let fixture = try SweepGUIFixture()
        let path = fixture.env.ownSupportDir + "/sweep-folders.json"
        let live = SweepDependencies.live
        #expect(live.loadFolders(path).isEmpty)
        try live.saveFolders([fixture.folder], path)
        #expect(live.loadFolders(path) == [fixture.folder])
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        #expect(live.loadFolders(path).isEmpty)
    }

    @Test func vanishedFolderShowsAnErrorInsteadOfAStaleResult() async throws {
        let fixture = try SweepGUIFixture()
        fixture.swiftProject("app")
        let session = await fixture.scanned()
        #expect(session.plan != nil)
        try FileManager.default.removeItem(atPath: fixture.folder)
        await session.scan(fixture.folder)
        #expect(session.plan == nil)
        #expect(session.error?.code == "invalid_root")
        #expect(session.selectedItems.isEmpty)
        await session.prepare(mode: .trash)
        #expect(session.confirmation == nil)
    }

    // MARK: - 只读截图模式

    @Test func readOnlySessionNeverChangesAnything() async throws {
        let fixture = try SweepGUIFixture()
        let build = fixture.swiftProject("app")

        // 先用正常会话留下一份可放回的回执。
        let other = fixture.swiftProject("other")
        let normal = await fixture.scanned()
        normal.setSelected(try #require(normal.plan?.item(build)), false)
        await normal.prepare(mode: .trash)
        await normal.execute(try #require(normal.confirmation))
        let run = try #require(normal.pendingRuns.first)
        #expect(!fixture.exists(other))
        let savesBefore = fixture.saved.count

        let session = fixture.session(saved: [fixture.folder], idle: .any, readOnly: true)
        #expect(session.folders.isEmpty, "截图模式不读文件夹清单")
        #expect(session.pendingRuns.isEmpty)
        #expect(!session.addFolder(fixture.home))
        #expect(session.addFolder(fixture.folder))
        #expect(session.folders == [fixture.folder])
        #expect(fixture.saved.count == savesBefore, "截图模式不写文件夹清单")
        await session.showDemoFolder(fixture.folder)
        await fixture.settle(session)
        #expect(session.selectedItems.map(\.path) == [build])

        await session.prepare(mode: .permanent)
        let confirmation = try #require(session.confirmation)
        await session.execute(confirmation)
        #expect(session.result == nil)
        #expect(fixture.exists(build))
        #expect(!(await session.restore(run)))
        #expect(!fixture.exists(other), "截图模式也不放回")

        session.cancelConfirmation()
        session.showDemoResult(mode: .trash)
        #expect(session.result?.items.contains { $0.status == .trashed } == true)
        session.showDemoPending()
        #expect(session.pendingRuns.first?.runID == "demo")
        session.showDemoResidue()
        #expect(session.residue(in: fixture.folder).isEmpty)
        session.showDemoRestoreFailure()
        #expect(session.restoreFailures.count == 1)
        #expect(fixture.exists(build))
    }

    @Test func demoHelpersDoNothingOutsideSnapshotMode() async throws {
        let fixture = try SweepGUIFixture()
        fixture.swiftProject("app")
        let session = await fixture.scanned()
        session.showDemoResult(mode: .permanent)
        session.showDemoPending()
        session.showDemoResidue()
        session.showDemoRestoreFailure()
        #expect(session.result == nil)
        #expect(session.pendingRuns.isEmpty)
        #expect(session.stagingResidue.isEmpty)
        #expect(session.restoreFailures.isEmpty)
    }

    // MARK: - 和 AppModel、窗口的衔接

    @Test func switchingWorkspaceScansTheRememberedFolder() async throws {
        let fixture = try SweepGUIFixture()
        let build = fixture.swiftProject("app")
        let scans = Counter()
        let model = fixture.model(saved: [fixture.folder], scans: scans)
        #expect(model.workspace == .tools)
        #expect(model.sweep.plan == nil, "没切过去就不扫描")

        model.workspace = .sweep
        await fixture.settle(model.sweep)
        #expect(model.sweep.plan?.item(build) != nil)

        let toolScans = scans.value
        let scannedAt = try #require(model.sweep.plan?.createdAt)
        fixture.clock.advance(hours: 1)
        model.rescanCurrent()
        await fixture.waitUntil { (model.sweep.plan?.createdAt ?? 0) > scannedAt }
        #expect(scans.value == toolScans, "在「项目清理」里按 ⌘R 只重扫这个文件夹")
    }

    @Test func sweepMessagesAppearInTheBanner() async throws {
        let fixture = try SweepGUIFixture()
        let model = fixture.model()
        #expect(!model.sweep.addFolder(fixture.home))
        #expect(model.bannerIsError)
        #expect(model.banner?.contains("不能清理这个文件夹") == true)
    }

    @Test func confirmationSheetGivesWayToTheResultSheet() async throws {
        let fixture = try SweepGUIFixture()
        let build = fixture.swiftProject("app")
        let model = fixture.model(saved: [fixture.folder])
        model.sweep.setIdle(.any)
        model.workspace = .sweep
        await fixture.settle(model.sweep)

        _ = NSApplication.shared
        let view = NSHostingView(rootView: RootView().environment(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        #expect(window.attachedSheet == nil)

        await model.sweep.prepare(mode: .trash)
        try await Task.sleep(for: .milliseconds(400))
        #expect(window.attachedSheet != nil)
        await model.sweep.execute(try #require(model.sweep.confirmation))
        try await Task.sleep(for: .milliseconds(600))
        #expect(model.sweep.confirmation == nil)
        #expect(model.sweep.result?.items.map(\.status) == [.trashed])
        #expect(window.attachedSheet != nil, "确认单关掉后要接着出结果")
        #expect(!fixture.exists(build))

        model.sweep.result = nil
        try await Task.sleep(for: .milliseconds(600))
        #expect(window.attachedSheet == nil)
    }
}

// MARK: - 夹具

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}

/// 测试自己拨的钟。起点比真实时间晚一小时：夹具里的文件都是「一小时前」写的，
/// 不会因为修改时间比钟还新而被当成仍在写入。
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date().addingTimeInterval(3600)
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(hours: Double) { lock.lock(); defer { lock.unlock() }; date += hours * 3600 }
}

/// 测试自己打开的门。探针堵在这里，界面状态可以趁这段时间变化。
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    func open() { lock.lock(); opened = true; lock.unlock() }
    func close() { lock.lock(); opened = false; lock.unlock() }
    func wait() {
        while true {
            lock.lock()
            let ready = opened
            lock.unlock()
            if ready { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

/// 可以中途改口的进程探针。
private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [SweepOpenPath] = []
    var open: [SweepOpenPath] {
        get { lock.lock(); defer { lock.unlock() }; return paths }
        set { lock.lock(); defer { lock.unlock() }; paths = newValue }
    }
    var probes: SweepProbes {
        SweepProbes(openPaths: { [self] in open }, gitTracked: { _, _ in .untracked })
    }
}

private struct NoRemover: Remover {
    func trash(_ path: String) throws -> String? { throw CocoaError(.featureUnsupported) }
    func restore(from trashed: String, to original: String) throws { throw CocoaError(.featureUnsupported) }
}

/// 临时目录里的假家目录，加上旁边一个要清理的文件夹。
@MainActor
private final class SweepGUIFixture {
    let root: String
    let home: String
    let folder: String
    let env: HostEnvironment
    let clock = Clock()
    private(set) var messages: [(text: String, isError: Bool)] = []
    private(set) var saved: [(folders: [String], path: String)] = []
    private(set) var savedExcludes: [([String: [String]], String)] = []
    var loadedExcludes: [String: [String]] = [:]

    init() throws {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent("acm-sweep-gui-tests-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: unresolved, withIntermediateDirectories: true)
        // 解析过软链的写法，和扫描结果、回执里的路径一致（/private/var/…）。
        root = SweepPath.realpath(unresolved) ?? unresolved
        home = root + "/home"
        folder = root + "/Projects"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        env = HostEnvironment(home: home, systemBinDirs: [], includeLibrary: false)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func path(_ relative: String) -> String { folder + "/" + relative }
    func exists(_ relative: String) -> Bool { SweepFS.lstat(path(relative)) != nil }
    func read(_ relative: String) -> String? {
        FileManager.default.contents(atPath: path(relative)).map { String(decoding: $0, as: UTF8.self) }
    }

    @discardableResult
    func file(_ relative: String, _ content: String = "data") -> String {
        let target = path(relative)
        try! FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: target, contents: Data(content.utf8))
        return relative
    }

    /// 一个带 SwiftPM 构建缓存的项目。返回缓存目录的相对路径。
    @discardableResult
    func swiftProject(_ project: String) -> String {
        file(project + "/Package.swift", "// swift-tools-version: 6.0\n")
        file(project + "/.build/artifacts/.keep", "")
        file(project + "/.build/workspace-state.json", "{}")
        file(project + "/.build/object.o", "rebuildable object")
        return project + "/.build"
    }

    /// 同一个项目里的一个旧版本、一个当前版本、一个和当前版本内容相同的重复下载。
    /// 安装包只在同一个项目里互相比较，所以要有项目标记。
    func installers() -> (old: String, keeper: String, duplicate: String) {
        file("product/Package.swift", "// swift-tools-version: 6.0\n")
        return (file("product/release/Product-0.9.0-arm64.dmg", "old"),
                file("product/release/Product-1.0.0-arm64.dmg", "same"),
                file("product/downloaded/Product-1.0.0-arm64.dmg", "same"))
    }

    func dependencies(saved: [String] = [], probes: SweepProbes? = nil) -> SweepDependencies {
        let clock = self.clock
        return SweepDependencies(
            probes: probes ?? SweepProbes(openPaths: { [] }, gitTracked: { _, _ in .untracked }),
            loadFolders: { _ in saved },
            saveFolders: { [weak self] folders, path in self?.saved.append((folders, path)) },
            loadExcludes: { [weak self] _ in self?.loadedExcludes ?? [:] },
            saveExcludes: { [weak self] excludes, path in self?.savedExcludes.append((excludes, path)) },
            now: { clock.now }
        )
    }

    /// - Parameter idle: nil 就用默认的「闲置 1 天以上」。
    func session(
        saved: [String] = [], idle: SweepIdle? = .any, probes: SweepProbes? = nil, readOnly: Bool = false
    ) -> SweepSession {
        let session = SweepSession(
            env: env, dependencies: dependencies(saved: saved, probes: probes), readOnly: readOnly
        )
        session.onMessage = { [weak self] text, isError in self?.messages.append((text, isError)) }
        if let idle { session.setIdle(idle) }
        return session
    }

    /// 已经加好文件夹、扫描完、不看闲置时间的会话。
    func scanned(probes: SweepProbes? = nil) async -> SweepSession {
        let session = session(probes: probes)
        session.addFolder(folder)
        await settle(session)
        return session
    }

    func model(saved: [String] = [], scans: Counter? = nil) -> AppModel {
        let env = self.env
        return AppModel(snapshot: nil, dependencies: AppDependencies(
            environment: { env }, catalog: { _ in LoadedCatalog(Catalog(products: [])) },
            scan: { _ in
                scans?.increment()
                return ScanReport(scannedAt: Date(), groups: [])
            },
            measure: { _ in AsyncStream { $0.finish() } },
            remover: NoRemover(), processProbe: { [] },
            loadLedger: { _ in UndoLedger() }, saveLedger: { _, _ in },
            sweep: dependencies(saved: saved)
        ))
    }

    /// 等选中的文件夹扫描出结果（或出错）。
    func settle(_ session: SweepSession) async {
        await waitUntil { !session.isScanningAny && (session.plan != nil || session.error != nil) }
    }

    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "等了 10 秒还没等到")
    }
}

private extension SweepPlan {
    func item(_ path: String) -> SweepItem? { items.first { $0.path == path } }
}
