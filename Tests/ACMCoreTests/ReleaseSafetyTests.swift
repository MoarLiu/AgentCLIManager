import Foundation
import Testing
@testable import ACMCore

@Suite struct ReleaseSafetyTests {
    @Test func uncataloguedVendorRootWarnsAboutNestedApp() throws {
        let fx = try Fixture()
        fx.app("Antigravity", bundleID: "com.google.antigravity")
        let program = fx.file(".someagent/bin/someagent", executable: true)
        fx.link(".local/bin/someagent", to: program)
        fx.file(".someagent/mcp.json")
        fx.file(".someagent/Antigravity/state.json")

        let root = try #require(find(scan(fx), fx.path(".someagent")))
        #expect(root.artifact.flags.contains(.shared))
        #expect(!root.artifact.defaultSelected)
        #expect(root.artifact.ownerAppName == "Antigravity")
        let plan = UninstallPlanner.plan(
            group: root.group, selected: Set(root.group.artifacts.map(\.path)), env: fx.env()
        )
        #expect(plan.warnings.contains { $0.contains("Antigravity") })
    }

    @Test func uncataloguedResidueWithNestedAppIsProtected() throws {
        let fx = try Fixture()
        fx.app("Antigravity", bundleID: "com.google.antigravity")
        fx.file(".someagent/mcp.json")
        fx.file(".someagent/Antigravity/state.json")

        let root = try #require(find(scan(fx), fx.path(".someagent")))
        #expect(root.group.section == .managedByApp)
        #expect(root.artifact.strength == .probable)
        #expect(!root.artifact.defaultSelected)
        let plan = UninstallPlanner.plan(group: root.group, selected: [root.artifact.path], env: fx.env())
        #expect(plan.steps.isEmpty)
    }

    @Test func nestedAppCheckPreservesIndependentCliSelection() throws {
        let fx = try Fixture()
        fx.app("Antigravity", bundleID: "com.google.antigravity")
        let program = fx.file(".someagent/bin/someagent", executable: true)
        fx.link(".local/bin/someagent", to: program)
        fx.file(".someagent/mcp.json")
        fx.file(".someagent/settings.json")

        let root = try #require(find(scan(fx), fx.path(".someagent")))
        #expect(!root.artifact.flags.contains(.shared))
        let plan = UninstallPlanner.plan(group: root.group, selected: [root.artifact.path], env: fx.env())
        #expect(plan.steps.map(\.path) == [root.artifact.path])
    }

    @Test func selectedCredentialStillWarnsWhenFoldedIntoParent() throws {
        let fx = try Fixture()
        let binary = fx.file(".grok/downloads/grok-1.0.0", executable: true)
        fx.link(".local/bin/grok", to: binary)
        fx.file(".grok/auth.json", "{}")
        let group = try #require(scan(fx).groups(in: .installed).first)
        let plan = UninstallPlanner.plan(
            group: group, selected: Set(group.artifacts.map(\.path)), env: fx.env()
        )
        #expect(plan.steps.contains { $0.path == fx.path(".grok") })
        #expect(plan.warnings.contains { $0.contains("auth.json") && $0.contains("Time Machine") })
    }
}
