import Foundation
import Testing
@testable import ACMCore

@Suite struct ReviewRegressionTests {
    @Test func sharedShimDirectoryMustNotMergeUnrelatedCommands() throws {
        let fx = try Fixture()
        for name in ["codex", "node", "npm", "yarn"] {
            fx.file(".volta/bin/" + name, "#!/bin/sh\nexit 0\n", executable: true)
        }
        let report = scan(fx, catalog: Catalog.loadBuiltin())
        let codex = try #require(report.groups.first { $0.id == "cli:codex" })
        let selected = Set(codex.artifacts.filter(\.defaultSelected).map(\.path))
        let plan = UninstallPlanner.plan(group: codex, selected: selected, env: fx.env())
        print("REVIEW shim grouping:", codex.binaries.map(\.name), "selected:", plan.steps.map(\.path))
        #expect(!codex.binaries.contains { ["node", "npm", "yarn"].contains($0.name) })
        #expect(!plan.steps.contains { ["node", "npm", "yarn"].contains(PathUtil.lastComponent($0.path)) })
    }

    /// 真实的 Volta 布局：bin 里每个命令都是指向同一个 `volta-shim` 的软链。
    /// 用普通文件建夹具测不到这一点——每个文件的最终目标天然不同。
    @Test func symlinksToSharedDispatcherMustStaySeparateGroups() throws {
        let fx = try Fixture()
        let shim = fx.file(".volta/bin/volta-shim", "#!/bin/sh\nexit 0\n", executable: true)
        let names = ["agentx", "codex", "node", "npm", "yarn"]
        for name in names { fx.link(".volta/bin/" + name, to: shim) }
        let report = scan(fx, catalog: Catalog.loadBuiltin())

        for group in report.groups {
            let held = group.binaries.map(\.name).filter { names.contains($0) || $0 == "volta-shim" }
            #expect(held.count <= 1, "\(group.id) 把 \(held) 并成了一组")
        }

        // 共用的调度程序只归它自己那个入口，并且带保护；别的命令不把它当程序本体。
        let hit = try #require(find(report, shim))
        #expect(hit.group.binaries.map(\.name) == ["volta-shim"])
        #expect(hit.artifact.flags.contains(.usedByOthers))
        #expect(!hit.artifact.defaultSelected)

        // 未收录和已收录的命令都一样：就算全选，计划里也只有它自己的入口。
        for name in ["agentx", "codex"] {
            let group = try #require(report.groups.first { $0.binaries.contains { $0.name == name } })
            #expect(group.artifacts.map(\.path) == [fx.path(".volta/bin/" + name)])
            let plan = UninstallPlanner.plan(group: group, selected: Set(group.artifacts.map(\.path)), env: fx.env())
            #expect(plan.steps.map(\.path) == [fx.path(".volta/bin/" + name)])
        }
    }

    /// Homebrew 装的 Volta：shim 指向家目录之外的 Cellar。那个 formula 是管理器的，
    /// 不是这些命令的——不能按它归组，也不能把它的版本号和卸载命令记到命令头上。
    @Test func managerShimsPointingOutsideTheManagerMustStaySeparate() throws {
        let fx = try Fixture()
        fx.file("../opt/homebrew/Cellar/volta/2.0.2/bin/volta-shim", "#!/bin/sh\nexit 0\n", executable: true)
        fx.link("../opt/homebrew/bin/volta-shim", to: "../Cellar/volta/2.0.2/bin/volta-shim")
        let names = ["agentx", "codex", "node", "npm"]
        for name in names { fx.link(".volta/bin/" + name, to: fx.root + "/opt/homebrew/bin/volta-shim") }
        let report = scan(fx, catalog: Catalog.loadBuiltin())

        for name in names {
            let group = try #require(report.groups.first { $0.binaries.contains { $0.name == name } })
            #expect(group.binaries.map(\.name) == [name])
            #expect(group.artifacts.map(\.path) == [fx.path(".volta/bin/" + name)])
            #expect(group.manualCommands.isEmpty, "\(name) 不该得到 \(group.manualCommands)")
            #expect(group.version == nil, "\(name) 的版本不该是管理器的 \(group.version ?? "")")
            #expect(group.notes.contains { $0.contains("Volta") })
            let plan = UninstallPlanner.plan(group: group, selected: Set(group.artifacts.map(\.path)), env: fx.env())
            #expect(plan.steps.map(\.path) == [fx.path(".volta/bin/" + name)])
        }
    }

