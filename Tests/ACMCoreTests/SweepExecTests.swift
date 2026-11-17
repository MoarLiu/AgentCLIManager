import Darwin
import Foundation
import Testing
@testable import ACMCore

/// 一次测试里的执行环境：同一个假家目录、同一个「现在」。
private struct Run {
    let ws: SweepWorkspace
    let env: HostEnvironment

    init(_ ws: SweepWorkspace) {
        self.ws = ws
        env = ws.env()
    }

    func scan(policy: SweepPolicy = SweepPolicy(), probes: SweepProbes = SweepWorkspace.quiet) throws -> SweepPlan {
        try SweepScanner.scan(root: ws.root, policy: policy, env: env, probes: probes)
    }

    /// 默认真的执行、用永久模式：大多数用例关心的是「该不该动」。
    func apply(
        _ plan: SweepPlan,
        execute: Bool = true,
        mode: SweepMode = .permanent,
        ids: [String] = [],
        includeOldVersions: Bool = false,
        probes: SweepProbes = SweepWorkspace.quiet,
        now: Date? = nil,
        fault: SweepJournal.Fault? = nil
    ) throws -> SweepApplyResult {
        try SweepExecutor.apply(
            plan, execute: execute, mode: mode, identifiers: ids, includeOldVersions: includeOldVersions,
            env: env, probes: probes, now: now, journalFault: fault
        )
    }

    func restore(_ receipt: String?, execute: Bool = true, confinedTo: String? = nil) throws -> SweepRestoreResult {
        try SweepRestorer.restore(receipt: receipt ?? "", execute: execute, env: env, confinedTo: confinedTo)
    }

    func exists(_ relative: String) -> Bool { SweepFS.lstat(ws.path(relative)) != nil }

    func read(_ relative: String) -> String? {
        FileManager.default.contents(atPath: ws.path(relative)).map { String(decoding: $0, as: UTF8.self) }
    }

    var trash: String { ws.fx.home + "/.Trash" }
    var stateDirectory: String { SweepState.directory(env) }
}

private struct Boom: Error {}

private func failing(at event: String, partial: String? = nil) -> SweepJournal.Fault {
    { current, fd in
        guard current == event else { return }
        if let partial {
            _ = partial.withCString { write(fd, $0, strlen($0)) }
            fsync(fd)
        }
        throw Boom()
    }
}

private func exists(_ path: String) -> Bool { SweepFS.lstat(path) != nil }

private func lines(_ path: String) -> [String] {
    String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
}

/// 执行清理：预演、两种方式、执行前后的各道核对。
@Suite struct SweepApplyTests {

