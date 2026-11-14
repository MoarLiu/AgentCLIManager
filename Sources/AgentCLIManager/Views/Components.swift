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
        case .installed: return .accentColor
        case .residue: return .orange
        case .unidentified: return .secondary
        case .otherCLI: return .secondary
        case .managedByApp: return .secondary
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
                Badge(text: "正在使用", color: .red, filled: true, help: "这个工具的进程正在运行")
            }
            if artifact.foreignChildren.contains(where: { $0.blocksRemoval }) {
                Badge(text: "内含其他 App 的数据", color: .orange,
                      help: "目录里有确定由桌面 App 使用的条目，整个目录不能移走；展开后可以只清理其余子项")
            } else if !artifact.foreignChildren.isEmpty {
                Badge(text: "内含其他组的条目", color: .secondary,
                      help: "目录里有属于其他工具的条目，移走外层目录会一并带走")
            }
            if artifact.flags.contains(.shared) {
                Badge(text: "与 \(artifact.ownerAppName ?? "桌面 App") 共用", color: .orange,
                      help: "已安装的桌面 App 也在用这个位置，移走会影响它")
            }
            if artifact.flags.contains(.credentials) {
                Badge(text: "登录凭据", color: .orange, help: "含 token 或密钥。移到废纸篓后仍可读取，也可能已进入 Time Machine")
            }
            if artifact.flags.contains(.invalidLauncher) {
                Badge(text: "入口异常", color: .orange, help: "入口指向的不是可执行程序（例如指向一个目录）")
            }
            if artifact.flags.contains(.usedByOthers) {
                Badge(text: "其他命令也在用", color: .secondary,
                      help: "还有别的命令靠这个程序启动：" + artifact.alsoUsedBy.joined(separator: "、"))
            }
            if artifact.flags.contains(.brokenShim) {
                Badge(text: "启动脚本已失效", color: .secondary)
            }
            if artifact.flags.contains(.danglingSymlink) {
                Badge(text: "悬空软链", color: .secondary, help: "它指向的东西已经不存在")
            }
            // 在用的工具最近有写入是常态，只在判断残留时才有意义
            if artifact.flags.contains(.recentlyModified), section == .residue || section == .unidentified {
                Badge(text: "最近有写入", color: .orange, help: "14 天内有改动，可能还有程序在用")
            }
            if artifact.flags.contains(.rootOwned) {
                Badge(text: "需要管理员", color: .secondary)
            }
            if artifact.flags.contains(.partialSize) {
                Badge(text: "大小未量全", color: .secondary, help: "有读不到的子目录，显示的大小只是下界")
            }
            if artifact.flags.contains(.manualOnly) {
                Badge(text: "由包管理器托管", color: .secondary, help: "请用下方给出的命令卸载")
            } else if artifact.flags.contains(.notRemovable) {
                Badge(text: "不可删除", color: .secondary, help: artifact.notRemovableReason)
            }
            if artifact.strength == .probable, artifact.claim != .usedByApp {
                Badge(text: "推测", color: .secondary, help: "归属只是推测，不是确定的")
            } else if artifact.strength == .speculative {
                Badge(text: "存疑", color: .secondary, help: "证据很弱，归属只是推测")
            }
        }
    }
}

struct EvidenceView: View {
    let artifact: Artifact
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("为什么这么判")
                        .font(.headline)
                    Text(model.show(artifact.path))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 6) {
                    Label(artifact.claim.displayName, systemImage: "scope")
                        .font(.subheadline.weight(.medium))
                    if artifact.strength != .certain {
                        Badge(text: "归属只是推测", color: .orange)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(artifact.evidence.enumerated()), id: \.offset) { _, evidence in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(strengthName(evidence.strength))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(evidence.kind).font(.caption.weight(.semibold))
                                Text(evidence.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                if !artifact.foreignChildren.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("里面有属于别处的条目", systemImage: "folder.badge.person.crop")
                            .font(.subheadline.weight(.medium))
                        ForEach(artifact.foreignChildren, id: \.path) { child in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.show(child.path))
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Text("属于 \(child.owner)"
                                     + (child.usedByApp ? "（桌面 App 在用）" : "")
                                     + (child.certain ? "" : "，归属只是推测")
                                     + (child.blocksRemoval ? "。这一项让整个目录不能移走；展开后可以只清理其余子项。" : "。移走外层目录会把它一并带走。"))
                                    .font(.caption)
                                    .foregroundStyle(child.blocksRemoval ? Color.orange : Color.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                if let reason = artifact.notRemovableReason {
                    Label("不可删除：\(reason)", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let modified = artifact.lastModified {
                    Text("最近改动：\(modified.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(width: 400, alignment: .leading)
        }
        .frame(maxHeight: 460)
    }

    private func strengthName(_ strength: Strength) -> String {
        switch strength {
        case .certain: return "确定"
        case .probable: return "推测"
        case .speculative: return "存疑"
        }
    }
}

/// 一条可以复制、可以在终端里运行的命令。
struct CommandLineView: View {
    let command: String
    var runnable = false
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("复制") { model.copy(command) }
                .controlSize(.small)
                .help("复制命令")
            if runnable {
                Button("在终端运行") { model.runInTerminal(command) }
                    .controlSize(.small)
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

    var body: some View {
        VStack(spacing: 14) {
            if scanning {
                ProgressView()
                    .controlSize(.regular)
                Text("正在扫描命令目录和家目录…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("只读取目录，不修改任何文件")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ContentUnavailableView(
                    "没有发现 Agent CLI",
                    systemImage: "terminal",
                    description: Text("命令目录和家目录里都没有找到 Agent 工具或它们的残留。\n可以点右上角「安装新工具」看看支持哪些。")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
