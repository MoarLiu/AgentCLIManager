import ACMCore
import AppKit
import SwiftUI

/// 界面的节奏都收在这里，保证各处的间距、圆角、配色一致。
/// 只用语义色加不透明度，浅色深色都成立。
enum UI {
    static let gutter: CGFloat = 20        // 详情页左右留白
    static let sectionGap: CGFloat = 22    // 大区块之间
    static let rowGap: CGFloat = 10        // 行内元素
    static let corner: CGFloat = 8
    static let sizeColumn: CGFloat = 78    // 大小列宽，等宽数字右对齐
    /// 清单的列基准：勾选框 16 + 展开箭头 16 + 图标 18，加上间距
    static let textIndent: CGFloat = 16 + 8 + 16 + 8 + 18 + 8
}

extension Color {
    /// 清单分组容器：比窗口底色略实一点，但不做成卡片。
    static let groupFill = Color.primary.opacity(0.035)
    static let rowHover = Color.primary.opacity(0.05)
    static let barFill = Color.primary.opacity(0.06)
    static let barTrack = Color.primary.opacity(0.10)
}

/// 分组标题 + 一句说明 + 右侧的计数/合计。
struct SectionHeader<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    init(title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

/// 小徽标：细线框 + 同色文字，不用实心色块，避免整页都是彩色胶囊。
/// 只有「正在使用」这类必须一眼看到的才保留填充。
struct Badge: View {
    let text: String
    var color: Color = .secondary
    var filled = false
    var help: String?

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(filled ? color : color.opacity(0.95))
            .background(filled ? color.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                if !filled {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(color.opacity(0.35), lineWidth: 0.5)
                }
            }
            .fixedSize()
            .help(help ?? text)
    }
}

/// 每个工具一个可辨识的标识：名字首字母 + 分组色，单色。
/// 比一组共用同一个 SF Symbol 更容易在侧栏里定位。
struct ToolIcon: View {
    let name: String
    var section: ACMCore.Section = .installed
    var size: CGFloat = 30
    /// 侧栏选中行是实心强调色底，图标要反白
    var selected = false

    var body: some View {
        Text(initials)
            .font(.system(size: size * (initials.count > 1 ? 0.36 : 0.46), weight: .medium, design: .rounded))
            .foregroundStyle(selected ? Color.white : section.tint)
            .frame(width: size, height: size)
            .background(selected ? Color.white.opacity(0.22) : section.tint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }

    private var initials: String {
        // 拉丁字母取首字母（两个词取两个首字母），中文取第一个字
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        if words.count > 1, words.allSatisfy({ $0.first?.isASCII == true }) {
            return words.prefix(2).map { String($0.prefix(1)).uppercased() }.joined()
        }
        return String(name.prefix(1)).uppercased()
    }
}

/// 占用大小的相对比例条：在大小数字下面，2pt 高、淡色，只作辅助。
struct SizeBar: View {
    /// 0…1
    var fraction: Double
    var color: Color = .secondary
    var width: CGFloat = UI.sizeColumn

    var body: some View {
        ZStack(alignment: .trailing) {
            Capsule()
                .fill(color.opacity(0.5))
                .frame(width: max(2, width * CGFloat(min(1, max(0, fraction)))))
        }
        .frame(width: width, height: 2)
    }
}

/// 行尾的「为什么这么判 / 在 Finder 中显示」。默认只显示一个弱的图标，
/// 悬停或键盘聚焦时两个都出现，避免每行两个常驻按钮很吵。
struct RowActions: View {
    var onEvidence: () -> Void
    var onReveal: () -> Void
    var emphasized = false

    var body: some View {
        HStack(spacing: 2) {
            iconButton("info.circle", label: "为什么这么判", help: "归属判定与证据", action: onEvidence)
                .opacity(emphasized ? 1 : 0.55)
            iconButton("arrow.up.forward.square", label: "在 Finder 中显示", help: "在 Finder 中显示", action: onReveal)
                .opacity(emphasized ? 1 : 0)
                .disabled(!emphasized)
                .allowsHitTesting(emphasized)
        }
        .frame(width: 44, height: 22)
    }

    private func iconButton(_ symbol: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
        .help(help)
    }
}

/// 确认单/结果弹窗里的一项：路径 + 原因，等宽路径可以选中复制。
struct ReasonRow: View {
    let path: String
    var reason: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.show(path))
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
