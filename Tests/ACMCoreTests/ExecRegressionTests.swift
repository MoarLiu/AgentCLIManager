import Foundation
import Testing
@testable import ACMCore

@Suite struct ExecRegressionTests {

    // MARK: - R07：程序没移走时不能移走入

    @Test func failedContainingDirectoryMustPreserveLaunchers() throws {
        let fx = try Fixture()
        let program = fx.file(".tool/versions/1.2.3/tool", executable: true)
        let launcher = fx.link(".local/bin/tool", to: program)
        fx.file(".tool/mcp.json")
        let group = try #require(scan(fx).groups(in: .installed).first)
        let plan = UninstallPlanner.plan(group: group, selected: Set(group.artifacts.map(\.path)), env: fx.env())

        let parentStep = try #require(plan.steps.first { $0.path == fx.path(".tool") })
        #expect(parentStep.containsProgram)
        #expect(plan.steps.first { $0.path == launcher }?.dependsOn == [fx.path(".tool")])

        let remover = RecordingRemover(failing: [fx.path(".tool")])
        let result = Uninstaller.execute(plan, env: fx.env(), remover: remover)
        #expect(result.failures.count >= 1)
        #expect(!remover.trashed.contains(launcher))
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
        #expect(!plan.steps.contains { $0.path == entry })
        #expect(plan.skipped.contains { $0.path == program })
        #expect(plan.skipped.contains { $0.path == entry && $0.reason.contains("保留入口") })

        let remover = RecordingRemover()
        _ = Uninstaller.execute(plan, env: fx.env(), remover: remover, processProbe: nil)
        #expect(!remover.trashed.contains(entry))
    }

    @Test func launcherAloneCanStillBeMoved() throws {
        let fx = try Fixture()
        let program = fx.file(".tool/bin/agent", executable: true)
        let entry = fx.link(".local/bin/tool", to: program)
        let programArtifact = Artifact(path: program, kind: .program, claim: .ownedByCLI, strength: .certain)
        let entryArtifact = Artifact(path: entry, kind: .launcher, claim: .ownedByCLI, strength: .certain)
        let group = ToolGroup(id: "cli:tool", name: "tool", section: .installed, artifacts: [programArtifact, entryArtifact])

        let plan = UninstallPlanner.plan(group: group, selected: [entry], env: fx.env())
        #expect(plan.steps.map(\.path) == [entry])
        #expect(plan.steps[0].dependsOn.isEmpty)
        let remover = RecordingRemover()
        let result = Uninstaller.execute(plan, env: fx.env(), remover: remover, processProbe: nil)
        #expect(result.succeeded)
        #expect(remover.trashed == [entry])
    }

