import ACMCore
import AppKit
import SwiftUI

// MARK: - 展示用的名字

extension SweepCategory {
    var displayName: String {
        switch self {
        case .swiftCache: return "SwiftPM 缓存"
        case .nodeDependencies: return "Node 依赖"
        case .orphanNodeDependencies: return "孤立的 Node 依赖"
        case .pythonCache: return "Python 字节码"
        case .webCache: return "前端构建缓存"
        case .unrecognizedCache: return "名字像缓存"
        case .installer: return "安装包"
        }
    }

    var symbol: String {
        switch self {
        case .swiftCache, .webCache, .pythonCache: return "hammer"
        case .nodeDependencies, .orphanNodeDependencies: return "shippingbox"
        case .unrecognizedCache: return "questionmark.folder"
        case .installer: return "arrow.down.circle"
        }
    }
}

extension SweepStatus {
    var hint: String {
        switch self {
        case .cleanup: return "有生成依据、闲置、没有进程占用"
        case .review: return "证据不够或最近还在写，本 App 不会动"
        case .keep: return "最新版本的安装包"
        case .blocked: return "有保护条件拦着，本 App 不会动"
        }
    }
}

func sweepSize(_ bytes: Int64) -> String {
    bytes == 0 ? "—" : SweepOutput.size(bytes)
}

/// 选一个要清理的文件夹。返回 nil 表示取消。
@MainActor
enum SweepFolderPicker {
    static func pick() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "扫描这个文件夹"
        panel.message = "选一个放项目或下载文件的文件夹。扫描只读取目录，不修改任何文件。"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

// MARK: - 侧栏

/// 侧栏顶部：在「工具」和「项目清理」之间切换。
struct WorkspaceSwitch: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            segment(.tools, "工具", "terminal")
            segment(.sweep, "项目清理", "folder")
        }
        .padding(2)
        .background(Color.barFill, in: RoundedRectangle(cornerRadius: 8))
    }

    private func segment(_ workspace: Workspace, _ title: String, _ symbol: String) -> some View {
        let selected = model.workspace == workspace
        return Button {
            model.workspace = workspace
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                Text(title)
                    .font(.acmCaptionMed)
            }
            .foregroundStyle(selected ? Color.textPrimary : Color.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(selected ? Color.surfaceRaised : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.lineHairline, lineWidth: UI.hairline)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 「项目清理」的侧栏：扫描过的文件夹，加一个「添加文件夹」。
struct SweepFolderList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sweep = model.sweep
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 14)
                    Text("文件夹")
                        .font(.acmCaptionMed)
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(sweep.folders.count)")
                        .font(.acmCaption)
                        .foregroundStyle(Color.textTertiary)
                        .monospacedDigit()
                }
                .padding(.init(top: 10, leading: 8, bottom: 4, trailing: 8))

                ForEach(sweep.folders, id: \.self) { folder in
                    SweepFolderRow(folder: folder)
                }
                if sweep.folders.isEmpty {
                    Text("还没有添加文件夹。选一个放项目或下载文件的文件夹，本 App 只在你选的文件夹里找。")
                        .font(.acmCaption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                Button {
                    if let path = SweepFolderPicker.pick() { sweep.addFolder(path) }
                } label: {
                    Label("添加文件夹…", systemImage: "plus")
                        .font(.acmCallout)
                        .foregroundStyle(Color.textPrimary)
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.snapshot != nil)
                .padding(.top, 4)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }
}

struct SweepFolderRow: View {
    let folder: String
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let sweep = model.sweep
        let selected = sweep.selectedFolder == folder
        Button {
            sweep.select(folder)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Color.toolIconFill, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(PathUtil.lastComponent(folder))
                        .font(.acmBodyMed)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Text(model.show(PathUtil.parent(folder)))
                        .font(.acmCaption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                trailing
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Color.fillSelected : hovering ? Color.rowHover : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(folder)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("在 Finder 中显示") { model.reveal(folder) }
            Button("从清单中移除") { sweep.removeFolder(folder) }
                .disabled(sweep.isBusy)
        }
    }

    @ViewBuilder private var trailing: some View {
        let sweep = model.sweep
        if sweep.isScanning(folder) {
            ProgressView().controlSize(.small)
        } else if sweep.errors[folder] != nil {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(Color.acmCaution)
                .help("没能扫描这个文件夹")
        } else if let plan = sweep.plans[folder] {
            Text(sweepSize(plan.summary.estimatedCleanupBytes))
                .font(.acmMonoPath)
                .foregroundStyle(Color.textSecondary)
                .fixedSize()
                .help("可清理 \(plan.summary.cleanup) 项")
        }
    }
}

