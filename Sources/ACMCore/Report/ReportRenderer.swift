import Foundation

public enum ReportRenderer {

    public static func json(_ report: ScanReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func text(_ report: ScanReport, home: String, verbose: Bool = false) -> String {
        var lines: [String] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        lines.append("Agent CLI Manager —— 扫描结果 \(formatter.string(from: report.scannedAt))")
        if let free = report.diskFreeBytes, let total = report.diskTotalBytes {
            lines.append("磁盘：剩余 \(bytes(free)) / 共 \(bytes(total))")
        }
        lines.append("命令目录：\(report.binDirs.count) 个")
        lines.append("")

        for section in Section.allCases {
            let groups = report.groups(in: section)
            guard !groups.isEmpty else { continue }
            lines.append("== \(section.displayName)（\(groups.count)）==")
            lines.append("")
            for group in groups {
                lines.append(contentsOf: render(group, home: home, verbose: verbose))
            }
        }
        if report.groups.isEmpty {
            lines.append("没有发现任何 Agent CLI。")
        }
        return lines.joined(separator: "\n")
    }

    static func render(_ group: ToolGroup, home: String, verbose: Bool) -> [String] {
        var lines: [String] = []
        var headline = "▸ \(group.name)"
        if let version = group.version { headline += "  \(version)" }
        if let channel = group.channel { headline += "  ·  \(channel.displayName)" }
        if let size = group.totalSize { headline += "  ·  \(size.display)" }
        if group.isRunning { headline += "  ·  正在运行 PID \(group.runningPIDs.map(String.init).joined(separator: "、"))" }
        lines.append(headline)

        for b in group.binaries {
            var line = "    \(b.name): \(PathUtil.display(b.path, home: home))"
            if b.chain.count > 1 {
                line += " → " + b.chain.dropFirst().map { PathUtil.display($0, home: home) }.joined(separator: " → ")
            }
            if b.isDangling { line += "  [悬空]" }
            if let target = b.brokenShimTarget { line += "  [要执行的 \(target) 不存在]" }
            if let what = b.invalidTarget { line += "  [指向\(what)，不是可执行程序]" }
            if let identifier = b.signIdentifier, identifier != "-" { line += "  [签名 \(identifier)]" }
            lines.append(line)
        }
        for note in group.notes {
            lines.append("    注：\(note)")
        }
        if !group.rcLines.isEmpty {
            lines.append("    shell 配置（只读，本版不代改）：")
            for rc in group.rcLines {
                lines.append("      \(PathUtil.display(rc.file, home: home)):\(rc.line)  \(rc.text)")
            }
        }
        for artifact in group.artifacts {
            var line = "    [\(artifact.defaultSelected ? "x" : " ")] \(artifact.kind.displayName.padding(toLength: 6, withPad: " ", startingAt: 0))  "
            line += artifact.display(home: home)
            if let size = artifact.size { line += "  \(size.display)" }
            var marks: [String] = []
            for flag in ArtifactFlag.allCases where artifact.flags.contains(flag) {
                // 在用的工具「最近有写入」是常态，只在判断残留时才值得提
                if flag == .recentlyModified && group.section == .installed { continue }
                if flag == .topLevelRoot { continue }
                marks.append(flag.displayName)
            }
            if artifact.claim == .usedByApp, let owner = artifact.ownerAppName { marks.append("\(owner) 在用") }
            if artifact.strength != .certain { marks.append(artifact.strength == .probable ? "推测" : "存疑") }
            if !marks.isEmpty { line += "   ⚠ " + marks.joined(separator: "、") }
            lines.append(line)
            if let reason = artifact.notRemovableReason, verbose {
                lines.append("        不可删除：\(reason)")
            }
            if verbose {
                for e in artifact.evidence {
                    lines.append("        证据[\(e.strength.rawValue)] \(e.kind)：\(e.detail)")
                }
            }
            if let note = artifact.note {
                lines.append("        \(note)")
            }
            if !artifact.alsoUsedBy.isEmpty {
                lines.append("        其他命令也通过它启动：" + artifact.alsoUsedBy.joined(separator: "、"))
            }
            for foreign in artifact.foreignChildren {
                let what = foreign.usedByApp ? "由 \(foreign.owner) 使用" : "属于「\(foreign.owner)」"
                lines.append("        里面的 \(PathUtil.display(foreign.path, home: home)) \(what)\(foreign.certain ? "" : "（推测）")")
            }
        }
        if !group.manualCommands.isEmpty {
            lines.append("    需要你自己执行：")
            for command in group.manualCommands { lines.append("      " + command) }
        }
        lines.append("")
        return lines
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
