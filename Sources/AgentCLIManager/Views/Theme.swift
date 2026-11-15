import ACMCore
import AppKit
import SwiftUI

/// 界面的节奏都收在这里，保证各处的间距、圆角、配色一致。
enum UI {
    static let gutter: CGFloat = 20        // 详情页左右留白
    static let sectionGap: CGFloat = 22    // 大区块之间
    static let rowGap: CGFloat = 10        // 行内元素
    static let corner: CGFloat = 8
    static let sizeColumn: CGFloat = 78    // 大小列宽，等宽数字右对齐
    /// 清单的列基准：勾选框 16 + 展开箭头 16 + 图标 18，加上间距
    static let textIndent: CGFloat = 16 + 8 + 16 + 8 + 18 + 8
    static let checkbox: CGFloat = 16
    static let hitTarget: CGFloat = 28
    static let buttonHeight: CGFloat = 32
    static let hairline: CGFloat = 0.5
    static let focusWidth: CGFloat = 2
    static let flowWidth: CGFloat = 640
}

// MARK: - 颜色 token（浅色 / 深色）

private func dynamicColor(light: (UInt32, Double), dark: (UInt32, Double)) -> Color {
    func make(_ value: (UInt32, Double)) -> NSColor {
        NSColor(srgbRed: CGFloat((value.0 >> 16) & 0xFF) / 255,
                green: CGFloat((value.0 >> 8) & 0xFF) / 255,
                blue: CGFloat(value.0 & 0xFF) / 255,
                alpha: CGFloat(value.1))
    }
    let lightColor = make(light), darkColor = make(dark)
    return Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
    })
}

extension Color {
    static let surfaceBase = dynamicColor(light: (0xFFFFFF, 1), dark: (0x1E1E20, 1))
    static let surfaceSidebar = dynamicColor(light: (0xF4F4F5, 1), dark: (0x262628, 1))
    static let surfaceRaised = dynamicColor(light: (0xFFFFFF, 1), dark: (0x2C2C2E, 1))

    /// 清单分组容器：比窗口底色略实一点，但不做成卡片。
    static let groupFill = dynamicColor(light: (0x1D1D1F, 0.035), dark: (0xF2F2F7, 0.035))
    static let rowHover = dynamicColor(light: (0x1D1D1F, 0.05), dark: (0xF2F2F7, 0.05))
    /// 选中工具：中性填充，不用系统强调色
    static let fillSelected = dynamicColor(light: (0x1D1D1F, 0.08), dark: (0xF2F2F7, 0.10))
    static let barFill = dynamicColor(light: (0x1D1D1F, 0.06), dark: (0xF2F2F7, 0.06))
    static let barTrack = dynamicColor(light: (0x1D1D1F, 0.10), dark: (0xF2F2F7, 0.10))
    static let toolIconFill = dynamicColor(light: (0x1D1D1F, 0.12), dark: (0xF2F2F7, 0.12))

    static let lineHairline = dynamicColor(light: (0x1D1D1F, 0.12), dark: (0xF2F2F7, 0.14))
    static let lineControl = dynamicColor(light: (0x6E6E73, 1), dark: (0xA0A0A6, 1))

    static let textPrimary = dynamicColor(light: (0x1D1D1F, 1), dark: (0xF2F2F7, 1))
    static let textSecondary = dynamicColor(light: (0x6E6E73, 1), dark: (0xA0A0A6, 1))
    static let textTertiary = dynamicColor(light: (0x85858B, 1), dark: (0x8E8E95, 1))
    static let textInverse = dynamicColor(light: (0xFFFFFF, 1), dark: (0x1E1E20, 1))

    /// 确定归属 · 不等于同意删除
    static let acmConfirmed = dynamicColor(light: (0x1F6A43, 1), dark: (0x71CDA0, 1))
    /// 推测与需要留意的风险
    static let acmCaution = dynamicColor(light: (0x805500, 1), dark: (0xD7B879, 1))
    /// 敏感内容与不可恢复风险
    static let acmDanger = dynamicColor(light: (0xA53F36, 1), dark: (0xECAB9F, 1))
    /// 放回原处与恢复回执
    static let acmRecover = dynamicColor(light: (0x246A58, 1), dark: (0x85C9B5, 1))
}

// MARK: - 字体 token

