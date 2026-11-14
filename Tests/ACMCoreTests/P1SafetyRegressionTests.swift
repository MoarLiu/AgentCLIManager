import Foundation
import Testing
@testable import ACMCore

/// 复审发现的四项 P1：既检查保护生效，也检查没有过度阻止合法操作。
/// 只使用假家目录和 RecordingRemover，不调用真实废纸篓。
@Suite struct P1SafetyRegressionTests {
    @Test func selectedProtectedChildBlocksContainingDirectory() throws {
        let fx = try Fixture()
        let childPath = fx.file(".parent/bin/agent", executable: true)
        let parent = Artifact(path: fx.path(".parent"), kind: .data,
                              claim: .ownedByCLI, strength: .certain, isDirectory: true)
        var child = Artifact(path: childPath, kind: .program, claim: .ownedByCLI, strength: .certain)
        child.flags = [.rootOwned]
        let group = ToolGroup(id: "cli:test", name: "Test", section: .installed,
                              artifacts: [parent, child])

        let plan = UninstallPlanner.plan(group: group, selected: [parent.path, child.path], env: fx.env())
        #expect(plan.steps.isEmpty)
        #expect(Set(plan.skipped.map(\.path)) == [parent.path, child.path])
        #expect(plan.skipped.contains { $0.path == parent.path && $0.reason.contains("agent") })
        let remover = RecordingRemover()
        _ = Uninstaller.execute(plan, env: fx.env(), remover: remover, processProbe: nil)
        #expect(remover.trashed.isEmpty)
    }

    @Test func implicitProtectedDescendantBlocksEverySelectedAncestor() throws {
        let fx = try Fixture()
        let childPath = fx.file(".parent/nested/keep.txt")
        let safePath = fx.file(".safe/cache.txt")
        let parent = Artifact(path: fx.path(".parent"), kind: .data,
                              claim: .ownedByCLI, strength: .certain, isDirectory: true)
        let middle = Artifact(path: fx.path(".parent/nested"), kind: .data,
                              claim: .ownedByCLI, strength: .certain, isDirectory: true)
        let safe = Artifact(path: safePath, kind: .cache, claim: .ownedByCLI, strength: .certain)
        for flag in [ArtifactFlag.rootOwned, .invalidLauncher, .notRemovable] {
            var child = Artifact(path: childPath, kind: .other, claim: .ownedByCLI, strength: .certain)
            child.flags = [flag]
            child.notRemovableReason = "保留这个子项"
            // 反序排列，确保不依赖先访问父项还是子项；子项本身未被勾选。
            let group = ToolGroup(id: "cli:test", name: "Test", section: .installed,
                                  artifacts: [child, middle, safe, parent])
            let plan = UninstallPlanner.plan(group: group,
                                            selected: [parent.path, middle.path, safe.path], env: fx.env())
            #expect(plan.steps.map(\.path) == [safePath], "\(flag) 必须约束所有覆盖它的目录")
            #expect(plan.skipped.contains { $0.path == parent.path })
            #expect(plan.skipped.contains { $0.path == middle.path })
        }
    }

    @Test func absentProtectedDescendantDoesNotBlockExistingParent() throws {
        let fx = try Fixture()
        let parent = Artifact(path: fx.dir(".parent"), kind: .data,
                              claim: .ownedByCLI, strength: .certain, isDirectory: true)
        var missing = Artifact(path: fx.path(".parent/gone"), kind: .other,
                               claim: .ownedByCLI, strength: .certain)
        missing.flags = [.invalidLauncher]
        let group = ToolGroup(id: "cli:test", name: "Test", section: .installed, artifacts: [parent, missing])
        let plan = UninstallPlanner.plan(group: group, selected: [parent.path], env: fx.env())
        #expect(plan.steps.map(\.path) == [parent.path])
    }

