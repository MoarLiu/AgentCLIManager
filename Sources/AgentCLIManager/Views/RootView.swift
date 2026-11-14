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
                    if let group = model.selectedGroup {
                        DetailView(group: group)
                    } else {
                        DetailPlaceholder(scanning: model.isScanning)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                OperationStatusView()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if model.isScanning || model.isMeasuring {
                    ProgressView()
                        .controlSize(.small)
                        .help(model.isScanning ? "正在扫描" : "正在计算占用")
                }
                Button {
                    model.rescan()
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanning)
                .help("重新扫描（⌘R）")

                Button {
                    model.showInstall = true
                } label: {
                    Label("安装新工具", systemImage: "plus")
                }
                .help("从目录清单里挑一个工具安装")
            }
        }
        .sheet(isPresented: Binding(
            get: { model.plan != nil },
            set: { if !$0 { model.plan = nil } }
        )) {
            if let plan = model.plan { ConfirmSheet(plan: plan) }
        }
        .sheet(isPresented: Binding(
            get: { model.result != nil },
            set: { if !$0 { model.result = nil } }
        )) {
            if let result = model.result { ResultSheet(result: result) }
        }
        .sheet(isPresented: $model.showInstall) {
            InstallSheet()
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var collapsed: Set<ACMCore.Section> = [.otherCLI, .managedByApp]

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedGroupID) {
            ForEach(ACMCore.Section.allCases, id: \.self) { section in
                let groups = model.groups(in: section)
                if !groups.isEmpty {
                    SwiftUI.Section(isExpanded: expansion(section)) {
                        ForEach(groups) { group in
                            GroupRow(group: group)
                                .tag(group.id)
                        }
                    } header: {
                        HStack(spacing: 5) {
                            Text(section.displayName)
                            Text("\(groups.count)")
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.search, placement: .sidebar, prompt: "搜索工具或路径")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DiskFooter()
        }
    }

    private func expansion(_ section: ACMCore.Section) -> Binding<Bool> {
        Binding(
            // 搜索时全部展开，否则搜到了也看不见
            get: { !model.search.isEmpty || !collapsed.contains(section) },
            set: { expanded in
                if expanded { collapsed.remove(section) } else { collapsed.insert(section) }
            }
        )
    }
}

struct GroupRow: View {
    let group: ToolGroup
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            ToolIcon(name: group.name, section: group.section, size: 26,
                     selected: model.selectedGroupID == group.id)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(group.name)
                        .font(.callout)
                        .lineLimit(1)
                    if group.isRunning {
                        Circle()
                            .fill(.green)
                            .frame(width: 5, height: 5)
                            .help("正在运行")
                            .accessibilityLabel("正在运行")
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(sizeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
                .help(group.totalSize.map { "共 \($0.display)" } ?? "正在计算占用")
        }
        .padding(.vertical, 3)
    }

    private var sizeText: String {
        guard let size = group.totalSize else { return model.isMeasuring ? "…" : "" }
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

/// 磁盘占用：一行数字 + 一条细条，配上「Agent CLI 占了多少」。
/// 不再用两行小字加进度条挤在一起。
struct DiskFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let report = model.report, let free = report.diskFreeBytes, let total = report.diskTotalBytes, total > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("磁盘可用")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(format(free))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                DiskUsageBar(free: free, total: total)
                Text("共 \(format(total))")
                    .foregroundStyle(.tertiary)
            }
            if let footprint = model.managedFootprint {
                HStack(spacing: 5) {
                    Image(systemName: "terminal")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Agent CLI 与残留占用 \(footprint.display)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.top, 10)
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
                    .fill(tint.opacity(0.8))
                    .frame(width: max(3, geo.size.width * CGFloat(usedFraction)))
            }
        }
        .frame(height: 5)
        .help("已用 \(ByteCountFormatter.string(fromByteCount: total - free, countStyle: .file))，可用 \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))")
    }

    private var tint: Color {
        Double(free) / Double(total) < 0.12 ? .red : .secondary
    }
}
