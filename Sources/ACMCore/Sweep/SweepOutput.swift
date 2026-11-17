import Foundation

/// `acm sweep` 的输出。JSON 用固定的封装，文字版给人看。
///
/// 封装的形状与 BuildSweep 相同，原来读 `buildsweep --json` 的脚本可以直接换过来：
/// 成功是 `{"ok": true, "schema_version": 1, "data": …}`，
/// 失败是 `{"ok": false, "schema_version": 1, "error": {"code", "message", "details"}}`。
public enum SweepOutput {

    private struct Success<Payload: Encodable>: Encodable {
        var ok = true
        var schemaVersion = SweepEngine.schemaVersion
        var data: Payload

        private enum CodingKeys: String, CodingKey {
            case ok, data
            case schemaVersion = "schema_version"
        }
    }

    private struct Failure: Encodable {
        struct Detail: Encodable {
            var code: String
            var message: String
            var details: [String: String]
        }

        var ok = false
        var schemaVersion = SweepEngine.schemaVersion
        var error: Detail

        private enum CodingKeys: String, CodingKey {
            case ok, error
            case schemaVersion = "schema_version"
        }
    }

    /// 执行了，但有的项目没走完：逐项结果照常给出，同时标明这次不算成功。
    private struct Partial<Payload: Encodable>: Encodable {
        var ok = false
        var schemaVersion = SweepEngine.schemaVersion
        var data: Payload
        var error = Failure.Detail(
            code: "incomplete_operation", message: "部分项目已跳过，请查看逐项结果。", details: [:]
        )

        private enum CodingKeys: String, CodingKey {
            case ok, data, error
            case schemaVersion = "schema_version"
        }
    }

