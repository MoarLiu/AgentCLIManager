import Foundation
import Testing
@testable import ACMCore

/// 计划文件的存取，以及 `items` / `inspect` 和 JSON 输出的形状。
@Suite struct SweepPlanTests {

    private func planFile(_ ws: SweepWorkspace, _ name: String = "plan.json") -> String {
        ws.fx.root + "/" + name
    }

    private func rewrite(_ path: String, _ change: (inout [String: Any]) -> Void) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: path))
    }

    @Test func planRoundTrips() throws {
        let ws = try SweepWorkspace()
        ws.swiftProject()
        ws.package("Product-1.0.0-arm64.dmg")
        ws.package("Product-1.1.0-rc.1-arm64.dmg")
        let plan = try ws.scan()
        let path = try SweepPlanStore.write(plan, to: planFile(ws))
        #expect(try SweepPlanStore.read(path, env: ws.env()) == plan)

        // 只有自己能读写。
        let mode = try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
    }

    @Test func tamperedPlanIsRejected() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let plan = try ws.scan()

        // 把扫描根改成别处。
        let rerooted = try SweepPlanStore.write(plan, to: planFile(ws, "rerooted.json"))
        try rewrite(rerooted) { $0["root"] = "/" }
        #expect(sweepErrorCode { _ = try SweepPlanStore.read(rerooted, env: ws.env()) } == "invalid_plan")

        // 把一个被保护的条目改成可清理。
        ws.dir(cache + "/checkouts/Dependency/.git")
        let blocked = try ws.scan()
        #expect(blocked.item(cache)?.status == .blocked)
        let promoted = try SweepPlanStore.write(blocked, to: planFile(ws, "promoted.json"))
        try rewrite(promoted) { object in
            var items = object["items"] as! [[String: Any]]
            items[0]["status"] = "cleanup"
            object["items"] = items
        }
        #expect(sweepErrorCode { _ = try SweepPlanStore.read(promoted, env: ws.env()) } == "invalid_plan")

        // 不是 JSON、是软链、文件不存在。
        let garbage = planFile(ws, "garbage.json")
        FileManager.default.createFile(atPath: garbage, contents: Data("not json".utf8))
        #expect(sweepErrorCode { _ = try SweepPlanStore.read(garbage, env: ws.env()) } == "invalid_plan")
        let alias = planFile(ws, "alias.json")
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: rerooted)
        #expect(sweepErrorCode { _ = try SweepPlanStore.read(alias, env: ws.env()) } == "invalid_plan")
        #expect(sweepErrorCode { _ = try SweepPlanStore.read(planFile(ws, "missing.json"), env: ws.env()) } == "io_error")
    }

    @Test func planWhoseRootIsGoneIsRejected() throws {
        let ws = try SweepWorkspace()
        ws.swiftProject("Project")
        let plan = try SweepScanner.scan(root: ws.path("Project"), env: ws.env(), probes: SweepWorkspace.quiet)
        let path = try SweepPlanStore.write(plan, to: planFile(ws))
        try FileManager.default.removeItem(atPath: ws.path("Project"))
        #expect(sweepErrorCode { _ = try SweepPlanStore.read(path, env: ws.env()) } == "invalid_root")
    }

    @Test func writingNeverOverwrites() throws {
        let ws = try SweepWorkspace()
        ws.swiftProject()
        let plan = try ws.scan()

        let existing = planFile(ws)
        FileManager.default.createFile(atPath: existing, contents: Data("original".utf8))
        #expect(sweepErrorCode { try SweepPlanStore.write(plan, to: existing) } == "plan_exists")
        #expect(try String(contentsOfFile: existing, encoding: .utf8) == "original")

        // 悬空软链也算占着位置：不能顺着它把文件写到别处去。
        let alias = planFile(ws, "alias.json")
        let target = planFile(ws, "elsewhere.json")
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: target)
        #expect(sweepErrorCode { try SweepPlanStore.write(plan, to: alias) } == "plan_exists")
        #expect(!FileManager.default.fileExists(atPath: target))

        #expect(sweepErrorCode { try SweepPlanStore.write(plan, to: "relative.json") } == "unsafe_plan_path")
    }

    @Test func planCannotLiveInsideSomethingItWouldRemove() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject()
        let plan = try ws.scan()
        #expect(sweepErrorCode { try SweepPlanStore.write(plan, to: ws.path(cache + "/plan.json")) } == "unsafe_plan_path")
        #expect(!FileManager.default.fileExists(atPath: ws.path(cache + "/plan.json")))
        // 经过软链绕进去也不行。
        ws.fx.link("shortcut", to: ws.path(cache))
        #expect(sweepErrorCode { try SweepPlanStore.write(plan, to: ws.fx.path("shortcut/plan.json")) } == "unsafe_plan_path")
    }

    // MARK: items / inspect

    @Test func itemsArePagedAndFiltered() throws {
        let ws = try SweepWorkspace()
        for name in ["A", "B", "C"] { ws.swiftProject(name) }
        ws.file("D/.build/notes.txt")
        let plan = try ws.scan()

        let first = try SweepPage(plan: plan, status: nil, limit: 2, offset: 0)
        #expect(first.total == 4)
        #expect(first.items.map(\.path) == ["A/.build", "B/.build"])
        #expect(first.nextOffset == 2)
        let last = try SweepPage(plan: plan, status: nil, limit: 2, offset: 2)
        #expect(last.items.map(\.path) == ["C/.build", "D/.build"])
        #expect(last.nextOffset == nil)
        #expect(try SweepPage(plan: plan, status: nil, limit: 10, offset: 99).items.isEmpty)

        let review = try SweepPage(plan: plan, status: .review, limit: 50, offset: 0)
        #expect(review.items.map(\.path) == ["D/.build"])
        #expect(review.total == 1)

        for (limit, offset) in [(0, 0), (1001, 0), (10, -1)] {
            #expect(sweepErrorCode {
                _ = try SweepPage(plan: plan, status: nil, limit: limit, offset: offset)
            } == "invalid_pagination")
        }
    }

    @Test func inspectFindsByIdentifierOrPath() throws {
        let ws = try SweepWorkspace()
        let cache = ws.swiftProject("App")
        let plan = try ws.scan()
        let item = try #require(plan.item(cache))
        #expect(try plan.item(matching: item.id) == item)
        #expect(try plan.item(matching: cache) == item)
        #expect(sweepErrorCode { _ = try plan.item(matching: "App") } == "unknown_item")
        #expect(sweepErrorCode { _ = try plan.item(matching: "") } == "unknown_item")
    }

    // MARK: 输出

    @Test func jsonKeepsTheReferenceShape() throws {
        let ws = try SweepWorkspace()
        ws.swiftProject("App")
        ws.package("Product-1.0.0-arm64.dmg")
        let plan = try ws.scan()

        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(SweepOutput.json(plan).utf8)) as? [String: Any]
        )
        #expect(envelope["ok"] as? Bool == true)
        #expect(envelope["schema_version"] as? Int == 1)
        let data = try #require(envelope["data"] as? [String: Any])
        #expect(Set(data.keys) == [
            "schema_version", "tool_version", "root", "root_identity", "created_at",
            "policy", "items", "summary", "warnings",
        ])
        #expect((data["root_identity"] as? [Any])?.count == 2)
        #expect(Set((data["summary"] as? [String: Any] ?? [:]).keys) == [
            "cleanup", "keep", "review", "blocked", "estimated_cleanup_bytes",
        ])
        #expect(Set((data["policy"] as? [String: Any] ?? [:]).keys) == ["idle_hours", "max_entries", "excludes"])

        let items = try #require(data["items"] as? [[String: Any]])
        let cache = try #require(items.first { $0["path"] as? String == "App/.build" })
        #expect(Set(cache.keys) == [
            "id", "path", "parent", "project", "category", "status", "reason", "retained_ids", "snapshot",
        ])
        #expect(Set((cache["snapshot"] as? [String: Any] ?? [:]).keys) == [
            "digest", "device", "inode", "entries", "allocated_bytes", "latest_mtime_ns", "kind",
        ])
        // 没有所属项目时这个键仍然在，值是 null。
        let installer = try #require(items.first { $0["category"] as? String == "installer" })
        #expect(installer["project"] is NSNull)
        #expect((installer["snapshot"] as? [String: Any])?["content_sha256"] is String)
        #expect(Set((installer["installer"] as? [String: Any] ?? [:]).keys) == [
            "recognized", "version", "product", "architecture", "format",
        ])
    }

    @Test func errorsAndPagesUseTheSameEnvelope() throws {
        let failure = try #require(try JSONSerialization.jsonObject(
            with: Data(SweepOutput.json(SweepError("invalid_plan", "请重新扫描。")).utf8)
        ) as? [String: Any])
        #expect(failure["ok"] as? Bool == false)
        let detail = try #require(failure["error"] as? [String: Any])
        #expect(detail["code"] as? String == "invalid_plan")
        #expect(detail["message"] as? String == "请重新扫描。")
        #expect(detail["details"] is [String: Any])

        let ws = try SweepWorkspace()
        ws.swiftProject()
        let page = try SweepPage(plan: try ws.scan(), status: nil, limit: 50, offset: 0)
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(SweepOutput.json(page).utf8)) as? [String: Any]
        )
        let data = try #require(envelope["data"] as? [String: Any])
        #expect(data["total"] as? Int == 1)
        #expect(data["next_offset"] is NSNull)
    }

    @Test func textOutputKeepsOddFileNamesOnOneLine() throws {
        let ws = try SweepWorkspace()
        ws.file("odd\nname/Package.swift", "")
        ws.dir("odd\nname/.build/artifacts")
        ws.file("odd\nname/.build/workspace-state.json", "{}")
        let plan = try ws.scan()
        let text = SweepOutput.text(plan)
        #expect(text.contains(#""odd\nname/.build""#))
        #expect(text.contains("可清理 1 项"))
        #expect(SweepOutput.text(try #require(plan.items.first)).contains("指纹"))
    }
}
