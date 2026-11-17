import Foundation
import Testing
@testable import ACMCore

/// 只读扫描的结论：什么算可清理，什么被哪条保护拦下。
@Suite struct SweepScanTests {

    // MARK: 基本结论

    @Test func generatedCacheIsCleanupAndScanWritesNothing() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        ws.file("main.swift", "print(42)")

        let plan = try ws.scan()
        let item = try #require(plan.item(cache))
        #expect(item.status == .cleanup)
        #expect(item.category == .swiftCache)
        #expect(item.project == ".")
        #expect(item.parent == ".")
        #expect(plan.summary.cleanup == 1)
        #expect(plan.summary.estimatedCleanupBytes == item.snapshot?.allocatedBytes)

        // 扫描是只读的：缓存和源码都在，也没有顺手建出自己的数据目录。
        #expect(FileManager.default.fileExists(atPath: ws.path(cache + "/object.o")))
        #expect(try String(contentsOfFile: ws.path("main.swift"), encoding: .utf8) == "print(42)")
        #expect(!FileManager.default.fileExists(atPath: ws.fx.path("Library")))
    }

    @Test func cacheNameWithoutEvidenceNeedsReview() throws {
        let ws = try SweepWorkspace()
        ws.file(".build/notes.txt", "original notes")
        let item = try #require(try ws.scan().item(".build"))
        #expect(item.status == .review)
        #expect(item.category == .unrecognizedCache)
    }

    @Test func recentActivityIsReviewed() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        // 「现在」就是真的现在：刚建的缓存还没闲置够 24 小时。
        #expect(try ws.scan(now: Date()).item(cache)?.status == .review)
        // 明确说不看闲置时间时可以清。
        #expect(try ws.scan(policy: SweepPolicy(idleHours: 0), now: Date()).item(cache)?.status == .cleanup)
    }

    @Test func sourceDataAndSensitiveDirectoriesAreNeverCandidates() throws {
        let ws = try SweepWorkspace()
        for name in ["Sources", "assets", "data", "backup", ".ssh", "docs", "design"] {
            ws.swiftProject(name + "/NestedProject")
        }
        ws.file("certificate.pem", "private fixture")
        #expect(try ws.scan().items.isEmpty)
    }

    @Test func symlinkedCandidateIsSkipped() throws {
        let ws = try SweepWorkspace()
        let outside = ws.fx.root + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outside + "/keep", contents: Data("keep".utf8))
        ws.link(".build", to: outside)
        #expect(try ws.scan().items.isEmpty)
    }

    // MARK: 各类缓存的生成依据

    @Test func nodeModulesNeedInstallMarkerAndManifest() throws {
        let ws = try SweepWorkspace()
        // 有项目清单、有 npm 的隐藏锁文件：可以重新安装。
        ws.file("web/package.json", "{}")
        ws.file("web/node_modules/.package-lock.json", "{}")
        ws.file("web/node_modules/left-pad/index.js")
        // 只剩依赖，项目文件都没了。
        ws.file("orphan/node_modules/.modules.yaml", "")
        // 名字对，但没有任何安装标记。
        ws.file("vendor/package.json", "{}")
        ws.file("vendor/node_modules/pkg/index.js")
        // 有安装标记，但旁边还有别的东西，又没有项目清单：不能当孤立依赖清掉。
        ws.file("tools/lib/node_modules/.package-lock.json", "{}")
        ws.file("tools/lib/README", "hand-made")

        let plan = try ws.scan()
        #expect(plan.item("web/node_modules")?.category == .nodeDependencies)
        #expect(plan.item("web/node_modules")?.status == .cleanup)
        #expect(plan.item("orphan/node_modules")?.category == .orphanNodeDependencies)
        #expect(plan.item("orphan/node_modules")?.status == .cleanup)
        #expect(plan.item("vendor/node_modules")?.status == .review)
        #expect(plan.item("tools/lib/node_modules")?.status == .review)
    }

    @Test func pythonAndWebCachesNeedTheirOwnEvidence() throws {
        let ws = try SweepWorkspace()
        ws.file("py/pyproject.toml", "")
        ws.file("py/pkg/__pycache__/mod.cpython-312.pyc", "bytecode")
        ws.file("py/odd/__pycache__/mod.cpython-312.pyc", "bytecode")
        ws.file("py/odd/__pycache__/notes.txt", "not generated")
        ws.file("next/package.json", "{}")
        ws.file("next/next.config.mjs", "")
        ws.file("next/.next/build-manifest.json", "{}")
        ws.file("plain/package.json", "{}")
        ws.file("plain/.next/something", "")
        ws.file("mono/turbo.json", "{}")
        ws.file("mono/package.json", "{}")
        ws.file("mono/.turbo/cache/a", "")

        let plan = try ws.scan()
        #expect(plan.item("py/pkg/__pycache__")?.category == .pythonCache)
        #expect(plan.item("py/odd/__pycache__")?.category == .unrecognizedCache)
        #expect(plan.item("next/.next")?.category == .webCache)
        #expect(plan.item("plain/.next")?.category == .unrecognizedCache)
        #expect(plan.item("mono/.turbo")?.category == .webCache)
        #expect(plan.items.filter { $0.category == .unrecognizedCache }.allSatisfy { $0.status == .review })
    }

    // MARK: Git 保护

    @Test func trackedFilesBlockTheCache() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject("Project")
        ws.dir("Project/.git")
        let asked = Recorder()
        let probes = SweepProbes(openPaths: { [] }, gitTracked: { repository, relative in
            asked.add(repository + "|" + relative)
            return .tracked
        })
        let item = try #require(try ws.scan(probes: probes).item(cache))
        #expect(item.status == .blocked)
        #expect(item.reason.contains("Git"))
        // 问的是最近的那个仓库，路径相对于仓库。
        #expect(asked.values == [ws.path("Project") + "|.build"])
    }

    @Test func unreadableGitIndexBlocksInsteadOfGuessing() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        ws.dir(".git")
        let item = try #require(try ws.scan(probes: SweepWorkspace.probes(git: .failed)).item(cache))
        #expect(item.status == .blocked)
    }

    @Test func cacheOutsideAnyRepositoryIsNotAskedAbout() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        // 没有 .git 就不该去问；问了就会被这个探针拦下。
        #expect(try ws.scan(probes: SweepWorkspace.probes(git: .tracked)).item(cache)?.status == .cleanup)
    }

    @Test func nestedRepositoryInsideCacheIsBlocked() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        ws.dir(cache + "/checkouts/Dependency/.git")
        let item = try #require(try ws.scan().item(cache))
        #expect(item.status == .blocked)
        #expect(item.snapshot == nil)
    }

    // MARK: 进程占用

    @Test func processProbeFailureBlocksEveryCleanup() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let probes = SweepProbes(
            openPaths: { throw SweepError("process_probe_failed", "unavailable") },
            gitTracked: { _, _ in .untracked }
        )
        let plan = try ws.scan(probes: probes)
        #expect(plan.item(cache)?.status == .blocked)
        #expect(plan.warnings.map(\.code) == ["process_probe_failed"])
    }

    @Test func openFileInsideCacheBlocks() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let open = SweepOpenPath(pid: 4242, command: "tail", path: ws.path(cache + "/object.o"), isCwd: false)
        let item = try #require(try ws.scan(probes: SweepWorkspace.probes(open: [open])).item(cache))
        #expect(item.status == .blocked)
        #expect(item.processes == [SweepProcessUser(pid: 4242, command: "tail")])
    }

    @Test func developmentToolWorkingInProjectBlocksButShellDoesNot() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject("App")
        let project = ws.path("App")
        let build = SweepOpenPath(pid: 1, command: "swift-build", path: project + "/Sources", isCwd: true)
        let shell = SweepOpenPath(pid: 2, command: "zsh", path: project, isCwd: true)
        let elsewhere = SweepOpenPath(pid: 3, command: "node", path: ws.path("Other"), isCwd: true)
        // 名字相近的隔壁目录不算在里面。
        let sibling = SweepOpenPath(pid: 4, command: "tail", path: ws.path("App/.build-old/x"), isCwd: false)

        #expect(try ws.scan(probes: SweepWorkspace.probes(open: [build])).item(cache)?.status == .blocked)
        #expect(try ws.scan(probes: SweepWorkspace.probes(open: [shell, elsewhere, sibling])).item(cache)?.status == .cleanup)
    }

    // MARK: 排除与自身保护

    @Test func entryLimitPreventsPartialCleanup() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        #expect(try ws.scan(policy: SweepPolicy(maxEntries: 1)).item(cache)?.status == .blocked)
    }

    @Test func exclusionInsideCandidateBlocksWholeDirectory() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        ws.file(cache + "/preserved.txt", "keep this")
        let plan = try ws.scan(policy: SweepPolicy(excludes: [ws.path(cache + "/preserved.txt")]))
        #expect(plan.item(cache)?.status == .blocked)
        #expect(plan.policy.excludes == [ws.path(cache + "/preserved.txt")])
    }

    @Test func excludedCandidateIsNotListed() throws {
        let ws = try SweepWorkspace()
        ws.swiftProject("A")
        ws.swiftProject("B")
        let plan = try ws.scan(policy: SweepPolicy(excludes: [ws.path("A")]))
        #expect(plan.items.map(\.path) == ["B/.build"])
    }

    @Test func ownFilesInsideCandidateAreProtected() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        // 本 App 自己的程序恰好在某个缓存目录里（开发时就是这样）。
        let item = try #require(try ws.scan(selfPaths: [ws.path(cache + "/debug/acm")]).item(cache))
        #expect(item.status == .blocked)
        #expect(item.snapshot == nil)
    }

    // MARK: 扫描根与策略

    @Test func broadSystemAndManagedRootsAreRejected() throws {
        let ws = try SweepWorkspace()
        let env = ws.env()
        ws.fx.dir(".nvm/versions")
        ws.fx.dir("Library/Caches/tool")
        ws.fx.dir("Projects/app")
        ws.file("plain-file")

        func code(_ root: String) -> String {
            sweepErrorCode { _ = try SweepScanner.scan(root: root, env: env, probes: SweepWorkspace.quiet) }
        }
        #expect(code("/") == "broad_root")
        #expect(code(ws.fx.home) == "broad_root")
        #expect(code(ws.fx.root) == "broad_root")
        #expect(code("/tmp") == "broad_root")
        #expect(code("/private/var") == "broad_root")
        #expect(code("/usr/lib") == "system_root")
        #expect(code("/Applications") == "system_root")
        #expect(code(ws.fx.path(".nvm/versions")) == "managed_root")
        #expect(code(ws.fx.path("Library/Caches/tool")) == "managed_root")
        #expect(code(ws.path("plain-file")) == "invalid_root")
        #expect(code(ws.path("missing")) == "invalid_root")
        #expect(code("relative/path") == "invalid_root")
        // 家目录下的普通文件夹正是这个模块要管的地方。
        #expect(code(ws.fx.path("Projects/app")) == "没有抛错")
    }

    @Test func symlinkedRootIsResolvedBeforeChecking() throws {
        let ws = try SweepWorkspace()
        ws.swiftProject()
        ws.fx.link("Shortcut", to: ws.root)
        ws.fx.link("Everything", to: "/")
        let plan = try SweepScanner.scan(root: ws.fx.path("Shortcut"), env: ws.env(), probes: SweepWorkspace.quiet)
        #expect(plan.root == ws.root)
        #expect(sweepErrorCode {
            _ = try SweepScanner.scan(root: ws.fx.path("Everything"), env: ws.env(), probes: SweepWorkspace.quiet)
        } == "broad_root")
    }

    @Test func rehearsalRootMustStayInsideTheFakeHome() throws {
        let ws = try SweepWorkspace()
        ws.fx.dir("Projects/app")
        ws.fx.link("Outside", to: ws.root)
        func code(_ path: String) -> String {
            sweepErrorCode { try SweepPath.requireInside(path, home: ws.fx.home) }
        }
        #expect(code(ws.fx.path("Projects/app")) == "没有抛错")
        #expect(code(ws.root) == "usage")
        #expect(code(ws.fx.home) == "usage")
        #expect(code("/") == "usage")
        // 字面上在里面、实际指向外面的软链不算在里面。
        #expect(code(ws.fx.path("Outside")) == "usage")
        // 不存在的路径留给扫描去报「目录不存在」。
        #expect(code(ws.fx.path("missing")) == "没有抛错")
    }

    @Test func nonsensePolicyIsRejected() throws {
        let ws = try SweepWorkspace()
        for policy in [
            SweepPolicy(idleHours: .nan), SweepPolicy(idleHours: .infinity), SweepPolicy(idleHours: -1),
            SweepPolicy(maxEntries: 0), SweepPolicy(maxEntries: 2_000_001),
        ] {
            #expect(sweepErrorCode { _ = try ws.scan(policy: policy) } == "invalid_policy")
        }
    }

    // MARK: 指纹

    @Test func identifiersAreStableAcrossScans() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject("App")
        let first = try #require(try ws.scan().item(cache))
        let second = try #require(try ws.scan().item(cache))
        #expect(first.id == second.id)
        #expect(first.id.count == 16)
        #expect(first.id == SweepScanner.candidateID(root: ws.root, relative: cache))
        #expect(first.snapshot == second.snapshot)
    }

    @Test func snapshotNoticesContentChangesButNotRenames() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let before = try SweepSnapshotter.snapshot(root: ws.root, relative: cache)

        // 整个目录改名再改回来：里面的东西没变，指纹不变。
        try FileManager.default.moveItem(atPath: ws.path(cache), toPath: ws.path(".build-moved"))
        let moved = try SweepSnapshotter.snapshot(root: ws.root, relative: ".build-moved")
        #expect(moved == before)
        try FileManager.default.moveItem(atPath: ws.path(".build-moved"), toPath: ws.path(cache))

        // 原地改写一个文件：指纹变。
        ws.file(cache + "/object.o", "new data, different size")
        let after = try SweepSnapshotter.snapshot(root: ws.root, relative: cache)
        #expect(after.digest != before.digest)
        #expect(after.inode == before.inode)

        // 多一个文件也变。
        ws.file(cache + "/extra.o")
        #expect(try SweepSnapshotter.snapshot(root: ws.root, relative: cache).entries == before.entries + 1)
    }

    @Test func snapshotRecordsLinksWithoutFollowingAndCountsHardLinksOnce() throws {
        let ws = try SweepWorkspace()
        let outside = ws.fx.root + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        for index in 0..<50 {
            FileManager.default.createFile(atPath: outside + "/big-\(index)", contents: Data(count: 8192))
        }
        ws.file("cache/blob", Data(count: 64 * 1024))
        try FileManager.default.linkItem(atPath: ws.path("cache/blob"), toPath: ws.path("cache/blob-again"))
        let single = try SweepSnapshotter.snapshot(root: ws.root, relative: "cache/blob")

        ws.link("cache/escape", to: outside)
        let snapshot = try SweepSnapshotter.snapshot(root: ws.root, relative: "cache")
        // 目录本身、两个硬链接名、一个软链：外面那 50 个文件一个都没算进来。
        #expect(snapshot.entries == 4)
        #expect(snapshot.kind == "directory")
        #expect(snapshot.allocatedBytes < single.allocatedBytes * 2)

        // 软链换个目标，指纹跟着变。
        try FileManager.default.removeItem(atPath: ws.path("cache/escape"))
        ws.link("cache/escape", to: "/nonexistent")
        #expect(try SweepSnapshotter.snapshot(root: ws.root, relative: "cache").digest != snapshot.digest)
    }

    @Test func snapshotRefusesSymlinksAndPathsOutsideRoot() throws {
        let ws = try SweepWorkspace()
        ws.swiftProject("Real")
        ws.link("Alias", to: ws.path("Real"))
        ws.link("direct", to: ws.path("Real/.build"))

        func code(_ relative: String) -> String {
            sweepErrorCode { _ = try SweepSnapshotter.snapshot(root: ws.root, relative: relative) }
        }
        #expect(code("Alias/.build") == "unsafe_path")
        #expect(code("direct") == "unsafe_path")
        #expect(code("../outside") == "unsafe_path")
        #expect(code("Real/../Real/.build") == "unsafe_path")
        #expect(code("/etc") == "unsafe_path")
        #expect(code("") == "unsafe_path")
        #expect(code("Real/.build") == "没有抛错")
    }

    /// 摘要里的字符串写法必须和 BuildSweep 一致，否则两边的指纹对不上。
    @Test func canonicalStringsEscapeLikeTheReference() {
        func encode(_ text: String) -> String {
            var out: [UInt8] = []
            SweepCanonical.append(text, to: &out)
            return String(decoding: out, as: UTF8.self)
        }
        #expect(encode("a/b.txt") == #""a/b.txt""#)
        #expect(encode("q\"b\\s") == #""q\"b\\s""#)
        #expect(encode("line\nfeed\ttab\r") == #""line\nfeed\ttab\r""#)
        #expect(encode("\u{08}\u{0C}\u{01}\u{7F}") == #""\b\f\u0001\u007f""#)
        #expect(encode("中文\u{E9}") == #""\u4e2d\u6587\u00e9""#)
        #expect(encode("😀") == #""\ud83d\ude00""#)
        // 分解形式的字符不能被悄悄合成：文件名在磁盘上是什么样就记成什么样。
        #expect(encode("e\u{301}") == #""e\u0301""#)
    }
}

/// 在探针回调里记录调用，供断言用。
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func add(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(value)
    }

    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
