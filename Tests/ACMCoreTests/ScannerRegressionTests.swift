import Foundation
import Testing
@testable import ACMCore

/// 扫描器的边界用例：共享运行时、shell 取词和跨组目录关系。
@Suite struct ScannerRegressionTests {
    @Test func execTargetUnderstandsQuotesEscapesAndHome() {
        #expect(BinaryRegistry.execTarget("\"/Library/Application Support/Tool/agent\" \"$@\"", home: "/h")
            == "/Library/Application Support/Tool/agent")
        #expect(BinaryRegistry.execTarget("'/Library/Application Support/Tool/agent'", home: "/h")
            == "/Library/Application Support/Tool/agent")
        #expect(BinaryRegistry.execTarget("$HOME/.tool/bin/agent", home: "/h") == "/h/.tool/bin/agent")
        #expect(BinaryRegistry.execTarget("${HOME}/.tool/bin/agent", home: "/h") == "/h/.tool/bin/agent")
        #expect(BinaryRegistry.execTarget("/tmp/a\\ b/agent", home: "/h") == "/tmp/a b/agent")
        #expect(BinaryRegistry.execTarget("-a agent \"/tmp/a b\"", home: "/h") == "/tmp/a b")
    }

    @Test func execTargetRefusesToGuessDynamicPaths() {
        #expect(BinaryRegistry.execTarget("$TOOL/bin/agent", home: "/h") == nil)
        #expect(BinaryRegistry.execTarget("$(dirname \"$0\")/agent", home: "/h") == nil)
        #expect(BinaryRegistry.execTarget("\"/tmp/unterminated", home: "/h") == nil)
        #expect(BinaryRegistry.execTarget("relative/agent", home: "/h") == nil)
    }

    @Test func conditionalShimWithOneMissingTargetIsNotBroken() throws {
        let fx = try Fixture()
        let present = fx.file("Library/Application Support/Tool/agent", executable: true)
        let missing = fx.path("Library/Application Support/Gone/agent")
        let launcher = fx.file(".local/bin/tool", """
        #!/bin/sh
        if [ -x "\(present)" ]; then
          exec "\(present)" "$@"
        else
          exec "\(missing)" "$@"
        fi
        """, executable: true)
        let report = scan(fx)
        let hit = try #require(find(report, launcher))
        #expect(hit.group.section != .residue)
        #expect(!hit.artifact.flags.contains(.brokenShim))
    }

    @Test func managerDirectoryItselfIsNotAnArtifactOfOneCommand() throws {
        let fx = try Fixture()
        for name in ["codex", "node", "npm", "yarn"] {
            fx.file(".volta/bin/" + name, "#!/bin/sh\nexit 0\n", executable: true)
        }
        let report = scan(fx, catalog: Catalog.loadBuiltin())
        let codex = try #require(report.groups.first { $0.id == "cli:codex" })
        #expect(!codex.artifacts.contains { $0.path == fx.path(".volta") })
        #expect(!codex.artifacts.contains { $0.path == fx.path(".volta/bin") })
        #expect(report.groups.contains { $0.binaries.contains { $0.name == "node" } })
    }

    @Test func expandedChildKeepsForeignAppProtection() throws {
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
        let parent = try #require(find(report, fx.path(".parent")))
        #expect(parent.artifact.foreignChildren.contains { $0.usedByApp && $0.blocksRemoval })
        let children = ToolScanner.children(of: parent.artifact, in: parent.group, env: fx.env())
        let app = try #require(children.first { $0.path == fx.path(".parent/app") })
        #expect(app.foreignChildren.contains { $0.usedByApp })
    }

    @Test func shellQuoteKeepsUnsafePackageAsData() {
        #expect(ShellText.quote("evil;printf REVIEW_INJECTED") == "'evil;printf REVIEW_INJECTED'")
        #expect(ShellText.quote("@openai/codex") == "@openai/codex")
        #expect(ShellText.quote("a'b") == "'a'\\''b'")
    }
}
