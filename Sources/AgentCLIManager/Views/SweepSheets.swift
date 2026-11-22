import ACMCore
import SwiftUI

/// 清理确认单：怎么清理 → 执行前再核对 → 将清理 → 不会动 → 已核对。
/// 列出来的就是确认之后会去动的全部内容。
struct SweepConfirmSheet: View {
    let confirmation: SweepConfirmation
    @Environment(AppModel.self) private var model
    @State private var acknowledged = false

    private var permanent: Bool { confirmation.mode == .permanent }

    var body: some View {
        let sweep = model.sweep
        let ready = confirmation.readyItems
        let name = PathUtil.lastComponent(confirmation.folder)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ready.isEmpty ? "「\(name)」里没有可以清理的条目"
                     : permanent ? "核对这次要永久删除的内容" : "核对这次要移走的内容")
                    .font(.acmTitle)
                    .foregroundStyle(Color.textPrimary)
                if !ready.isEmpty {
                    Text("「\(name)」· \(ready.count) 项 · 合计 \(sweepSize(confirmation.readyBytes))")
                        .font(.acmCallout)
                        .foregroundStyle(Color.textSecondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = sweep.confirmationError {
                        FlowSection(title: "没有执行，什么都没动", tone: .acmCaution) {
                            Text(error)
                                .font(.acmCallout)
                                .foregroundStyle(Color.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !ready.isEmpty {
                        if permanent {
                            FlowSection(title: "将永久删除，无法恢复", tone: .acmDanger) {
                                Text("不经过废纸篓。删除之后本 App 和访达都找不回这些内容。")
                                    .font(.acmCallout)
                                    .foregroundStyle(Color.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("这些都是可以重新生成或重新下载的内容；拿不准的，请改用「移到废纸篓」。")
                                    .font(.acmCaption)
                                    .foregroundStyle(Color.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            FlowSection(title: "将移到废纸篓", tone: .acmRecover) {
                                Text("不是直接删除。清空废纸篓之前都可以放回原处。")
                                    .font(.acmCallout)
                                    .foregroundStyle(Color.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("移到废纸篓不会立刻释放空间；清空废纸篓后可释放约 \(sweepSize(confirmation.readyBytes))。"
                                     + "系统可能在 30 天后自动清除废纸篓里的东西，本 App 不会替你清空。")
                                    .font(.acmCaption)
                                    .foregroundStyle(Color.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        FlowSection(title: "执行前再次核对") {
                            Text("点击后会逐项再核对一次内容、Git 跟踪和进程占用；和现在不一样的那一项不动，并告诉你原因。")
                                .font(.acmCallout)
                                .foregroundStyle(Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        FlowSection(title: permanent ? "将删除" : "将移走", detail: "\(ready.count) 项",
                                    trailing: sweepSize(confirmation.readyBytes)) {
                            VStack(spacing: 0) {
                                ForEach(Array(ready.enumerated()), id: \.element.id) { index, item in
                                    HStack(spacing: 8) {
                                        Image(systemName: item.snapshot?.kind == "file" ? item.category.symbol : "folder")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.textSecondary)
                                            .frame(width: 18)
                                        Text(item.path)
                                            .font(.acmMonoNum)
                                            .foregroundStyle(Color.textPrimary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .help(confirmation.plan.absolutePath(of: item))
                                        Spacer(minLength: 8)
                                        Text(item.category.displayName)
                                            .font(.acmCaption)
                                            .foregroundStyle(Color.textSecondary)
                                            .fixedSize()
                                        Text(sweepSize(item.snapshot?.allocatedBytes ?? 0))
                                            .font(.acmMonoNum)
                                            .foregroundStyle(Color.textPrimary)
                                            .frame(width: UI.sizeColumn, alignment: .trailing)
                                    }
                                    .padding(.vertical, 6)
                                    if index < ready.count - 1 { Hairline() }
                                }
                            }
                        }
                    }

                    FlowSection(title: "不会动 · 这是清理边界", tone: .acmConfirmed) {
                        boundary("没有勾选的条目，以及需复核、保留、跳过的条目")
                        boundary("源码、Git 已跟踪的文件和这个文件夹之外的任何东西")
                        boundary("缓存里的符号链接只移走链接本身，不动它指向的内容")
                        if !confirmation.notReady.isEmpty {
                            Hairline().padding(.vertical, 2)
                            Text("勾选了但不会动（\(confirmation.notReady.count) 项）")
                                .font(.acmCaptionMed)
                                .foregroundStyle(Color.textPrimary)
                            ForEach(confirmation.notReady) { outcome in
                                ReasonRow(path: SweepPath.join(confirmation.folder, outcome.path),
                                          reason: outcome.reason ?? outcome.status.displayName)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 440)

            if !ready.isEmpty {
                let text = permanent ? "我已核对清单，并知道永久删除无法恢复。" : "我已核对将移走与不会动的内容。"
                HStack(spacing: 8) {
                    ACMCheckbox(state: acknowledged ? .on : .off, enabled: !sweep.isApplying, label: text) {
                        acknowledged.toggle()
                    }
                    Text(text)
                        .font(.acmBody)
                        .foregroundStyle(Color.textPrimary)
                        .onTapGesture { if !sweep.isApplying { acknowledged.toggle() } }
                }
            }

            HStack(spacing: 10) {
                if sweep.isApplying {
                    ProgressView()
                        .controlSize(.small)
                    Text(permanent ? "正在删除…" : "正在移到废纸篓…")
                        .font(.acmCallout)
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
                Button(ready.isEmpty ? "关闭" : "返回修改") { sweep.cancelConfirmation() }
                    .buttonStyle(.acmSecondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(sweep.isApplying)
                if !ready.isEmpty {
                    // 永久删除不设成回车默认键：要用户自己点。
                    if permanent {
                        Button("永久删除") { run() }
                            .buttonStyle(.acmPrimary)
                            .disabled(!canRun)
                    } else {
                        Button("移到废纸篓") { run() }
                            .buttonStyle(.acmPrimary)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canRun)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: UI.flowWidth)
        .background(Color.surfaceRaised)
    }

    private var canRun: Bool {
        acknowledged && !model.sweep.isBusy && model.snapshot == nil
    }

    private func run() {
        Task { await model.sweep.execute(confirmation) }
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
}

/// 清理结果：做了什么、哪些没动及原因、哪些停在半路需要你处理。
struct SweepResultSheet: View {
    let result: SweepApplyResult
    @Environment(AppModel.self) private var model

    private var permanent: Bool { result.mode == .permanent }
    private var done: [SweepOutcome] { result.items.filter { $0.status == .trashed || $0.status == .deleted } }
    private var stranded: [SweepOutcome] { result.items.filter { $0.status == .recoveryRequired } }
    private var untouched: [SweepOutcome] {
        result.items.filter { ![.trashed, .deleted, .recoveryRequired].contains($0.status) }
    }

    var body: some View {
        let sweep = model.sweep
        let clean = stranded.isEmpty && untouched.isEmpty
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: clean ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(clean ? Color.acmRecover : Color.acmCaution)
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

            if !done.isEmpty {
                FlowSection(title: permanent ? "已永久删除" : "已移到废纸篓",
                            detail: permanent ? "无法恢复" : "可放回原处",
                            tone: permanent ? nil : .acmRecover, trailing: "\(done.count) 项") {
                    paths(done)
                }
            }

            if !stranded.isEmpty {
                FlowSection(title: "停在半路，需要你处理", detail: "内容完好，留在暂存位置", tone: .acmCaution,
                            trailing: "\(stranded.count) 项") {
                    SweepBoundedList(count: stranded.count, limit: 2) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(stranded) { outcome in
                                VStack(alignment: .leading, spacing: 4) {
                                    ReasonRow(path: SweepPath.join(result.root, outcome.path), reason: outcome.reason)
                                    if let recovery = outcome.recoveryPath {
                                        HStack(spacing: 8) {
                                            Text("现在在 " + model.show(recovery))
                                                .font(.acmCaption)
                                                .foregroundStyle(Color.textSecondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                                .help(recovery)
                                            Spacer(minLength: 8)
                                            Button("在 Finder 中显示") { model.reveal(recovery) }
                                                .buttonStyle(.acmCompact)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if !untouched.isEmpty {
                FlowSection(title: "没有动", detail: "仍在原处", tone: .acmCaution, trailing: "\(untouched.count) 项") {
                    SweepBoundedList(count: untouched.count, limit: 3) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(untouched) { outcome in
                                ReasonRow(path: SweepPath.join(result.root, outcome.path),
                                          reason: outcome.reason ?? outcome.status.displayName)
                            }
                        }
                    }
                }
            }

            Text(footnote)
                .font(.acmCaption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if sweep.restoreReceipt == result.receipt {
                if let error = sweep.restoreError {
                    restoreError(error)
                }
                if !sweep.restoreFailures.isEmpty {
                    restoreFailures(sweep.restoreFailures)
                }
            }

            HStack(spacing: 10) {
                if sweep.isRestoring {
                    ProgressView().controlSize(.small)
                    Text("正在放回原处…")
                        .font(.acmCallout)
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
                if let run = sweep.resultRun {
                    Button("放回原处") {
                        Task {
                            let complete = await sweep.restore(run)
                            if complete { sweep.result = nil }
                        }
                    }
                    .buttonStyle(.acmSecondary)
                    .disabled(sweep.isBusy || model.snapshot != nil)
                    .help("把这次清理移走、还在暂存位置的内容放回原处")
                }
                Button("好") { sweep.result = nil }
                    .buttonStyle(.acmPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sweep.isRestoring)
            }
        }
        .padding(24)
        .frame(width: UI.flowWidth)
        .background(Color.surfaceRaised)
    }

    private func paths(_ outcomes: [SweepOutcome]) -> some View {
        SweepBoundedList(count: outcomes.count, limit: 6) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(outcomes) { outcome in
                    Text(outcome.path)
                        .font(.acmMonoNum)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(SweepPath.join(result.root, outcome.path))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var title: String {
        let rest = stranded.count + untouched.count
        guard !done.isEmpty else {
            return stranded.isEmpty ? "什么都没有清理" : "清理停在半路"
        }
        let verb = permanent ? "已永久删除 \(done.count) 项" : "已把 \(done.count) 项移到废纸篓"
        return rest == 0 ? verb : verb + "，\(rest) 项没有清理"
    }

    private var subtitle: String {
        let name = "「\(PathUtil.lastComponent(result.root))」"
        if !stranded.isEmpty { return name + " · 有内容停在暂存位置，没有丢失" }
        if done.isEmpty { return name + " · 勾选的条目在执行前复核时都没有通过" }
        return name + (permanent ? " · 删除的内容无法恢复" : " · 清空废纸篓之前都可以放回原处")
    }

    private var footnote: String {
        if permanent {
            if let delta = result.freeSpaceDeltaBytes, delta > 0, !done.isEmpty {
                return "可用空间增加约 \(SweepOutput.size(delta))。"
            }
            return "永久删除不经过废纸篓。"
        }
        return "空间要等清空废纸篓后才会释放；本 App 不会替你清空。"
    }

    private func restoreFailures(_ failures: [SweepOutcome]) -> some View {
        let skipped = failures.filter { $0.status == .notAttempted }.count
        return FlowSection(title: "没能放回", detail: skipped > 0 ? "另有 \(skipped) 项未执行" : "还在暂存位置",
                           tone: .acmCaution, trailing: "\(failures.count) 项") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(failures) { outcome in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outcome.path)
                            .font(.acmMonoNum)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(outcome.reason ?? outcome.status.displayName)
                            .font(.acmCaption)
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let recovery = outcome.recoveryPath {
                            Text("现在在 " + model.show(recovery))
                                .font(.acmCaption)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(recovery)
                        }
                    }
                }
            }
        }
    }

    private func restoreError(_ text: String) -> some View {
        FlowSection(title: "没能放回", detail: "这次没有逐项执行", tone: .acmCaution) {
            Text(text)
                .font(.acmCallout)
                .foregroundStyle(Color.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 项目清理留下的、还能放回的内容，一次清理一块。
struct SweepRecoverySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sweep = model.sweep
        let runs = sweep.pendingRuns
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(runs.isEmpty ? "没有需要放回的内容" : "可放回原处")
                    .font(.acmTitle)
                    .foregroundStyle(Color.textPrimary)
                Text(runs.isEmpty
                     ? "项目清理移到废纸篓的内容会在这里留下回执；清空废纸篓之前都可以放回原处。永久删除的不在这里。"
                     : "\(runs.count) 次清理的内容还在暂存位置。原处已经有东西时不会覆盖；暂存内容被改动过的不会放回。")
                    .font(.acmCallout)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !runs.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(runs) { run in
                            FlowSection(title: PathUtil.lastComponent(run.root), detail: detail(run),
                                        tone: run.mode == .trash ? .acmRecover : .acmCaution,
                                        trailing: sweepSize(run.bytes)) {
                                ForEach(run.items.prefix(6)) { item in
                                    Text(item.path)
                                        .font(.acmMonoNum)
                                        .foregroundStyle(Color.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(SweepPath.join(run.root, item.path))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if run.items.count > 6 {
                                    Text("另有 \(run.items.count - 6) 项")
                                        .font(.acmCaption)
                                        .foregroundStyle(Color.textSecondary)
                                }
                                HStack(spacing: 8) {
                                    Text(model.show(run.root))
                                        .font(.acmCaption)
                                        .foregroundStyle(Color.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(run.root)
                                    Spacer(minLength: 8)
                                    Button("放回原处") {
                                        Task { await sweep.restore(run) }
                                    }
                                    .buttonStyle(.acmCompact)
                                    .disabled(sweep.isBusy || model.snapshot != nil)
                                }
                                if sweep.restoreRunID == run.runID, let error = sweep.restoreError {
                                    Text(error)
                                        .font(.acmCallout)
                                        .foregroundStyle(Color.acmCaution)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if sweep.restoreRunID == run.runID, !sweep.restoreFailures.isEmpty {
                                    ForEach(sweep.restoreFailures) { outcome in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(outcome.path)
                                                .font(.acmMonoNum)
                                                .foregroundStyle(Color.textPrimary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Text(outcome.reason ?? outcome.status.displayName)
                                                .font(.acmCaption)
                                                .foregroundStyle(Color.textSecondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                            if let recovery = outcome.recoveryPath {
                                                Text("现在在 " + model.show(recovery))
                                                    .font(.acmCaption)
                                                    .foregroundStyle(Color.textSecondary)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                    .help(recovery)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
            }

            HStack(spacing: 10) {
                if sweep.isRestoring {
                    ProgressView().controlSize(.small)
                    Text("正在放回原处…")
                        .font(.acmCallout)
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.acmPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sweep.isRestoring)
            }
        }
        .padding(24)
        .frame(width: UI.flowWidth)
        .background(Color.surfaceRaised)
    }

    private func detail(_ run: SweepPendingRun) -> String {
        let when = run.createdAt.formatted(date: .abbreviated, time: .shortened)
        let what = run.mode == .trash ? "在废纸篓里" : "永久删除中断时留下的"
        return "\(when) · \(run.items.count) 项 · \(what)"
    }
}

/// 短清单直接铺开，长清单才收进固定高度的滚动区域。
private struct SweepBoundedList<Content: View>: View {
    let count: Int
    let limit: Int
    @ViewBuilder var content: Content

    var body: some View {
        if count <= limit {
            content
        } else {
            ScrollView { content }
                .frame(height: 150)
        }
    }
}