    @Test func dryRunTouchesNothing() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        ws.file("main.swift", "source")
        let run = Run(ws)
        let plan = try run.scan()
        for mode in [SweepMode.trash, .permanent] {
            let result = try run.apply(plan, execute: false, mode: mode)
            #expect(!result.executed)
            #expect(result.mode == mode)
            #expect(result.receipt == nil)
            #expect(result.items.map(\.status) == [.ready])
            #expect(!result.incomplete)
        }
        #expect(run.exists(cache + "/object.o"))
        // 预演连状态目录、暂存目录都不建。
        #expect(!exists(run.stateDirectory))
        #expect(!exists(run.trash))
        #expect(!run.exists(SweepState.stagingName))
    }

    @Test func permanentCleanupPreservesLinkTargetsAndSources() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        ws.file("main.swift", "source")
        let outside = ws.fx.root + "/outside.txt"
        FileManager.default.createFile(atPath: outside, contents: Data("outside".utf8))
        let outsideDir = ws.fx.root + "/outside-dir"
        try FileManager.default.createDirectory(atPath: outsideDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outsideDir + "/kept.txt", contents: Data("kept".utf8))
        ws.link(cache + "/external-link", to: outside)
        ws.link(cache + "/artifacts/external-dir", to: outsideDir)
        let run = Run(ws)
        let plan = try run.scan()

        let result = try run.apply(plan)
        #expect(result.executed)
        #expect(result.items.map(\.status) == [.deleted])
        #expect(result.items[0].recoveryPath == nil)
        #expect(result.requiresEmptyingTrash == false)
        #expect(!run.exists(cache))
        #expect(run.read("main.swift") == "source")
        // 缓存里的软链只删链接本身，链接指向的东西原样留着。
        #expect(FileManager.default.contents(atPath: outside) == Data("outside".utf8))
        #expect(exists(outsideDir + "/kept.txt"))
        #expect(!run.exists(SweepState.stagingName))

        let receipt = try #require(result.receipt)
        let events = lines(receipt).map { $0.contains("\"event\":\"run\"") ? "run" : $0 }
        #expect(events.count == 4)
        #expect(lines(receipt).last?.contains("\"event\":\"deleted\"") == true)
        // 删掉的东西放不回来：回执里没有可恢复的项。
        #expect(try run.restore(receipt).items.isEmpty)

        let again = try run.apply(plan)
        #expect(!again.executed)
        #expect(again.items.map(\.status) == [.alreadyAbsent])
        #expect(!again.incomplete)
    }

    @Test func trashModeAndRestore() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let run = Run(ws)
        let plan = try run.scan()

        let result = try run.apply(plan, mode: .trash)
        #expect(result.executed)
        #expect(result.requiresEmptyingTrash == true)
        #expect(result.items.map(\.status) == [.trashed])
        #expect(!run.exists(cache))
        let staged = try #require(result.items[0].recoveryPath)
        #expect(staged.hasPrefix((SweepPath.realpath(run.trash) ?? run.trash) + "/" + SweepState.stagePrefix))
        #expect(FileManager.default.contents(atPath: staged + "/object.o") == Data("rebuildable object".utf8))

        let preview = try run.restore(result.receipt, execute: false)
        #expect(!preview.executed)
        #expect(preview.items.map(\.status) == [.ready])
        #expect(!run.exists(cache))

        let restored = try run.restore(result.receipt)
        #expect(restored.executed)
        #expect(restored.items.map(\.status) == [.restored])
        #expect(run.read(cache + "/object.o") == "rebuildable object")
        // 暂存目录空了就收掉，废纸篓本身留着。
        #expect(!exists(SweepPath.parent(staged)))
        #expect(exists(run.trash))
        #expect(try run.restore(result.receipt).items.isEmpty)

        // 放回之后东西和原来一模一样，同一份计划可以再执行一次。
        #expect(try run.apply(plan, mode: .trash).items.map(\.status) == [.trashed])
    }

    @Test func newProcessAfterPlanningBlocksExecution() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let run = Run(ws)
        let plan = try run.scan()
        let busy = SweepWorkspace.probes(open: [
            SweepOpenPath(pid: 12345, command: "swift-build", path: ws.root, isCwd: true),
        ])
        let result = try run.apply(plan, probes: busy)
        #expect(!result.executed)
        #expect(result.items.map(\.status) == [.blocked])
        #expect(result.incomplete)
        #expect(run.exists(cache + "/object.o"))
    }

    @Test func processStartingBetweenRescanAndMoveBlocksThatItem() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let run = Run(ws)
        let plan = try run.scan()
        // 前两次询问（两轮重新扫描）都安静，第三次（移动前）才出现进程。
        let calls = Recorder()
        let root = ws.root
        let late = SweepProbes(openPaths: {
            calls.add("open")
            return calls.values.count < 3
                ? [] : [SweepOpenPath(pid: 4242, command: "swift-build", path: root, isCwd: true)]
        }, gitTracked: { _, _ in .untracked })
        let result = try run.apply(plan, probes: late)
        #expect(result.executed)
        #expect(result.items.map(\.status) == [.blocked])
        #expect(result.items[0].reason?.contains("进程") == true)
        #expect(run.exists(cache + "/object.o"))
        // 没有动过任何东西：回执里只有抬头，暂存目录也收掉了。
        #expect(lines(try #require(result.receipt)).count == 1)
        #expect(!run.exists(SweepState.stagingName))
    }

    @Test func changedTreeIsNotDeleted() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let run = Run(ws)
        let plan = try run.scan()
        ws.file(cache + "/object.o", "new data")
        let result = try run.apply(plan)
        #expect(!result.executed)
        #expect(result.items.map(\.status) == [.blocked])
        #expect(run.read(cache + "/object.o") == "new data")
    }

    @Test func unchangedItemsStillRunWhenAnotherIsBlocked() throws {
        let ws = try SweepWorkspace()
        let first = ws.swiftProject("A")
        let second = ws.swiftProject("B")
        let run = Run(ws)
        let plan = try run.scan()
        ws.file(first + "/extra.o", "appeared later")
        let result = try run.apply(plan)
        #expect(result.executed)
        #expect(result.incomplete)
        let status = Dictionary(uniqueKeysWithValues: result.items.map { ($0.path, $0.status) })
        #expect(status == [first: .blocked, second: .deleted])
        #expect(run.exists(first + "/extra.o"))
        #expect(!run.exists(second))
        #expect(run.exists("B/Package.swift"))
    }

    @Test func parentReplacedBySymlinkIsNotFollowed() throws {
        let ws = try SweepWorkspace()
        ws.swiftProject("Project")
        let run = Run(ws)
        let plan = try run.scan()
        try FileManager.default.moveItem(atPath: ws.path("Project"), toPath: ws.path("renamed"))
        let outside = ws.fx.root + "/outside"
        try FileManager.default.createDirectory(atPath: outside + "/.build/artifacts", withIntermediateDirectories: true)
        for (name, content) in [("Package.swift", ""), (".build/workspace-state.json", "{}"), (".build/object.o", "outside object")] {
            FileManager.default.createFile(atPath: outside + "/" + name, contents: Data(content.utf8))
        }
        ws.link("Project", to: outside)

        let result = try run.apply(plan)
        #expect(result.items.map(\.status) == [.blocked])
        #expect(exists(outside + "/.build/object.o"))
        #expect(run.exists("renamed/.build/object.o"))
    }

    @Test func deletingKeeperInvalidatesPlan() throws {
        let ws = try SweepWorkspace()
        let old = ws.package("Product-1.0.0-arm64.dmg")
        let keeper = ws.package("Product-2.0.0-arm64.dmg")
        let run = Run(ws)
        let plan = try run.scan()
        try FileManager.default.removeItem(atPath: ws.path(keeper))
        let result = try run.apply(plan, includeOldVersions: true)
        #expect(result.items.map(\.status) == [.blocked])
        #expect(run.exists(old))
    }

    @Test func replacedKeeperInvalidatesPlan() throws {
        let ws = try SweepWorkspace()
        let old = ws.package("Product-1.0.0-arm64.dmg")
        let keeper = ws.package("Product-2.0.0-arm64.dmg", "installer two")
        let run = Run(ws)
        let plan = try run.scan()
        // 新版本那份被换成了别的内容：旧版本不能再凭它清掉。
        ws.file(keeper, "something else")
        let result = try run.apply(plan, ids: [try #require(plan.item(old)).id])
        #expect(result.items.map(\.status) == [.blocked])
        #expect(result.items[0].reason?.contains("保留") == true)
        // 重新扫描那一步就拦下了：没有建回执，没有进入执行。
        #expect(!result.executed)
        #expect(result.receipt == nil)
        #expect(run.exists(old))
    }

    @Test func keeperReplacedDuringExecutionBlocksTheMove() throws {
        let ws = try SweepWorkspace()
        let old = ws.package("Product-1.0.0-arm64.dmg")
        let keeper = ws.package("Product-2.0.0-arm64.dmg", "installer two")
        let run = Run(ws)
        let plan = try run.scan()
        // 重新扫描通过之后、移动之前，保留的那份才被换掉（写抬头的那一刻）。
        let result = try run.apply(plan, includeOldVersions: true, fault: { event, _ in
            if event == "run" { ws.file(keeper, "something else") }
        })
        #expect(result.executed)
        #expect(result.items.map(\.status) == [.blocked])
        #expect(result.items[0].reason?.contains("保留") == true)
        #expect(run.exists(old))
    }

    @Test func contentAppearingJustBeforeTheMoveIsKeptInStaging() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let run = Run(ws)
        let plan = try run.scan()
        // 最后一轮核对之后、移动之前，又有东西写进了缓存（写 intent 的那一刻）。
        let result = try run.apply(plan, fault: { event, _ in
            if event == "intent" { ws.file(cache + "/late.o", "written at the last moment") }
        })
        // 移动后的复核发现和计划里不一样：不删，原样留在暂存目录里。
        #expect(result.items.map(\.status) == [.recoveryRequired])
        #expect(result.items[0].reason?.contains("复核") == true)
        let staged = try #require(result.items[0].recoveryPath)
        #expect(FileManager.default.contents(atPath: staged + "/late.o") == Data("written at the last moment".utf8))
        #expect(FileManager.default.contents(atPath: staged + "/object.o") == Data("rebuildable object".utf8))
        #expect(!run.exists(cache))
        // 回执里记的是计划里的样子，和暂存内容对不上，所以不会自动放回；路径已经告诉用户了。
        #expect(lines(try #require(result.receipt)).last?.contains("intent") == true)
        #expect(try run.restore(result.receipt).items.map(\.status) == [.blocked])
        #expect(exists(staged + "/late.o"))
    }

    @Test func oldVersionsNeedToBeNamed() throws {
        let ws = try SweepWorkspace()
        ws.file("Package.swift", "package")
        let old = ws.package("Product-0.9.0-arm64.dmg", "old")
        let keeper = ws.package("Product-1.0.0-arm64.dmg", "same")
        let duplicate = ws.package("Product-1.0.0-arm64.dmg", "same", folder: "downloaded")
        let run = Run(ws)
        let plan = try run.scan()
        let oldID = try #require(plan.item(old)).id
        let duplicateID = try #require(plan.item(duplicate)).id
        #expect(plan.isSupersededVersion(try #require(plan.item(old))))
        #expect(!plan.isSupersededVersion(try #require(plan.item(duplicate))))
        #expect(!plan.isSupersededVersion(try #require(plan.item(keeper))))

        // 不点名：只清内容完全相同的重复件；「有更新版本」的那份留着并报出来。
        let preview = try run.apply(plan, execute: false)
        #expect(preview.items.map(\.id) == [duplicateID])
        #expect(preview.unselectedIDs == [oldID])
        let everything = try run.apply(plan, execute: false, includeOldVersions: true)
        #expect(Set(everything.items.map(\.id)) == [oldID, duplicateID])
        #expect(everything.unselectedIDs.isEmpty)

        let result = try run.apply(plan, mode: .trash)
        #expect(result.items.map(\.status) == [.trashed])
        #expect(run.exists(old))
        #expect(!run.exists(duplicate))
        #expect(run.exists(keeper))

        // 点了名就照办。
        let named = try run.apply(plan, mode: .trash, ids: [oldID, oldID])
        #expect(named.items.map(\.id) == [oldID])
        #expect(named.items.map(\.status) == [.trashed])
        #expect(!run.exists(old))
        #expect(run.exists(keeper))
    }

    @Test func onlyCleanupItemsFromThePlanCanBeNamed() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        ws.package("Product-1.0.0-arm64.dmg")
        let keeper = ws.package("Product-2.0.0-arm64.dmg")
        let run = Run(ws)
        let plan = try run.scan()
        let keeperID = try #require(plan.item(keeper)).id
        #expect(sweepErrorCode { _ = try run.apply(plan, ids: ["0000000000000000"]) } == "unknown_item")
        #expect(sweepErrorCode { _ = try run.apply(plan, ids: [keeperID]) } == "protected_item")
        // 有一个不行就整个不做，不会只执行其中合格的。
        let cacheID = try #require(plan.item(cache)).id
        #expect(sweepErrorCode { _ = try run.apply(plan, ids: [cacheID, keeperID]) } == "protected_item")
        #expect(run.exists(cache))
    }

    @Test func exclusionInsideCandidateBlocksWholeDirectory() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        ws.file(cache + "/preserved.txt", "keep this")
        let run = Run(ws)
        let plan = try run.scan(policy: SweepPolicy(excludes: [ws.path(cache + "/preserved.txt")]))
        #expect(plan.item(cache)?.status == .blocked)
        let result = try run.apply(plan)
        #expect(!result.executed)
        #expect(result.items.isEmpty)
        #expect(run.read(cache + "/preserved.txt") == "keep this")
    }

    @Test func planMustBeFreshAndForTheSameDirectory() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let run = Run(ws)
        let plan = try run.scan()
        let created = Date(timeIntervalSince1970: plan.createdAt)
        #expect(sweepErrorCode { _ = try run.apply(plan, now: created.addingTimeInterval(25 * 3600)) } == "expired_plan")
        #expect(sweepErrorCode { _ = try run.apply(plan, now: created.addingTimeInterval(-60)) } == "expired_plan")
        #expect(try run.apply(plan, execute: false, now: created.addingTimeInterval(23 * 3600)).items.map(\.status) == [.ready])

        // 目录被整个换掉（哪怕内容看起来一样）：计划作废。
        try FileManager.default.moveItem(atPath: ws.root, toPath: ws.fx.root + "/moved-away")
        try FileManager.default.createDirectory(atPath: ws.root, withIntermediateDirectories: true)
        ws.swiftProject()
        #expect(sweepErrorCode { _ = try run.apply(plan) } == "root_changed")
        #expect(run.exists(cache + "/object.o"))
        #expect(exists(ws.fx.root + "/moved-away/.build/object.o"))
    }

    @Test func onlyOneRunPerDirectoryAtATime() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let run = Run(ws)
        let plan = try run.scan()
        try SweepState.withRootLock(ws.root, env: run.env) {
            #expect(sweepErrorCode { _ = try run.apply(plan) } == "already_running")
            // 预演不拿锁。
            let rehearsal = try run.apply(plan, execute: false)
            #expect(rehearsal.items.map(\.status) == [.ready])
        }
        #expect(run.exists(cache))
        // 另一个目录不受影响；锁放开之后可以执行。
        #expect(try run.apply(plan).items.map(\.status) == [.deleted])
    }

    @Test func trashMustBeARealPrivateDirectory() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let run = Run(ws)
        let plan = try run.scan()
        let elsewhere = ws.fx.root + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: run.trash, withDestinationPath: elsewhere)
        #expect(sweepErrorCode { _ = try run.apply(plan, mode: .trash) } == "unsafe_state")
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere).isEmpty)

        try FileManager.default.removeItem(atPath: run.trash)
        try FileManager.default.createDirectory(atPath: run.trash, withIntermediateDirectories: true)
        chmod(run.trash, 0o755)
        #expect(sweepErrorCode { _ = try run.apply(plan, mode: .trash) } == "unsafe_state")
        #expect(run.exists(cache + "/object.o"))
        // 这些失败都发生在建回执之前。
        let receipts = (try? FileManager.default.contentsOfDirectory(atPath: SweepState.runs(run.env))) ?? []
        #expect(receipts.isEmpty)
    }

    @Test func stagingDirectoryIsNeverACandidate() throws {
        let ws = try SweepWorkspace()
        // 上次没走完的暂存内容留在扫描根里：下一次扫描不能把它当成新的缓存。
        ws.swiftProject(SweepState.stagingName + "/ACM-Sweep-leftover/abc")
        let cache = ws.swiftProject("Project")
        let plan = try Run(ws).scan()
        #expect(plan.items.map(\.path) == [cache])
    }

    @Test func purgeStaysOnPinnedDescriptors() throws {
        let ws = try SweepWorkspace()
        ws.file("stage/item/a/b/file.txt", "x")
        ws.file("victim/keep.txt", "keep")
        ws.link("stage/item/a/link", to: ws.path("victim"))
        let fd = open(ws.path("stage"), O_RDONLY | O_DIRECTORY)
        defer { close(fd) }
        let device = try #require(SweepFS.lstat(ws.path("stage"))).st_dev
        // 设备号对不上：一个字节都不删。
        #expect(sweepErrorCode { try SweepExecutor.purge(parentFD: fd, name: "item", device: device + 1) } == "purge_boundary")
        #expect(exists(ws.path("stage/item/a/b/file.txt")))
        try SweepExecutor.purge(parentFD: fd, name: "item", device: device)
        #expect(!exists(ws.path("stage/item")))
        #expect(exists(ws.path("victim/keep.txt")))
    }
}

