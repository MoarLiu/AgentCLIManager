import ACMCore
import SwiftUI

extension ACMCore.Section {
    var symbol: String {
        switch self {
        case .installed: return "terminal"
        case .residue: return "archivebox"
        case .unidentified: return "questionmark.folder"
        case .otherCLI: return "chevron.left.forwardslash.chevron.right"
        case .managedByApp: return "macwindow"
        }
    }

    var tint: Color {
        switch self {
        case .installed, .residue, .unidentified, .otherCLI, .managedByApp: return .textPrimary
        }
    }

    var explanation: String {
        switch self {
        case .installed: return "能在命令行里直接运行的 Agent 工具。"
        case .residue: return "程序已经不在了，只剩下这些文件。"
        case .unidentified: return "内容看起来像 Agent 工具留下的，但找不到它属于谁。请自己判断，默认都不勾选。"
        case .otherCLI: return "命令目录里的其他可执行文件，不是 Agent 工具。"
        case .managedByApp: return "这些位置由已安装的桌面 App 使用，不在管理范围内，这里只作说明。要清理它们，请先卸载对应的 App。"
        }
    }
}

extension ArtifactKind {
    var symbol: String {
        switch self {
        case .program: return "shippingbox"
        case .launcher: return "link"
        case .config: return "gearshape"
        case .data: return "tray.full"
        case .cache: return "clock.arrow.circlepath"
        case .logs: return "doc.plaintext"
        case .credentials: return "key"
        case .other: return "doc"
        }
    }
}

/// 行上的状态徽标。重要的风险（在用、共用、凭据、入口异常）优先；
/// 剩下的小徽标如果太多会挤掉路径，所以按重要性排好，让窄窗口自然截断。
struct FlagBadges: View {
    let artifact: Artifact
    let section: ACMCore.Section

    var body: some View {
        HStack(spacing: 4) {
            if artifact.flags.contains(.inUse) {
                Badge(text: "正在使用", color: .acmDanger, filled: true, help: "这个工具的进程正在运行")
            }
            if artifact.foreignChildren.contains(where: { $0.blocksRemoval }) {
                Badge(text: "内含其他 App 的数据", color: .acmCaution,
                      help: "目录里有确定由桌面 App 使用的条目，整个目录不能移走；展开后可以只清理其余子项")
            } else if !artifact.foreignChildren.isEmpty {
                Badge(text: "内含其他组的条目", color: .textSecondary,
                      help: "目录里有属于其他工具的条目，移走外层目录会一并带走")
            }
            if artifact.flags.contains(.shared) {
                Badge(text: "与 \(artifact.ownerAppName ?? "桌面 App") 共用", color: .acmCaution,
                      help: "已安装的桌面 App 也在用这个位置，移走会影响它")
            }
            if artifact.flags.contains(.credentials) {
                Badge(text: "登录凭据", color: .acmCaution, help: "含 token 或密钥。移到废纸篓后仍可读取，也可能已进入 Time Machine")
            }
            if artifact.flags.contains(.invalidLauncher) {
                Badge(text: "入口异常", color: .acmCaution, help: "入口指向的不是可执行程序（例如指向一个目录）")
            }
            if artifact.flags.contains(.usedByOthers) {
                Badge(text: "其他命令也在用", color: .textSecondary,
                      help: "还有别的命令靠这个程序启动：" + artifact.alsoUsedBy.joined(separator: "、"))
            }
            if artifact.flags.contains(.brokenShim) {
                Badge(text: "启动脚本已失效", color: .textSecondary)
            }
            if artifact.flags.contains(.danglingSymlink) {
                Badge(text: "悬空软链", color: .textSecondary, help: "它指向的东西已经不存在")
            }
            // 在用的工具最近有写入是常态，只在判断残留时才有意义
            if artifact.flags.contains(.recentlyModified), section == .residue || section == .unidentified {
                Badge(text: "最近有写入", color: .acmCaution, help: "14 天内有改动，可能还有程序在用")
            }
            if artifact.flags.contains(.rootOwned) {
                Badge(text: "需要管理员", color: .textSecondary)
            }
            if artifact.flags.contains(.partialSize) {
                Badge(text: "大小未量全", color: .textSecondary, help: "有读不到的子目录，显示的大小只是下界")
            }
            if artifact.flags.contains(.manualOnly) {
                Badge(text: "由包管理器托管", color: .textSecondary, help: "请用下方给出的命令卸载")
            } else if artifact.flags.contains(.notRemovable) {
                Badge(text: "不可删除", color: .textSecondary, help: artifact.notRemovableReason)
            }
        }
    }
}