    /// 装在 ~/.local/bin 的 mise：调度程序自己是个独立命令，shim 目录靠 rc 文件进 PATH。
    @Test func standaloneDispatcherKeepsItsOwnGroupAndItsDataDirectory() throws {
        let fx = try Fixture()
        let mise = fx.file(".local/bin/mise", "#!/bin/sh\nexit 0\n", executable: true)
        fx.file(".zshrc", "export PATH=\"$HOME/.local/share/mise/shims:$PATH\"\n")
        let names = ["agentx", "codex", "node", "npm"]
        for name in names { fx.link(".local/share/mise/shims/" + name, to: mise) }
        let report = scan(fx, catalog: Catalog.loadBuiltin())

        for name in names {
            let group = try #require(report.groups.first { $0.binaries.contains { $0.name == name } })
            #expect(group.binaries.map(\.name) == [name])
            #expect(group.artifacts.map(\.path) == [fx.path(".local/share/mise/shims/" + name)])
        }
        let own = try #require(find(report, mise))
        #expect(own.group.binaries.map(\.name) == ["mise"])
        #expect(own.artifact.flags.contains(.usedByOthers))
        #expect(!own.artifact.defaultSelected)
        // 整个 mise 目录只能跟着 mise 自己走，而且里面有别的命令的入口。
        let data = try #require(find(report, fx.path(".local/share/mise")))
        #expect(data.group.id == own.group.id)
        #expect(data.artifact.flags.contains(.usedByOthers))
        #expect(!data.artifact.defaultSelected)
    }

    /// 只有一个 shim 也一样：调度程序自己是另一个名字的命令，不是这个 shim 的程序本体。
    @Test func singleShimStillDoesNotOwnTheDispatcher() throws {
        let fx = try Fixture()
        let mise = fx.file(".local/bin/mise", "#!/bin/sh\nexit 0\n", executable: true)
        fx.file(".zshrc", "export PATH=\"$HOME/.local/share/mise/shims:$PATH\"\n")
        let shim = fx.link(".local/share/mise/shims/codex", to: mise)
        let report = scan(fx, catalog: Catalog.loadBuiltin())
        let codex = try #require(report.groups.first { $0.id == "cli:codex" })
        #expect(codex.artifacts.map(\.path) == [shim])
        let own = try #require(find(report, mise))
        #expect(own.group.binaries.map(\.name) == ["mise"])
        #expect(own.artifact.kind == .program)
        #expect(own.artifact.flags.contains(.usedByOthers))
    }

