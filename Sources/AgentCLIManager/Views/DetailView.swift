import ACMCore
import SwiftUI

struct DetailView: View {
    let group: ToolGroup
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: UI.sectionGap) {
                    GroupHeader(group: group)
                    if group.section != .managedByApp { TierSummary(group: group) }
                    if !group.notes.isEmpty { notes }
                    artifacts
                    if !group.binaries.isEmpty { BinariesSection(group: group) }
                    if !group.rcLines.isEmpty { rcLines }
                    if !group.manualCommands.isEmpty || group.uninstallCommand != nil { manualCommands }
                }
                .padding(.horizontal, UI.gutter)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if group.section != .managedByApp {
                Hairline()
                actionBar
            }
        }
        .background(Color.surfaceBase)
        .overlay(alignment: .top) {
            if !model.search.isEmpty {
                Label("搜索只筛选侧栏，详情仍显示「\(group.name)」；勾选和计划没有被筛选改变。", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.acmCaption)
                    .foregroundStyle(Color.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.surfaceRaised, in: Capsule())
                    .overlay { Capsule().strokeBorder(Color.lineControl, lineWidth: UI.hairline) }
                    .padding(.top, 6)
                    .help("当前工具可能不在搜索结果里。清空搜索可回到完整清单。")
            }
        }
        .navigationTitle("Agent CLI Manager")
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(group.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.acmCallout)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.groupFill, in: RoundedRectangle(cornerRadius: UI.corner))
    }

    // MARK: - 关联文件

    private var artifacts: some View {
        let top = group.artifacts.filter { $0.parentPath == nil }
        let kinds = ArtifactKind.allCases
            .sorted { $0.order < $1.order }
            .filter { kind in top.contains { $0.kind == kind } }
        // 这一组里最大的那个条目，作为比例条的基准
        let largest = top.map { $0.size?.bytes ?? 0 }.max() ?? 0

        return VStack(alignment: .leading, spacing: 12) {
            ForEach(kinds, id: \.self) { kind in
                let items = top.filter { $0.kind == kind }
                VStack(spacing: 0) {
                    groupHeader(kind, items: items)
                    ForEach(items) { artifact in
                        Hairline().padding(.horizontal, 10)
                        ArtifactRow(artifact: artifact, group: group, largest: largest)
                        if model.expanded.contains(artifact.path) {
                            let children = model.children(of: artifact, in: group)
                            if children.isEmpty {
                                Text("里面没有可以单独列出的子项")
                                    .font(.acmCaption)
                                    .foregroundStyle(Color.textSecondary)
                                    .padding(.leading, UI.textIndent + 10)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                ForEach(children) { child in
                                    ArtifactRow(artifact: child, group: group, depth: 1, largest: largest)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
                .background(Color.groupFill, in: RoundedRectangle(cornerRadius: UI.corner))
            }
        }
    }

    /// 分组标题行：组勾选框 + 标题 + 一句说明 + 计数 + 合计。
    private func groupHeader(_ kind: ArtifactKind, items: [Artifact]) -> some View {
        let summary = model.kindSelectionSummary(kind, in: group)
        let state: CheckState = switch summary.state {
        case .none: .off
        case .partial: .mixed
        case .all: .on
        case .protected: .protected
        }
        let sum = ToolGroup.totalSize(of: items)
        return HStack(spacing: 8) {
            if group.section != .managedByApp {
                if kind == .credentials {
                    Image(systemName: "key")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: UI.checkbox, height: UI.hitTarget)
                        .help("登录凭据不参与全选，只能逐条勾选")
                } else {
                    ACMCheckbox(state: state, label: "勾选全部\(kind.displayName)") {
                        model.toggleKind(kind, in: group)
                    }
                    .help(summary.state == .protected ? "这一组的条目都不能勾选"
                          : summary.state == .partial
                            ? "已覆盖 \(summary.picked)/\(summary.candidates) 项；点击先勾选这一组，再点一次全部取消（不含登录凭据）"
                            : "勾选或取消这一组（不含登录凭据）")
                }
            }
            Text(kind.displayName)
                .font(.acmHeadline)
                .foregroundStyle(Color.textPrimary)
                .fixedSize()
            Text(hint(kind) ?? "")
                .font(.acmCaption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(items.count) 项")
                .font(.acmCaption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize()
            Text(sum.map { $0.bytes == 0 ? "—" : $0.accurate ? $0.display : "≥ \($0.display)" } ?? (model.isMeasuring ? "…" : "—"))
                .font(.acmMonoNum)
                .foregroundStyle((sum?.bytes ?? 0) == 0 ? Color.textTertiary : Color.textPrimary)
                .lineLimit(1)
                .frame(width: UI.sizeColumn, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    private func hint(_ kind: ArtifactKind) -> String? {
        guard group.section != .managedByApp else { return nil }
        switch kind {
        case .program: return "卸载就是移走这些"
        case .launcher: return "扫描发现的命令入口"
        case .cache, .logs: return "可以放心清理"
        case .data: return "会话、历史等；移走后工具里就找不回了"
        case .config: return "设置；默认保留"
        case .credentials: return "默认不勾选，也不参与全选"
        case .other: return nil
        }
    }

    // MARK: - shell 配置与手工命令

    private var rcLines: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Shell 配置里的相关行", detail: "本 App 不代改，卸载后请自己删掉")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(group.rcLines, id: \.self) { rc in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.show(rc.file)):\(rc.line)")
                            .font(.acmCaption)
                            .foregroundStyle(Color.textSecondary)
                        Text(rc.text)
                            .font(.acmMonoPath)
                            .foregroundStyle(Color.textPrimary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.groupFill, in: RoundedRectangle(cornerRadius: UI.corner))
        }
    }

    private var manualCommands: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "需要你自己执行的命令", detail: "本 App 不调用包管理器，也不提权")
            ForEach(group.manualCommands, id: \.self) { command in
                CommandLineView(command: command, runnable: true)
            }
            if let official = group.uninstallCommand, !group.manualCommands.contains(official) {
                CommandLineView(command: official, runnable: true)
                Text("这是厂商文档给出的卸载命令。")
                    .font(.acmCaption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    // MARK: - 底部

    private var actionBar: some View {
        let chosen = model.selectedArtifacts(group)
        let outer = ToolGroup.outermost(chosen)
        // 上级目录勾选后，里面展开出来的子项也显示为勾选；数量按最外层算，另注明带走了几个子项
        let swallowed = group.artifacts.filter { model.isImplied($0, in: group) }.count
        let risky = outer.contains {
            $0.flags.contains(.shared) || $0.flags.contains(.credentials) || $0.flags.contains(.inUse)
                || !$0.foreignChildren.isEmpty || $0.strength != .certain
        }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(outer.isEmpty
                         ? "没有勾选任何条目"
                         : "将移走 \(outer.count) 项" + (swallowed > 0 ? "（连同里面的 \(swallowed) 个子项）" : ""))
                        .font(.acmBodyMed)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    if let size = model.selectedSize(group), !outer.isEmpty {
                        Text("· " + (size.accurate ? size.display : "≥ \(size.display)"))
                            .font(.acmMonoNum)
                            .foregroundStyle(Color.textPrimary)
                    }
                    if risky {
                        Badge(text: "含需留意条目", color: .acmCaution,
                              help: "含共用、凭据或归属不确定的条目，确认单里会逐条列出")
                    }
                }
                Text("清空废纸篓后才释放空间 · 默认保留配置、数据与凭据 · 只移废纸篓，不用 sudo")
                    .font(.acmCallout)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("本 App 不会替你清空废纸篓；.ssh / .aws 全保护。勾选与确认都不会立即释放磁盘空间")
            }
            .layoutPriority(0)
            Spacer(minLength: 8)
            Menu {
                Text("勾选和取消都不改文件，只有确认单执行后才移动")
                Button("恢复默认勾选") { model.selectDefaults(group) }
                Button("选择全部（不含登录凭据）") {
                    model.selectAll(group)
                }
                .help("选择所有可勾选条目，包含配置和数据；登录凭据只能单独勾选，受保护项始终排除")
                Divider()
                Button("全部取消") { model.selectNone(group) }
            } label: {
                Text("选择")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("批量调整勾选")

            Button("卸载") {
                model.preparePlan(for: group)
            }
            .buttonStyle(.acmPrimary)
            .disabled(outer.isEmpty || model.isBusy || model.isScanning)
            .help("打开卸载确认单，核对后才会移走所选条目")
            .layoutPriority(1)
        }
        .padding(.horizontal, UI.gutter)
        .frame(height: 78)
        .background(Color.surfaceBase)
    }
}

// MARK: - 头部

/// 名称、来源、状态、占用，一屏之内说清楚。
struct GroupHeader: View {
    let group: ToolGroup
    @Environment(AppModel.self) private var model

    var body: some View {
        let top = group.artifacts.filter { $0.parentPath == nil }
        let partial = top.filter { $0.size == nil || $0.size?.accurate == false }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ToolIcon(name: group.name, section: group.section, size: 40,
                                 logo: ToolLogo.lookup(catalog: model.catalog, productID: group.productID,
                                                       binaries: group.binaries.map(\.name),
                                                       ownerApps: group.ownerApps))
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name)
                        .font(.acmTitle)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Text(facts)
                        .font(.acmCallout)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(group.totalSize?.display ?? (model.isMeasuring ? "…" : "—"))
                        .font(.acmMonoDisplay)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Text("关联占用 · \(top.count) 项" + (partial > 0 ? " · \(partial) 项未量全" : ""))
                        .font(.acmCaption)
                        .foregroundStyle(Color.textSecondary)
                }
                .fixedSize()
            }
            HStack(spacing: 6) {
                if group.isRunning {
                    Badge(text: "正在运行", color: .acmCaution, filled: true,
                          help: "PID " + group.runningPIDs.map(String.init).joined(separator: "、"))
                }
                if group.section == .residue { Badge(text: "程序已不在", color: .acmCaution) }
                if group.section == .unidentified { Badge(text: "归属不明", color: .acmCaution, help: "默认都不勾选，请自己判断") }
                if let shared = sharedSummary {
                    Badge(text: shared, color: .acmCaution, help: "已安装的桌面 App 也在用这些位置，移走会影响它")
                }
                if group.binaries.contains(where: { $0.invalidTarget != nil }) {
                    Badge(text: "有命令入口异常", color: .acmCaution, help: "入口指向的不是可执行程序，详见下方命令区")
                }
                Text(group.section.explanation)
                    .font(.acmCaption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if let docs = group.docs ?? group.homepage, let url = URL(string: docs) {
                    Link(destination: url) {
                        Label("官方文档", systemImage: "arrow.up.right")
                            .font(.acmCaption)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .fixedSize()
                }
            }
        }
    }

    private var facts: String {
        var parts: [String] = []
        if let vendor = group.vendor { parts.append(vendor) }
        switch group.section {
        case .installed, .otherCLI:
            if let channel = group.channel { parts.append("来源：" + channel.displayName) }
            if let version = group.version { parts.append("版本 " + version) }
        case .residue:
            parts.append("\(group.artifacts.filter { $0.parentPath == nil }.count) 项残留")
        case .unidentified:
            parts.append("找不到它属于哪个工具")
        case .managedByApp:
            if let app = group.ownerApps.first { parts.append(app.bundleID) }
        }
        return parts.isEmpty ? group.section.displayName : parts.joined(separator: "  ·  ")
    }

    private var sharedSummary: String? {
        let names = Array(Set(group.artifacts.compactMap { a in
            a.flags.contains(.shared) ? (a.ownerAppName ?? "桌面 App") : nil
        })).sorted()
        guard !names.isEmpty else { return nil }
        return "与 " + names.joined(separator: "、") + " 共用"
    }
}

/// 「归属判定」摘要：三档各多少条 + 这一类工具的默认勾选策略。
struct TierSummary: View {
    let group: ToolGroup
    @Environment(AppModel.self) private var model

    var body: some View {
        let top = group.artifacts.filter { $0.parentPath == nil }
        HStack(alignment: .center, spacing: 14) {
            Text("归属判定")
                .font(.acmHeadline)
                .foregroundStyle(Color.textPrimary)
                .fixedSize()
            ForEach(Tier.allCases, id: \.self) { tier in
                TierTag(tier: tier, count: top.filter { Tier($0.strength) == tier }.count)
            }
            Text(policy)
                .font(.acmCallout)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.groupFill, in: RoundedRectangle(cornerRadius: UI.corner))
    }

    /// 默认勾选里最外层那些条目的合计。
    private var defaultCleanable: SizeResult? {
        ToolGroup.totalSize(of: group.artifacts.filter { $0.defaultSelected && $0.parentPath == nil })
    }

    private var policy: String {
        let clean = defaultCleanable.map { "默认勾选可清理 \($0.display)；" } ?? ""
        switch group.section {
        case .installed:
            return clean + "只有「确定」才默认勾选，配置、数据和登录凭据默认保留"
        case .residue:
            return clean + "确定的旧残留才默认勾选；最近写入、共用和顶层目录仍要你确认"
        case .unidentified, .otherCLI:
            return "归属不确定，默认都不勾选；请确认后再清理"
        case .managedByApp:
            return "由桌面 App 使用，不在管理范围内"
        }
    }
}

// MARK: - 命令链路

/// 把链路画成「入口 → 目标」的层级，而不是一长串箭头文本。
/// 展示扫描发现的入口；未解析实际 shell，不能据此判断执行优先级。
struct BinariesSection: View {
    let group: ToolGroup
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "命令", detail: "按扫描顺序列出；实际 PATH 优先级未确认") {
                Text("\(group.binaries.count) 个入口")
                    .font(.acmCaption)
                    .foregroundStyle(Color.textSecondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(group.binaries.enumerated()), id: \.element.path) { index, binary in
                    BinaryRow(binary: binary,
                              hasDuplicate: group.binaries.contains(where: { $0.name == binary.name && $0.path != binary.path }))
                    if index < group.binaries.count - 1 {
                        Hairline().padding(.leading, 12)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.groupFill, in: RoundedRectangle(cornerRadius: UI.corner))
        }
    }


}

struct BinaryRow: View {
    let binary: BinaryInfo
    var hasDuplicate = false
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(binary.name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                if hasDuplicate {
                    Badge(text: "同名入口", color: .textSecondary,
                          help: "扫描发现多个同名入口；实际 shell PATH 优先级未确认")
                }
                if binary.isDangling {
                    Badge(text: "悬空", color: .textSecondary, help: "它指向的东西已经不存在")
                }
                if let target = binary.brokenShimTarget {
                    Badge(text: "已失效", color: .acmCaution, help: "启动脚本 exec 的程序已不存在：\(target)")
                }
                if let invalid = binary.invalidTarget {
                    Badge(text: "入口异常", color: .acmCaution,
                          help: "入口最终指向的不是可执行程序，而是\(invalid)")
                }
                if let identifier = binary.signIdentifier, identifier != "-" {
                    Badge(text: "签名 " + identifier, color: .textSecondary,
                          help: binary.teamID.map { "团队 ID \($0)" } ?? "没有团队 ID")
                }
                Spacer(minLength: 0)
            }
            chainView
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var chainView: some View {
        let chain = binary.chain
        if chain.count <= 1 {
            Text(chain.first.map { model.show($0) } ?? model.show(binary.path))
                .font(.acmMonoPath)
                .foregroundStyle(Color.textSecondary)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(chain.enumerated()), id: \.offset) { index, link in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(index == 0 ? "入口" : (index == chain.count - 1 ? "链路目标" : "链接到"))
                            .font(.acmMicroMed)
                            .foregroundStyle(Color.textTertiary)
                            .frame(width: 48, alignment: .trailing)
                        Text(model.show(link))
                            .font(.acmMonoPath)
                            .foregroundStyle(index == chain.count - 1 ? Color.textPrimary : Color.textSecondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - 文件行

/// 清单行：默认只显示路径、归属档位和风险徽标；完整判据收进证据弹窗。
struct ArtifactRow: View {
    let artifact: Artifact
    let group: ToolGroup
    var depth = 0
    var largest: Int64 = 0
    @Environment(AppModel.self) private var model
    @State private var showEvidence = false
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        let implied = model.isImplied(artifact, in: group)
        let selectable = model.canSelect(artifact, in: group)
        let picked = model.isEffectivelySelected(artifact, in: group)

        HStack(alignment: .center, spacing: 8) {
            if group.section != .managedByApp {
                ACMCheckbox(state: !selectable ? .protected : picked ? .on : .off,
                            enabled: !implied,
                            label: "勾选 \(PathUtil.lastComponent(artifact.path))") {
                    model.setSelected(artifact, in: group, !model.isSelected(artifact, in: group))
                }
                .help(!selectable ? (artifact.notRemovableReason ?? "受保护，不能勾选")
                      : implied ? "上级目录已勾选，这一项会被一并移走" : "勾选后进入卸载确认清单")
            }

            if artifact.expandable && depth == 0 {
                Button {
                    model.toggleExpand(artifact, in: group)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(model.expanded.contains(artifact.path) ? 90 : 0))
                        .frame(width: 16, height: UI.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.textSecondary)
                .accessibilityLabel(model.expanded.contains(artifact.path) ? "收起子项" : "展开一层")
                .help("展开一层，可以只清理里面的某几项")
            } else {
                Color.clear.frame(width: 16, height: 1)
            }

            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 18)

            HStack(spacing: 6) {
                Text(depth == 0 ? artifact.display(home: model.env.home) : PathUtil.lastComponent(artifact.path))
                    .font(.acmMonoNum)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(artifact.path)
                    .layoutPriority(1)
                TierTag(tier: Tier(artifact.strength))
                FlagBadges(artifact: artifact, section: group.section)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            RowActions(
                onEvidence: { showEvidence = true },
                onReveal: { model.reveal(artifact.path) },
                emphasized: hovering || focused
            )

            VStack(alignment: .trailing, spacing: 4) {
                Text(sizeText)
                    .font(.acmMonoNum)
                    .foregroundStyle(sizeText == "—" ? Color.textTertiary : Color.textPrimary)
                    .lineLimit(1)
                    .help(sizeHelp)
                if depth == 0 {
                    SizeBar(fraction: largest > 0 ? Double(artifact.size?.bytes ?? 0) / Double(largest) : 0)
                }
            }
            .frame(width: UI.sizeColumn, alignment: .trailing)
        }
        .padding(.leading, depth == 0 ? 10 : 10 + UI.textIndent - 16 - 8 - 18)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(hovering ? Color.rowHover : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.textPrimary, lineWidth: UI.focusWidth)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        // 空格勾选当前行；回车展开
        .onKeyPress(.space) {
            guard selectable, !implied else { return .ignored }
            model.setSelected(artifact, in: group, !model.isSelected(artifact, in: group))
            return .handled
        }
        .onKeyPress(.return) {
            guard artifact.expandable, depth == 0 else { return .ignored }
            model.toggleExpand(artifact, in: group)
            return .handled
        }
        .contextMenu {
            Button("为什么这么判") { showEvidence = true }
            Button("在 Finder 中显示") { model.reveal(artifact.path) }
            if artifact.expandable && depth == 0 {
                Button(model.expanded.contains(artifact.path) ? "收起子项" : "展开一层") {
                    model.toggleExpand(artifact, in: group)
                }
            }
            if group.section != .managedByApp {
                Divider()
                Button("复制完整路径") { model.copy(artifact.path) }
            }
        }
        .sheet(isPresented: $showEvidence) {
            EvidenceView(artifact: artifact, group: group)
        }
    }

    private var symbol: String {
        if artifact.isSymlink { return "link" }
        if artifact.isDirectory { return "folder" }
        if artifact.kind == .credentials { return "key" }
        return "doc"
    }

    /// 只含软链的目录、悬空软链本身，占不了什么空间，显示「—」比「0 字节」清楚。
    private var sizeText: String {
        guard let size = artifact.size else { return model.isMeasuring ? "…" : "—" }
        if size.bytes == 0, artifact.isDirectory || artifact.isSymlink { return "—" }
        return size.accurate ? size.display : "≥ \(size.display)"
    }

    private var sizeHelp: String {
        guard let size = artifact.size else { return "还没量完" }
        return size.accurate ? size.display : "有读不到的子目录，实际至少 \(size.display)"
    }
}