extension Font {
    static let acmTitle = Font.system(size: 17, weight: .bold)
    static let acmHeadline = Font.system(size: 13, weight: .bold)
    static let acmBodyMed = Font.system(size: 13, weight: .medium)
    static let acmBody = Font.system(size: 13)
    static let acmCallout = Font.system(size: 12)
    static let acmCaptionMed = Font.system(size: 12, weight: .medium)
    static let acmCaption = Font.system(size: 12)
    static let acmMicroMed = Font.system(size: 11, weight: .medium)
    static let acmMonoDisplay = Font.system(size: 22, design: .monospaced)
    static let acmMonoNum = Font.system(size: 12, design: .monospaced)
    static let acmMonoPath = Font.system(size: 12, design: .monospaced)
}

// MARK: - 归属档位

/// 归属判定三档。只有「确定」才可能默认勾选。
enum Tier: CaseIterable {
    case confirmed, inferred, unknown

    init(_ strength: Strength) {
        switch strength {
        case .certain: self = .confirmed
        case .probable: self = .inferred
        case .speculative: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .confirmed: return "确定"
        case .inferred: return "推测"
        case .unknown: return "未知"
        }
    }

    var color: Color {
        switch self {
        case .confirmed: return .acmConfirmed
        case .inferred: return .acmCaution
        case .unknown: return .textSecondary
        }
    }
}

/// 证据档位：圆点 + 文字，两个通道都带信息，不只靠颜色。
struct TierTag: View {
    let tier: Tier
    var count: Int?

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if tier == .unknown {
                    Circle().strokeBorder(tier.color, lineWidth: 1)
                } else {
                    Circle().fill(tier.color)
                }
            }
            .frame(width: 6, height: 6)
            Text(count.map { "\(tier.label) \($0)" } ?? tier.label)
                .font(.acmCaptionMed)
                .foregroundStyle(tier.color)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 复选框

enum CheckState {
    case off, on, mixed, protected
}

/// 16 pt 视觉尺寸，28 pt 命中区域。Protected 用锁表示不可绕过。
struct ACMCheckbox: View {
    let state: CheckState
    var enabled = true
    var label: String = "勾选"
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(filled ? Color.textPrimary : Color.surfaceRaised)
                if state == .off {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.lineControl, lineWidth: 1)
                }
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: state == .protected ? 9 : 9.5, weight: .bold))
                        .foregroundStyle(state == .protected ? Color.textSecondary : Color.textInverse)
                }
            }
            .frame(width: UI.checkbox, height: UI.checkbox)
            .opacity(enabled || state == .protected ? 1 : 0.45)
            .frame(width: UI.checkbox, height: UI.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || state == .protected)
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAddTraits(state == .off ? [] : .isSelected)
    }

    private var filled: Bool { state == .on || state == .mixed }

    private var symbol: String? {
        switch state {
        case .off: return nil
        case .on: return "checkmark"
        case .mixed: return "minus"
        case .protected: return "lock.fill"
        }
    }

    private var valueText: String {
        switch state {
        case .off: return "未勾选"
        case .on: return "已勾选"
        case .mixed: return "部分勾选"
        case .protected: return "受保护，不可勾选"
        }
    }
}

// MARK: - 按钮

/// 32 pt 高。主操作用中性色，不把可恢复色当品牌色。
struct ACMButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .secondary
    var height: CGFloat = UI.buttonHeight

    func makeBody(configuration: Configuration) -> some View {
        Chrome(kind: kind, height: height, configuration: configuration)
    }

    private struct Chrome: View {
        let kind: Kind
        let height: CGFloat
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(height < UI.buttonHeight ? .acmCaptionMed : .acmBodyMed)
                .lineLimit(1)
                .foregroundStyle(!isEnabled ? Color.textSecondary
                                 : kind == .primary ? Color.textInverse : Color.textPrimary)
                .padding(.horizontal, height < UI.buttonHeight ? 8 : 12)
                .frame(height: height)
                .background(!isEnabled ? Color.groupFill
                            : kind == .primary ? Color.textPrimary : Color.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.textPrimary, lineWidth: UI.focusWidth)
                            .padding(-3)
                    } else if isEnabled, kind == .secondary {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.lineControl, lineWidth: UI.hairline)
                    }
                }
                .opacity(configuration.isPressed ? 0.75 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .fixedSize()
        }
    }
}