    @Test func credentialsStillWarnInsteadOfBlockingExplicitParentSelection() throws {
        let fx = try Fixture()
        let path = fx.file(".parent/auth.json")
        let parent = Artifact(path: fx.path(".parent"), kind: .data,
                              claim: .ownedByCLI, strength: .certain, isDirectory: true)
        let credentials = Artifact(path: path, kind: .credentials, claim: .ownedByCLI,
                                   strength: .certain, flags: [.credentials])
        let group = ToolGroup(id: "cli:test", name: "Test", section: .installed,
                              artifacts: [parent, credentials])
        let plan = UninstallPlanner.plan(group: group, selected: [parent.path], env: fx.env())
        #expect(plan.steps.map(\.path) == [parent.path])
        #expect(plan.warnings.contains { $0.contains("auth.json") })
    }

    @Test func sharedProgramProtectionSurvivesDirectoryPruning() throws {
        let fx = try Fixture()
        let program = fx.file(".suite/bin/dispatch", "#!/bin/sh\nexit 0\n", executable: true)
        fx.file(".suite/config/settings.json")
        fx.link(".local/bin/alpha", to: program)
        fx.link(".local/bin/beta", to: program)
        let catalog = try Catalog.decode(Data("""
        {"schemaVersion":1,"products":[
          {"id":"alpha","name":"Alpha","kind":"cli","binaries":["alpha"],"paths":[
            {"path":"~/.suite/bin","kind":"program"},
            {"path":"~/.suite/config","kind":"config"}]},
          {"id":"beta","name":"Beta","kind":"cli","binaries":["beta"]}
        ]}
        """.utf8))
        let report = scan(fx, catalog: catalog)
        let alpha = try #require(report.groups.first { $0.id == "cli:alpha" })
        let directory = try #require(alpha.artifacts.first { $0.path == fx.path(".suite/bin") })
        #expect(!alpha.artifacts.contains { $0.path == program }, "同类叶子已经被折叠")
        #expect(directory.flags.contains(.usedByOthers))
        #expect(directory.alsoUsedBy.contains("beta"))
        #expect(!directory.defaultSelected)
        let defaults = UninstallPlanner.plan(
            group: alpha, selected: Set(alpha.artifacts.filter(\.defaultSelected).map(\.path)), env: fx.env())
        #expect(!defaults.steps.contains { $0.path == directory.path })
        let explicit = UninstallPlanner.plan(group: alpha, selected: [directory.path], env: fx.env())
        #expect(explicit.warnings.contains { $0.contains("beta") })
        let sibling = try #require(alpha.artifacts.first { $0.path == fx.path(".suite/config") })
        #expect(!sibling.flags.contains(.usedByOthers), "同一厂商根目录不等于共享每个子目录")
    }

    private func appCatalog(exclusivePath: String? = nil) throws -> Catalog {
        let paths = exclusivePath.map {
            ",\"paths\":[{\"path\":\"\($0)\",\"kind\":\"program\",\"exclusive\":true}]"
        } ?? ""
        return try Catalog.decode(Data("""
        {"schemaVersion":1,"products":[
          {"id":"alpha","name":"Alpha","kind":"cli","binaries":["alpha"]\(paths)},
          {"id":"owner","name":"OwnerDesk","kind":"app","bundleIDs":["com.example.owner"],
           "paths":[{"path":"~/.suite/app","kind":"data"}]}
        ]}
        """.utf8))
    }

    @Test func appOwnedAncestorProtectsBinaryDerivedChild() throws {
        let fx = try Fixture()
        fx.app("OwnerDesk", bundleID: "com.example.owner")
        let program = fx.file(".suite/app/bin/agent", executable: true)
        fx.link(".local/bin/alpha", to: program)
        let report = scan(fx, catalog: try appCatalog())
        let group = try #require(report.groups.first { $0.id == "cli:alpha" })
        let child = try #require(group.artifacts.first { $0.path == program })
        #expect(child.flags.contains(.notRemovable))
        #expect(child.ownerAppName == "OwnerDesk")
        #expect(!child.defaultSelected)
        let plan = UninstallPlanner.plan(group: group, selected: [program], env: fx.env())
        #expect(plan.steps.isEmpty)
        #expect(plan.skipped.contains { $0.reason.contains("OwnerDesk") })
    }

