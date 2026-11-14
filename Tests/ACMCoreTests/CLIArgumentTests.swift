import Foundation
import Testing
@testable import ACMCore

/// 参数解析的纯逻辑测试：不碰文件系统，不跑子命令。
/// 这里守的是最要紧的一条——`--home` 缺值绝不能被当成「没给」。
@Suite struct CLIArgumentTests {

    private func error(_ args: [String]) -> String? {
        do {
            _ = try CLIArguments.parse(args)
            return nil
        } catch let e as CLIArguments.Error {
            return e.message
        } catch {
            return "其他错误"
        }
    }

    private func usageError(_ args: [String], _ fragment: String) {
        let message = error(args)
        #expect(message != nil, "\(args) 应该报用法错误")
        if let message {
            #expect(message.contains(fragment), "「\(message)」里应包含「\(fragment)」")
        }
    }

    // MARK: 带值选项缺值（R05）

    @Test func homeAtEndOfLineIsAnError() {
        usageError(["scan", "--home"], "--home")
        usageError(["plan", "claude-code", "--home"], "--home")
    }

    @Test func homeFollowedByAnotherFlagIsAnError() {
        // 旧实现会把 --json 摘掉，--home 取不到值就当没给，于是扫描真实家目录。
        usageError(["scan", "--home", "--json"], "--home")
        usageError(["scan", "--home", "--no-processes"], "--home")
        usageError(["plan", "claude-code", "--home", "--execute"], "--home")
        usageError(["plan", "claude-code", "--execute", "--home", "--all"], "--home")
    }

    @Test func homeFollowedByDashPrefixedTokenIsAnError() {
        // 值的位置上是以 - 开头的参数（不是合法路径），必须报错。
        usageError(["--home", "-h"], "--home")
        usageError(["--home", "--verbose", "scan"], "--home")
    }

    @Test func receiptsMissingValueIsAnError() {
        usageError(["plan", "claude-code", "--execute", "--receipts"], "--receipts")
        usageError(["plan", "claude-code", "--receipts", "--execute"], "--receipts")
        usageError(["undo", "--receipts", "--home"], "--receipts")
    }

    @Test func negativeLookingValuesAreRejected() {
        usageError(["scan", "--home", "-x"], "--home")
        usageError(["undo", "--receipts", "-"], "--receipts")
    }

    // MARK: 重复、未知、多余

    @Test func duplicateOptionsAreErrors() {
        usageError(["scan", "--home", "/tmp/a", "--home", "/tmp/b"], "两次")
        usageError(["scan", "--json", "--json"], "两次")
        usageError(["plan", "x", "--execute", "--receipts", "/tmp/a", "--receipts", "/tmp/b"], "两次")
    }

    @Test func unknownOptionIsAnError() {
        usageError(["scan", "--bogus"], "--bogus")
        usageError(["catalog", "--sizes"], "--sizes")
    }

    @Test func unknownSubcommandIsAnError() {
        usageError(["frobnicate"], "frobnicate")
        usageError(["uninstall", "claude"], "uninstall")
    }

    @Test func extraPositionalsAreErrors() {
        usageError(["scan", "extra"], "多余")
        usageError(["plan", "a", "b"], "多余")
        usageError(["catalog", "json"], "多余")
        usageError(["undo", "--receipts", "/tmp/r.json", "extra"], "多余")
    }

    @Test func planRequiresTarget() {
        usageError(["plan"], "组 id")
        usageError(["plan", "--execute"], "组 id")
    }

    // MARK: 每个子命令只接受自己的选项

