import Foundation
import Testing
@testable import ACMCore

@Suite struct PathSafetyTests {

    @Test func refusesEverythingThatIsNotAToolLocation() throws {
        let fx = try Fixture()
        let env = fx.env()
        let home = fx.home
        fx.dir(".ssh"); fx.dir("Documents"); fx.dir("Library/Caches"); fx.dir(".foo")

        let refused = [
            home,
            home + "/",
            home + "/Library",
            home + "/Library/Caches",
            home + "/Library/Application Support",
            home + "/Library/Keychains/login.keychain-db",
            home + "/Library/Mobile Documents/x",
            home + "/.config",
            home + "/.cache",
            home + "/.local",
            home + "/.local/bin",
            home + "/.local/share",
            home + "/.agents",
            home + "/.ssh",
            home + "/.ssh/id_ed25519",
            home + "/.zshrc",
            home + "/.Trash/anything",
            home + "/Documents",
            home + "/Documents/notes.txt",
            home + "/Projects",
            home + "/.foo/../.ssh",
            home + "/.foo/../../outside",
            "/",
            "/etc/passwd",
            "/usr/local/bin/tool",
            "/Applications/Some.app",
            "relative/path",
            "",
            "/System/Volumes/Data" + home,
            "/System/Volumes/Data" + home + "/Library",
            "/System/Volumes/Data" + home + "/.ssh/id_ed25519",
            fx.root,
        ]
        for path in refused {
            #expect(!PathSafety.check(path, env: env).allowed, "应当拒绝：\(path)")
        }
    }

    @Test func allowsToolLocations() throws {
        let fx = try Fixture()
        let env = fx.env()
        let home = fx.home
        let allowed = [
            home + "/.foo",
            home + "/.foo/bar/baz",
            home + "/.foo.json",
            home + "/.config/foo",
            home + "/.cache/foo",
            home + "/.local/share/foo",
            home + "/.local/bin/foo",
            home + "/Library/Caches/com.example.tool",
            home + "/Library/Application Support/Tool",
            home + "/Library/Preferences/com.example.tool.plist",
            "/System/Volumes/Data" + home + "/.foo",
            home + "//.foo/./bar",
        ]
        for path in allowed {
            let decision = PathSafety.check(path, env: env)
            #expect(decision.allowed, "应当放行：\(path)（\(decision.reason ?? "")）")
        }
    }

    @Test func caseAndUnicodeVariantsOfProtectedPathsAreRefused() throws {
        let fx = try Fixture()
        let env = fx.env()
        #expect(!PathSafety.check(fx.home + "/.SSH/id", env: env).allowed)
        #expect(!PathSafety.check(fx.home + "/.Config", env: env).allowed)
        #expect(!PathSafety.check(fx.home + "/library/caches", env: env).allowed)
    }

    @Test func symlinkedParentCannotRedirectDeletionOutsideHome() throws {
        let fx = try Fixture()
        let env = fx.env()
        let outside = fx.root + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outside + "/victim", contents: Data())
        fx.link(".foo/escape", to: outside)
        fx.dir("Documents")
        fx.link(".foo/docs", to: fx.path("Documents"))

        // 路径字面上在 ~/.foo 里，实际落在家目录之外或受保护目录里
        #expect(!PathSafety.check(fx.path(".foo/escape/victim"), env: env).allowed)
        #expect(!PathSafety.check(fx.path(".foo/docs/notes.txt"), env: env).allowed)
        // 链接本身可以移走——移走的是链接，不是它指向的东西
        #expect(PathSafety.check(fx.path(".foo/escape"), env: env).allowed)
    }

    @Test func danglingSymlinkItselfIsRemovable() throws {
        let fx = try Fixture()
        fx.link(".dangling", to: "/nonexistent/target")
        #expect(PathSafety.check(fx.path(".dangling"), env: fx.env()).allowed)
    }

    @Test func symlinkLoopDoesNotHang() throws {
        let fx = try Fixture()
        fx.link(".loop/a", to: "b")
        fx.link(".loop/b", to: "a")
        _ = PathSafety.check(fx.path(".loop/a/x"), env: fx.env())
        let chain = BinaryRegistry.resolveChain(fx.path(".loop/a"))
        #expect(chain.final == nil)
    }

    @Test func ownFilesAreRefused() throws {
        let fx = try Fixture()
        let own = fx.dir("Library/Application Support/AgentCLIManager")
        let env = fx.env(selfPaths: [own])
        #expect(!PathSafety.check(own, env: env).allowed)
        #expect(!PathSafety.check(own + "/catalog.json", env: env).allowed)
    }
}

@Suite struct PlannerTests {

    /// 没收录在清单里的工具，四环链路：
    /// ~/.local/bin/tool → ~/.tool/bin/tool → ~/.tool/current → ~/.tool/versions/1.2.3/tool
    private func chainFixture() throws -> (Fixture, [String]) {
        let fx = try Fixture()
        let program = fx.file(".tool/versions/1.2.3/tool", executable: true)
        let inner = fx.link(".tool/current", to: "versions/1.2.3/tool")
        let middle = fx.link(".tool/bin/tool", to: "../current")
        let outer = fx.link(".local/bin/tool", to: fx.path(".tool/bin/tool"))
        fx.file(".tool/mcp.json")
        fx.file(".tool/sessions/1.json")
        return (fx, [outer, middle, inner, program])
    }