/// 「为什么这么判」：目标路径 → 判据 → 证据边界 → 选择策略 → 来源与时效。
struct EvidenceView: View {
    let artifact: Artifact
    let group: ToolGroup
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("为什么这么判")
                    .font(.acmTitle)
                    .foregroundStyle(Color.textPrimary)
                Text("归属判定只回答「它是谁的」，不替你决定要不要移走。")
                    .font(.acmCallout)
                    .foregroundStyle(Color.textSecondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    FlowSection(title: "目标路径", trailing: sizeText) {
                        Text(artifact.path)
                            .font(.acmMonoNum)
                            .foregroundStyle(Color.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(pathFacts)
                            .font(.acmCaption)
                            .foregroundStyle(Color.textSecondary)
                    }

                    FlowSection(title: "发现来源与判据", tone: tier == .unknown ? nil : tier.color) {
                        HStack(spacing: 8) {
                            TierTag(tier: tier)
                            Text(artifact.claim.displayName)
                                .font(.acmBodyMed)
                                .foregroundStyle(Color.textPrimary)
                        }
                        if artifact.evidence.isEmpty {
                            Text("没有可靠证据。")
                                .font(.acmCallout)
                                .foregroundStyle(Color.textSecondary)
                        }
                        ForEach(Array(artifact.evidence.enumerated()), id: \.offset) { _, evidence in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                TierTag(tier: Tier(evidence.strength))
                                    .frame(width: 44, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(evidence.kind)
                                        .font(.acmCaptionMed)
                                        .foregroundStyle(Color.textPrimary)
                                    Text(evidence.detail)
                                        .font(.acmCaption)
                                        .foregroundStyle(Color.textSecondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    FlowSection(title: "证据边界", tone: boundaryIsCaution ? .acmCaution : nil) {
                        ForEach(boundaries, id: \.self) { line in
                            bullet(line)
                        }
                        ForEach(artifact.foreignChildren, id: \.path) { child in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.show(child.path))
                                    .font(.acmMonoPath)
                                    .foregroundStyle(Color.textPrimary)
                                    .textSelection(.enabled)
                                Text("属于 \(child.owner)"
                                     + (child.usedByApp ? "（桌面 App 在用）" : "")
                                     + (child.certain ? "" : "，归属只是推测")
                                     + (child.blocksRemoval ? "。这一项让整个目录不能移走；展开后可以只清理其余子项。" : "。移走外层目录会把它一并带走。"))
                                    .font(.acmCaption)
                                    .foregroundStyle(child.blocksRemoval ? Color.acmCaution : Color.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    FlowSection(title: "选择策略") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: policy.symbol)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.textSecondary)
                                .frame(width: 14)
                            Text(policy.text)
                                .font(.acmCallout)
                                .foregroundStyle(Color.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    FlowSection(title: "来源与时效") {
                        if let modified = artifact.lastModified {
                            bullet("最近改动：\(modified.formatted(date: .abbreviated, time: .shortened))")
                        }
                        bullet("判定基于本次扫描的只读结果；移走之前还会再复查一次。")
                    }
                }
            }
            .frame(maxHeight: 420)

            HStack(spacing: 10) {
                Spacer()
                Button(copied ? "已复制" : "复制完整路径") {
                    model.copy(artifact.path)
                    copied = true
                }
                .buttonStyle(.acmSecondary)
                Button("返回清单") { dismiss() }
                    .buttonStyle(.acmPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: UI.flowWidth)
        .background(Color.surfaceRaised)
    }

    private var tier: Tier { Tier(artifact.strength) }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(Color.textTertiary)
                .frame(width: 4, height: 4)
                .offset(y: -2)
            Text(text)
                .font(.acmCallout)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sizeText: String? {
        guard let size = artifact.size else { return nil }
        return size.accurate ? size.display : "≥ \(size.display)"
    }

    private var pathFacts: String {
        var parts = [artifact.kind.displayName]
        parts.append(artifact.isSymlink ? "软链接" : artifact.isDirectory ? "目录" : "文件")
        if let size = artifact.size, !size.accurate { parts.append("有读不到的子目录，大小只是下界") }
        return parts.joined(separator: " · ")
    }

    private var boundaryIsCaution: Bool {
        artifact.strength != .certain || artifact.foreignChildren.contains { $0.blocksRemoval }
    }

    private var boundaries: [String] {
        var lines: [String] = []
        switch artifact.strength {
        case .certain:
            lines.append("归属是确定的，但确定归属不等于同意删除；要不要移走仍由你决定。")
        case .probable:
            lines.append("只有线索，没有足够的归属依据。这些证据只供你判断，不会据此默认勾选。")
        case .speculative:
            lines.append("没有可靠证据能说明它属于谁，请自己判断。")
        }
        if artifact.flags.contains(.shared) {
            lines.append("\(artifact.ownerAppName ?? "桌面 App") 也在用这个位置，移走会影响它。")
        }
        if artifact.flags.contains(.credentials) {
            lines.append("含 token 或密钥。移到废纸篓后仍可读取，也可能已进入 Time Machine。")
        }
        if let note = artifact.note { lines.append(note) }
        return lines
    }

    private var policy: (symbol: String, text: String) {
        if group.section == .managedByApp {
            return ("lock", "由桌面 App 使用，不在管理范围内，这里只作说明。")
        }
        if !model.canSelect(artifact, in: group) {
            return ("lock", "受保护，不能勾选" + (artifact.notRemovableReason.map { "：\($0)" } ?? "。"))
        }
        if artifact.flags.contains(.credentials) {
            return ("key", "登录凭据默认保留，批量选择会跳过独立凭据。逐条勾选凭据或选中包含它的上级目录时，确认单会提示风险。")
        }
        if artifact.defaultSelected {
            return ("checkmark", "归属确定，且属于程序本体或可重建的内容，所以默认勾选；可以随时取消。")
        }
        if artifact.strength != .certain {
            return ("minus", "归属不是「确定」档，默认不勾选。")
        }
        switch artifact.kind {
        case .config, .data:
            return ("minus", "配置与数据默认保留，需要你自己勾选。")
        default:
            return ("minus", "默认不勾选，需要你确认后自己勾选。")
        }
    }
}

/// 一条可以复制、可以在终端里运行的命令。
struct CommandLineView: View {
    let command: String
    var runnable = false
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.acmMonoPath)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "已复制" : "复制命令") {
                model.copy(command)
                copied = true
            }
            .buttonStyle(.acmCompact)
            .help("复制命令")
            if runnable {
                Button("在终端运行") { model.runInTerminal(command) }
                    .buttonStyle(.acmCompact)
                    .help("打开「终端」执行这条命令，本 App 自己不运行")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.groupFill, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// 空状态、扫描中的占位。
struct DetailPlaceholder: View {
    var scanning = false
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            if scanning {
                ProgressView()
                    .controlSize(.regular)
                    .padding(.bottom, 4)
                Text("正在扫描命令目录和家目录…")
                    .font(.acmBodyMed)
                    .foregroundStyle(Color.textPrimary)
                Text("只读取目录，不修改任何文件")
                    .font(.acmCaption)
                    .foregroundStyle(Color.textSecondary)
            } else if !model.search.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.textTertiary)
                    .padding(.bottom, 4)
                Text("没有匹配的工具或路径")
                    .font(.acmTitle)
                    .foregroundStyle(Color.textPrimary)
                Text("换个关键词，或清空搜索查看全部。搜索不会改变任何勾选。")
                    .font(.acmCallout)
                    .foregroundStyle(Color.textSecondary)
                Button("清空搜索") { model.search = "" }
                    .buttonStyle(.acmSecondary)
                    .padding(.top, 6)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.textTertiary)
                    .padding(.bottom, 4)
                Text("没有发现 Agent CLI")
                    .font(.acmTitle)
                    .foregroundStyle(Color.textPrimary)
                Text("命令目录和家目录里都没有找到 Agent 工具或它们的残留。\n本次扫描只读取目录，没有修改任何文件。")
                    .font(.acmCallout)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button("重新扫描") { model.rescan() }
                        .buttonStyle(.acmSecondary)
                    Button("安装工具…") { model.showInstall = true }
                        .buttonStyle(.acmPrimary)
                }
                .padding(.top, 6)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceBase)
    }
}
