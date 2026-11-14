import Foundation
import Testing
@testable import ACMCore

@Suite struct P2UndoLedgerTests {
    @Test func batchRestoreKeepsUnattemptedBatchesAndDuplicateCounts() throws {
        let receipt = TrashReceipt(original: "/a", trashed: "/trash/a")
        var ledger = UndoLedger()
        let olderID = ledger.merge([receipt, receipt], groupName: "older")
        let currentID = ledger.merge([receipt, receipt], groupName: "current")
        let older = try #require(olderID)
        let current = try #require(currentID)
        ledger.retain(remaining: [receipt], batchID: current)
        #expect(ledger.batches.map(\.id) == [older, current])
        #expect(ledger.batches[0].receipts.count == 2)
        #expect(ledger.batches[1].receipts.count == 1)
        ledger.retain(remaining: [], batchID: current)
        #expect(ledger.batches.map(\.id) == [older])
        #expect(ledger.receipts == [receipt, receipt])
    }

    @Test func legacyBatchJSONGetsStablePersistedIdentity() throws {
        let oldJSON = Data(#"{"batches":[{"groupName":"old","receipts":[{"original":"/a","trashed":"/trash/a"}]},{"groupName":"old","receipts":[{"original":"/a","trashed":"/trash/a"}]}]}"#.utf8)
        let decoded = try JSONDecoder().decode(UndoLedger.self, from: oldJSON)
        #expect(decoded.batches.count == 2)
        #expect(Set(decoded.batches.map(\.id)).count == 2)
        let reloaded = try JSONDecoder().decode(UndoLedger.self, from: JSONEncoder().encode(decoded))
        #expect(reloaded.batches == decoded.batches)
        #expect(decoded.receipts.count == 2)
    }

    @Test func legacyRetainPreservesBatchIdentityAndMultiplicity() throws {
        let receipt = TrashReceipt(original: "/a", trashed: nil)
        var ledger = UndoLedger()
        let batchID = ledger.merge([receipt, receipt], groupName: "old")
        let batch = try #require(batchID)
        ledger.retain(remaining: [receipt])
        #expect(ledger.batches.first?.id == batch)
        #expect(ledger.receipts == [receipt])
        let emptyID = ledger.merge([], groupName: "empty")
        #expect(emptyID == nil)
    }
}
