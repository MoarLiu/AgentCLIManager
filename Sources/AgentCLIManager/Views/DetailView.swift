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
                    if !group.notes.isEmpty { notes }
                    if !group.binaries.isEmpty { BinariesSection(group: group) }
                    artifacts
                    if !group.rcLines.isEmpty { rcLines }
                    if !group.manualCommands.isEmpty || group.uninstallCommand != nil { manualCommands }
                }
                .padding(.horizontal, UI.gutter)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if group.section != .managedByApp {
                Divider()
                actionBar
            }
        }
        .navigationTitle(group.name)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(group.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

        return VStack(alignment: .leading, spacing: UI.sectionGap) {
            ForEach(kinds, id: \.self) { kind in
                let items = top.filter { $0.kind == kind }
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: kind.displayName, detail: hint(kind)) {
                        if let size = ToolGroup.totalSize(of: items), items.count > 1 {
                            Text("共 \(items.count) 项 · \(size.display)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, artifact in
                            ArtifactRow(artifact: artifact, group: group, largest: largest)
                            if model.expanded.contains(artifact.path) {
                                let children = model.children(of: artifact, in: group)
                                if children.isEmpty {
                                    Text("里面没有可以单独列出的子项")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .padding(.leading, UI.textIndent + 12)
                                        .padding(.vertical, 8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    ForEach(children) { child in
                                        ArtifactRow(artifact: child, group: group, depth: 1, largest: largest)
                                    }
                                }
                            }
                            if index < items.count - 1 {
                                Divider().padding(.leading, UI.textIndent + 12)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                    .background(Color.groupFill, in: RoundedRectangle(cornerRadius: UI.corner))
                }
            }
        }
    }

    private func hint(_ kind: ArtifactKind) -> String? {
        guard group.section != .managedByApp else { return nil }
        switch kind {
        case .program: return "卸载就是移走这些"
        case .launcher: return "扫描发现的命令入口"
        case .cache, .logs: return "可以放心清理"
        case .data: return "会话、历史等；移走后工具里就找不回了"
        case .config: return "设置"
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(rc.text)
                            .font(.system(.caption, design: .monospaced))
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(outer.isEmpty
                         ? "没有勾选任何条目"
                         : "已选 \(outer.count) 项" + (swallowed > 0 ? "（连同里面的 \(swallowed) 个子项）" : ""))
                        .font(.callout.weight(.medium))
                    if let size = model.selectedSize(group), !outer.isEmpty {
                        Text(size.display)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(outer.isEmpty
                     ? selectionHint
                     : risky
                        ? "含共用、凭据或归属不确定的条目，确认单里会逐条列出"
                        : "移到废纸篓不会立刻释放空间，清空后才释放")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu("选择") {
                Button("恢复默认勾选") { model.selectDefaults(group) }
                Button(group.section == .installed ? "连同配置和数据（不含登录凭据）" : "全选（不含登录凭据）") {
                    model.selectAll(group)
                }
                Divider()
                Button("全部取消") { model.selectNone(group) }
            }
            .fixedSize()
            .help("批量调整勾选")

            Button {
                model.preparePlan(for: group)
            } label: {
                Label("移到废纸篓…", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(outer.isEmpty || model.isBusy || model.isScanning)
            .help("先看确认单，再决定要不要移走")
        }
        .padding(.horizontal, UI.gutter)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var selectionHint: String {
        switch group.section {
        case .installed:
            return "默认只勾程序、启动链接、缓存和日志；配置与数据要自己点"
        case .residue:
            return "确定的旧残留才默认勾选；最近写入或顶层目录仍要确认"
        case .unidentified, .otherCLI:
            return "归属不确定，默认不勾选；请确认后再清理"
        case .managedByApp:
            return "由桌面 App 使用，不在管理范围内"
        }
    }
}

// MARK: - 头部

/// 名称、来源、状态、占用、默认可清理量，一屏之内说清楚。
struct GroupHeader: View {
    let group: ToolGroup
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                ToolIcon(name: group.name, section: group.section, size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name)
                        .font(.title2.weight(.semibold))
                    Text(facts)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(group.totalSize?.display ?? (model.isMeasuring ? "…" : "—"))
                        .font(.system(.title2, design: .rounded).weight(.medium).monospacedDigit())
                    Text("总占用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                if group.isRunning {
                    Badge(text: "正在运行", color: .green, filled: true,
                          help: "PID " + group.runningPIDs.map(String.init).joined(separator: "、"))
                }
                if group.section == .residue { Badge(text: "程序已不在", color: .orange) }
                if group.section == .unidentified { Badge(text: "归属不明", color: .orange, help: "默认都不勾选，请自己判断") }
                if let shared = sharedSummary {
                    Badge(text: shared, color: .orange, help: "已安装的桌面 App 也在用这些位置，移走会影响它")
                }
                if group.binaries.contains(where: { $0.invalidTarget != nil }) {
                    Badge(text: "有命令入口异常", color: .orange, help: "入口指向的不是可执行程序，详见下方命令区")
                }
                if let docs = group.docs ?? group.homepage, let url = URL(string: docs) {
                    Link(destination: url) {
                        Label("官方文档", systemImage: "safari")
                            .font(.caption)
                    }
                }
                Spacer(minLength: 0)
            }
            Text(group.section.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if group.section != .managedByApp, let clean = defaultCleanable {
                Label(defaultCleanableText(clean), systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func defaultCleanableText(_ clean: SizeResult) -> String {
        switch group.section {
        case .installed:
            return "默认勾选可清理 \(clean.display)，配置、数据和登录凭据默认保留"
        case .residue:
            return "默认勾选可清理 \(clean.display)；最近写入、共用和归属不确定的条目默认保留"
        case .unidentified, .otherCLI, .managedByApp:
            return "默认勾选可清理 \(clean.display)；登录凭据默认保留"
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
        return parts.joined(separator: "  ·  ")
    }

    private var sharedSummary: String? {
        let names = Array(Set(group.artifacts.compactMap { a in
            a.flags.contains(.shared) ? (a.ownerAppName ?? "桌面 App") : nil
        })).sorted()
        guard !names.isEmpty else { return nil }
        return "与 " + names.joined(separator: "、") + " 共用"
    }

    /// 默认勾选里最外层那些条目的合计。
    private var defaultCleanable: SizeResult? {
        ToolGroup.totalSize(of: group.artifacts.filter { $0.defaultSelected && $0.parentPath == nil })
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(group.binaries.enumerated()), id: \.element.path) { index, binary in
                    BinaryRow(binary: binary,
                              hasDuplicate: group.binaries.contains(where: { $0.name == binary.name && $0.path != binary.path }))
                    if index < group.binaries.count - 1 {
                        Divider().padding(.leading, 12)
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
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                if hasDuplicate {
                    Badge(text: "同名入口", color: .secondary,
                          help: "扫描发现多个同名入口；实际 shell PATH 优先级未确认")
                }
                if binary.isDangling {
                    Badge(text: "悬空", color: .secondary, help: "它指向的东西已经不存在")
                }
                if let target = binary.brokenShimTarget {
                    Badge(text: "已失效", color: .orange, help: "启动脚本 exec 的程序已不存在：\(target)")
                }
                if let invalid = binary.invalidTarget {
                    Badge(text: "入口异常", color: .orange,
                          help: "入口最终指向的不是可执行程序，而是\(invalid)")
                }
                if let identifier = binary.signIdentifier, identifier != "-" {
                    Badge(text: "签名 " + identifier, color: .secondary,
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
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(chain.enumerated()), id: \.offset) { index, link in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(index == 0 ? "入口" : (index == chain.count - 1 ? "链路目标" : "链接到"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 48, alignment: .trailing)
                        Text(model.show(link))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(index == chain.count - 1 ? Color.primary : Color.secondary)
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

        HStack(alignment: .center, spacing: 8) {
            if group.section != .managedByApp {
                Toggle("", isOn: Binding(
                    get: { implied || model.isSelected(artifact, in: group) },
                    set: { model.setSelected(artifact, in: group, $0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!selectable || implied)
                .frame(width: 16)
                .help(implied ? "上级目录已勾选，这一项会被一并移走" : "勾选后随「移到废纸篓」一起处理")
                .accessibilityLabel("勾选 \(PathUtil.lastComponent(artifact.path))")
            }

            if artifact.expandable && depth == 0 {
                Button {
                    model.toggleExpand(artifact, in: group)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(model.expanded.contains(artifact.path) ? 90 : 0))
                        .frame(width: 16, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(model.expanded.contains(artifact.path) ? "收起子项" : "展开一层")
                .help("展开一层，可以只清理里面的某几项")
            } else {
                Color.clear.frame(width: 16, height: 1)
            }

            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(depth == 0 ? artifact.display(home: model.env.home) : PathUtil.lastComponent(artifact.path))
                    .font(.system(.callout, design: depth == 0 ? .monospaced : .default))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(artifact.path)
                if hasDetail {
                    HStack(spacing: 5) {
                        FlagBadges(artifact: artifact, section: group.section)
                        if let foreign = foreignSummary {
                            Text(foreign)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                                .help(foreign)
                        }
                        if let note = artifact.note {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(note)
                        }
                    }
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 4) {
                Text(sizeText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(sizeHelp)
                if depth == 0, let bytes = artifact.size?.bytes, bytes > 0, largest > 0 {
                    SizeBar(fraction: Double(bytes) / Double(largest), color: .secondary)
                }
            }
            .frame(width: UI.sizeColumn, alignment: .trailing)

            RowActions(
                onEvidence: { showEvidence = true },
                onReveal: { model.reveal(artifact.path) },
                emphasized: hovering || focused
            )
        }
        .padding(.leading, depth == 0 ? 0 : UI.textIndent - 16)
        .padding(.vertical, 7)
        .background(hovering ? Color.rowHover : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .focusable()
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
        .popover(isPresented: $showEvidence, arrowEdge: .trailing) {
            EvidenceView(artifact: artifact)
        }
    }

    private var isPicked: Bool {
        model.isImplied(artifact, in: group) || model.isSelected(artifact, in: group)
    }

    private var hasDetail: Bool {
        !artifact.flags.isEmpty || artifact.note != nil || !artifact.foreignChildren.isEmpty
            || artifact.strength != .certain
    }

    private var symbol: String {
        if artifact.isSymlink { return "link" }
        if artifact.isDirectory { return "folder" }
        if artifact.kind == .credentials { return "key" }
        return "doc"
    }

    private var tint: Color {
        if artifact.flags.contains(.credentials) { return .orange }
        return .secondary
    }

    /// 一句话点出目录里属于别处的条目；完整清单在证据气泡里。
    private var foreignSummary: String? {
        guard let first = artifact.foreignChildren.first else { return nil }
        let name = PathUtil.lastComponent(first.path) + "/"
        let rest = artifact.foreignChildren.count > 1 ? " 等 \(artifact.foreignChildren.count) 项" : ""
        let blocked = artifact.foreignChildren.contains(where: { $0.blocksRemoval })
        return "内含 \(first.owner) 的 \(name)\(rest)" + (blocked ? "，整个目录不能移走；展开后可只清理其余子项" : "，移走外层会一并带走")
    }

    /// 只含软链的目录、悬空软链本身，占不了什么空间，显示「—」比「0 字节」清楚。
    private var sizeText: String {
        guard let size = artifact.size else { return model.isMeasuring ? "…" : "—" }
        if size.bytes == 0, artifact.isDirectory || artifact.isSymlink { return "—" }
        return size.display
    }

    private var sizeHelp: String {
        guard let size = artifact.size else { return "还没量完" }
        return size.accurate ? size.display : "有读不到的子目录，实际至少 \(size.display)"
    }
}
