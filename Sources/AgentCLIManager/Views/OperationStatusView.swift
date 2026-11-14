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
        let isError = model.bannerIsError
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.orange : Color.green)
                .padding(.top, 1)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("知道了") { model.banner = nil }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background((isError ? Color.orange : Color.green).opacity(0.10))
        .overlay(alignment: .top) { Divider() }
    }

    private var undoBar: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.isUndoing ? "arrow.uturn.backward.circle" : "trash")
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.isUndoing
                     ? "正在把「\(model.undoGroupName)」放回原处…"
                     : "「\(model.undoGroupName)」共 \(model.undoReceipts.count) 项尚未放回")
                    .font(.callout)
                if !model.undoFailures.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.undoFailures.count) 项没能放回，它们仍在废纸篓里：")
                            .foregroundStyle(.secondary)
                        ForEach(Array(model.undoFailures.enumerated()), id: \.offset) { _, failure in
                            Text("\(model.show(failure.path))：\(failure.reason)")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption)
                } else if !model.isUndoing {
                    Text("在清空废纸篓之前都可以放回")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if model.isUndoing {
                ProgressView().controlSize(.small)
            } else {
                Button(model.undoFailures.isEmpty ? "全部放回原处" : "重试全部未恢复项") {
                    Task { await model.undoLast() }
                }
                .controlSize(.small)
                .disabled(!model.operationStatus.canUndoAll)
                .help("恢复所有尚未放回的批次，包括之前操作留下的回执")
                Button("不用了") { model.dismissUndo() }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                    .help("丢掉全部回执，条目留在废纸篓里")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.08))
        .overlay(alignment: .top) { Divider() }
    }

}
