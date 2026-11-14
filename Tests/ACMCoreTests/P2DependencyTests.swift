import Foundation
import Testing
@testable import ACMCore

@Suite struct P2DependencyTests {
    @Test func programTypedLauncherDirectoryWaitsForActualProgram() throws {
        let fx = try Fixture()
        let program = fx.file(".grok/downloads/grok-1.0.0", executable: true)
        let middle = fx.link(".grok/bin/grok", to: program)
        let entry = fx.link(".local/bin/grok", to: middle)
        let group = try #require(scan(fx, catalog: Catalog.loadBuiltin()).groups.first { $0.id == "cli:grok-cli" })
        let selected = Set(group.artifacts.filter(\.defaultSelected).map(\.path))
        let plan = UninstallPlanner.plan(group: group, selected: selected, env: fx.env())
        let downloads = fx.path(".grok/downloads")
        let bin = fx.path(".grok/bin")
        let binStep = try #require(plan.steps.first { $0.path == bin })
        #expect(binStep.kind == .program)
        #expect(binStep.dependsOn.contains(downloads))
        let programIndex = try #require(plan.steps.firstIndex { $0.path == downloads })
        let binIndex = try #require(plan.steps.firstIndex { $0.path == bin })
        #expect(programIndex < binIndex)
        let remover = RecordingRemover(failing: [downloads])
        _ = Uninstaller.execute(plan, env: fx.env(), remover: remover, processProbe: nil)
        #expect(!remover.trashed.contains(bin))
        #expect(!remover.trashed.contains(entry))
    }

    private func tool(_ fx: Fixture) throws -> (ToolGroup, String, String) {
        let program = fx.file(".tool/bin/agent", executable: true)
        let entry = fx.link(".local/bin/tool", to: program)
        let parent = Artifact(path: fx.path(".tool"), kind: .data,
                              claim: .ownedByCLI, strength: .certain, isDirectory: true)
        let body = Artifact(path: program, kind: .program, claim: .ownedByCLI, strength: .certain)
        let launcher = Artifact(path: entry, kind: .launcher, claim: .ownedByCLI, strength: .certain)
        return (ToolGroup(id: "cli:tool", name: "Tool", section: .installed,
                          artifacts: [parent, body, launcher]), program, entry)
    }

    @Test func rejectedContainingDirectoryBlocksExternalLauncher() throws {
        let fx = try Fixture()
        var (group, _, entry) = try tool(fx)
        group.artifacts[0].flags.insert(.rootOwned)
        let parent = group.artifacts[0].path
        // 程序叶子没被显式勾选，但选中的父目录本来要把它一起移走。
        let plan = UninstallPlanner.plan(group: group, selected: [parent, entry], env: fx.env())
        #expect(plan.steps.isEmpty)
        #expect(plan.skipped.contains { $0.path == entry })
        let remover = RecordingRemover()
        _ = Uninstaller.execute(plan, env: fx.env(), remover: remover, processProbe: nil)
        #expect(remover.trashed.isEmpty)
    }

    @Test func explicitSafeProgramCanStillMoveDespiteRejectedBroaderDirectory() throws {
        let fx = try Fixture()
        var (group, program, entry) = try tool(fx)
        group.artifacts[0].flags.insert(.rootOwned)
        let plan = UninstallPlanner.plan(group: group,
                                        selected: [group.artifacts[0].path, program, entry], env: fx.env())
        #expect(plan.steps.map(\.path) == [program, entry])
        #expect(plan.steps.last?.dependsOn.contains(program) == true)
    }

    @Test func intermediateLauncherFailureAlsoPreservesOuterEntry() throws {
        let fx = try Fixture()
        let program = fx.file(".tool/versions/1.0.0/tool", executable: true)
        let middle = fx.link(".tool/current", to: program)
        let entry = fx.link(".local/bin/tool", to: middle)
        fx.file(".tool/mcp.json")
        let group = try #require(scan(fx).groups(in: .installed).first)
        let plan = UninstallPlanner.plan(group: group, selected: [program, middle, entry], env: fx.env())
        let remover = RecordingRemover(failing: [middle])
        _ = Uninstaller.execute(plan, env: fx.env(), remover: remover, processProbe: nil)
        #expect(remover.trashed == [program])
        #expect(plan.steps.first { $0.path == entry }?.dependsOn.contains(middle) == true)
    }

