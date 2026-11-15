import ACMCore
import SwiftUI

/// 确认单：将移到废纸篓 → 执行前再次核对 → 风险 → 将移走 → 不会动（计划边界）→ 已核对。
/// 头尾固定，中间滚动。
struct ConfirmSheet: View {
    let plan: UninstallPlan
    var preservedArtifacts: [Artifact] = []
    @Environment(AppModel.self) private var model
    @State private var acknowledgedToken: String?
    private var acknowledged: Bool { acknowledgedToken == model.planConfirmationToken && acknowledgedToken != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.isEmpty ? "「\(plan.groupName)」没有可以移走的条目" : "核对这次要移走的内容")
                    .font(.acmTitle)
                    .foregroundStyle(Color.textPrimary)
                if !plan.isEmpty {
                    Text("「\(plan.groupName)」· \(plan.steps.count) 项"
                         + (plan.reclaimable.map { " · 合计 \($0.display)" } ?? ""))
                        .font(.acmCallout)
                        .foregroundStyle(Color.textSecondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let notice = model.planNotice {
                        FlowSection(title: "清单已更新", tone: .acmCaution) {
                            Text(notice)
                                .font(.acmCallout)
                                .foregroundStyle(Color.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !plan.isEmpty {
                        FlowSection(title: "将移到废纸篓", tone: .acmRecover) {
                            Text("不是直接删除，也不使用 sudo。清空废纸篓之前都可以放回原处。")
                                .font(.acmCallout)
                                .foregroundStyle(Color.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(footnote)
                                .font(.acmCaption)
                                .foregroundStyle(Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        FlowSection(title: "执行前再次核对") {
                            Text("点击后会先复查这些路径和工具是否在运行；有变化就不动手，先把新的清单给你看。")
                                .font(.acmCallout)
                                .foregroundStyle(Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !plan.warnings.isEmpty {
                        FlowSection(title: "你需要知道的风险", tone: .acmCaution) {
                            ForEach(plan.warnings, id: \.self) { warning in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Circle()
                                        .fill(Color.acmCaution)
                                        .frame(width: 4, height: 4)
                                        .offset(y: -2)
                                    Text(warning)
                                        .font(.acmCallout)
                                        .foregroundStyle(Color.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    if !plan.steps.isEmpty {
                        FlowSection(title: "将移走", detail: "\(plan.steps.count) 项",
                                    trailing: plan.reclaimable?.display) {
                            VStack(spacing: 0) {
                                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                                    HStack(spacing: 8) {
                                        Image(systemName: step.isDirectory ? "folder" : step.kind.symbol)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.textSecondary)
                                            .frame(width: 18)
                                        Text(model.show(step.path))
                                            .font(.acmMonoNum)
                                            .foregroundStyle(Color.textPrimary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .help(step.path)
                                        Spacer(minLength: 8)
                                        Text(step.kind.displayName)
                                            .font(.acmCaption)
                                            .foregroundStyle(Color.textSecondary)
                                            .fixedSize()
                                        Text(step.size.map { $0.bytes == 0 ? "—" : $0.display } ?? "—")
                                            .font(.acmMonoNum)
                                            .foregroundStyle((step.size?.bytes ?? 0) == 0 ? Color.textTertiary : Color.textPrimary)
                                            .frame(width: UI.sizeColumn, alignment: .trailing)
                                    }
                                    .padding(.vertical, 6)
                                    if index < plan.steps.count - 1 { Hairline() }
                                }
                            }
                        }
                    }

                    FlowSection(title: "不会动 · 这是计划边界", tone: .acmConfirmed) {
                        boundary("未勾选且未被所选目录包含的配置、数据与登录凭据会保留")
                        boundary(".ssh / .aws 等全保护路径，任何情况下都不会进入计划")
                        boundary("不调用包管理器，不清空废纸篓")
                        if !preservedArtifacts.isEmpty {
                            Hairline().padding(.vertical, 2)
                            Text("完全保留的顶层条目（\(preservedArtifacts.count) 项）")
                                .font(.acmCaptionMed)
                                .foregroundStyle(Color.textPrimary)
                            ForEach(preservedArtifacts) { item in
                                HStack(spacing: 8) {
                                    Text(model.show(item.path))
                                        .font(.acmMonoNum)
                                        .foregroundStyle(Color.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(item.path)
                                    Spacer(minLength: 8)
                                    Text(item.kind.displayName)
                                        .font(.acmCaption)
                                        .foregroundStyle(Color.textSecondary)
                                        .fixedSize()
                                    Text(item.size?.display ?? "—")
                                        .font(.acmMonoNum)
                                        .foregroundStyle(item.size == nil ? Color.textTertiary : Color.textPrimary)
                                        .frame(width: UI.sizeColumn, alignment: .trailing)
                                }
                            }
                        }
                        if !plan.skipped.isEmpty {
                            Hairline().padding(.vertical, 2)
                            Text("勾选了但不会动（\(plan.skipped.count) 项）")
                                .font(.acmCaptionMed)
                                .foregroundStyle(Color.textPrimary)
                            ForEach(plan.skipped) { item in
                                ReasonRow(path: item.path, reason: item.reason)
                            }
                        }
                    }

                    if !plan.manualCommands.isEmpty {
                        FlowSection(title: "还需要你自己执行", detail: "本 App 不提权、不调用包管理器") {
                            ForEach(plan.manualCommands, id: \.self) { command in
                                CommandLineView(command: command)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 440)

            if !plan.isEmpty {
                Text("请滚动核对完整清单与计划边界。")
                    .font(.acmCaption)
                    .foregroundStyle(Color.textSecondary)
                HStack(spacing: 8) {
                    ACMCheckbox(state: acknowledged ? .on : .off, enabled: !model.isExecuting,
                                label: "我已核对将移走与不会动，并了解恢复条件。") {
                        toggleAcknowledgement()
                    }
                    Text("我已核对将移走与不会动，并了解恢复条件。")
                        .font(.acmBody)
                        .foregroundStyle(Color.textPrimary)
                        .onTapGesture { if !model.isExecuting { toggleAcknowledgement() } }
                }
            }

            HStack(spacing: 10) {
                if model.isExecuting {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在移到废纸篓…")
                        .font(.acmCallout)
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
                Button("返回修改") { model.plan = nil }
                    .buttonStyle(.acmSecondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isExecuting)
                Button("移到废纸篓") {
                    Task { await model.execute(plan) }
                }
                .buttonStyle(.acmPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(plan.isEmpty || model.isBusy || model.snapshot != nil || !acknowledged)
            }
        }
        .padding(24)
        .frame(width: UI.flowWidth)
        .background(Color.surfaceRaised)
    }

    private func toggleAcknowledgement() {
        guard !model.isExecuting else { return }
        acknowledgedToken = acknowledged ? nil : model.planConfirmationToken
    }

    private func boundary(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.acmConfirmed)
                .frame(width: 12)
            Text(text)
                .font(.acmCallout)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnote: String {
        var text = "移到废纸篓不会立刻释放空间"
        if let size = plan.reclaimable {
            text += "；清空废纸篓后可释放 \(size.display)"
        }
        text += "。系统可能在 30 天后自动清除废纸篓里的东西，本 App 不会替你清空。"
        return text
    }
}

struct ResultSheet: View {
    let result: UninstallResult
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: blocked ? "hand.raised" : (result.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle"))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(blocked || !result.failures.isEmpty ? Color.acmCaution : Color.acmRecover)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.acmTitle)
                        .foregroundStyle(Color.textPrimary)
                    Text(subtitle)
                        .font(.acmCallout)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !result.receipts.isEmpty {
                FlowSection(title: "已移到废纸篓", detail: "可放回原处", tone: .acmRecover,
                            trailing: "\(result.receipts.count) 项") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(result.receipts.enumerated()), id: \.offset) { _, receipt in
                                Text(model.show(receipt.original))
                                    .font(.acmMonoNum)
                                    .foregroundStyle(Color.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(receipt.original)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }

            if !result.failures.isEmpty {
                FlowSection(title: "没有移走", detail: "仍在原处", tone: .acmCaution,
                            trailing: "\(result.failures.count) 项") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(result.failures) { failure in
                                ReasonRow(path: failure.path, reason: failure.reason)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            }

            Text(blocked
                 ? "先退出这个工具，再重新操作。"
                 : "空间要等清空废纸篓后才会释放；本 App 不会替你清空。")
                .font(.acmCaption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Spacer()
                if !result.receipts.isEmpty {
                    Button("仅放回本次操作") {
                        Task { await model.undoResult() }
                    }
                    .buttonStyle(.acmSecondary)
                    .disabled(!model.canUndoResult)
                    .help("只放回这次移走的条目，其他批次保留在全局恢复入口")
                }
                Button("好") { model.result = nil }
                    .buttonStyle(.acmPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: UI.flowWidth)
        .background(Color.surfaceRaised)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("安装工具")
                        .font(.acmTitle)
                        .foregroundStyle(Color.textPrimary)
                    Text("命令来自各工具的官方文档。本 App 只给出命令，不执行脚本，不获取凭据。")
                        .font(.acmCallout)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textSecondary)
                    TextField("筛选工具", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.acmBody)
                        .frame(width: 120)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.lineControl, lineWidth: UI.hairline)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(products) { product in
                        productCard(product)
                    }
                    if products.isEmpty {
                        VStack(spacing: 6) {
                            Text("没有匹配的工具")
                                .font(.acmBodyMed)
                                .foregroundStyle(Color.textPrimary)
                            Text("没有列出的工具，是因为它的安装命令还没有对照官方文档核实。")
                                .font(.acmCaption)
                                .foregroundStyle(Color.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    }
                }
            }

            HStack(spacing: 10) {
                Text("点命令旁的「运行」会打开「终端」，由你自己执行。")
                    .font(.acmCaption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                Spacer()
                Button("关闭") { model.showInstall = false }
                    .buttonStyle(.acmSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("我已安装，重新扫描") {
                    model.showInstall = false
                    model.rescan()
                }
                .buttonStyle(.acmPrimary)
                .disabled(model.isScanning)
            }
        }
        .padding(24)
        .frame(width: UI.flowWidth, height: 580)
        .background(Color.surfaceRaised)
    }

    private func productCard(_ product: CatalogProduct) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ToolIcon(name: product.name, size: 26,
                                 logo: ToolLogo.lookup(catalog: model.catalog, productID: product.id,
                                                       binaries: product.binaries ?? [], ownerApps: []))
                Text(product.name)
                    .font(.acmHeadline)
                    .foregroundStyle(Color.textPrimary)
                if let vendor = product.vendor {
                    Text(vendor)
                        .font(.acmCaption)
                        .foregroundStyle(Color.textSecondary)
                }
                if model.isInstalled(product) {
                    Badge(text: "已安装", color: .acmConfirmed)
                }
                Spacer()
                if let docs = product.docs ?? product.homepage, let url = URL(string: docs) {
                    Link(destination: url) {
                        Label("打开官方说明", systemImage: "arrow.up.right")
                            .font(.acmCaption)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }
            ForEach(product.install ?? [], id: \.self) { method in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(channelLabel(method.channel))
                            .font(.acmCaptionMed)
                            .foregroundStyle(Color.textSecondary)
                            .frame(width: 40, alignment: .leading)
                        CommandLineView(command: method.command, runnable: true)
                    }
                    if let note = method.note {
                        Text(note)
                            .font(.acmCaption)
                            .foregroundStyle(Color.textSecondary)
                            .padding(.leading, 48)
                    }
                }
            }
        }
        .padding(12)
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