    /// 调度程序自己在跑，不等于每个经它启动的命令都在跑：借来的那一环不算这个命令的位置。
    @Test func runningDispatcherDoesNotMarkItsBorrowersAsRunning() throws {
        let fx = try Fixture()
        let mise = fx.file(".local/bin/mise", "#!/bin/sh\nexit 0\n", executable: true)
        fx.file(".zshrc", "export PATH=\"$HOME/.local/share/mise/shims:$PATH\"\n")
        let shim = fx.link(".local/share/mise/shims/codex", to: mise)
        fx.link(".local/share/mise/shims/node", to: mise)
        let dispatcher = RunningProcess(pid: 77, executable: mise, arguments: [mise, "watch"])
        let report = scan(fx, processes: [dispatcher], catalog: Catalog.loadBuiltin())

        let own = try #require(find(report, mise))
        #expect(own.group.runningPIDs == [77])
        #expect(own.artifact.flags.contains(.inUse))

        let codex = try #require(report.groups.first { $0.id == "cli:codex" })
        #expect(codex.runningPIDs.isEmpty)
        #expect(codex.artifacts.allSatisfy { !$0.flags.contains(.inUse) })
        #expect(codex.artifacts.first { $0.path == shim }?.defaultSelected == true)
        let plan = UninstallPlanner.plan(group: codex, selected: [shim], env: fx.env())
        #expect(!plan.watchPaths.contains(mise))
        #expect(plan.watchPaths.contains(shim))
        #expect(plan.acknowledgedPIDs.isEmpty)
        #expect(ToolScanner.runningPIDs(usingAnyOf: plan.watchPaths, in: [dispatcher]).isEmpty)

        // 入口自己被当作可执行文件或参数用到时，仍然算在跑。
        let viaShim = RunningProcess(pid: 78, executable: "/bin/sh", arguments: ["/bin/sh", shim])
        #expect(ToolScanner.runningPIDs(for: codex, in: [viaShim]) == [78])
    }

    /// 同一个命令经两个入口（自己建的软链指向管理器的 shim）：还是一个组，两条入口都在里面。
    @Test func sameCommandThroughTwoEntriesStaysOneGroup() throws {
        let fx = try Fixture()
        let shim = fx.file(".volta/bin/volta-shim", "#!/bin/sh\nexit 0\n", executable: true)
        for name in ["agentx", "node"] { fx.link(".volta/bin/" + name, to: shim) }
        let outer = fx.link(".local/bin/agentx", to: fx.path(".volta/bin/agentx"))
        let report = scan(fx, catalog: Catalog.loadBuiltin())

        let groups = report.groups.filter { $0.binaries.contains { $0.name == "agentx" } }
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(Set(group.artifacts.map(\.path)) == [outer, fx.path(".volta/bin/agentx")])
        #expect(group.artifacts.allSatisfy { $0.kind == .launcher && !$0.flags.contains(.usedByOthers) })
        #expect(!report.groups.contains { $0.artifacts.isEmpty && !$0.binaries.isEmpty })
        #expect(group.notes.filter { $0.contains("volta-shim") }.count == 1)
        #expect(group.notes.contains { $0.contains("Volta") })
    }

    /// 管理器目录里的软链指向厂商自己的目录：那是它自己的程序，不是管理器的 shim。
    @Test func linkFromManagerDirectoryIntoVendorDirectoryKeepsItsProgram() throws {
        let fx = try Fixture()
        let program = fx.file(".agentx/bin/agentx-real", "#!/bin/sh\nexit 0\n", executable: true)
        fx.file(".agentx/mcp.json", "{}")
        fx.file(".agentx/sessions/a.jsonl", "{}")
        let entry = fx.link(".bun/bin/agentx", to: program)
        let report = scan(fx, catalog: Catalog.loadBuiltin())

        let hit = try #require(find(report, entry))
        #expect(hit.group.section == .installed)
        #expect(Set(hit.group.binaries.map(\.name)) == ["agentx", "agentx-real"])
        #expect(hit.artifact.defaultSelected)
        let body = try #require(hit.group.artifacts.first { $0.path == program })
        #expect(body.kind == .program)
        #expect(!body.flags.contains(.usedByOthers))
        #expect(body.defaultSelected)
        #expect(hit.group.artifacts.contains { $0.path == fx.path(".agentx") })
    }

    /// 说明里只能写查得到的事实：入口在谁的目录里。「由谁管理」是猜的——
    /// ~/.cargo/bin 里的 rustc 归 rustup 管，不归 cargo。
    @Test func borrowedNoteDoesNotGuessWhoManagesTheProgram() throws {
        let fx = try Fixture()
        let rustup = fx.file(".cargo/bin/rustup", "#!/bin/sh\nexit 0\n", executable: true)
        for name in ["cargo", "rustc"] { fx.link(".cargo/bin/" + name, to: rustup) }
        let report = scan(fx, catalog: Catalog.loadBuiltin())
        let rustc = try #require(report.groups.first { $0.binaries.map(\.name) == ["rustc"] })
        let note = try #require(rustc.notes.first { $0.contains("rustup") })
        #expect(!note.contains("由 cargo 管理"))
        #expect(!note.contains("cargo 自己的命令"))
    }

