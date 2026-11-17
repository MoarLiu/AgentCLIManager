import Foundation
import Testing
@testable import ACMCore

/// `acm sweep` 的参数解析：纯逻辑，不碰文件系统。
@Suite struct SweepArgumentTests {

    private func sweep(_ args: [String]) throws -> SweepArguments {
        guard case .sweep(let parsed) = try CLIArguments.parse(args).command else {
            throw CLIArguments.Error("解析出来的不是 sweep")
        }
        return parsed
    }

    private func usageError(_ args: [String], _ fragment: String) {
        do {
            _ = try CLIArguments.parse(args)
            Issue.record("\(args) 应该报用法错误")
        } catch let error as CLIArguments.Error {
            #expect(error.message.contains(fragment), "「\(error.message)」里应包含「\(fragment)」")
        } catch {
            Issue.record("\(args) 抛出了其他错误")
        }
    }

    @Test func scanDefaults() throws {
        let parsed = try sweep(["sweep", "scan", "~/Downloads"])
        #expect(parsed.command == .scan(root: "~/Downloads", out: nil, idleHours: 24, maxEntries: 500_000, excludes: []))
        #expect(!parsed.json)
        #expect(parsed.home == nil)
    }

    @Test func scanOptionsInAnyOrder() throws {
        let parsed = try sweep([
            "--json", "sweep", "scan", "--exclude", "a", "--idle-hours", "0", "dir",
            "--out", "plan.json", "--exclude", "b", "--max-entries", "1000", "--home", "/fake",
        ])
        #expect(parsed.command == .scan(root: "dir", out: "plan.json", idleHours: 0, maxEntries: 1000, excludes: ["a", "b"]))
        #expect(parsed.json)
        #expect(parsed.home == "/fake")
        #expect(try CLIArguments.parse(["--home", "/fake", "sweep", "scan", "dir"]).home == "/fake")
    }