    @Test func wholeChainIsResolved() throws {
        let (fx, chain) = try chainFixture()
        let report = scan(fx)
        let group = try #require(report.groups(in: .installed).first)
        let binary = try #require(group.binaries.first { $0.path == chain[0] })
        #expect(binary.chain == chain)
        #expect(binary.version == "1.2.3")
        #expect(binary.payloadRoot == fx.path(".tool"))
    }

    @Test func defaultPlanRemovesProgramFirstThenLaunchersInnermostFirst() throws {
        let (fx, chain) = try chainFixture()
        let env = fx.env()
        let group = try #require(scan(fx).groups(in: .installed).first)
        let selected = Set(group.artifacts.filter(\.defaultSelected).map(\.path))

        // 默认：程序和三环链接；整个厂商目录（含数据）不在默认之列
        #expect(selected == Set(chain))
        let plan = UninstallPlanner.plan(group: group, selected: selected, env: env)
        #expect(plan.steps.map(\.path) == [chain[3], chain[2], chain[1], chain[0]])

        let remover = RecordingRemover()
        let result = Uninstaller.execute(plan, env: env, remover: remover)
        #expect(result.succeeded)
        #expect(remover.trashed == [chain[3], chain[2], chain[1], chain[0]])
    }

    @Test func selectingTheVendorDirSubsumesWhatIsInside() throws {
        let (fx, chain) = try chainFixture()
        let group = try #require(scan(fx).groups(in: .installed).first)
        let all = Set(group.artifacts.map(\.path))
        let plan = UninstallPlanner.plan(group: group, selected: all, env: fx.env())
        // 厂商目录一次移走，外面只剩最外层的入口；没有哪一步落在另一步里面
        #expect(plan.steps.map(\.path) == [fx.path(".tool"), chain[0]])
    }

    @Test func launchersStayWhenProgramCannotBeMoved() throws {
        let (fx, chain) = try chainFixture()
        let env = fx.env()
        let group = try #require(scan(fx).groups(in: .installed).first)
        let plan = UninstallPlanner.plan(group: group, selected: Set(chain), env: env)

        let remover = RecordingRemover(failing: [chain[3]])
        let result = Uninstaller.execute(plan, env: env, remover: remover)
        // 程序没移走就不动入口，否则会留下一串断链
        #expect(remover.trashed.isEmpty)
        #expect(result.failures.count == 4)
    }

    @Test func swallowedCredentialsAreCalledOut() throws {
        let fx = try Fixture()
        let binary = fx.file(".grok/downloads/grok-1.0.0", executable: true)
        fx.link(".local/bin/grok", to: binary)
        fx.file(".grok/auth.json")
        let group = try #require(scan(fx).groups(in: .installed).first)

        let credentials = try #require(group.artifacts.first { $0.kind == .credentials })
        #expect(!credentials.defaultSelected)

        // 勾了整个 ~/.grok、没勾 auth.json：凭据会被一并带走，必须提示
        let plan = UninstallPlanner.plan(group: group, selected: [fx.path(".grok")], env: fx.env())
        #expect(plan.steps.map(\.path) == [fx.path(".grok")])
        #expect(plan.warnings.contains { $0.contains("auth.json") })
    }

    @Test func protectedFlagsVetoDefaultSelection() {
        for flag in [ArtifactFlag.shared, .inUse, .credentials, .rootOwned, .notRemovable, .manualOnly] {
            var a = Artifact(path: "/h/.x/bin", kind: .program, claim: .ownedByCLI, strength: .certain)
            #expect(EvidenceRules.defaultSelected(a, in: .installed))
            a.flags.insert(flag)
            #expect(!EvidenceRules.defaultSelected(a, in: .installed), "\(flag) 应当否决默认勾选")
        }
        var guess = Artifact(path: "/h/.x", kind: .program, claim: .ownedByCLI, strength: .probable)
        #expect(!EvidenceRules.defaultSelected(guess, in: .installed))
        guess.strength = .certain
        #expect(!EvidenceRules.defaultSelected(guess, in: .unidentified))
        #expect(!EvidenceRules.defaultSelected(guess, in: .managedByApp))
    }

    @Test func rootOwnedItemBecomesAManualCommand() throws {
        let fx = try Fixture()
        fx.file(".tool/data")
        var artifact = Artifact(path: fx.path(".tool"), kind: .data, claim: .residue, strength: .certain)
        artifact.flags.insert(.rootOwned)
        let group = ToolGroup(id: "residue:tool", name: "tool", section: .residue, artifacts: [artifact])

        let plan = UninstallPlanner.plan(group: group, selected: [artifact.path], env: fx.env())
        #expect(plan.steps.isEmpty)
        #expect(plan.skipped.count == 1)
        #expect(plan.manualCommands.contains { $0.hasPrefix("sudo rm -rf -- ") })
    }

