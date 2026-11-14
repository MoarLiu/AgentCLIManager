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