extension ButtonStyle where Self == ACMButtonStyle {
    static var acmPrimary: ACMButtonStyle { ACMButtonStyle(kind: .primary) }
    static var acmSecondary: ACMButtonStyle { ACMButtonStyle(kind: .secondary) }
    /// 行内小按钮（复制命令等）
    static var acmCompact: ACMButtonStyle { ACMButtonStyle(kind: .secondary, height: 24) }
}

// MARK: - 区块

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
                .font(.acmHeadline)
                .foregroundStyle(Color.textPrimary)
            if let detail {
                Text(detail)
                    .font(.acmCaption)
                    .foregroundStyle(Color.textSecondary)
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

/// 流程弹窗里的一个区块：8 圆角容器，可带语义色细描边。
struct FlowSection<Content: View>: View {
    let title: String
    var detail: String?
    var tone: Color?
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.acmHeadline)
                    .foregroundStyle(tone ?? Color.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.acmCaption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.acmMonoNum)
                        .foregroundStyle(Color.textPrimary)
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.groupFill, in: RoundedRectangle(cornerRadius: UI.corner))
        .overlay {
            if let tone {
                RoundedRectangle(cornerRadius: UI.corner)
                    .strokeBorder(tone.opacity(0.35), lineWidth: UI.hairline)
            }
        }
    }
}

/// 0.5 pt 分隔线
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.lineHairline)
            .frame(height: UI.hairline)
    }
}

/// 小徽标：细线框 + 同色文字，不用实心色块，避免整页都是彩色胶囊。
/// 只有「正在使用」这类必须一眼看到的才保留填充。
struct Badge: View {
    let text: String
    var color: Color = .textSecondary
    var filled = false
    var help: String?

    var body: some View {
        Text(text)
            .font(.acmMicroMed)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(color)
            .background(filled ? color.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                if !filled {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(color.opacity(0.35), lineWidth: UI.hairline)
                }
            }
            .fixedSize()
            .help(help ?? text)
    }
}

/// 工具标识的查找与缓存。CLI 用 bundle 内置图；桌面 App 读本机 .app 自带图标。
@MainActor
enum ToolLogo {
    private static var cache: [String: NSImage?] = [:]
    private static var directory: URL?

    /// 有明确身份才显示对应图标，不按名字猜。桌面 App 自己的图标优先于
    /// 同厂商 CLI 的图标：ChatGPT 桌面版与 Codex CLI 本来就是两个产品。
    static func lookup(
        catalog: Catalog,
        productID: String?,
        binaries: [String],
        ownerApps: [AppInfo]
    ) -> NSImage? {
        for app in ownerApps {
            if let image = appIcon(app) { return image }
        }
        if let productID, let image = load(productID) { return image }
        for product in catalog.products {
            let match = product.binaries?.contains { binaries.contains($0) } == true
                || product.allBundleIDs.contains { bundleID in
                    ownerApps.contains { $0.bundleID == bundleID }
                }
            if match, let image = load(product.id) { return image }
        }
        return nil
    }

    /// NSWorkspace 处理 CFBundleIconFile / CFBundleIconName / Assets.car，
    /// 包含新版 .icon 与 Liquid Glass 图标，不需要自行解析 App 的资源。
    static func appIcon(_ app: AppInfo) -> NSImage? {
        let key = "app:" + PathUtil.key(app.path)
        if let cached = cache[key] { return cached }
        let image: NSImage?
        if FileManager.default.fileExists(atPath: app.path + "/Contents/Info.plist") {
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            // 工作区偶尔会对尚未注册的 bundle 返回通用应用图标，不能冒充厂商图标。
            // 通用图标仍然比首字母更符合桌面 App 的语义，保留它。
            icon.size = NSSize(width: 128, height: 128)
            image = icon
        } else {
            image = nil
        }
        cache[key] = image
        return image
    }

    private static func load(_ id: String) -> NSImage? {
        if let cached = cache[id] { return cached }
        if directory == nil {
            directory = Bundle.main.resourceURL?.appendingPathComponent("tool-logos", isDirectory: true)
            #if DEBUG
            // Debug 的 SwiftPM / 测试环境可读源码资源，发布版只读 App 内置资源。
            if directory == nil || !FileManager.default.fileExists(atPath: directory!.path) {
                directory = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("assets/tool-logos", isDirectory: true)
            }
            #endif
        }
        guard let url = directory?.appendingPathComponent(id + ".png") else { return nil }
        let image = FileManager.default.fileExists(atPath: url.path) ? NSImage(contentsOf: url) : nil
        cache[id] = image
        return image
    }
}