    // MARK: - R08：确认之后新启动的进程必须阻止执行

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
        #expect(remover.trashed.isEmpty)
        #expect(result.failures.count == plan.steps.count)
        #expect(result.newlyRunningPIDs.contains(process.processIdentifier))
        #expect(result.failures.allSatisfy { $0.reason.contains("确认之后被启动") })
    }

    @Test func acknowledgedPIDAllowsExecutionAndLatePIDBlocksIt() throws {
        let fx = try Fixture()
        let path = fx.file(".tool/bin/agent", executable: true)
        let artifact = Artifact(path: path, kind: .program, claim: .ownedByCLI, strength: .certain)
        let group = ToolGroup(
            id: "cli:tool", name: "tool", section: .installed,
            artifacts: [artifact], runningPIDs: [4101]
        )
        let plan = UninstallPlanner.plan(group: group, selected: [path], env: fx.env())
        #expect(plan.watchPaths == [path])
        #expect(plan.acknowledgedPIDs == [4101])
        #expect(plan.warnings.contains { $0.contains("4101") })

        let acknowledged = RecordingRemover()
        let first = Uninstaller.execute(plan, env: fx.env(), remover: acknowledged, processProbe: {
            [RunningProcess(pid: 4101, executable: path)]
        })
        #expect(first.succeeded)
        #expect(acknowledged.trashed == [path])

        let late = RecordingRemover()
        let second = Uninstaller.execute(plan, env: fx.env(), remover: late, processProbe: {
            [
                RunningProcess(pid: 4101, executable: path),
                RunningProcess(pid: 4102, executable: path),
            ]
        })
        #expect(late.trashed.isEmpty)
        #expect(second.newlyRunningPIDs == [4102])
        #expect(second.failures.count == 1)
    }

    // MARK: - R03：跨组与桌面 App 的嵌套数据

    @Test func selectableDirectoryMustNotSwallowAppManagedSubdirectory() throws {
        let fx = try Fixture()
        fx.file(".parent/mcp.json")
        let appData = fx.file(".parent/app/state.json")
        var root = Artifact(
            path: fx.path(".parent"), kind: .data, claim: .residue, strength: .certain, isDirectory: true
        )
        root.foreignChildren = [
            ForeignChild(path: PathUtil.parent(appData), owner: "ChildApp", usedByApp: true, certain: true)
        ]
        let group = ToolGroup(id: "residue:parent", name: "Parent", section: .residue, artifacts: [root])

        let plan = UninstallPlanner.plan(group: group, selected: [root.path], env: fx.env())
        #expect(plan.steps.isEmpty)
        #expect(plan.skipped.count == 1)
        #expect(plan.skipped[0].reason.contains(PathUtil.display(PathUtil.parent(appData), home: fx.home)))
        #expect(plan.skipped[0].reason.contains("ChildApp"))
        #expect(plan.skipped[0].reason.contains("展开"))
    }

    @Test func installedCliMustPreserveNestedAppOwnership() throws {
        let fx = try Fixture()
        fx.file(".gemini/settings.json")
        let appData = fx.dir(".gemini/antigravity")
        var root = Artifact(
            path: fx.path(".gemini"), kind: .data, claim: .ownedByCLI, strength: .certain, isDirectory: true
        )
        root.foreignChildren = [
            ForeignChild(path: appData, owner: "Antigravity", usedByApp: true, certain: true)
        ]
        let group = ToolGroup(id: "cli:gemini", name: "Gemini", section: .installed, artifacts: [root])

        let plan = UninstallPlanner.plan(group: group, selected: [root.path], env: fx.env())
        #expect(plan.steps.isEmpty)
        #expect(plan.skipped.contains { $0.path == root.path && $0.reason.contains("Antigravity") })
    }

    @Test func nonBlockingForeignChildrenProduceOwnershipWarnings() throws {
        let fx = try Fixture()
        let other = fx.dir(".parent/other-tool")
        var root = Artifact(
            path: fx.path(".parent"), kind: .data, claim: .residue, strength: .certain, isDirectory: true
        )
        root.foreignChildren = [
            ForeignChild(path: other, owner: "OtherTool", usedByApp: false, certain: true)
        ]
        let group = ToolGroup(id: "residue:parent", name: "Parent", section: .residue, artifacts: [root])

        let plan = UninstallPlanner.plan(group: group, selected: [root.path], env: fx.env())
        #expect(plan.steps.map(\.path) == [root.path])
        #expect(plan.warnings.contains {
            $0.contains(PathUtil.display(other, home: fx.home)) && $0.contains("OtherTool")
        })
    }

    @Test func expandedChildrenInheritForeignOwnershipProtection() throws {
        let fx = try Fixture()
        let parentPath = fx.dir(".parent")
        let appRoot = fx.dir(".parent/app")
        let blockedPath = fx.file(".parent/app/state.json")
        let warnedPath = fx.file(".parent/other/state.json")
        var parent = Artifact(path: parentPath, kind: .data, claim: .ownedByCLI, strength: .certain, isDirectory: true)
        parent.foreignChildren = [
            ForeignChild(path: appRoot, owner: "ChildApp", usedByApp: true, certain: true),
            ForeignChild(path: PathUtil.parent(warnedPath), owner: "OtherTool", usedByApp: false, certain: false),
        ]
        var blocked = Artifact(path: blockedPath, kind: .data, claim: .ownedByCLI, strength: .certain)
        blocked.parentPath = parentPath
        var warned = Artifact(path: warnedPath, kind: .data, claim: .ownedByCLI, strength: .certain)
        warned.parentPath = parentPath
        let group = ToolGroup(
            id: "cli:parent", name: "Parent", section: .installed, artifacts: [parent, blocked, warned]
        )

        let plan = UninstallPlanner.plan(group: group, selected: [blockedPath, warnedPath], env: fx.env())
        #expect(!plan.steps.contains { $0.path == blockedPath })
        #expect(plan.skipped.contains { $0.path == blockedPath && $0.reason.contains("ChildApp") })
        #expect(plan.steps.map(\.path) == [warnedPath])
        #expect(plan.warnings.contains {
            $0.contains(PathUtil.display(warnedPath, home: fx.home)) && $0.contains("OtherTool")
        })
    }

    @Test func sharedProgramAndInvalidLauncherAreHandledExplicitly() throws {
        let fx = try Fixture()
        let sharedPath = fx.file(".tool/bin/agent", executable: true)
        var shared = Artifact(path: sharedPath, kind: .program, claim: .ownedByCLI, strength: .certain)
        shared.flags = [.usedByOthers]
        shared.alsoUsedBy = ["other", "helper"]
        let sharedGroup = ToolGroup(id: "cli:tool", name: "tool", section: .installed, artifacts: [shared])
        let sharedPlan = UninstallPlanner.plan(group: sharedGroup, selected: [sharedPath], env: fx.env())
        #expect(sharedPlan.warnings.contains { $0.contains("other、helper") && $0.contains("会失效") })

        let invalidPath = fx.link(".local/bin/invalid", to: fx.dir(".important-data"))
        var invalid = Artifact(path: invalidPath, kind: .launcher, claim: .ownedByCLI, strength: .certain)
        invalid.flags = [.invalidLauncher]
        let validPath = fx.link(".local/bin/valid", to: fx.path(".important-data"))
        let valid = Artifact(path: validPath, kind: .launcher, claim: .ownedByCLI, strength: .certain)
        let invalidGroup = ToolGroup(id: "cli:invalid", name: "invalid", section: .installed, artifacts: [invalid, valid])
        let invalidPlan = UninstallPlanner.plan(group: invalidGroup, selected: [invalidPath, validPath], env: fx.env())
        #expect(invalidPlan.steps.map(\.path) == [validPath])
        #expect(invalidPlan.skipped.contains {
            $0.path == invalidPath && $0.reason == "入口指向的不是可执行程序，未将其作为卸载目标"
        })
    }

    // MARK: - R06：回执是不可信输入

    @Test func restoreRejectsSourceOutsideTrash() throws {
        let fx = try Fixture()
        let source = fx.file(".tool/not-in-trash")
        let original = fx.path(".tool/restored")
        let receipt = TrashReceipt(original: original, trashed: source)
        let remover = RecordingRemover()

        let result = Uninstaller.restore([receipt], env: fx.env(trashDirs: [fx.root + "/trash"]), remover: remover)
        #expect(result.restored.isEmpty)
        #expect(result.failures.count == 1)
        #expect(result.remaining == [receipt])
        #expect(remover.restored.isEmpty)
        #expect(FileProbe.exists(source))
    }

    @Test func restoreRejectsTargetsOutsideHomeAndInsideSSH() throws {
        let fx = try Fixture()
        let trash = fx.root + "/trash"
        let env = fx.env(trashDirs: [trash])
        let receipts = [
            TrashReceipt(original: fx.root + "/outside/restored", trashed: trash + "/one"),
            TrashReceipt(original: fx.path(".ssh/id_ed25519"), trashed: trash + "/two"),
        ]
        let remover = RecordingRemover()

        let result = Uninstaller.restore(receipts, env: env, remover: remover)
        #expect(result.restored.isEmpty)
        #expect(result.failures.count == 2)
        #expect(result.remaining == receipts)
        #expect(remover.restored.isEmpty)
    }

    @Test func restoreRejectsRelativeAndDotDotSources() throws {
        let fx = try Fixture()
        let trash = fx.root + "/trash"
        let receipts = [
            TrashReceipt(original: fx.path(".tool/one"), trashed: "relative/item"),
            TrashReceipt(original: fx.path(".tool/two"), trashed: trash + "/../outside"),
        ]
        let remover = RecordingRemover()
        let result = Uninstaller.restore(receipts, env: fx.env(trashDirs: [trash]), remover: remover)
        #expect(result.failures.count == 2)
        #expect(result.remaining == receipts)
        #expect(remover.restored.isEmpty)
    }

    @Test func restoreRejectsTrashParentSymlinkEscape() throws {
        let fx = try Fixture()
        let trash = fx.root + "/trash"
        let outside = fx.root + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        let source = outside + "/important"
        FileManager.default.createFile(atPath: source, contents: Data("keep".utf8))
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: trash + "/escape", withDestinationPath: outside)
        let receipt = TrashReceipt(original: fx.path(".tool/restored"), trashed: trash + "/escape/important")
        let remover = MoveRemover(trashDir: trash)

        let result = Uninstaller.restore([receipt], env: fx.env(trashDirs: [trash]), remover: remover)
        #expect(result.restored.isEmpty)
        #expect(result.remaining == [receipt])
        #expect(FileProbe.exists(source))
        #expect(!FileProbe.exists(receipt.original))
    }

    @Test func restoreRejectsMismatchedFileID() throws {
        let fx = try Fixture()
        let trash = fx.root + "/trash"
        let remover = MoveRemover(trashDir: trash)
        let original = fx.file(".tool/item")
        let actualID = try #require(FileProbe.lstat(original)?.fileID)
        let trashed = try #require(try remover.trash(original))
        let receipt = TrashReceipt(original: original, trashed: trashed, fileID: actualID + 1)

        let result = Uninstaller.restore([receipt], env: fx.env(trashDirs: [trash]), remover: remover)
        #expect(result.restored.isEmpty)
        #expect(result.remaining == [receipt])
        #expect(result.failures.contains { $0.reason.contains("inode") })
        #expect(FileProbe.exists(trashed))
        #expect(!FileProbe.exists(original))
    }

    @Test func partialRestoreKeepsOnlyFailedReceiptsInRemaining() throws {
        let fx = try Fixture()
        let trash = fx.root + "/trash"
        let remover = MoveRemover(trashDir: trash)
        let firstOriginal = fx.file(".tool/first", "first")
        let secondOriginal = fx.file(".tool/second", "second")
        let firstID = FileProbe.lstat(firstOriginal)?.fileID
        let secondID = FileProbe.lstat(secondOriginal)?.fileID
        let first = TrashReceipt(original: firstOriginal, trashed: try remover.trash(firstOriginal), fileID: firstID)
        let second = TrashReceipt(original: secondOriginal, trashed: try remover.trash(secondOriginal), fileID: secondID)
        // 第二项的原位置被重建，放回会失败；第一项仍应成功。
        fx.file(".tool/second", "new")

        let result = Uninstaller.restore([first, second], env: fx.env(trashDirs: [trash]), remover: remover)
        #expect(result.restored == [firstOriginal])
        #expect(result.failures.map(\.path) == [secondOriginal])
        #expect(result.remaining == [second])
        #expect(FileProbe.readText(firstOriginal) == "first")
        #expect(FileProbe.readText(secondOriginal) == "new")
        #expect(FileProbe.exists(second.trashed ?? ""))
    }

    @Test func legacyPlanStepAndReceiptStillDecode() throws {
        let stepJSON = #"{"path":"/h/.tool/bin/tool","kind":"program","isDirectory":false}"#
        let step = try JSONDecoder().decode(PlanStep.self, from: Data(stepJSON.utf8))
        #expect(!step.containsProgram)
        #expect(step.dependsOn.isEmpty)

        let planJSON = #"{"groupID":"cli:tool","groupName":"tool","steps":[],"skipped":[],"manualCommands":[],"warnings":[]}"#
        let plan = try JSONDecoder().decode(UninstallPlan.self, from: Data(planJSON.utf8))
        #expect(!plan.token.isEmpty)
        #expect(plan.watchPaths.isEmpty)
        #expect(plan.acknowledgedPIDs.isEmpty)

        let receiptJSON = #"{"original":"/h/.tool/item","trashed":"/h/.Trash/item"}"#
        let receipt = try JSONDecoder().decode(TrashReceipt.self, from: Data(receiptJSON.utf8))
        #expect(receipt.fileID == nil)
    }
}
