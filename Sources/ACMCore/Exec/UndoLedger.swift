import Foundation

/// 一次卸载产生的一批回执。不同批次按卸载发生的先后排列。
public struct UndoBatch: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var groupName: String
    public var receipts: [TrashReceipt]

    public init(id: UUID = UUID(), groupName: String, receipts: [TrashReceipt]) {
        self.id = id
        self.groupName = groupName
        self.receipts = receipts
    }

    private enum CodingKeys: String, CodingKey { case id, groupName, receipts }

    /// 旧账本没有批次 ID；首次载入时分配，下次保存后保持稳定。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            groupName: try values.decode(String.self, forKey: .groupName),
            receipts: try values.decode([TrashReceipt].self, forKey: .receipts)
        )
    }
}

/// 还没放回原处的回执。
///
/// `Uninstaller.restore` 按数组逆序放回，所以新卸载的批次追加在后面，
/// 放回时自然先处理后移走的东西。这个类型只管合并与保留，不碰文件系统。
public struct UndoLedger: Codable, Sendable {
    public private(set) var batches: [UndoBatch]

    public init() {
        batches = []
    }

    public init(receipts: [TrashReceipt], groupName: String) {
        batches = receipts.isEmpty ? [] : [UndoBatch(groupName: groupName, receipts: receipts)]
    }

    public init(batches: [UndoBatch]) {
        self.batches = batches.filter { !$0.receipts.isEmpty }
    }

    public var receipts: [TrashReceipt] {
        batches.flatMap(\.receipts)
    }

    public var isEmpty: Bool {
        batches.isEmpty
    }

    /// 撤销栏显示的名字。组太多时不把一整行撑满。
    public var groupName: String {
        var seen = Set<String>()
        let names = batches.map(\.groupName).filter { seen.insert($0).inserted }
        if names.count <= 2 { return names.joined(separator: "、") }
        return "\(names.count) 个工具"
    }

    /// 并进去一次新的卸载；空结果不产生一条空撤销栏。
    @discardableResult
    public mutating func merge(_ newReceipts: [TrashReceipt], groupName: String) -> UUID? {
        guard !newReceipts.isEmpty else { return nil }
        let batch = UndoBatch(groupName: groupName, receipts: newReceipts)
        batches.append(batch)
        return batch.id
    }

    /// 只更新实际尝试过的批次。其他批次（即使含相同回执）保持原样。
    public mutating func retain(remaining: [TrashReceipt], batchID: UUID) {
        guard let index = batches.firstIndex(where: { $0.id == batchID }) else { return }
        var scoped = UndoLedger(batches: [batches[index]])
        scoped.retain(remaining: remaining)
        batches.replaceSubrange(index...index, with: scoped.batches)
    }

    /// 一次放回之后只留下没能放回的回执，顺序不变。
    ///
    /// 用计数而不是简单的 contains，避免同一路径的重复回执被一次结果全部带走。
    public mutating func retain(remaining: [TrashReceipt]) {
        var counts: [TrashReceipt: Int] = [:]
        for receipt in remaining { counts[receipt, default: 0] += 1 }
        batches = batches.compactMap { batch in
            var kept: [TrashReceipt] = []
            for receipt in batch.receipts {
                guard let count = counts[receipt], count > 0 else { continue }
                kept.append(receipt)
                counts[receipt] = count - 1
            }
            return kept.isEmpty ? nil : UndoBatch(id: batch.id, groupName: batch.groupName, receipts: kept)
        }
    }

    /// 用户选择不再放回；东西仍在废纸篓，只是不再保留恢复信息。
    public mutating func dismiss() {
        batches.removeAll()
    }
}

/// 执行前复查的判定结果。它不查询进程，只比较计划确认过的 PID 与最新 PID。
public struct RecheckDecision: Sendable, Equatable {
    public var newlyRunningPIDs: [Int32]
    public var shouldPause: Bool { !newlyRunningPIDs.isEmpty }
    public var notice: String?

    public init(newlyRunningPIDs: [Int32], notice: String?) {
        self.newlyRunningPIDs = newlyRunningPIDs
        self.notice = notice
    }
}

public enum PlanRecheck {
    public static func evaluate(
        groupName: String,
        acknowledgedPIDs: [Int32],
        currentPIDs: [Int32]
    ) -> RecheckDecision {
        let acknowledged = Set(acknowledgedPIDs)
        let newPIDs = Array(Set(currentPIDs.filter { !acknowledged.contains($0) })).sorted()
        guard !newPIDs.isEmpty else {
            return RecheckDecision(newlyRunningPIDs: [], notice: nil)
        }
        let pids = newPIDs.map(String.init).joined(separator: "、")
        return RecheckDecision(
            newlyRunningPIDs: newPIDs,
            notice: "在你确认期间，\(groupName) 被启动了（PID \(pids)）。计划已更新，请重新确认。"
        )
    }
}
