import Foundation
import Testing
@testable import ACMCore

@Suite struct GUISupportTests {

    @Test func terminalScriptPreservesSuccessAndFailureExitCodes() throws {
        let cases: [(command: String, status: Int32, ending: String)] = [
            ("true", 0, "命令已成功结束"),
            ("false", 1, "命令未成功"),
            ("sh -c 'exit 7'", 7, "命令未成功"),
        ]
        for testCase in cases {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("acm-terminal-tests-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let body = TerminalScript.body(for: testCase.command)
            #expect(body.hasPrefix("#!/bin/zsh -l\n"))
            let script = directory.appendingPathComponent("run.zsh")
            try body.write(to: script, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [script.path]
            process.currentDirectoryURL = directory
            process.environment = [
                "HOME": directory.path,
                "ZDOTDIR": directory.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ]
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)

            #expect(process.terminationStatus == testCase.status)
            #expect(output.contains("退出码 \(testCase.status)"))
            #expect(output.contains(testCase.ending))
        }
    }

    @Test func terminalScriptSingleQuotesTheEchoButNotTheCommand() {
        let body = TerminalScript.body(for: "sh -c 'exit 7'")
        #expect(body.contains("sh -c 'exit 7'\nacm_exit_status=$?"))
        #expect(body.contains("'\\''"))
    }

    @Test func undoLedgerMergesBatchesInRestoreOrder() {
        let first = TrashReceipt(original: "/a", trashed: "/trash/a")
        let second = TrashReceipt(original: "/b", trashed: "/trash/b")
        let third = TrashReceipt(original: "/c", trashed: "/trash/c")
        var ledger = UndoLedger()
        ledger.merge([first, second], groupName: "A")
        ledger.merge([third], groupName: "B")

        #expect(ledger.receipts == [first, second, third])
        #expect(ledger.groupName == "A、B")
        #expect(!ledger.isEmpty)
    }

    @Test func undoLedgerRetainsOnlyFailedReceiptsAndTheirGroups() {
        let first = TrashReceipt(original: "/a", trashed: "/trash/a")
        let second = TrashReceipt(original: "/b", trashed: "/trash/b")
        let third = TrashReceipt(original: "/c", trashed: "/trash/c")
        var ledger = UndoLedger()
        ledger.merge([first, second], groupName: "A")
        ledger.merge([third], groupName: "B")

        ledger.retain(remaining: [second])
        #expect(ledger.receipts == [second])
        #expect(ledger.groupName == "A")

        ledger.retain(remaining: [])
        #expect(ledger.isEmpty)
        #expect(ledger.groupName == "")
    }

    @Test func undoLedgerCodingRoundTripAndDismiss() throws {
        let receipt = TrashReceipt(original: "/a", trashed: nil)
        var ledger = UndoLedger(receipts: [receipt], groupName: "工具")
        let data = try JSONEncoder().encode(ledger)
        var decoded = try JSONDecoder().decode(UndoLedger.self, from: data)
        #expect(decoded.receipts == [receipt])
        #expect(decoded.groupName == "工具")

        decoded.dismiss()
        #expect(decoded.isEmpty)
        #expect(decoded.receipts.isEmpty)
        ledger.dismiss()
        #expect(ledger.isEmpty)
    }

    @Test func undoLedgerUsesCountForManyGroups() {
        var ledger = UndoLedger()
        for name in ["A", "B", "C"] {
            ledger.merge([TrashReceipt(original: "/" + name, trashed: "/trash/" + name)], groupName: name)
        }
        #expect(ledger.groupName == "3 个工具")
    }

    @Test func planRecheckOnlyPausesForNewPIDs() {
        let unchanged = PlanRecheck.evaluate(groupName: "X", acknowledgedPIDs: [10, 11], currentPIDs: [11])
        #expect(!unchanged.shouldPause)
        #expect(unchanged.notice == nil)

        let changed = PlanRecheck.evaluate(groupName: "X", acknowledgedPIDs: [10], currentPIDs: [12, 10, 12])
        #expect(changed.shouldPause)
        #expect(changed.newlyRunningPIDs == [12])
        #expect(changed.notice?.contains("X") == true)
        #expect(changed.notice?.contains("PID 12") == true)
        #expect(changed.notice?.contains("重新确认") == true)
    }
}