    private static func encode<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            return #"{"error":{"code":"encoding_failed","details":{},"message":"结果无法编码。"},"ok":false,"schema_version":1}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func json<Payload: Encodable>(_ data: Payload) -> String {
        encode(Success(data: data))
    }

    /// `incomplete` 为真时 `ok` 是 false，并带上 `incomplete_operation` 错误；`data` 仍然完整。
    public static func json<Payload: Encodable>(_ data: Payload, incomplete: Bool) -> String {
        incomplete ? encode(Partial(data: data)) : encode(Success(data: data))
    }

    public static func json(_ error: SweepError) -> String {
        encode(Failure(error: .init(code: error.code, message: error.message, details: error.details)))
    }

    // MARK: - 文字版

    public static func size(_ bytes: Int64) -> String {
        SizeResult(bytes: bytes, accurate: true).display
    }

    /// 路径加引号并转义：文件名里可能有换行、引号，原样打印会把一行拆成几行。
    static func quoted(_ path: String) -> String {
        var out = "\""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    public static func text(_ items: [SweepItem]) -> String {
        items.map { item in
            let amount = size(item.snapshot?.allocatedBytes ?? 0)
            return "\(item.id)  \(item.status.displayName)  \(amount)  \(quoted(item.path))\n  \(item.reason)"
        }.joined(separator: "\n")
    }

    public static func text(_ plan: SweepPlan, limit: Int = 50) -> String {
        var lines = [
            "扫描目录  \(quoted(plan.root))",
            "可清理 \(plan.summary.cleanup) 项，预计占用 \(size(plan.summary.estimatedCleanupBytes))",
            "保留 \(plan.summary.keep) 项，需要复核 \(plan.summary.review) 项，跳过 \(plan.summary.blocked) 项",
        ]
        if !plan.items.isEmpty {
            lines.append(text(Array(plan.items.prefix(limit))))
        }
        if plan.items.count > limit {
            lines.append("其余项目可通过 acm sweep items 分页查看。")
        }
        if let file = plan.planFile {
            lines.append("计划已保存  \(quoted(file))")
        }
        lines += plan.warnings.map(\.message)
        return lines.joined(separator: "\n")
    }

    public static func text(_ page: SweepPage) -> String {
        let header = "共 \(page.total) 项，本页 \(page.items.count) 项"
        return page.items.isEmpty ? header : header + "\n" + text(page.items)
    }

    /// 单项详情：识别依据、文件身份、保留的版本。
    public static func text(_ item: SweepItem) -> String {
        var lines = [
            "\(item.id)  \(item.status.displayName)  \(quoted(item.path))",
            "  \(item.reason)",
            "  类别  \(item.category.rawValue)",
            "  所属项目  \(item.project.map(quoted) ?? "无")",
        ]
        if let snapshot = item.snapshot {
            lines.append("  占用  \(size(snapshot.allocatedBytes))，\(snapshot.entries) 个条目")
            lines.append("  文件身份  设备 \(snapshot.device)，inode \(snapshot.inode)")
            lines.append("  指纹  \(snapshot.digest)")
            if let content = snapshot.contentSHA256 {
                lines.append("  内容 SHA-256  \(content)")
            }
        }
        if let installer = item.installer, installer.recognized {
            lines.append(
                "  安装包  \(installer.product ?? "")  \(installer.version?.text ?? "")"
                    + "  \(installer.architecture ?? "")  \(installer.format ?? "")"
            )
        }
        if !item.retainedIDs.isEmpty {
            lines.append("  保留的版本  \(item.retainedIDs.joined(separator: "、"))")
        }
        for process in item.processes ?? [] {
            lines.append("  占用进程  \(process.pid)  \(process.command)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 执行与恢复

    private static func text(_ outcomes: [SweepOutcome]) -> [String] {
        outcomes.flatMap { outcome -> [String] in
            var lines = ["\(outcome.id)  \(outcome.status.displayName)  \(quoted(outcome.path))"]
            if let reason = outcome.reason { lines.append("  \(reason)") }
            if let recovery = outcome.recoveryPath { lines.append("  内容现在在  \(quoted(recovery))") }
            return lines
        }
    }

    private static func count(_ outcomes: [SweepOutcome], _ status: SweepOutcomeStatus) -> Int {
        outcomes.filter { $0.status == status }.count
    }

    /// - Parameter requested: 调用方要求了真的执行。要求了却一项都没动时，不能说成「预演」。
    public static func text(_ result: SweepApplyResult, plan: SweepPlan, requested: Bool = false) -> String {
        let how = result.mode == .permanent ? "永久删除（不可恢复）" : "移到废纸篓"
        var lines = ["扫描目录  \(quoted(result.root))"]
        if result.executed {
            let done = count(result.items, result.mode == .permanent ? .deleted : .trashed)
            lines.append("已\(result.mode == .permanent ? "永久删除" : "移到废纸篓") \(done) 项，共 \(result.items.count) 项")
        } else if requested {
            lines.append("没有可以执行的项目，什么都没动。")
        } else {
            lines.append("预演：\(count(result.items, .ready)) 项可以\(how)，共 \(result.items.count) 项。加 --execute 才会执行")
        }
        lines += text(result.items)
        if !result.unselectedIDs.isEmpty {
            lines.append(
                "另有 \(result.unselectedIDs.count) 个旧版本安装包没有列入（新旧是按文件名里的版本号推测的）："
            )
            let byID = Dictionary(plan.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            lines += result.unselectedIDs.map { "  \($0)  \(quoted(byID[$0]?.path ?? ""))" }
            lines.append("  要清理它们，用 --id 点名，或加 --include-old-versions")
        }
        if let receipt = result.receipt {
            lines.append("回执  \(quoted(receipt))")
            if result.items.contains(where: { $0.status == .trashed || $0.status == .recoveryRequired }) {
                lines.append("放回原处：acm sweep restore <回执> --execute")
            }
        }
        if let delta = result.freeSpaceDeltaBytes, result.mode == .permanent, delta > 0 {
            lines.append("可用空间增加约 \(size(delta))")
        }
        if result.requiresEmptyingTrash == true {
            lines.append("清空废纸篓之后空间才会释放。")
        }
        return lines.joined(separator: "\n")
    }

    public static func text(_ result: SweepRestoreResult, requested: Bool = false) -> String {
        var lines = ["扫描目录  \(quoted(result.root))"]
        if result.executed {
            lines.append("已放回 \(count(result.items, .restored)) 项，共 \(result.items.count) 项")
        } else if result.items.isEmpty {
            lines.append("这份回执里没有还能放回的内容。")
        } else if requested {
            lines.append("没有可以放回的项目，什么都没动。")
        } else {
            lines.append("预演：\(count(result.items, .ready)) 项可以放回，共 \(result.items.count) 项。加 --execute 才会执行")
        }
        lines += text(result.items)
        return lines.joined(separator: "\n")
    }
}
