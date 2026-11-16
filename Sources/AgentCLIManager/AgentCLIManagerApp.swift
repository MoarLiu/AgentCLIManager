import ACMCore
import AppKit
import SwiftUI

@main
struct AgentCLIManagerApp: App {
    @State private var model = AppModel(snapshot: SnapshotOptions.parse(CommandLine.arguments))

    var body: some Scene {
        Window("Agent CLI Manager", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 920, minHeight: 580)
                .task { await model.start() }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("重新扫描") { model.rescan() }
                    .keyboardShortcut("r")
            }
        }
    }
}

/// 开发用：把窗口渲染成 PNG 后退出，用来在没有屏幕录制权限的环境里检查界面。
/// 这个模式下所有会动文件的操作都被禁用。
struct SnapshotOptions {
    var path: String
    var select: String?
    var sheet: String?
    var expand: String?
    /// 只读截图：展开某个侧栏分组
    var expandSection: String?
    var selectAll = false
    /// light / dark，用来检查两种外观
    var appearance: String?
    /// 宽x高，用来检查小窗口下的排版
    var size: String?
    /// 只读演示开关：往选中组里注入假的状态（运行中、入口异常、foreignChildren、横幅等），
    /// 让真实机器上没有的情况也能截图。只改内存里的数据，不碰文件。
    var demo: String?
    /// 打印各组概况后照常截图，用来挑截图对象
    var listGroups = false

    static func parse(_ args: [String]) -> SnapshotOptions? {
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        guard let path = value("--snapshot") else { return nil }
        var options = SnapshotOptions(path: path)
        options.select = value("--select")
        options.sheet = value("--sheet")
        options.expand = value("--expand")
        options.expandSection = value("--expand-section")
        options.selectAll = args.contains("--select-all")
        options.appearance = value("--appearance")
        options.size = value("--size")
        options.demo = value("--demo")
        options.listGroups = args.contains("--list-groups")
        return options
    }
}

@MainActor
enum Snapshotter {
    static func run(_ options: SnapshotOptions, model: AppModel) async {
        if let needle = options.select,
           let group = model.report?.groups.first(where: { $0.id == needle || $0.name == needle })
            ?? model.report?.groups.first(where: { $0.id.contains(needle) || $0.name.localizedCaseInsensitiveContains(needle) }) {
            model.selectedGroupID = group.id
        }
        // 等大小量完
        for _ in 0..<200 where model.isMeasuring || model.isScanning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if options.listGroups, let report = model.report {
            for group in report.groups {
                let names = group.artifacts.prefix(3).map { model.show($0.path) }.joined(separator: ", ")
                FileHandle.standardError.write(Data("group: \(group.section.rawValue) | \(group.name) | \(group.id) | \(group.artifacts.count) 项 | \(names)\n".utf8))
            }
        }
        if let group = model.selectedGroup {
            if options.selectAll { model.selectAll(group) }
            if let expand = options.expand,
               let artifact = group.artifacts.first(where: { $0.path.hasSuffix(expand) }) {
                model.toggleExpand(artifact, in: group)
                try? await Task.sleep(for: .milliseconds(600))
                for _ in 0..<100 where model.isMeasuring {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        applyDemo(options.demo, model: model)
        switch options.sheet {
        case "confirm":
            if let group = model.selectedGroup { model.preparePlan(for: group) }
        case "install":
            model.showInstall = true
        case "recovery":
            model.showRecovery = true
        default:
            break
        }
        if let appearance = options.appearance {
            let value = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            NSApp.appearance = value
            // sheet 是独立窗口，逐个窗口同步，避免主窗口深色而弹窗仍是浅色。
            for window in NSApp.windows { window.appearance = value }
        }
        if let size = options.size {
            let parts = size.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, let window = NSApp.windows.first(where: { $0.isVisible }) {
                window.setContentSize(NSSize(width: parts[0], height: parts[1]))
            }
        }
        try? await Task.sleep(for: .milliseconds(1500))

        let count = capture(to: options.path)
        FileHandle.standardError.write(Data("snapshot: 写出 \(count) 张\n".utf8))
        exit(count > 0 ? 0 : 1)
    }

    /// 往选中组里注入演示状态，纯内存操作。
    private static func applyDemo(_ demo: String?, model: AppModel) {
        guard let demo, var group = model.selectedGroup, var report = model.report,
              let index = report.groups.firstIndex(where: { $0.id == group.id }) else { return }
        let parts = demo.split(separator: ",").map(String.init)
        if parts.contains("running") {
            group.runningPIDs = [4321]
            for i in group.artifacts.indices { group.artifacts[i].flags.insert(.inUse) }
        }
        if parts.contains("foreign") || parts.contains("blocked") {
            for i in group.artifacts.indices where group.artifacts[i].isDirectory && group.artifacts[i].expandable {
                let child = ForeignChild(
                    path: group.artifacts[i].path + "/antigravity",
                    owner: "Antigravity",
                    usedByApp: parts.contains("blocked"),
                    certain: true)
                group.artifacts[i].foreignChildren = [child]
                if parts.contains("blocked") {
                    group.artifacts[i].flags.insert(.shared)
                    group.artifacts[i].ownerAppName = "Antigravity"
                }
            }
        }
        if parts.contains("invalid"), !group.binaries.isEmpty {
            group.binaries[0].invalidTarget = "一个目录"
            if let i = group.artifacts.firstIndex(where: { $0.kind == .launcher }) {
                group.artifacts[i].flags.insert(.invalidLauncher)
            }
        }
        if parts.contains("shared"), !group.binaries.isEmpty {
            for i in group.artifacts.indices where group.artifacts[i].kind == .program {
                group.artifacts[i].flags.insert(.usedByOthers)
                group.artifacts[i].alsoUsedBy = ["qodersec", "qoder-debug"]
            }
        }
        if parts.contains("banner") {
            model.banner = "没能打开终端：找不到「终端」"
            model.bannerIsError = true
        }
        if parts.contains("notice") {
            model.planNotice = "Qoder CLI 刚刚被启动（PID 4321），请重新确认风险后再移走。"
        }
        if parts.contains("undo"), let receipt = try? JSONDecoder().decode(
            TrashReceipt.self,
            from: Data("{\"original\":\"\(group.artifacts.first?.path ?? "/tmp/x")\",\"trashed\":\"/tmp/trash/x\"}".utf8)) {
            // 纯内存回执：undoLast 在截图模式下直接返回，不会真的碰废纸篓
            model.showDemoUndo(receipts: [receipt], groupName: group.name)
            model.undoFailures = [SkippedItem(path: group.artifacts.first?.path ?? "/tmp/x", reason: "原位置已有同名条目")]
        }
        report.groups[index] = group
        model.report = report
    }

    static func capture(to path: String) -> Int {
        var index = 0
        for window in NSApp.windows where window.isVisible {
            guard let content = window.contentView else { continue }
            let target = content.superview ?? content
            guard target.bounds.width > 50,
                  let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds)
            else { continue }
            target.cacheDisplay(in: target.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let out = index == 0 ? path : path.replacingOccurrences(of: ".png", with: "-\(index).png")
            do {
                try data.write(to: URL(fileURLWithPath: out))
                index += 1
            } catch {
                continue
            }
        }
        return index
    }
}
