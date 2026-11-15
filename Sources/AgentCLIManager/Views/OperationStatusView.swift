import ACMCore
import SwiftUI

/// 全局呈现状态与当前选中组无关，也供原生 AppModel 测试断言。
struct OperationStatus: Equatable {
    var banner: String?
    var bannerIsError: Bool
    var showsUndo: Bool
    var canUndoAll: Bool
}

/// 根视图唯一的操作状态区域：空报告和未选择工具时也保留恢复入口。
struct OperationStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let banner = model.operationStatus.banner {
                bannerBar(banner)
            }
            if model.operationStatus.showsUndo {
                undoBar
            }
        }
    }

    private func bannerBar(_ text: String) -> some View {
        let tone = model.bannerIsError ? Color.acmCaution : Color.acmRecover
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: model.bannerIsError ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tone)
            Text(text)
                .font(.acmCallout)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("知道了") { model.banner = nil }
                .buttonStyle(.acmCompact)
        }
        .padding(.horizontal, UI.gutter)
        .padding(.vertical, 9)
        .background(tone.opacity(0.10))
        .overlay(alignment: .top) { Hairline() }
    }

    private var undoBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.acmRecover)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.isUndoing
                     ? "正在把「\(model.undoGroupName)」放回原处…"
                     : "「\(model.undoGroupName)」共 \(model.undoReceipts.count) 项尚未放回")
                    .font(.acmCallout)
                    .foregroundStyle(Color.textPrimary)
                if !model.undoFailures.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.undoFailures.count) 项没能放回，它们仍在废纸篓里：")
                        ForEach(Array(model.undoFailures.prefix(3).enumerated()), id: \.offset) { _, failure in
                            Text("\(model.show(failure.path))：\(failure.reason)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if model.undoFailures.count > 3 {
                            Text("另有 \(model.undoFailures.count - 3) 项，完整原因见侧栏「可放回原处」。")
                        }
                    }
                    .font(.acmCaption)
                    .foregroundStyle(Color.acmCaution)
                } else if !model.isUndoing {
                    Text("在清空废纸篓之前都可以放回")
                        .font(.acmCaption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            Spacer(minLength: 8)
            if model.isUndoing {
                ProgressView().controlSize(.small)
            } else {
                Button(model.undoFailures.isEmpty ? "全部放回原处" : "重试全部未恢复项") {
                    Task { await model.undoLast() }
                }
                .buttonStyle(.acmCompact)
                .disabled(!model.operationStatus.canUndoAll)
                .help("恢复所有尚未放回的批次，包括之前操作留下的回执")
                Button("不用了") { model.dismissUndo() }
                    .buttonStyle(.acmCompact)
                    .disabled(model.isBusy)
                    .help("丢掉全部回执，条目留在废纸篓里")
            }
        }
        .padding(.horizontal, UI.gutter)
        .padding(.vertical, 9)
        .background(Color.acmRecover.opacity(0.08))
        .overlay(alignment: .top) { Hairline() }
        .accessibilityElement(children: .contain)
    }
}

/// 全部未恢复的回执：从侧栏底部的「可放回原处」进入。
struct RecoverySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let receipts = model.undoReceipts
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(receipts.isEmpty ? "没有需要放回的内容" : "可放回原处")
                    .font(.acmTitle)
                    .foregroundStyle(Color.textPrimary)
                Text(receipts.isEmpty
                     ? "移到废纸篓的条目会在这里留下回执；清空废纸篓之前都可以放回原处。"
                     : "\(model.undoBatchCount) 批、共 \(receipts.count) 项尚未放回。只放回本 App 移走的条目，不会动废纸篓里的其他东西。")
                    .font(.acmCallout)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !receipts.isEmpty {
                FlowSection(title: "未恢复的条目", detail: model.undoGroupName, tone: .acmRecover,
                            trailing: "\(receipts.count) 项") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(receipts.enumerated()), id: \.offset) { _, receipt in
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
                    .frame(maxHeight: 200)
                }
            }

            if !model.undoFailures.isEmpty {
                FlowSection(title: "上次没能放回", detail: "它们仍在废纸篓里", tone: .acmCaution) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(model.undoFailures.enumerated()), id: \.offset) { _, failure in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.show(failure.path))
                                        .font(.acmMonoNum)
                                        .foregroundStyle(Color.textPrimary)
                                        .textSelection(.enabled)
                                    Text(failure.reason)
                                        .font(.acmCallout)
                                        .foregroundStyle(Color.textSecondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(minHeight: 52, maxHeight: 140)
                }
            }

            if !receipts.isEmpty {
                Text("「全部放回原处」会逐批恢复，失败项保留回执；也可以只丢弃本 App 的恢复信息，条目仍留在废纸篓。")
                    .font(.acmCaption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if model.isUndoing {
                    ProgressView().controlSize(.small)
                    Text("正在放回原处…")
                        .font(.acmCallout)
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
                if !receipts.isEmpty {
                    Button("不用了") {
                        model.dismissUndo()
                        dismiss()
                    }
                    .buttonStyle(.acmSecondary)
                    .disabled(model.isBusy)
                    .help("只丢弃本 App 的恢复信息，不移出或删除废纸篓里的条目")
                }
                Button("关闭") { dismiss() }
                    .buttonStyle(.acmSecondary)
                    .keyboardShortcut(.cancelAction)
                if !receipts.isEmpty {
                    Button(model.undoFailures.isEmpty ? "全部放回原处" : "重试全部未恢复项") {
                        Task { await model.undoLast() }
                    }
                    .buttonStyle(.acmPrimary)
                    .disabled(!model.operationStatus.canUndoAll)
                }
            }
        }
        .padding(24)
        .frame(width: UI.flowWidth)
        .background(Color.surfaceRaised)
    }
}