    @Test func explicitExclusiveSubpathRemainsRemovableInsideAppRoot() throws {
        let fx = try Fixture()
        fx.app("OwnerDesk", bundleID: "com.example.owner")
        let program = fx.file(".suite/app/cli/agent", executable: true)
        fx.link(".local/bin/alpha", to: program)
        let report = scan(fx, catalog: try appCatalog(exclusivePath: "~/.suite/app/cli"))
        let group = try #require(report.groups.first { $0.id == "cli:alpha" })
        let cli = try #require(group.artifacts.first { $0.path == fx.path(".suite/app/cli") })
        #expect(cli.defaultSelected)
        #expect(!cli.flags.contains(.notRemovable))
        let plan = UninstallPlanner.plan(group: group, selected: [cli.path], env: fx.env())
        #expect(plan.steps.map(\.path) == [cli.path])
        #expect(find(report, fx.path(".suite/app"))?.group.section == .managedByApp)
    }

    @Test func broadExclusiveDeclarationDoesNotOverrideMoreSpecificAppOwner() throws {
        let fx = try Fixture()
        fx.app("OwnerDesk", bundleID: "com.example.owner")
        let program = fx.file(".suite/app/bin/agent", executable: true)
        fx.link(".local/bin/alpha", to: program)
        let report = scan(fx, catalog: try appCatalog(exclusivePath: "~/.suite"))
        let group = try #require(report.groups.first { $0.id == "cli:alpha" })
        let plan = UninstallPlanner.plan(group: group,
                                        selected: Set(group.artifacts.map(\.path)), env: fx.env())
        #expect(!plan.steps.contains { PathUtil.isInside(program, $0.path) })
    }

    @Test func appProtectedProgramDirectoryStaysProtectedWhenExpanded() throws {
        let fx = try Fixture()
        fx.app("OwnerDesk", bundleID: "com.example.owner")
        let program = fx.file(".suite/app/lib/node_modules/pkg/bin/agent", executable: true)
        fx.link(".local/bin/alpha", to: program)
        let report = scan(fx, catalog: try appCatalog())
        var group = try #require(report.groups.first { $0.id == "cli:alpha" })
        let package = try #require(group.artifacts.first { $0.path.hasSuffix("node_modules/pkg") })
        let children = ToolScanner.children(of: package, in: group, env: fx.env())
        #expect(!children.isEmpty)
        group.artifacts += children
        let plan = UninstallPlanner.plan(group: group, selected: Set(children.map(\.path)), env: fx.env())
        #expect(plan.steps.isEmpty)
    }

    @Test func sharedVendorRootDoesNotWeakenCertainAppChildProtection() throws {
        let fx = try Fixture()
        fx.app("OwnerDesk", bundleID: "com.example.owner")
        fx.app("SuiteDesktop", bundleID: "com.example.suite")
        let program = fx.file(".suite/app/lib/node_modules/pkg/bin/agent", executable: true)
        fx.link(".local/bin/alpha", to: program)
        let catalog = try Catalog.decode(Data("""
        {"schemaVersion":1,"products":[
          {"id":"alpha","name":"Alpha","kind":"cli","binaries":["alpha"],
           "companionApps":["com.example.suite"],
           "paths":[{"path":"~/.suite","kind":"data","shared":true}]},
          {"id":"owner","name":"OwnerDesk","kind":"app","bundleIDs":["com.example.owner"],
           "paths":[{"path":"~/.suite/app","kind":"data"}]}
        ]}
        """.utf8))
        let report = scan(fx, catalog: catalog)
        var group = try #require(report.groups.first { $0.id == "cli:alpha" })
        let package = try #require(group.artifacts.first { $0.path.hasSuffix("node_modules/pkg") })
        #expect(package.claim == .usedByApp)
        #expect(package.ownerAppName == "OwnerDesk")
        let children = ToolScanner.children(of: package, in: group, env: fx.env())
        #expect(!children.isEmpty)
        group.artifacts += children
        let plan = UninstallPlanner.plan(group: group, selected: Set(children.map(\.path)), env: fx.env())
        #expect(plan.steps.isEmpty)
    }