/// 中途失败之后的状态，以及按回执放回。
@Suite struct SweepRestoreTests {

    @Test func journalFailureBeforeMovePreservesOriginal() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let run = Run(ws)
        let plan = try run.scan()
        for event in ["run", "intent"] {
            let outcome = Result { try run.apply(plan, fault: failing(at: event)) }
            // 抬头都写不进去就整个不做；某一项的 intent 写不进去就跳过那一项。
            if case .success(let result) = outcome {
                #expect(result.items.map(\.status) == [.blocked])
            } else {
                #expect(event == "run")
            }
            #expect(run.exists(cache + "/object.o"))
            #expect(!run.exists(SweepState.stagingName))
        }
    }

    @Test func failureAfterMoveCanBeRestoredWithoutOverwrite() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let run = Run(ws)
        let plan = try run.scan()
        let result = try run.apply(plan, fault: failing(at: "staged"))
        #expect(result.executed)
        #expect(result.incomplete)
        #expect(result.items.map(\.status) == [.recoveryRequired])
        #expect(!run.exists(cache))
        let staged = try #require(result.items[0].recoveryPath)
        #expect(exists(staged + "/object.o"))

        // 原位置又有了新东西：放回不覆盖。
        ws.file(cache + "/new.txt", "new")
        let blocked = try run.restore(result.receipt)
        #expect(blocked.items.map(\.status) == [.blocked])
        #expect(blocked.incomplete)
        #expect(run.read(cache + "/new.txt") == "new")
        #expect(exists(staged + "/object.o"))

        try FileManager.default.removeItem(atPath: ws.path(cache))
        let restored = try run.restore(result.receipt)
        #expect(restored.items.map(\.status) == [.restored])
        #expect(run.read(cache + "/object.o") == "rebuildable object")
        #expect(!exists(staged))
        #expect(!run.exists(SweepState.stagingName))
        #expect(try run.restore(result.receipt).items.isEmpty)
    }

    @Test func failureStopsBeforeTouchingLaterItems() throws {
        let ws = try SweepWorkspace()
        let first = ws.swiftProject("A")
        let second = ws.swiftProject("B")
        let run = Run(ws)
        let plan = try run.scan()
        let result = try run.apply(plan, fault: failing(at: "staged"))
        // 回执写不进去之后不再继续：第二项原地不动，仍是「可执行」而不是被悄悄处理。
        #expect(result.items.map(\.status) == [.recoveryRequired, .ready])
        let untouched = result.items[1].path
        #expect(run.exists(untouched + "/object.o"))
        #expect(Set([first, second]).contains(untouched))
        #expect(try run.restore(result.receipt).items.map(\.status) == [.restored])
        #expect(run.exists(first + "/object.o") && run.exists(second + "/object.o"))
    }

    @Test func undeletableContentStaysInStagingForTheUser() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        ws.file(cache + "/locked/inner.o", "cannot unlink me")
        chmod(ws.path(cache + "/locked"), 0o555)
        let run = Run(ws)
        let plan = try run.scan()
        #expect(plan.item(cache)?.status == .cleanup)

        // 子目录没有写权限，里面的文件删不掉：停下，把剩下的留在暂存目录里并说明在哪。
        let result = try run.apply(plan)
        #expect(result.items.map(\.status) == [.recoveryRequired])
        #expect(result.incomplete)
        let staged = try #require(result.items[0].recoveryPath)
        #expect(staged.hasPrefix(ws.path(SweepState.stagingName) + "/"))
        #expect(FileManager.default.contents(atPath: staged + "/locked/inner.o") == Data("cannot unlink me".utf8))
        #expect(!run.exists(cache))
        // 留下的暂存内容不会被下一次扫描当成候选项。
        #expect(try run.scan().items.isEmpty)
        chmod(staged + "/locked", 0o755)
    }

    @Test func truncatedJournalTailIsRepairedDuringRestore() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let run = Run(ws)
        let plan = try run.scan()
        let result = try run.apply(plan, fault: failing(at: "staged", partial: #"{"event": "sta"#))
        let receipt = try #require(result.receipt)
        #expect(lines(receipt).last == #"{"event": "sta"#)

        let preview = try run.restore(receipt, execute: false)
        #expect(preview.items.map(\.status) == [.ready])
        #expect(lines(receipt).last == #"{"event": "sta"#) // 预演不改回执

        #expect(try run.restore(receipt).items.map(\.status) == [.restored])
        #expect(run.exists(cache + "/object.o"))
        #expect(try run.restore(receipt).items.isEmpty)
        for line in lines(receipt) {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) is [String: Any])
        }
        #expect(lines(receipt).last?.contains("restored") == true)
    }

    @Test func modifiedReceiptCannotRedirectAnything() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let run = Run(ws)
        let plan = try run.scan()
        let result = try run.apply(plan, fault: failing(at: "staged"))
        let receipt = try #require(result.receipt)
        let original = try #require(FileManager.default.contents(atPath: receipt))
        let staged = try #require(result.items[0].recoveryPath)

        func rewrite(_ change: (inout [String: Any]) -> Void) throws {
            let records = try lines(receipt).map { line -> String in
                var record = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                change(&record)
                return String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes]), as: UTF8.self)
            }
            try Data((records.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: receipt))
        }
        func reset() throws { try original.write(to: URL(fileURLWithPath: receipt)) }

        // 改原路径：想把内容放到别处。
        try rewrite { if $0["event"] as? String == "intent" { $0["path"] = "injected.py" } }
        #expect(sweepErrorCode { _ = try run.restore(receipt) } == "invalid_receipt")
        #expect(!run.exists("injected.py"))

        // 改成往扫描根外面放。
        try reset()
        try rewrite { if $0["event"] as? String == "intent" { $0["path"] = "../escaped" } }
        #expect(sweepErrorCode { _ = try run.restore(receipt) } == "invalid_receipt")
        #expect(!exists(ws.fx.root + "/escaped"))

        // 改来源：想把别的东西当成暂存内容搬进来。
        try reset()
        ws.file("decoy/object.o", "decoy")
        try rewrite { if $0["event"] as? String == "intent" { $0["destination"] = ws.path("decoy") } }
        #expect(sweepErrorCode { _ = try run.restore(receipt) } == "invalid_receipt")

        // 改抬头里的暂存目录或扫描根。
        try reset()
        try rewrite { if $0["event"] as? String == "run" { $0["stage"] = ws.path("decoy") } }
        #expect(sweepErrorCode { _ = try run.restore(receipt) } == "invalid_receipt")
        try reset()
        try rewrite { if $0["event"] as? String == "run" { $0["root"] = ws.fx.home } }
        #expect(sweepErrorCode { _ = try run.restore(receipt) } == "invalid_receipt")
        // 抬头和逐项记录一起改、彼此对得上：暂存目录仍然不由回执说了算。
        try reset()
        let id = result.items[0].id
        ws.dir("fake-stage")
        try FileManager.default.moveItem(atPath: ws.path("decoy"), toPath: ws.path("fake-stage/" + id))
        try rewrite {
            if $0["event"] as? String == "run" { $0["stage"] = ws.path("fake-stage") }
            if $0["event"] as? String == "intent" { $0["destination"] = ws.path("fake-stage/" + id) }
        }
        #expect(sweepErrorCode { _ = try run.restore(receipt) } == "invalid_receipt")
        try FileManager.default.moveItem(atPath: ws.path("fake-stage/" + id), toPath: ws.path("decoy"))
        // 把废纸篓方式改写成永久方式也一样：暂存目录跟着方式走。
        try reset()
        try rewrite { if $0["event"] as? String == "run" { $0["mode"] = "trash" } }
        #expect(sweepErrorCode { _ = try run.restore(receipt) } == "invalid_receipt")

        #expect(!run.exists(cache))
        #expect(exists(staged + "/object.o"))
        #expect(run.read("decoy/object.o") == "decoy")

        try reset()
        #expect(try run.restore(receipt).items.map(\.status) == [.restored])
    }

    @Test func receiptsThatAreNotReceiptsAreRejected() throws {
        let ws = try SweepWorkspace()
        let run = Run(ws)
        ws.file("notes.jsonl", "{\"event\":\"intent\",\"id\":\"x\"}\n")
        ws.file("broken.jsonl", "not json\n{\"event\":\"run\"}\n")
        ws.file("empty.jsonl", "")
        ws.link("link.jsonl", to: ws.path("notes.jsonl"))
        for name in ["notes.jsonl", "broken.jsonl", "empty.jsonl", "link.jsonl"] {
            #expect(sweepErrorCode { _ = try run.restore(ws.path(name)) } == "invalid_receipt", "\(name)")
        }
        #expect(sweepErrorCode { _ = try run.restore("relative.jsonl") } == "invalid_receipt")
        #expect(sweepErrorCode { _ = try run.restore(ws.path("missing.jsonl")) } == "io_error")
    }

    @Test func changedOrMissingStagedContentIsNotPutBack() throws {
        let ws = try SweepWorkspace()
        let first = ws.swiftProject("A")
        let second = ws.swiftProject("B")
        let third = ws.swiftProject("C")
        let run = Run(ws)
        let plan = try run.scan()
        let result = try run.apply(plan, mode: .trash)
        #expect(result.items.map(\.status) == [.trashed, .trashed, .trashed])
        let staged = Dictionary(uniqueKeysWithValues: result.items.map { ($0.path, $0.recoveryPath ?? "") })

        // A：暂存的内容被动过；B：被用户自己拖回了原处；C：从废纸篓里清掉了。
        FileManager.default.createFile(atPath: try #require(staged[first]) + "/object.o", contents: Data("tampered".utf8))
        try FileManager.default.moveItem(atPath: try #require(staged[second]), toPath: ws.path(second))
        try FileManager.default.removeItem(atPath: try #require(staged[third]))

        let restored = try run.restore(result.receipt)
        let status = Dictionary(uniqueKeysWithValues: restored.items.map { ($0.path, $0.status) })
        #expect(status == [first: .blocked, second: .alreadyRestored, third: .missing])
        #expect(!restored.executed)
        #expect(restored.incomplete)
        #expect(!run.exists(first))
        #expect(run.exists(second + "/object.o"))
        // 还有内容等着处理：暂存目录留着。
        #expect(exists(try #require(staged[first])))
    }

    @Test func restoreRespectsLockAndRehearsalBoundary() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let run = Run(ws)
        let result = try run.apply(try run.scan(), mode: .trash)
        try SweepState.withRootLock(ws.root, env: run.env) {
            #expect(sweepErrorCode { _ = try run.restore(result.receipt) } == "already_running")
        }
        // 演练时回执指向的目录必须在假家目录之内。
        #expect(sweepErrorCode { _ = try run.restore(result.receipt, confinedTo: ws.fx.home) } == "usage")
        #expect(!run.exists(cache))
        #expect(try run.restore(result.receipt, confinedTo: ws.fx.root).items.map(\.status) == [.restored])
    }

    @Test func restoreRefusesAReplacedRoot() throws {
        let ws = try SweepWorkspace()
        ws.swiftProject()
        let run = Run(ws)
        let result = try run.apply(try run.scan(), mode: .trash)
        try FileManager.default.moveItem(atPath: ws.root, toPath: ws.fx.root + "/moved-away")
        try FileManager.default.createDirectory(atPath: ws.root, withIntermediateDirectories: true)
        #expect(sweepErrorCode { _ = try run.restore(result.receipt) } == "root_changed")
        #expect(try FileManager.default.contentsOfDirectory(atPath: ws.root).isEmpty)
    }
}