    /// 共用的不只是链尾：`node -> volta-shim -> Cellar/…`，中间那条 volta-shim 软链
    /// 同样是所有命令的必经之路，也不能记到某一个命令头上。
    @Test func sharedIntermediateHopBelongsToNoBorrower() throws {
        let fx = try Fixture()
        fx.file("../opt/homebrew/Cellar/volta/2.0.2/bin/volta-shim", "#!/bin/sh\nexit 0\n", executable: true)
        let shim = fx.link(".volta/bin/volta-shim", to: fx.root + "/opt/homebrew/Cellar/volta/2.0.2/bin/volta-shim")
        for name in ["agentx", "node"] { fx.link(".volta/bin/" + name, to: "volta-shim") }
        let report = scan(fx, catalog: Catalog.loadBuiltin())

        for name in ["agentx", "node"] {
            let group = try #require(report.groups.first { $0.binaries.contains { $0.name == name } })
            #expect(group.artifacts.map(\.path) == [fx.path(".volta/bin/" + name)])
        }
        let hit = try #require(find(report, shim))
        #expect(hit.group.binaries.map(\.name) == ["volta-shim"])
        #expect(hit.artifact.flags.contains(.usedByOthers))
        #expect(!hit.artifact.defaultSelected)
    }

    /// 管理器目录里的软链指向目录之外、又只有这一个命令在用（Nix profile 那样）：
    /// 目标仍是它自己的程序，路径里的版本号也是它的。
    @Test func soleUserOfATargetOutsideTheManagerKeepsItsProgramAndVersion() throws {
        let fx = try Fixture()
        fx.file("../nix/store/abc-agentx-1.4.0/bin/agentx", "#!/bin/sh\nexit 0\n", executable: true)
        let store = fx.root + "/nix/store/abc-agentx-1.4.0/bin/agentx"
        fx.file(".zshrc", "export PATH=\"$HOME/.nix-profile/bin:$PATH\"\n")
        let entry = fx.link(".nix-profile/bin/agentx", to: store)
        let report = scan(fx, catalog: Catalog.loadBuiltin())
        let group = try #require(report.groups.first { $0.binaries.contains { $0.name == "agentx" } })
        #expect(group.version == "1.4.0")
        #expect(group.manualCommands.isEmpty)
        #expect(Set(group.artifacts.map(\.path)) == [entry, store])
        let body = try #require(group.artifacts.first { $0.path == store })
        #expect(body.kind == .program)
        #expect(body.flags.contains(.notRemovable), "家目录之外的程序只列出来，不能移走")
    }

    /// 管理器目录里的入口如果被更具体的规则认出了自己的包（npm 全局包），照旧按包归组。
    @Test func packageEntriesInsideManagerDirectoriesStillGroupByPackage() throws {
        let fx = try Fixture()
        let cli = fx.file(".npm-global/lib/node_modules/agentx/cli.js", "#!/usr/bin/env node\n", executable: true)
        fx.file(".npm-global/lib/node_modules/agentx/package.json", "{\"version\":\"1.4.0\"}")
        fx.link(".npm-global/bin/agentx", to: cli)
        fx.link(".npm-global/bin/ax", to: cli)
        let report = scan(fx, catalog: Catalog.loadBuiltin())
        let group = try #require(report.groups.first { $0.binaries.contains { $0.name == "agentx" } })
        #expect(Set(group.binaries.map(\.name)) == ["agentx", "ax"])
        #expect(group.channel == .npm)
        #expect(group.version == "1.4.0")
        #expect(group.artifacts.contains { $0.path == fx.path(".npm-global/lib/node_modules/agentx") && $0.kind == .program })
    }