    @Test func dynamicExecWithMissingFallbackIsNotBroken() throws {
        let fx = try Fixture()
        let valid = fx.file(".payload/agent", "#!/bin/sh\nexit 0\n", executable: true)
        let missing = fx.path(".gone/fallback")
        let launcher = fx.file(".local/bin/tool", """
        #!/bin/sh
        TOOL_BIN="\(valid)"
        if [ -x "$TOOL_BIN" ]; then
          exec "$TOOL_BIN" "$@"
        else
          exec "\(missing)" "$@"
        fi
        """, executable: true)
        let hit = try #require(find(scan(fx), launcher))
        #expect(hit.group.section != .residue)
        #expect(!hit.artifact.flags.contains(.brokenShim))
        #expect(!hit.artifact.defaultSelected)
    }

    @Test func unresolvedPathCommandDoesNotProveShimBroken() throws {
        let fx = try Fixture()
        let launcher = fx.file(".local/bin/tool", """
        #!/bin/sh
        if command -v sh >/dev/null; then
          exec sh "$@"
        else
          exec "\(fx.path(".gone/fallback"))" "$@"
        fi
        """, executable: true)
        #expect(BinaryRegistry.shimInfo(launcher, home: fx.home)?.missingTarget == nil)
    }

    @Test func inlineExecBranchIsNotIgnoredWhenFallbackIsMissing() throws {
        let fx = try Fixture()
        let valid = fx.file(".payload/agent", executable: true)
        let launcher = fx.file(".local/bin/tool", """
        #!/bin/sh
        TOOL_BIN="\(valid)"
        if [ -x "$TOOL_BIN" ]; then exec "$TOOL_BIN" "$@"; fi
        exec "\(fx.path(".gone/fallback"))" "$@"
        """, executable: true)
        #expect(BinaryRegistry.shimInfo(launcher, home: fx.home)?.missingTarget == nil)
        #expect(find(scan(fx), launcher)?.group.section != .residue)
    }

    @Test func execTextInsideHereDocumentIsNotAnExecutableStatement() throws {
        let fx = try Fixture()
        let launcher = fx.file(".local/bin/tool", """
        #!/bin/sh
        cat <<'MESSAGE'
        exec "\(fx.path(".gone/example"))"
        MESSAGE
        """, executable: true)
        #expect(BinaryRegistry.shimInfo(launcher, home: fx.home)?.missingTarget == nil)
    }

    @Test func commentsDoNotHideSimpleMissingLiteralExec() throws {
        let fx = try Fixture()
        let missing = fx.path(".gone/agent")
        let launcher = fx.file(".local/bin/tool", """
        #!/bin/sh
        # 一个直接启动脚本

        exec "\(missing)" "$@"
        # 没有其他控制流
        """, executable: true)
        #expect(BinaryRegistry.shimInfo(launcher, home: fx.home)?.missingTarget == missing)
    }

    @Test func simpleMissingLiteralExecIsStillDetected() throws {
        let fx = try Fixture()
        let missing = fx.path(".gone/agent")
        let launcher = fx.file(".local/bin/tool", "#!/bin/sh\nexec \"\(missing)\" \"$@\"\n", executable: true)
        #expect(BinaryRegistry.shimInfo(launcher, home: fx.home)?.missingTarget == missing)
        #expect(find(scan(fx), launcher)?.artifact.flags.contains(.brokenShim) == true)
    }
}