/// 每个工具一个可辨识的标识：名字首字母，中性 12% 底色，选中反白。
struct ToolIcon: View {
    let name: String
    var section: ACMCore.Section = .installed
    var size: CGFloat = 30
    var selected = false
    /// 有官方图标时直接用；没有就回首字母
    var logo: NSImage?

    var body: some View {
        Group {
            if let logo {
                if section == .managedByApp {
                    // macOS App 图标有自己的形状、阴影和透明边距，不再套圆角底板。
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: visualSize, height: visualSize)
                        .accessibilityHidden(true)
                } else {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: visualSize, height: visualSize)
                        .clipShape(RoundedRectangle(cornerRadius: visualSize * 0.24))
                        .overlay {
                            RoundedRectangle(cornerRadius: visualSize * 0.24)
                                .strokeBorder(Color.lineHairline, lineWidth: UI.hairline)
                        }
                        .accessibilityHidden(true)
                }
            } else {
                initialsTile
            }
        }
        // 保持布局占位不变，只缩小 CLI 图标的视觉尺寸，避免整行文字随图标调整而移动。
        .frame(width: size, height: size)
    }

    /// macOS App 图标自带透明边距；CLI 图标缩小到同样的视觉重量，而不是把 App 图标放大裁切。
    private var visualSize: CGFloat {
        section == .managedByApp ? size : size * 0.84
    }

    private var initialsTile: some View {
        Text(initials)
            .font(.system(size: visualSize * (initials.count > 1 ? 0.36 : 0.46), weight: .medium))
            .foregroundStyle(selected ? Color.surfaceBase : Color.textPrimary)
            .frame(width: visualSize, height: visualSize)
            .background(selected ? Color.textPrimary : Color.toolIconFill,
                        in: RoundedRectangle(cornerRadius: visualSize * 0.24))
            .accessibilityHidden(true)
    }
}

private extension ToolIcon {
    var initials: String {
        // 拉丁字母取首字母（两个词取两个首字母），中文取第一个字
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        if words.count > 1, words.allSatisfy({ $0.first?.isASCII == true }) {
            return words.prefix(2).map { String($0.prefix(1)).uppercased() }.joined()
        }
        return String(name.prefix(1)).uppercased()
    }
}

/// 占用大小的相对比例条：3pt 高，能辅助比较但不编码风险或归属。
struct SizeBar: View {
    /// 0…1
    var fraction: Double
    var width: CGFloat? = 56

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.barTrack)
                Capsule()
                    .fill(Color.textPrimary.opacity(0.55))
                    .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(width: width, height: 3)
        .opacity(0.75)
        .accessibilityHidden(true)
    }
}

/// 行尾的「为什么这么判 / 在 Finder 中显示」。前者常驻，
/// 后者悬停或键盘聚焦时出现。28 pt 命中区域。
struct RowActions: View {
    var onEvidence: () -> Void
    var onReveal: () -> Void
    var emphasized = false

    var body: some View {
        HStack(spacing: 4) {
            iconButton("info.circle", label: "为什么这么判", help: "归属判定与证据", action: onEvidence)
            iconButton("magnifyingglass", label: "在 Finder 中显示", help: "在 Finder 中显示", action: onReveal)
                .opacity(emphasized ? 1 : 0)
                .disabled(!emphasized)
                .allowsHitTesting(emphasized)
        }
    }

    private func iconButton(_ symbol: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(emphasized ? Color.textPrimary : Color.textSecondary)
                .frame(width: UI.hitTarget, height: UI.hitTarget)
                .background(emphasized ? Color.rowHover : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(help)
    }
}

/// 确认单/结果弹窗里的一项：路径 + 原因。
struct ReasonRow: View {
    let path: String
    var reason: String?
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(model.show(path))
                    .font(.acmMonoNum)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                Spacer(minLength: 8)
                Button("复制路径") { model.copy(path) }
                    .buttonStyle(.acmCompact)
            }
            if let reason {
                Text(reason)
                    .font(.acmCaption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