    @Test func managedByAppGroupIsNeverPlanned() throws {
        let fx = try Fixture()
        fx.app("ChatGPT", bundleID: "com.openai.codex")
        fx.file(".codex/sessions/a.jsonl")
        let group = try #require(scan(fx).groups(in: .managedByApp).first)
        let plan = UninstallPlanner.plan(group: group, selected: Set(group.artifacts.map(\.path)), env: fx.env())
        #expect(plan.steps.isEmpty)
    }

    @Test func planIsRecheckedAtExecutionTime() throws {
        let (fx, chain) = try chainFixture()
        let env = fx.env()
        let group = try #require(scan(fx).groups(in: .installed).first)
        let plan = UninstallPlanner.plan(group: group, selected: [chain[0]], env: env)
        try FileManager.default.removeItem(atPath: chain[0])

        let remover = RecordingRemover()
        let result = Uninstaller.execute(plan, env: env, remover: remover)
        #expect(remover.trashed.isEmpty)
        #expect(result.failures.count == 1)
    }

    @Test func movedItemsCanBePutBack() throws {
        let (fx, chain) = try chainFixture()
        let env = fx.env(trashDirs: [fx.root + "/trash"])
        let group = try #require(scan(fx).groups(in: .installed).first)
        let plan = UninstallPlanner.plan(group: group, selected: Set(group.artifacts.map(\.path)), env: env)

        let remover = MoveRemover(trashDir: fx.root + "/trash")
        let result = Uninstaller.execute(plan, env: env, remover: remover)
        #expect(result.succeeded)
        #expect(FileProbe.lstat(fx.path(".tool")) == nil)
        #expect(FileProbe.lstat(chain[0]) == nil)

        let undone = Uninstaller.restore(result.receipts, env: env, remover: remover)
        #expect(undone.failures.isEmpty)
        #expect(FileProbe.exists(chain[3]))
        // 链路恢复完整
        #expect(BinaryRegistry.resolveChain(chain[0]).final == chain[3])
    }
}

@Suite struct ProbeTests {

    @Test func unreadableSubdirectoryMakesSizeALowerBound() throws {
        let fx = try Fixture()
        fx.file(".tool/readable/a", String(repeating: "x", count: 100_000))
        fx.file(".tool/locked/secret", String(repeating: "y", count: 100_000))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fx.path(".tool/locked"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.path(".tool/locked")) }

        let partial = try #require(DuSizeProbe().measure(fx.path(".tool")))
        #expect(!partial.accurate)
        #expect(partial.display.hasPrefix("≥"))

        let whole = try #require(DuSizeProbe().measure(fx.path(".tool/readable")))
        #expect(whole.accurate)
        #expect(whole.bytes >= 100_000)
    }

    @Test func nestedArtifactsAreNotDoubleCounted() {
        var outer = Artifact(path: "/h/.grok", kind: .data, claim: .ownedByCLI, strength: .certain)
        outer.size = SizeResult(bytes: 400, accurate: true)
        var inner = Artifact(path: "/h/.grok/downloads", kind: .program, claim: .ownedByCLI, strength: .certain)
        inner.size = SizeResult(bytes: 300, accurate: true)
        var launcher = Artifact(path: "/h/.local/bin/grok", kind: .launcher, claim: .ownedByCLI, strength: .certain)
        launcher.size = SizeResult(bytes: 1, accurate: true)

        #expect(ToolGroup.totalSize(of: [outer, inner, launcher]) == SizeResult(bytes: 401, accurate: true))
        #expect(ToolGroup.totalSize(of: [inner, launcher]) == SizeResult(bytes: 301, accurate: true))
        inner.size = SizeResult(bytes: 300, accurate: false)
        #expect(ToolGroup.totalSize(of: [inner, launcher])?.accurate == false)
    }

    @Test func processMatchesByExecutableArgumentOrWorkingDirectory() {
        let root = "/h/.tool"
        #expect(RunningProcess(pid: 1, executable: "/h/.tool/bin/x").uses(root))
        #expect(RunningProcess(pid: 2, executable: "/usr/bin/node", arguments: ["node", "/h/.tool/cli.js"]).uses(root))
        #expect(RunningProcess(pid: 3, executable: "/bin/zsh", cwd: "/h/.tool/work").uses(root))
        #expect(!RunningProcess(pid: 4, executable: "/h/.toolbox/bin/x").uses(root))
    }
}

@Suite struct SourceHygieneTests {

    /// 引擎不得自己去取真实家目录——那样测试就可能碰到用户的文件。
    /// 唯一的例外是组装真实环境的 HostEnvironment.swift。
    @Test func engineNeverReachesForTheRealHomeDirectory() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ACMCore")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if ["HostEnvironment.swift", "BuiltinCatalog.swift"].contains(url.lastPathComponent) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for forbidden in ["homeDirectoryForCurrentUser", "NSHomeDirectory", "/Users/", "NSUserName"] {
                #expect(!text.contains(forbidden), "\(url.lastPathComponent) 里出现了 \(forbidden)")
            }
            checked += 1
        }
        #expect(checked > 10)
    }
}
