import ACMCore
import SwiftUI

/// 确认单：一句话结论 → 计划变更提示 → 风险 → 将移走（带合计）→ 不会动（弱化）→ 底部说明。
struct ConfirmSheet: View {
    let plan: UninstallPlan
    @Environment(AppModel.self) private var model
    @State private var acknowledged = false
    @State private var showSkipped = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部结论
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: plan.isEmpty ? "trash.slash" : "trash")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(plan.isEmpty ? Color.secondary : Color.red)
                    .frame(width: 38, height: 38)
                    .background((plan.isEmpty ? Color.secondary : Color.red).opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.isEmpty
                         ? "「\(plan.groupName)」没有可以移走的条目"
                         : "把「\(plan.groupName)」的 \(plan.steps.count) 项移到废纸篓？")
                        .font(.title3.weight(.semibold))
                    if !plan.isEmpty {
                        Text("移到废纸篓，不是直接删除；清空之前都可以放回原处")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 14)

            if let notice = model.planNotice {
                Label(notice, systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: UI.corner))
                    .padding(.bottom, 12)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !plan.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("请先看这些风险", systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(plan.warnings, id: \.self) { warning in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Circle()
                                            .fill(Color.orange)
                                            .frame(width: 4, height: 4)
                                        Text(warning)
                                            .font(.callout)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: UI.corner))
                        .overlay {
                            RoundedRectangle(cornerRadius: UI.corner)
                                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
                        }
                    }

                    if !plan.steps.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "将移到废纸篓") {
                                if let size = plan.reclaimable {
                                    Text("合计 \(size.display)")
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            VStack(spacing: 0) {
                                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                                    HStack(spacing: 8) {
                                        Image(systemName: step.isDirectory ? "folder" : step.kind.symbol)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 18)
                                        Text(model.show(step.path))
                                            .font(.system(.callout, design: .monospaced))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .help(step.path)
                                        Spacer(minLength: 8)
                                        Text(step.kind.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 52, alignment: .trailing)
                                        Text(step.size?.display ?? "—")
                                            .font(.callout.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .frame(width: UI.sizeColumn, alignment: .trailing)
                                    }
                                    .padding(.vertical, 6)
                                    if index < plan.steps.count - 1 {
                                        Divider().padding(.leading, 26)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            .background(Color.groupFill, in: RoundedRectangle(cornerRadius: UI.corner))
                        }
                    }

                    if !plan.skipped.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                showSkipped.toggle()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .rotationEffect(.degrees(showSkipped ? 90 : 0))
                                    Text("勾选了但不会动（\(plan.skipped.count) 项）")
                                        .font(.subheadline.weight(.medium))
                                }
                                .foregroundStyle(.secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if showSkipped {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(plan.skipped) { item in
                                        ReasonRow(path: item.path, reason: item.reason)
                                    }
                                }
                                .padding(12)
                                .background(Color.groupFill, in: RoundedRectangle(cornerRadius: UI.corner))
                            }
                        }
                    }

                    if !plan.manualCommands.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionHeader(title: "还需要你自己执行", detail: "本 App 不提权、不调用包管理器")
                            ForEach(plan.manualCommands, id: \.self) { command in
                                CommandLineView(command: command)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 360)

            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            if !plan.warnings.isEmpty && !plan.isEmpty {
                Toggle("我已了解上面的风险", isOn: $acknowledged)
                    .padding(.top, 10)
            }

            HStack(spacing: 10) {
                if model.isExecuting {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在移到废纸篓…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { model.plan = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isExecuting)
                Button("移到废纸篓") {
                    Task { await model.execute(plan) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(plan.isEmpty || model.isBusy || model.snapshot != nil || (!plan.warnings.isEmpty && !acknowledged))
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 640)
        // 状态层复查后可能换一份新计划：确认状态必须跟着重置
        .onChange(of: plan.token) { _, _ in acknowledged = false }
        .task(id: plan.token) { acknowledged = false }
    }

    private var footnote: String {
        var text = "移到废纸篓不会立刻释放空间"
        if let size = plan.reclaimable {
            text += "；清空废纸篓后可释放 \(size.display)"
        }
        text += "。在清空之前都可以放回原处，但系统可能在 30 天后自动清除废纸篓里的东西。本 App 不会替你清空废纸篓。"
        return text
    }
}

struct ResultSheet: View {
    let result: UninstallResult
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: blocked ? "hand.raised.fill" : (result.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                    .font(.system(size: 26))
                    .foregroundStyle(blocked ? Color.orange : (result.failures.isEmpty ? Color.green : Color.orange))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !result.receipts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "已移到废纸篓")
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(result.receipts.enumerated()), id: \.offset) { _, receipt in
                            Text(model.show(receipt.original))
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(receipt.original)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.groupFill, in: RoundedRectangle(cornerRadius: UI.corner))
                }
            }

            if !result.failures.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "没有移走")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(result.failures) { failure in
                                ReasonRow(path: failure.path, reason: failure.reason)
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxHeight: 160)
                    .background(Color.groupFill, in: RoundedRectangle(cornerRadius: UI.corner))
                }
            }

            Text(blocked
                 ? "先退出这个工具，再重新操作。"
                 : "空间要等清空废纸篓后才会释放；本 App 不会替你清空。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                if !result.receipts.isEmpty {
                    Button("仅放回本次操作") {
                        Task { await model.undoResult() }
                    }
                    .disabled(!model.canUndoResult)
                    .help("只放回这次移走的条目，其他批次保留在全局恢复栏")
                }
                Button("好") { model.result = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    /// 工具在确认之后被启动：执行器拒绝动手，什么都没有移走。
    private var blocked: Bool { !result.newlyRunningPIDs.isEmpty }

    private var title: String {
        if blocked { return "什么都没有移走" }
        return result.failures.isEmpty
            ? "已把 \(result.receipts.count) 项移到废纸篓"
            : "移走了 \(result.receipts.count) 项，\(result.failures.count) 项没有移走"
    }

    private var subtitle: String {
        if blocked {
            return "\(model.resultGroupName) 在确认之后被启动（PID \(result.newlyRunningPIDs.map(String.init).joined(separator: "、"))），执行前复查拦下了这次操作。"
        }
        return result.failures.isEmpty ? "清空之前都可以放回原处" : "没能移走的条目仍在原处"
    }
}