    @Test func executorRequiresDependencySuccessRatherThanAbsenceOfFailure() throws {
        let fx = try Fixture()
        let program = fx.file(".tool/program", executable: true)
        let entry = fx.link(".local/bin/tool", to: program)
        // 模拟顺序错误的旧/外部计划：依赖项还没执行，也不能先移走入口。
        let plan = UninstallPlan(groupID: "cli:tool", groupName: "Tool", steps: [
            PlanStep(path: entry, kind: .launcher, isDirectory: false, dependsOn: [program]),
            PlanStep(path: program, kind: .program, isDirectory: false)
        ], skipped: [], manualCommands: [], warnings: [], reclaimable: nil)
        let remover = RecordingRemover()
        let result = Uninstaller.execute(plan, env: fx.env(), remover: remover, processProbe: nil)
        #expect(remover.trashed == [program])
        #expect(result.failures.contains { $0.path == entry })
    }

    @Test func launcherAloneDoesNotRequireUnselectedProgram() throws {
        let fx = try Fixture()
        let (group, _, entry) = try tool(fx)
        let plan = UninstallPlanner.plan(group: group, selected: [entry], env: fx.env())
        #expect(plan.steps.map(\.path) == [entry])
        #expect(plan.steps[0].dependsOn.isEmpty)
    }

    @Test func directoryContainingWholeChainHasNoSelfDependency() throws {
        let fx = try Fixture()
        let program = fx.file(".tool/program", executable: true)
        fx.link(".tool/bin/tool", to: program)
        fx.file(".tool/mcp.json")
        let group = try #require(scan(fx).groups(in: .installed).first)
        let plan = UninstallPlanner.plan(group: group, selected: [fx.path(".tool")], env: fx.env())
        #expect(plan.steps.map(\.path) == [fx.path(".tool")])
        #expect(plan.steps[0].dependsOn.isEmpty)
    }

    @Test func cyclicDirectoryDependenciesAreSkippedWithoutBlockingIndependentCache() throws {
        let fx = try Fixture()
        let leftProgram = fx.file(".left/program", executable: true)
        let rightProgram = fx.file(".right/program", executable: true)
        let leftEntry = fx.link(".left/launch", to: rightProgram)
        let rightEntry = fx.link(".right/launch", to: leftProgram)
        fx.link(".local/bin/alpha", to: leftEntry)
        fx.link(".local/bin/beta", to: rightEntry)
        fx.file(".cache/multi/item")
        let catalog = try Catalog.decode(Data("""
        {"schemaVersion":1,"products":[
          {"id":"multi","name":"Multi","kind":"cli","binaries":["alpha","beta"],
           "paths":[{"path":"~/.left","kind":"program"},
                    {"path":"~/.right","kind":"program"},
                    {"path":"~/.cache/multi","kind":"cache"}]}]}
        """.utf8))
        let group = try #require(scan(fx, catalog: catalog).groups.first { $0.id == "cli:multi" })
        let selected: Set<String> = [fx.path(".left"), fx.path(".right"), fx.path(".cache/multi")]
        let plan = UninstallPlanner.plan(group: group, selected: selected, env: fx.env())
        #expect(plan.steps.map(\.path) == [fx.path(".cache/multi")])
        #expect(plan.skipped.contains { $0.path == fx.path(".left") })
        #expect(plan.skipped.contains { $0.path == fx.path(".right") })
    }

    @Test func invalidDirectoryTargetCannotExposeSelectableChildren() throws {
        let fx = try Fixture()
        let data = fx.dir(".important-data")
        fx.file(".important-data/history.txt")
        fx.link(".local/bin/codex", to: data)
        let hit = try #require(find(scan(fx), data))
        #expect(hit.artifact.flags.contains(.invalidLauncher))
        #expect(!hit.artifact.expandable)
        #expect(ToolScanner.children(of: hit.artifact, in: hit.group, env: fx.env()).isEmpty)
        // 即使调用方持有旧的 expandable 状态，也不能生成可清理的子项。
        var stale = hit.artifact
        stale.expandable = true
        #expect(ToolScanner.children(of: stale, in: hit.group, env: fx.env()).isEmpty)
    }
}