    @Test func optionsAreScopedToTheirSubcommand() {
        usageError(["undo", "--receipts", "/tmp/r.json", "--all"], "--all")
        usageError(["undo", "--receipts", "/tmp/r.json", "--execute"], "--execute")
        usageError(["undo", "--receipts", "/tmp/r.json", "--json"], "--json")
        usageError(["catalog", "--sizes"], "--sizes")
        usageError(["catalog", "--receipts", "/tmp/r.json"], "--receipts")
        usageError(["scan", "--execute"], "--execute")
        usageError(["scan", "--all"], "--all")
        usageError(["scan", "--receipts", "/tmp/r.json"], "--receipts")
        usageError(["plan", "x", "--json"], "--json")
        usageError(["plan", "x", "--sizes"], "--sizes")
        usageError(["plan", "x", "--no-library"], "--no-library")
        usageError(["undo", "--receipts", "/tmp/r.json", "--no-processes"], "--no-processes")
    }

    @Test func receiptsWithoutExecuteIsAnError() {
        usageError(["plan", "claude-code", "--receipts", "/tmp/r.json"], "--execute")
    }

    @Test func undoRequiresReceipts() {
        usageError(["undo"], "--receipts")
    }

    // MARK: 合法组合

    @Test func scanCombinations() throws {
        let bare = try CLIArguments.parse([])
        #expect(bare.command == .scan(json: false, sizes: false, verbose: false))
        #expect(bare.home == nil)
        #expect(!bare.noLibrary && !bare.noProcesses)

        let full = try CLIArguments.parse([
            "scan", "--json", "--sizes", "--verbose", "--no-library", "--no-processes", "--home", "/tmp/fake",
        ])
        #expect(full.command == .scan(json: true, sizes: true, verbose: true))
        #expect(full.home == "/tmp/fake")
        #expect(full.noLibrary && full.noProcesses)

        // 选项写在子命令前面也算数
        let reordered = try CLIArguments.parse(["--home", "/tmp/fake", "scan", "--json"])
        #expect(reordered.command == .scan(json: true, sizes: false, verbose: false))
        #expect(reordered.home == "/tmp/fake")
    }

    @Test func planCombinations() throws {
        let dry = try CLIArguments.parse(["plan", "Qoder CLI"])
        #expect(dry.command == .plan(target: "Qoder CLI", all: false, execute: false, receipts: nil))

        let run = try CLIArguments.parse([
            "plan", "claude-code", "--all", "--execute", "--receipts", "/tmp/r.json",
            "--no-processes", "--home", "/tmp/fake",
        ])
        #expect(run.command == .plan(
            target: "claude-code", all: true, execute: true, receipts: "/tmp/r.json"
        ))
        #expect(run.home == "/tmp/fake")
        #expect(run.noProcesses)

        // 执行但不写回执是允许的（命令行会提示只能手工放回）
        let noReceipts = try CLIArguments.parse(["plan", "codex", "--execute"])
        #expect(noReceipts.command == .plan(target: "codex", all: false, execute: true, receipts: nil))
    }

    @Test func undoAndCatalogCombinations() throws {
        let undo = try CLIArguments.parse(["undo", "--receipts", "/tmp/r.json"])
        #expect(undo.command == .undo(receipts: "/tmp/r.json"))

        let undoHome = try CLIArguments.parse(["undo", "--receipts", "/tmp/r.json", "--home", "/tmp/fake"])
        #expect(undoHome.command == .undo(receipts: "/tmp/r.json"))
        #expect(undoHome.home == "/tmp/fake")

        #expect(try CLIArguments.parse(["catalog"]).command == .catalog(json: false))
        #expect(try CLIArguments.parse(["catalog", "--json"]).command == .catalog(json: true))
    }

    @Test func helpCombinations() throws {
        #expect(try CLIArguments.parse(["--help"]).command == .help)
        #expect(try CLIArguments.parse(["-h"]).command == .help)
        #expect(try CLIArguments.parse(["scan", "--help"]).command == .help)
        #expect(try CLIArguments.parse(["plan", "x", "-h"]).command == .help)
        // 请求帮助时不校验 --home 是否真的存在
        #expect(try CLIArguments.parse(["scan", "--home", "/tmp/whatever", "--help"]).command == .help)
        // 但缺值、未知选项这类错误仍然要报
        usageError(["scan", "--home", "--help"], "--home")
        usageError(["scan", "--bogus", "--help"], "--bogus")
    }
}