    @Test func itemsAndInspect() throws {
        #expect(try sweep(["sweep", "items", "plan.json"]).command
            == .items(plan: "plan.json", status: nil, limit: 50, offset: 0))
        #expect(try sweep(["sweep", "items", "plan.json", "--status", "cleanup", "--limit", "20", "--offset", "40"]).command
            == .items(plan: "plan.json", status: .cleanup, limit: 20, offset: 40))
        #expect(try sweep(["sweep", "inspect", "plan.json", "abc123"]).command
            == .inspect(plan: "plan.json", item: "abc123"))
        // 负数能进到引擎里，由它报「不能小于零」。
        #expect(try sweep(["sweep", "items", "plan.json", "--offset", "-1"]).command
            == .items(plan: "plan.json", status: nil, limit: 50, offset: -1))
    }

    @Test func helpDoesNotNeedValidArguments() throws {
        #expect(try CLIArguments.parse(["sweep", "--help"]).command == .help)
        #expect(try CLIArguments.parse(["sweep", "scan", "-h"]).command == .help)
    }

    @Test func missingOrUnknownSubcommand() {
        usageError(["sweep"], "子命令")
        usageError(["sweep", "--json"], "子命令")
        usageError(["sweep", "purge", "dir"], "purge")
        usageError(["sweep", "delete", "plan.json"], "delete")
    }

    @Test func applyDefaultsToRehearsalInTrashMode() throws {
        #expect(try sweep(["sweep", "apply", "plan.json"]).command
            == .apply(plan: "plan.json", ids: [], execute: false, permanent: false, includeOldVersions: false))
        let full = try sweep([
            "sweep", "--id", "aaaa", "apply", "--execute", "plan.json", "--id", "bbbb", "--permanent", "--json",
            "--home", "/tmp/h",
        ])
        #expect(full.command
            == .apply(plan: "plan.json", ids: ["aaaa", "bbbb"], execute: true, permanent: true, includeOldVersions: false))
        #expect(full.json)
        #expect(full.home == "/tmp/h")
        #expect(try sweep(["sweep", "apply", "plan.json", "--include-old-versions"]).command
            == .apply(plan: "plan.json", ids: [], execute: false, permanent: false, includeOldVersions: true))
    }

    @Test func restoreDefaultsToRehearsal() throws {
        #expect(try sweep(["sweep", "restore", "run.jsonl"]).command == .restore(receipt: "run.jsonl", execute: false))
        #expect(try sweep(["sweep", "restore", "--execute", "run.jsonl"]).command
            == .restore(receipt: "run.jsonl", execute: true))
    }

    @Test func applyAndRestoreUsageErrors() {
        usageError(["sweep", "apply"], "计划文件")
        usageError(["sweep", "apply", "a", "b"], "多余")
        usageError(["sweep", "restore"], "回执")
        usageError(["sweep", "restore", "a", "b"], "多余")
        usageError(["sweep", "apply", "plan.json", "--id"], "--id")
        usageError(["sweep", "apply", "plan.json", "--id", "--execute"], "--id")
        usageError(["sweep", "apply", "plan.json", "--execute", "--execute"], "两次")
        usageError(["sweep", "apply", "plan.json", "--id", "a", "--include-old-versions"], "不能同时")
        // 永久删除只属于 apply；放回没有「永久」一说，也不能点名。
        usageError(["sweep", "restore", "run.jsonl", "--permanent"], "--permanent")
        usageError(["sweep", "restore", "run.jsonl", "--id", "a"], "--id")
        usageError(["sweep", "restore", "run.jsonl", "--include-old-versions"], "--include-old-versions")
        usageError(["sweep", "apply", "plan.json", "--out", "x"], "--out")
        usageError(["sweep", "apply", "plan.json", "--force"], "--force")
    }

    @Test func positionalCounts() {
        usageError(["sweep", "scan"], "目录")
        usageError(["sweep", "scan", "a", "b"], "多余")
        usageError(["sweep", "items"], "计划文件")
        usageError(["sweep", "inspect", "plan.json"], "项目")
        usageError(["sweep", "inspect", "plan.json", "a", "b"], "多余")
    }

    @Test func valueOptionsNeedValues() {
        usageError(["sweep", "scan", "dir", "--out"], "--out")
        usageError(["sweep", "scan", "dir", "--out", "--json"], "--out")
        usageError(["sweep", "scan", "dir", "--exclude", "--out", "x"], "--exclude")
        usageError(["sweep", "scan", "dir", "--idle-hours"], "--idle-hours")
        usageError(["sweep", "scan", "dir", "--idle-hours", "soon"], "--idle-hours")
        usageError(["sweep", "scan", "dir", "--max-entries", "1.5"], "--max-entries")
        usageError(["sweep", "items", "plan.json", "--limit", "many"], "--limit")
        usageError(["sweep", "items", "plan.json", "--status", "deleted"], "--status")
        // 和其他子命令一样：--home 缺值绝不能当成没给。
        usageError(["sweep", "scan", "dir", "--home"], "--home")
        usageError(["sweep", "scan", "dir", "--home", "--json"], "--home")
    }

    @Test func duplicatesAndForeignOptions() {
        usageError(["sweep", "scan", "dir", "--out", "a", "--out", "b"], "两次")
        usageError(["sweep", "scan", "dir", "--json", "--json"], "两次")
        usageError(["sweep", "scan", "dir", "--status", "cleanup"], "--status")
        usageError(["sweep", "items", "plan.json", "--out", "x"], "--out")
        usageError(["sweep", "inspect", "plan.json", "id", "--limit", "5"], "--limit")
        // 会动文件的开关只属于 apply / restore；只读子命令不认。
        usageError(["sweep", "scan", "dir", "--execute"], "--execute")
        usageError(["sweep", "scan", "dir", "--permanent"], "--permanent")
        usageError(["sweep", "items", "plan.json", "--execute"], "--execute")
        usageError(["sweep", "inspect", "plan.json", "id", "--id", "x"], "--id")
    }

    @Test func usageErrorsRememberJSONMode() {
        func error(_ args: [String]) -> CLIArguments.Error? {
            do { _ = try CLIArguments.parse(args); return nil } catch { return error as? CLIArguments.Error }
        }
        #expect(error(["sweep", "scan", "--json"])?.sweepJSON == true)
        #expect(error(["sweep", "scan"])?.sweepJSON == false)
        // 其他子命令的用法错误照旧写到 stderr。
        #expect(error(["plan", "--json"])?.sweepJSON == false)
    }

    @Test func otherCommandsAreUnaffected() throws {
        #expect(try CLIArguments.parse(["scan", "--json"]).command == .scan(json: true, sizes: false, verbose: false))
        // 「sweep」作为别的命令的参数时不是子命令。
        #expect(try CLIArguments.parse(["plan", "sweep"]).command
            == .plan(target: "sweep", all: false, execute: false, receipts: nil))
        #expect(try CLIArguments.parse(["--home", "sweep", "scan"]).home == "sweep")
    }
}