    @Test func failedContainingDirectoryMustPreserveLaunchers() throws {
        let fx = try Fixture()
        let program = fx.file(".tool/versions/1.2.3/tool", executable: true)
        let launcher = fx.link(".local/bin/tool", to: program)
        fx.file(".tool/mcp.json")
        let group = try #require(scan(fx).groups(in: .installed).first)
        let plan = UninstallPlanner.plan(group: group, selected: Set(group.artifacts.map(\.path)), env: fx.env())
        let remover = RecordingRemover(failing: [fx.path(".tool")])
        let result = Uninstaller.execute(plan, env: fx.env(), remover: remover)
        print("REVIEW parent failure:", plan.steps.map { "\($0.kind):\($0.path)" }, "trashed:", remover.trashed)
        #expect(result.failures.count >= 1)
        #expect(!remover.trashed.contains(launcher))
    }

    @Test func installedCliMustPreserveNestedAppOwnership() throws {
        let fx = try Fixture()
        fx.app("Antigravity", bundleID: "com.google.antigravity")
        fx.file(".local/bin/gemini", "#!/bin/sh\nexit 0\n", executable: true)
        fx.file(".gemini/antigravity/state.json")
        fx.file(".gemini/settings.json")
        let hit = try #require(find(scan(fx, catalog: Catalog.loadBuiltin()), fx.path(".gemini")))
        let plan = UninstallPlanner.plan(group: hit.group, selected: [hit.artifact.path], env: fx.env())
        print("REVIEW nested app:", hit.artifact.claim, hit.artifact.flags, "warnings:", plan.warnings)
        #expect(hit.artifact.flags.contains(.shared) || hit.artifact.claim == .usedByApp)
        #expect(plan.steps.isEmpty || plan.warnings.contains { $0.contains("Antigravity") })
    }

    @Test func selectableDirectoryMustNotSwallowAppManagedSubdirectory() throws {
        let fx = try Fixture()
        fx.file(".parent/mcp.json")
        fx.file(".parent/app/state.json")
        fx.app("ChildApp", bundleID: "com.example.child")
        let json = """
        {"schemaVersion":1,"products":[
        {"id":"parent","name":"Parent","kind":"cli","binaries":["parent"],
        "paths":[{"path":"~/.parent","kind":"data","exclusive":true}]},
        {"id":"child","name":"Child","kind":"app","bundleIDs":["com.example.child"],
        "paths":[{"path":"~/.parent/app","kind":"data"}]}]}
        """
        let report = scan(fx, catalog: try Catalog.decode(Data(json.utf8)))
        let root = try #require(find(report, fx.path(".parent")))
        let child = try #require(find(report, fx.path(".parent/app")))
        let plan = UninstallPlanner.plan(group: root.group, selected: [root.artifact.path], env: fx.env())
        print("REVIEW cross group:", root.group.id, child.group.id, "default:", root.artifact.defaultSelected, "warnings:", plan.warnings)
        #expect(child.group.section == .managedByApp)
        #expect(plan.steps.isEmpty || !plan.warnings.isEmpty)
    }

    @Test func workingShimWithSpacesMustNotBeClassifiedAsBroken() throws {
        let fx = try Fixture()
        let target = fx.file("Library/Application Support/Tool/agent", executable: true)
        let launcher = fx.file(".local/bin/tool", "#!/bin/sh\nexec \"\(target)\" \"$@\"\n", executable: true)
        let report = scan(fx)
        let hit = try #require(find(report, launcher))
        print("REVIEW quoted shim:", hit.group.section, hit.group.binaries.first?.brokenShimTarget ?? "")
        #expect(hit.group.section != .residue)
        #expect(!hit.artifact.flags.contains(.brokenShim))
    }