/// 侧栏底部：项目清理里移到废纸篓、还能放回的内容。
struct SweepRecoverFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let runs = model.sweep.pendingRuns
        Button {
            model.sweep.refreshPending()
            model.sweep.showRecovery = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(runs.isEmpty ? Color.textTertiary : Color.acmRecover)
                    .frame(width: 14)
                Text("可放回原处")
                    .font(.acmCallout)
                    .foregroundStyle(runs.isEmpty ? Color.textSecondary : Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(runs.isEmpty ? "暂无" : "\(runs.count) 次清理")
                    .font(.acmCaption)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.sweep.isBusy)
        .help(runs.isEmpty ? "项目清理移到废纸篓的内容会在这里留下回执" : "查看移到废纸篓、还能放回的内容")
    }
}

// MARK: - 详情

struct SweepDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var collapsed: Set<SweepStatus> = [.keep, .blocked]
    @State private var showAll: Set<SweepStatus> = []
    private static let rowLimit = 200

    var body: some View {
        let sweep = model.sweep
        Group {
            if let folder = sweep.selectedFolder {
                if let plan = sweep.plan {
                    content(plan, folder: folder)
                } else if let error = sweep.error {
                    failure(error, folder: folder)
                } else {
                    scanning(folder)
                }
            } else {
                empty
            }
        }
        .background(Color.surfaceBase)
        .navigationTitle("Agent CLI Manager")
    }

    // MARK: 占位

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 24))
                .foregroundStyle(Color.textTertiary)
                .padding(.bottom, 4)
            Text("选一个要清理的文件夹")
                .font(.acmTitle)
                .foregroundStyle(Color.textPrimary)
            Text("在你选的文件夹里找闲置的构建缓存、开发依赖和旧安装包。\n扫描只读取目录；清理前会列出清单让你核对。")
                .font(.acmCallout)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
            Button("添加文件夹…") {
                if let path = SweepFolderPicker.pick() { model.sweep.addFolder(path) }
            }
            .buttonStyle(.acmPrimary)
            .disabled(model.snapshot != nil)
            .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scanning(_ folder: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
                .padding(.bottom, 4)
            Text("正在扫描「\(PathUtil.lastComponent(folder))」…")
                .font(.acmBodyMed)
                .foregroundStyle(Color.textPrimary)
            Text("只读取目录，不修改任何文件")
                .font(.acmCaption)
                .foregroundStyle(Color.textSecondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ error: SweepError, folder: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(Color.acmCaution)
                .padding(.bottom, 4)
            Text("没能扫描「\(PathUtil.lastComponent(folder))」")
                .font(.acmTitle)
                .foregroundStyle(Color.textPrimary)
            Text(error.message)
                .font(.acmCallout)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Button("从清单中移除") { model.sweep.removeFolder(folder) }
                    .buttonStyle(.acmSecondary)
                Button("重新扫描") { model.sweep.rescan() }
                    .buttonStyle(.acmPrimary)
            }
            .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 结果

    private func content(_ plan: SweepPlan, folder: String) -> some View {
        let largest = plan.items.map { $0.snapshot?.allocatedBytes ?? 0 }.max() ?? 0
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: UI.sectionGap) {
                    header(plan, folder: folder)
                    if !plan.warnings.isEmpty { warnings(plan) }
                    if plan.items.isEmpty {
                        Text("这个文件夹里没有发现构建缓存、开发依赖或安装包。")
                            .font(.acmCallout)
                            .foregroundStyle(Color.textSecondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.groupFill, in: RoundedRectangle(cornerRadius: UI.corner))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach([SweepStatus.cleanup, .review, .keep, .blocked], id: \.self) { status in
                            let items = plan.items.filter { $0.status == status }
                            if !items.isEmpty { section(status, items: items, plan: plan, largest: largest) }
                        }
                    }
                }
                .padding(.horizontal, UI.gutter)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Hairline()
            actionBar(plan)
        }
    }

    private func header(_ plan: SweepPlan, folder: String) -> some View {
        let sweep = model.sweep
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(Color.toolIconFill, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(PathUtil.lastComponent(folder))
                        .font(.acmTitle)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Text(model.show(folder))
                        .font(.acmMonoPath)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder)
                }
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(sweepSize(plan.summary.estimatedCleanupBytes))
                        .font(.acmMonoDisplay)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Text("可清理 · \(plan.summary.cleanup) 项")
                        .font(.acmCaption)
                        .foregroundStyle(Color.textSecondary)
                }
                .fixedSize()
                .help("按文件占用的磁盘块估算；硬链接只算一次，APFS 克隆会让实际释放量不同")
            }
            HStack(spacing: 8) {
                Text("保留 \(plan.summary.keep) 项 · 需复核 \(plan.summary.review) 项 · 跳过 \(plan.summary.blocked) 项")
                    .font(.acmCaption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Menu {
                    ForEach(SweepIdle.allCases) { choice in
                        Button {
                            sweep.setIdle(choice)
                        } label: {
                            if choice == sweep.idle {
                                Label(choice.label, systemImage: "checkmark")
                            } else {
                                Text(choice.label)
                            }
                        }
                    }
                } label: {
                    Text(sweep.idle.label)
                        .font(.acmCaption)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .disabled(sweep.isBusy)
                .help("最近还在写入的缓存和依赖不算可清理；这里调整要闲置多久")
            }
        }
    }

    private func warnings(_ plan: SweepPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(plan.warnings, id: \.self) { warning in
                Label(warning.message, systemImage: "info.circle")
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

    private func section(_ status: SweepStatus, items: [SweepItem], plan: SweepPlan, largest: Int64) -> some View {
        let open = !collapsed.contains(status)
        let limited = showAll.contains(status) ? items : Array(items.prefix(Self.rowLimit))
        return VStack(spacing: 0) {
            sectionHeader(status, items: items, open: open)
            if open {
                ForEach(limited) { item in
                    Hairline().padding(.horizontal, 10)
                    SweepItemRow(item: item, plan: plan, largest: largest)
                }
                if limited.count < items.count {
                    Hairline().padding(.horizontal, 10)
                    Button("显示其余 \(items.count - limited.count) 项") { showAll.insert(status) }
                        .buttonStyle(.acmCompact)
                        .padding(.vertical, 8)
                }
            }
        }
        .padding(.vertical, 2)
        .background(Color.groupFill, in: RoundedRectangle(cornerRadius: UI.corner))
    }

    private func sectionHeader(_ status: SweepStatus, items: [SweepItem], open: Bool) -> some View {
        let sweep = model.sweep
        let bytes = items.reduce(Int64(0)) { $0 + ($1.snapshot?.allocatedBytes ?? 0) }
        let picked = items.filter { sweep.isSelected($0) }.count
        return HStack(spacing: 8) {
            if status == .cleanup {
                ACMCheckbox(state: picked == 0 ? .off : picked == items.count ? .on : .mixed,
                            label: "勾选全部可清理项") {
                    sweep.toggleAllCleanup()
                }
                .help(picked == items.count ? "全部取消" : "勾选全部可清理项，包括旧版本安装包")
            }
            Button {
                if open { collapsed.insert(status) } else { collapsed.remove(status) }
            } label: {
                HStack(spacing: 8) {
                    if status != .cleanup {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.textSecondary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: UI.checkbox)
                    }
                    Text(status.displayName)
                        .font(.acmHeadline)
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize()
                    Text(status.hint)
                        .font(.acmCaption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(items.count) 项")
                        .font(.acmCaption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize()
                    Text(sweepSize(bytes))
                        .font(.acmMonoNum)
                        .foregroundStyle(bytes == 0 ? Color.textTertiary : Color.textPrimary)
                        .lineLimit(1)
                        .frame(width: UI.sizeColumn, alignment: .trailing)
                }
                .frame(height: UI.hitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(status.displayName)，\(items.count) 项")
            .accessibilityHint(open ? "收起" : "展开")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    // MARK: 底部

    private func actionBar(_ plan: SweepPlan) -> some View {
        let sweep = model.sweep
        let chosen = sweep.selectedItems
        let blocked = chosen.isEmpty || sweep.isBusy || sweep.isPreparing || sweep.isScanning
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(chosen.isEmpty ? "没有勾选任何条目" : "将清理 \(chosen.count) 项")
                        .font(.acmBodyMed)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    if !chosen.isEmpty {
                        Text("· " + sweepSize(sweep.selectedBytes))
                            .font(.acmMonoNum)
                            .foregroundStyle(Color.textPrimary)
                    }
                }
                Text("移到废纸篓的可以放回原处，清空废纸篓后才释放空间 · 清理前会重新核对每一项")
                    .font(.acmCallout)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if sweep.isPreparing {
                ProgressView()
                    .controlSize(.small)
                    .help("正在重新核对勾选的条目")
            }
            Menu {
                Text("勾选和取消都不改文件，只有确认之后才清理")
                Button("恢复默认勾选") { sweep.selectDefaults() }
                    .help("缓存、依赖和内容相同的重复安装包；不含旧版本安装包")
                Button("选择全部可清理项（含旧版本安装包）") { sweep.selectAllCleanup() }
                Divider()
                Button("全部取消") { sweep.selectNone() }
            } label: {
                Text("选择")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("批量调整勾选")

            Button("永久删除…") {
                Task { await sweep.prepare(mode: .permanent) }
            }
            .buttonStyle(.acmSecondary)
            .disabled(blocked)
            .help("打开确认单。永久删除不经过废纸篓，删除后无法恢复")

            Button("移到废纸篓…") {
                Task { await sweep.prepare(mode: .trash) }
            }
            .buttonStyle(.acmPrimary)
            .disabled(blocked)
            .help("打开确认单，核对后才会移走所选条目")
            .layoutPriority(1)
        }
        .padding(.horizontal, UI.gutter)
        .frame(height: 78)
        .background(Color.surfaceBase)
    }
}

/// 候选项的一行：勾选框、类别、路径和结论的原因、占用。
struct SweepItemRow: View {
    let item: SweepItem
    let plan: SweepPlan
    var largest: Int64 = 0
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let sweep = model.sweep
        let bytes = item.snapshot?.allocatedBytes ?? 0
        HStack(alignment: .center, spacing: 8) {
            ACMCheckbox(state: item.status != .cleanup ? .protected : sweep.isSelected(item) ? .on : .off,
                        label: "勾选 \(PathUtil.lastComponent(item.path))") {
                sweep.setSelected(item, !sweep.isSelected(item))
            }
            .help(item.status == .cleanup ? "勾选后进入清理确认清单" : "\(item.status.displayName)：不能勾选")

            Image(systemName: item.snapshot?.kind == "file" ? item.category.symbol : "folder")
                .font(.system(size: 13))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.path)
                        .font(.acmMonoNum)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(plan.absolutePath(of: item))
                        .layoutPriority(1)
                    Badge(text: item.category.displayName)
                    if let version = item.installer?.version?.text {
                        Badge(text: version, help: versionHelp)
                    }
                    if plan.isSupersededVersion(item) {
                        Badge(text: "按文件名推测", color: .acmCaution,
                              help: "新旧是按文件名里的版本号判断的，默认不勾选，请自己核对")
                    }
                    if !(item.processes ?? []).isEmpty {
                        Badge(text: "正在使用", color: .acmCaution, filled: true, help: processHelp)
                    }
                }
                Text(item.reason)
                    .font(.acmCaption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            Button {
                model.reveal(plan.absolutePath(of: item))
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textPrimary)
                    .frame(width: UI.hitTarget, height: UI.hitTarget)
                    .background(Color.rowHover, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .accessibilityLabel("在 Finder 中显示")
            .help("在 Finder 中显示")

            VStack(alignment: .trailing, spacing: 4) {
                Text(sweepSize(bytes))
                    .font(.acmMonoNum)
                    .foregroundStyle(bytes == 0 ? Color.textTertiary : Color.textPrimary)
                    .lineLimit(1)
                SizeBar(fraction: largest > 0 ? Double(bytes) / Double(largest) : 0)
            }
            .frame(width: UI.sizeColumn, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(hovering ? Color.rowHover : Color.clear)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("在 Finder 中显示") { model.reveal(plan.absolutePath(of: item)) }
            Button("复制路径") { model.copy(plan.absolutePath(of: item)) }
        }
    }

    private var versionHelp: String {
        guard let installer = item.installer else { return "" }
        return [installer.product, installer.version?.text, installer.architecture, installer.format]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var processHelp: String {
        (item.processes ?? []).map { "\($0.command)（PID \($0.pid)）" }.joined(separator: "、")
    }
}
