import ACMCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 244, ideal: 268, max: 340)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if model.workspace == .sweep {
                        SweepDetailView()
                    } else if let group = model.selectedGroup {
                        DetailView(group: group)
                    } else {
                        DetailPlaceholder(scanning: model.isScanning)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                OperationStatusView()
            }
            .background(Color.surfaceBase)
        }
        .toolbar {
            ToolbarItemGroup {
                let sweeping = model.workspace == .sweep
                if sweeping ? model.sweep.isScanningAny : (model.isScanning || model.isMeasuring) {
                    ProgressView()
                        .controlSize(.small)
                        .help(sweeping || model.isScanning ? "正在扫描" : "正在计算占用")
                }
                Button {
                    model.rescanCurrent()
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .disabled(sweeping
                          ? model.sweep.selectedFolder == nil || model.sweep.isScanning || model.sweep.isBusy
                          : model.isScanning)
                .help(sweeping ? "重新扫描这个文件夹（⌘R）" : "重新扫描（⌘R）")

                if sweeping {
                    Button {
                        if let path = SweepFolderPicker.pick() { model.sweep.addFolder(path) }
                    } label: {
                        Text("添加文件夹…")
                    }
                    .disabled(model.snapshot != nil)
                    .help("选一个放项目或下载文件的文件夹来清理")
                } else {
                    Button {
                        model.showInstall = true
                    } label: {
                        Text("安装工具…")
                    }
                    .help("从目录清单里挑一个工具安装")
                }
            }
        }
        .sheet(item: Binding(
            get: { presentedSheet },
            set: { newValue in
                guard newValue == nil else { return }
                model.plan = nil
                model.planConfirmationToken = nil
                model.result = nil
                model.showInstall = false
                model.showRecovery = false
                model.sweep.cancelConfirmation()
                model.sweep.result = nil
                model.sweep.showRecovery = false
            }
        )) { sheet in
            switch sheet {
            case .confirm:
                if let plan = model.plan {
                    ConfirmSheet(plan: plan, preservedArtifacts: model.preservedTopLevelArtifacts(for: plan))
                }
            case .result:
                if let result = model.result { ResultSheet(result: result) }
            case .install:
                InstallSheet()
            case .evidence:
                if let pair = snapshotEvidence {
                    EvidenceView(artifact: pair.artifact, group: pair.group)
                }
            case .recovery:
                RecoverySheet()
            case .sweepConfirm:
                if let confirmation = model.sweep.confirmation {
                    SweepConfirmSheet(confirmation: confirmation)
                        .id(confirmation.id)
                }
            case .sweepResult:
                if let result = model.sweep.result { SweepResultSheet(result: result) }
            case .sweepRecovery:
                SweepRecoverySheet()
            }
        }
    }

    /// 三种主弹窗互斥，避免一个根视图同时挂多个 sheet 导致展示不确定。
    private var presentedSheet: PresentedSheet? {
        if model.plan != nil { return .confirm }
        if model.result != nil { return .result }
        if model.showInstall { return .install }
        if model.showRecovery { return .recovery }
        if model.sweep.confirmation != nil { return .sweepConfirm }
        if model.sweep.result != nil { return .sweepResult }
        if model.sweep.showRecovery { return .sweepRecovery }
        if model.snapshot?.sheet == "evidence", snapshotEvidence != nil { return .evidence }
        return nil
    }

    private var snapshotEvidence: (artifact: Artifact, group: ToolGroup)? {
        guard model.snapshot?.sheet == "evidence", let group = model.selectedGroup,
              let artifact = group.artifacts.first(where: { $0.parentPath == nil }) else { return nil }
        return (artifact, group)
    }

    private enum PresentedSheet: String, Identifiable {
        case confirm, result, install, evidence, recovery
        case sweepConfirm, sweepResult, sweepRecovery
        var id: String { rawValue }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var collapsed: Set<ACMCore.Section> = SidebarView.defaultCollapsed
    static var defaultCollapsed: Set<ACMCore.Section> {
        guard let raw = SnapshotOptions.parse(CommandLine.arguments)?.expandSection,
              let section = ACMCore.Section(rawValue: raw) else {
            return [.otherCLI, .managedByApp]
        }
        var result: Set<ACMCore.Section> = [.otherCLI, .managedByApp]
        result.remove(section)
        return result
    }
    @FocusState private var focusedGroupID: ToolGroup.ID?

    var body: some View {
        @Bindable var model = model
        let sections = ACMCore.Section.allCases.map { ($0, model.groups(in: $0)) }.filter { !$0.1.isEmpty }
        let largest = sections.flatMap { $0.1 }.map { $0.totalSize?.bytes ?? 0 }.max() ?? 0

        VStack(spacing: 0) {
        WorkspaceSwitch()
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 8)
        if model.workspace == .sweep {
            SweepFolderList()
        } else {
        SidebarSearchField(text: $model.search)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(sections, id: \.0) { section, groups in
                        header(section, count: groups.count)
                        if isExpanded(section) {
                            ForEach(groups) { group in
                                GroupRow(group: group, largest: largest, focusedGroupID: $focusedGroupID) { direction in
                                    move(direction, proxy: proxy)
                                }
                                    .id(group.id)
                            }
                        }
                    }
                    if sections.isEmpty, !model.search.isEmpty {
                        Text("没有匹配的工具或路径")
                            .font(.acmCaption)
                            .foregroundStyle(Color.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onMoveCommand { direction in
                switch direction {
                case .down: move(1, proxy: proxy)
                case .up: move(-1, proxy: proxy)
                default: return
                }
            }
        }
        }
        }
        .background(Color.surfaceSidebar)
        .onAppear {
            // 初次打开就把键盘焦点放到当前工具，方向键不用先鼠标点一下。
            if focusedGroupID == nil { focusedGroupID = model.selectedGroupID }
        }
        .onChange(of: model.search) { _, _ in
            // 搜索可能让当前焦点行消失，把焦点交给仍然选中的可见行。
            if let selected = model.selectedGroupID,
               ACMCore.Section.allCases.flatMap({ model.groups(in: $0) }).contains(where: { $0.id == selected }) {
                focusedGroupID = selected
            }
        }
        .onChange(of: model.selectedGroupID) { _, newValue in
            guard focusedGroupID != nil else { return }
            focusedGroupID = newValue
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Hairline()
                if model.workspace == .sweep {
                    SweepRecoverFooter()
                } else {
                    RecoverFooter { model.showRecovery = true }
                }
                DiskFooter()
            }
            .background(Color.surfaceSidebar)
        }
    }

    static func adjacentGroupID(in model: AppModel, collapsed: Set<ACMCore.Section>, direction: Int) -> ToolGroup.ID? {
        let visible = ACMCore.Section.allCases
            .filter { !model.search.isEmpty || !collapsed.contains($0) }
            .flatMap { model.groups(in: $0) }
        guard !visible.isEmpty else { return nil }
        let index = visible.firstIndex { $0.id == model.selectedGroupID }
        let next = max(0, min(visible.count - 1, (index ?? (direction > 0 ? -1 : 1)) + direction))
        return visible[next].id
    }

    private func move(_ direction: Int, proxy: ScrollViewProxy) {
        guard let next = Self.adjacentGroupID(in: model, collapsed: collapsed, direction: direction) else { return }
        model.selectedGroupID = next
        focusedGroupID = next
        proxy.scrollTo(next)
    }

    // 搜索时全部展开，否则搜到了也看不见
    private func isExpanded(_ section: ACMCore.Section) -> Bool {
        !model.search.isEmpty || !collapsed.contains(section)
    }

    private func header(_ section: ACMCore.Section, count: Int) -> some View {
        let expanded = isExpanded(section)
        return Button {
            if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: section.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 14)
                Text(section.displayName)
                    .font(.acmCaptionMed)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(count)")
                    .font(.acmCaption)
                    .foregroundStyle(Color.textTertiary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .opacity(expanded ? 0 : 1)
            }
            .padding(.init(top: 10, leading: 8, bottom: 4, trailing: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section.explanation)
        .accessibilityLabel("\(section.displayName)，\(count) 个")
        .accessibilityHint(expanded ? "收起" : "展开")
    }
}