/// 安装：只给出官方命令，由用户在终端里运行。
struct InstallSheet: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("安装新工具")
                    .font(.title3.weight(.semibold))
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("筛选工具", text: $filter)
                        .textFieldStyle(.plain)
                        .frame(width: 130)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.groupFill, in: RoundedRectangle(cornerRadius: 6))
            }
            Text("命令来自各工具的官方文档。点「在终端运行」会打开「终端」执行，本 App 自己不运行安装脚本；装完回来点「重新扫描」。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(products) { product in
                        productCard(product)
                    }
                    if products.isEmpty {
                        ContentUnavailableView("没有匹配的工具", systemImage: "magnifyingglass",
                                               description: Text("换个关键词试试"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    }
                }
                .padding(.vertical, 2)
            }

            HStack {
                Text("没有列出的工具，是因为它的安装命令还没有对照官方文档核实。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("关闭") { model.showInstall = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 740, height: 580)
    }

    private func productCard(_ product: CatalogProduct) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ToolIcon(name: product.name, size: 24)
                Text(product.name)
                    .font(.headline)
                if let vendor = product.vendor {
                    Text(vendor)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.isInstalled(product) {
                    Badge(text: "已安装", color: .green)
                }
                Spacer()
                if let docs = product.docs ?? product.homepage, let url = URL(string: docs) {
                    Link(destination: url) {
                        Label("文档", systemImage: "safari")
                            .font(.caption)
                    }
                }
            }
            ForEach(product.install ?? [], id: \.self) { method in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(channelLabel(method.channel))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                            .padding(.vertical, 2)
                            .background(Color.barFill, in: RoundedRectangle(cornerRadius: 4))
                            .frame(width: 48)
                        CommandLineView(command: method.command, runnable: true)
                    }
                    if let note = method.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 58)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.groupFill, in: RoundedRectangle(cornerRadius: UI.corner))
    }

    private func channelLabel(_ channel: String) -> String {
        switch channel {
        case "script": return "脚本"
        case "other": return "pip"
        case "brew": return "brew"
        default: return channel
        }
    }

    private var products: [CatalogProduct] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return model.installableProducts }
        return model.installableProducts.filter {
            $0.name.lowercased().contains(needle)
                || ($0.vendor ?? "").lowercased().contains(needle)
                || ($0.binaries ?? []).contains { $0.lowercased().contains(needle) }
        }
    }
}
