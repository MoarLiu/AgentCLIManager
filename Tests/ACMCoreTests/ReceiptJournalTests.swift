import Darwin
import Foundation
import Testing
@testable import ACMCore

@Suite struct ReceiptJournalTests {
    private func temporaryDirectory(_ body: (String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acm-receipt-tests-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try body(root)
    }

    private let receipts = [TrashReceipt(original: "/fake/.local/bin/tool", trashed: "/fake/.Trash/tool", fileID: 42)]

    @Test func refusesExistingReceiptsIncludingEmptyArrays() throws {
        try temporaryDirectory { root in
            for content in ["[]", "[{\"original\":\"old\"}]", "unrelated document"] {
                let path = root + "/r.json"
                try Data(content.utf8).write(to: URL(fileURLWithPath: path))
                #expect(throws: (any Error).self) { _ = try ReceiptJournal(reserving: path) }
                #expect(try String(contentsOfFile: path, encoding: .utf8) == content)
            }
        }
    }

    @Test func refusesDirectoriesAndAllSymlinks() throws {
        try temporaryDirectory { root in
            let directory = root + "/directory"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { _ = try ReceiptJournal(reserving: directory) }
            let original = root + "/original"
            try Data("untouched".utf8).write(to: URL(fileURLWithPath: original))
            for target in [original, root + "/absent"] {
                let link = root + "/link-" + UUID().uuidString
                try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
                #expect(throws: (any Error).self) { _ = try ReceiptJournal(reserving: link) }
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == target)
            }
            #expect(try String(contentsOfFile: original, encoding: .utf8) == "untouched")
            #expect(!FileManager.default.fileExists(atPath: root + "/absent"))
        }
    }

    @Test func immutableActualTargetIsRejectedBeforeExecution() throws {
        try temporaryDirectory { root in
            let path = root + "/locked.json"
            let data = try ReceiptJournal.encode(receipts)
            try data.write(to: URL(fileURLWithPath: path))
            #expect(chflags(path, UInt32(UF_IMMUTABLE)) == 0)
            defer { _ = chflags(path, 0) }
            let remover = RecordingRemover()
            do {
                _ = try ReceiptJournal(reserving: path)
                _ = try remover.trash(root + "/fake-tool")
                Issue.record("锁定目标不应允许开始移动")
            } catch {}
            #expect(remover.trashed.isEmpty)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)
        }
    }