/// 侧栏顶部的搜索框：32 pt 高，raised 底色。⌘F 聚焦，Esc 清空。
struct SidebarSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)
            TextField("搜索工具或路径", text: $text)
                .textFieldStyle(.plain)
                .font(.acmCallout)
                .foregroundStyle(Color.textPrimary)
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? Color.lineControl : Color.lineHairline,
                              lineWidth: focused ? 1 : UI.hairline)
        }
        .background {
            // ⌘F 聚焦搜索框
            Button("") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

/// 侧栏行：徽标 + 名称 + 右对齐大小 + 占用条。选中用中性填充。
struct GroupRow: View {
    let group: ToolGroup
    var largest: Int64 = 0
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    var focusedGroupID: FocusState<ToolGroup.ID?>.Binding
    var onMove: (Int) -> Void

    var body: some View {
        let selected = model.selectedGroupID == group.id
        Button {
            focusedGroupID.wrappedValue = group.id
            model.selectedGroupID = group.id
            DispatchQueue.main.async { focusedGroupID.wrappedValue = group.id }
        } label: {
            HStack(spacing: 8) {
                ToolIcon(name: group.name, section: group.section, size: 26, selected: selected,
                             logo: ToolLogo.lookup(catalog: model.catalog, productID: group.productID,
                                                   binaries: group.binaries.map(\.name),
                                                   ownerApps: group.ownerApps))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(group.name)
                            .font(.acmBodyMed)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                        if group.isRunning {
                            Circle()
                                .fill(Color.acmCaution)
                                .frame(width: 5, height: 5)
                                .help("正在运行")
                                .accessibilityLabel("正在运行")
                        }
                        Spacer(minLength: 4)
                        Text(sizeText)
                            .font(.acmMonoPath)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    SizeBar(fraction: largest > 0 ? Double(group.totalSize?.bytes ?? 0) / Double(largest) : 0,
                            width: nil)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Color.fillSelected : hovering ? Color.rowHover : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if focusedGroupID.wrappedValue == group.id {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.lineControl, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused(focusedGroupID, equals: group.id)
        .onChange(of: focusedGroupID.wrappedValue) { _, newValue in
            if newValue == group.id { model.selectedGroupID = group.id }
        }
        .onKeyPress(.downArrow) { onMove(1); return .handled }
        .onKeyPress(.upArrow) { onMove(-1); return .handled }
        .onHover { hovering = $0 }
        .help(subtitle)
        .accessibilityLabel("\(group.name)，\(subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var sizeText: String {
        guard let size = group.totalSize else { return model.isMeasuring ? "…" : "—" }
        return size.bytes == 0 ? "—" : size.display
    }

    private var subtitle: String {
        switch group.section {
        case .installed, .otherCLI:
            let parts = [group.channel?.displayName, group.version].compactMap { $0 }
            return parts.isEmpty ? "命令行工具" : parts.joined(separator: " · ")
        case .residue:
            return "\(group.artifacts.filter { $0.parentPath == nil }.count) 项残留"
        case .unidentified:
            return "归属不明 · 默认不勾选"
        case .managedByApp:
            return "\(group.artifacts.count) 个位置 · 不在管理范围"
        }
    }
}

/// 全局恢复入口：不管选中哪个工具、扫描是否为空，都在侧栏底部。
struct RecoverFooter: View {
    var action: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let batches = model.undoBatchCount
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(batches > 0 ? Color.acmRecover : Color.textTertiary)
                    .frame(width: 14)
                Text("可放回原处")
                    .font(.acmCallout)
                    .foregroundStyle(batches > 0 ? Color.textPrimary : Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(batches > 0 ? "\(batches) 批未恢复" : "暂无")
                    .font(.acmCaption)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .help(batches > 0 ? "查看尚未放回的条目，在清空废纸篓之前都可以放回" : "移到废纸篓的条目会在这里留下回执")
    }
}

/// 磁盘占用：一行数字 + 一条细条，配上「Agent CLI 占了多少」。
/// 不再用两行小字加进度条挤在一起。
struct DiskFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let report = model.report, let free = report.diskFreeBytes, let total = report.diskTotalBytes, total > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("磁盘可用")
                        .foregroundStyle(Color.textSecondary)
                    Spacer(minLength: 4)
                    Text(format(free))
                        .monospacedDigit()
                        .foregroundStyle(Color.textPrimary)
                }
                DiskUsageBar(free: free, total: total)
                Text("共 \(format(total))")
                    .foregroundStyle(Color.textTertiary)
            }
            if let footprint = model.managedFootprint {
                HStack(spacing: 5) {
                    Image(systemName: "terminal")
                        .font(.caption2)
                        .foregroundStyle(Color.textTertiary)
                    Text("Agent CLI 与残留占用 \(footprint.display)")
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .font(.acmCaption)
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 系统存储页那种细条：已用部分用填充色，剩余部分留白，快满时变红。
struct DiskUsageBar: View {
    let free: Int64
    let total: Int64

    var body: some View {
        let usedFraction = Double(total - free) / Double(total)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.barTrack)
                Capsule()
                    .fill(tint)
                    .frame(width: max(3, geo.size.width * CGFloat(usedFraction)))
            }
        }
        .frame(height: 2)
        .help("已用 \(ByteCountFormatter.string(fromByteCount: total - free, countStyle: .file))，可用 \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))")
    }

    private var tint: Color {
        Double(free) / Double(total) < 0.12 ? .acmDanger : .textSecondary
    }
}