    @Test func plannerSkippedProgramMustPreserveLaunchers() throws {
        let fx = try Fixture()
        let program = fx.file(".tool/bin/agent", executable: true)
        let entry = fx.link(".local/bin/tool", to: program)
        var programArtifact = Artifact(path: program, kind: .program, claim: .ownedByCLI, strength: .certain)
        programArtifact.flags = [.rootOwned]
        let entryArtifact = Artifact(path: entry, kind: .launcher, claim: .ownedByCLI, strength: .certain)
        let group = ToolGroup(id: "cli:tool", name: "tool", section: .installed, artifacts: [programArtifact, entryArtifact])
        let plan = UninstallPlanner.plan(group: group, selected: [entry, program], env: fx.env())
        let remover = RecordingRemover()
        _ = Uninstaller.execute(plan, env: fx.env(), remover: remover)
        print("REVIEW skipped program:", plan.skipped.map(\.path), "trashed:", remover.trashed)
        #expect(!remover.trashed.contains(entry))
    }

    @Test func symlinkToDirectoryMustNotBecomeDefaultProgramDeletion() throws {
        let fx = try Fixture()
        let data = fx.dir(".important-data")
        fx.file(".important-data/history.txt")
        fx.link(".local/bin/codex", to: data)
        let group = try #require(scan(fx).groups.first { $0.id == "cli:codex" })
        let plan = UninstallPlanner.plan(group: group, selected: Set(group.artifacts.filter(\.defaultSelected).map(\.path)), env: fx.env())
        print("REVIEW directory target:", plan.steps.map(\.path))
        #expect(!plan.steps.contains { $0.path == data })
    }

    @Test func pipxSharedDataRootMustNotMergeAllEnvironments() throws {
        let fx = try Fixture()
        for name in ["aider", "black"] {
            let target = fx.file(".local/share/pipx/venvs/\(name)/bin/\(name)", executable: true)
            fx.link(".local/bin/" + name, to: target)
        }
        let report = scan(fx, catalog: Catalog.loadBuiltin())
        let aider = try #require(report.groups.first { $0.productID == "aider" })
        let plan = UninstallPlanner.plan(group: aider, selected: Set(aider.artifacts.filter(\.defaultSelected).map(\.path)), env: fx.env())
        print("REVIEW pipx shared root:", aider.binaries.map(\.name), "plan:", plan.steps.map(\.path))
        #expect(!aider.binaries.contains { $0.name == "black" })
        #expect(!plan.steps.contains { $0.path.hasSuffix("/black") })
    }

    @Test func recheckingProcessAtExecutionMustNotUseOldSnapshot() throws {
        let fx = try Fixture()
        let path = fx.path(".tool/bin/sleep")
        fx.dir(".tool/bin")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: path)
        let artifact = Artifact(path: path, kind: .program, claim: .ownedByCLI, strength: .certain)
        let group = ToolGroup(id: "cli:tool", name: "tool", section: .installed, artifacts: [artifact])
        let plan = UninstallPlanner.plan(group: group, selected: [path], env: fx.env())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        #expect(process.isRunning)
        let remover = RecordingRemover()
        let result = Uninstaller.execute(plan, env: fx.env(), remover: remover)
        print("REVIEW late process:", process.processIdentifier, "trashed:", remover.trashed, "failures:", result.failures)
        #expect(remover.trashed.isEmpty)
    }

    @Test func packageNamesInManualCommandsMustBeShellQuoted() throws {
        let fx = try Fixture()
        let package = "evil;printf REVIEW_INJECTED"
        let target = fx.root + "/prefix/lib/node_modules/" + package + "/bin/codex.js"
        try FileManager.default.createDirectory(atPath: PathUtil.parent(target), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
        fx.link(".local/bin/codex", to: target)
        let group = try #require(scan(fx).groups.first { $0.id == "cli:codex" })
        print("REVIEW unsafe manual command:", group.manualCommands)
        #expect(group.manualCommands == ["npm uninstall -g " + UninstallPlanner.shellQuote(package)])
    }
}