    @Test func newPathCommitsOnceAndUndoSavesRemainingAtomically() throws {
        try temporaryDirectory { root in
            let path = root + "/new.json"
            let journal = try ReceiptJournal(reserving: path)
            #expect(journal.path.hasPrefix("/"))
            #expect(try JSONDecoder().decode([TrashReceipt].self, from: Data(contentsOf: URL(fileURLWithPath: path))).isEmpty)
            try journal.commit(receipts)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == ReceiptJournal.encode(receipts))
            #expect(throws: ReceiptJournal.CommitError.self) { try journal.commit([]) }
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == ReceiptJournal.encode(receipts))
            try ReceiptJournal.saveRemaining([], to: path)
            #expect(try JSONDecoder().decode([TrashReceipt].self, from: Data(contentsOf: URL(fileURLWithPath: path))).isEmpty)
        }
    }

    @Test func reservationFailurePreventsExecution() throws {
        try temporaryDirectory { root in
            let remover = RecordingRemover()
            do {
                _ = try ReceiptJournal(reserving: root + "/failed.json", write: { _, _, _, _ in
                    errno = ENOSPC
                    return -1
                })
                _ = try remover.trash(root + "/fake-tool")
                Issue.record("预留写入失败不应允许开始移动")
            } catch {}
            #expect(remover.trashed.isEmpty)
        }
    }

    @Test func shortWritesAndInterruptionsAreRetried() throws {
        try temporaryDirectory { root in
            var calls = 0
            let path = root + "/short.json"
            let journal = try ReceiptJournal(reserving: path, write: { fd, bytes, count, offset in
                calls += 1
                if calls == 1 { errno = EINTR; return -1 }
                return pwrite(fd, bytes, min(count, 2), offset)
            })
            try journal.commit(receipts)
            #expect(calls > 3)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == ReceiptJournal.encode(receipts))
        }
    }

    @Test func partialWriteFailureCarriesCompleteRecoveryJSON() throws {
        try temporaryDirectory { root in
            var failWrites = false
            let path = root + "/partial.json"
            let journal = try ReceiptJournal(reserving: path, write: { fd, bytes, count, offset in
                if failWrites && offset > 0 { errno = ENOSPC; return -1 }
                return pwrite(fd, bytes, failWrites ? min(count, 8) : count, offset)
            })
            failWrites = true
            do {
                try journal.commit(receipts)
                Issue.record("模拟磁盘写满应失败")
            } catch let error as ReceiptJournal.CommitError {
                #expect(try JSONDecoder().decode([TrashReceipt].self, from: error.recoveryJSON) == receipts)
                #expect(try Data(contentsOf: URL(fileURLWithPath: path)) != error.recoveryJSON)
            }
            failWrites = false
            try journal.commit(receipts)
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == ReceiptJournal.encode(receipts))
        }
    }

    @Test func changedPathBeforeCommitIsNeverOverwritten() throws {
        try temporaryDirectory { root in
            let path = root + "/race.json"
            let journal = try ReceiptJournal(reserving: path)
            try FileManager.default.moveItem(atPath: path, toPath: root + "/reserved.json")
            try Data("concurrent file".utf8).write(to: URL(fileURLWithPath: path))
            do {
                try journal.commit(receipts)
                Issue.record("替换后的路径必须拒绝提交")
            } catch let error as ReceiptJournal.CommitError {
                #expect(try JSONDecoder().decode([TrashReceipt].self, from: error.recoveryJSON) == receipts)
            }
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "concurrent file")
        }
    }

    @Test func replacementDuringWriteDoesNotReceiveReceiptBytes() throws {
        try temporaryDirectory { root in
            let path = root + "/race.json"
            var replaceDuringWrite = false
            let journal = try ReceiptJournal(reserving: path, write: { fd, bytes, count, offset in
                if replaceDuringWrite {
                    replaceDuringWrite = false
                    do {
                        try FileManager.default.moveItem(atPath: path, toPath: root + "/reserved.json")
                        try Data("concurrent file".utf8).write(to: URL(fileURLWithPath: path))
                    } catch { Issue.record("竞态测试准备失败：\(error)") }
                }
                return pwrite(fd, bytes, count, offset)
            })
            replaceDuringWrite = true
            do {
                try journal.commit(receipts)
                Issue.record("写入期间路径改变必须报告失败")
            } catch let error as ReceiptJournal.CommitError {
                #expect(try JSONDecoder().decode([TrashReceipt].self, from: error.recoveryJSON) == receipts)
            }
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "concurrent file")
            #expect(try Data(contentsOf: URL(fileURLWithPath: root + "/reserved.json")) == ReceiptJournal.encode(receipts))
        }
    }

    @Test func lockingReservationAfterPreflightReturnsRecoveryJSON() throws {
        try temporaryDirectory { root in
            let path = root + "/locked-after.json"
            let journal = try ReceiptJournal(reserving: path)
            #expect(chflags(path, UInt32(UF_IMMUTABLE)) == 0)
            defer { _ = chflags(path, 0) }
            do {
                try journal.commit(receipts)
                Issue.record("预留后锁定应报告保存失败")
            } catch let error as ReceiptJournal.CommitError {
                #expect(try JSONDecoder().decode([TrashReceipt].self, from: error.recoveryJSON) == receipts)
            }
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "[]\n")
        }
    }

    @Test func failedAtomicUndoSavePreservesOriginalBytes() throws {
        try temporaryDirectory { root in
            let path = root + "/undo.json"
            let data = try ReceiptJournal.encode(receipts)
            try data.write(to: URL(fileURLWithPath: path))
            #expect(chflags(path, UInt32(UF_IMMUTABLE)) == 0)
            defer { _ = chflags(path, 0) }
            #expect(throws: (any Error).self) { try ReceiptJournal.saveRemaining([], to: path) }
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)
        }
    }

    @Test func abandoningReservationKeepsEmptyPlaceholder() throws {
        try temporaryDirectory { root in
            let path = root + "/abandoned.json"
            do { _ = try ReceiptJournal(reserving: path) }
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "[]\n")
            #expect(throws: (any Error).self) { _ = try ReceiptJournal(reserving: path) }
        }
    }
}
