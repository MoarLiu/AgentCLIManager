import ACMCore
import Foundation

// 开发、核对与卸载操作用的命令行。
// scan / catalog / plan（演练）只读；undo 只把废纸篓里的东西放回原处。
// plan 加上 --execute 才会把选中的条目移到废纸篓——绝不直接删除文件。

let usage = """
用法：
  acm scan [--json] [--sizes] [--verbose] [--no-library] [--no-processes] [--home <目录>]
  acm plan <组 id 或名字> [--all] [--execute] [--receipts <文件>] [--no-processes] [--home <目录>]
  acm undo --receipts <文件> [--home <目录>]
  acm catalog [--json]
  acm [<子命令>] --help | -h        打印本说明（退出码 0）；不带子命令等同于 scan

  scan    只读扫描，列出已装的 Agent CLI 及其关联文件
  plan    生成某个工具的卸载计划（默认只演练，--execute 才真的移到废纸篓）
  undo    把某次执行移走的东西放回原处（读取 --execute 写出的回执文件）
  catalog 列出目录清单里认识的产品（--json 输出合并后的完整清单）

选项：
  --home <目录>      对着假家目录演练。必须是已存在的目录；不给值、值以 - 开头、
                     目录不存在都是用法错误，绝不会悄悄退回真实家目录
  --receipts <文件>  plan --execute 时把回执写到这里，undo 用它放回；支持相对路径。
                     新执行必须使用不存在的路径，不覆盖旧回执（包括 []）、目录或软链。
                     执行前排他预留实际文件；中止时可能留下 []，不能据此判定执行成功。
                     不带 --execute 单独给 --receipts 是用法错误
  --all              plan 时连默认没勾选的条目也一起列入计划，排除登录凭据。
                     父目录仍可能包含凭据，计划会单独提示风险
  --execute          plan 时真的执行（只移到废纸篓，从不直接删除）
  --no-processes     不查进程表，也不做执行前的运行状态复查
  --no-library       scan 时不扫 ~/Library
  --json / --sizes / --verbose   scan 的输出形式；--json 也用于 catalog

目标匹配（plan）：先按组 id 精确匹配，再按名字精确匹配（大小写不敏感），
最后才按子串匹配。子串命中多个组会列出全部候选并退出（码 2），不会替你挑一个；
一个都没有命中退出码 1。

退出码：
  0  完全成功（纯演练时计划为空也算成功）
  1  运行时失败：找不到目标、执行有任何一步失败、放回有任何一项失败、
     读不出回执、执行前发现工具刚被启动、--execute 时计划为空没有东西可移等
  2  用法错误：缺选项值、选项不认识或重复、多余的位置参数、子命令不认识、
     --home 不是已存在的目录、回执文件在执行前就确认写不进去等

所有错误信息都写到 stderr。undo 部分放回失败时会把剩余回执写回原文件，
处理完冲突后可以再跑一次 undo；全部放回后文件被改写成 []。
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("错误：\(message)\n".utf8))
    exit(code)
}

// MARK: - 参数解析（任何环境组装、扫描都发生在它之后）

let parsed: CLIArguments
do {
    parsed = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIArguments.Error {
    FileHandle.standardError.write(Data("错误：\(error.message)\n\n\(usage)\n".utf8))
    exit(2)
} catch {
    fail("\(error)", code: 2)
}
if case .help = parsed.command {
    print(usage)
    exit(0)
}

// MARK: - 组装环境

var env = HostEnvironment.live()
if let home = parsed.home {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory), isDirectory.boolValue else {
        fail("--home 必须是已存在的目录：\(home)", code: 2)
    }
    // 用于对着假家目录演练。
    //
    // 废纸篓要同时认两处：系统的 trashItem 把 /tmp 下的东西放进当前用户的真实废纸篓，
    // 所以除了假家目录自己的 .Trash，真实环境的废纸篓目录也得算数，否则 undo 会拒绝放回。
    env = HostEnvironment(
        home: home,
        appDirs: [home + "/Applications"],
        systemBinDirs: [],
        selfPaths: [],
        signProbe: nil,
        trashDirs: [home + "/.Trash"] + HostEnvironment.live().trashDirs
    )
}
if parsed.noLibrary { env.includeLibrary = false }

let catalog = Catalog.loadAll(env: env)

// MARK: - 小工具

let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return e
}()

/// 执行后只提交到预留的文件。失败时输出完整 JSON，恢复信息不能丢。
func saveReceiptsAfterExecute(_ receipts: [TrashReceipt], to journal: ReceiptJournal) -> Bool {
    let path = journal.path
    do {
        try journal.commit(receipts)
        print("回执已写入 \(path)，可用 acm undo --receipts \(path) 放回")
        return true
    } catch {
        FileHandle.standardError.write(Data((
            "错误：回执写入 \(path) 失败（\(error.localizedDescription)）。\n"
            + "下面是这次移走条目的回执 JSON，请手工保存后用 acm undo --receipts 放回：\n"
        ).utf8))
        if let data = (error as? ReceiptJournal.CommitError)?.recoveryJSON ?? (try? ReceiptJournal.encode(receipts)) {
            print(String(decoding: data, as: UTF8.self))
        }
        return false
    }
}

func scanReport() -> ScanReport {
    ToolScanner.scan(ScanOptions(
        env: env,
        catalog: catalog,
        processProbe: parsed.noProcesses ? nil : ProcessProbe.live
    ))
}

/// id 精确 → 名字精确（大小写不敏感）→ 子串。
/// 精确匹配唯一就用它；落到子串且命中多个时列出全部候选，不替用户挑。
func selectGroup(_ needle: String, in report: ScanReport) -> ToolGroup? {
    let groups = report.groups
    if let exact = groups.first(where: { $0.id == needle }) { return exact }
    let named = groups.filter { $0.name.caseInsensitiveCompare(needle) == .orderedSame }
    if named.count == 1 { return named[0] }
    if named.count > 1 {
        reportAmbiguous(needle, named, reason: "命中多个同名的组")
    }
    let fuzzy = groups.filter { $0.id.contains(needle) || $0.name.localizedCaseInsensitiveContains(needle) }
    if fuzzy.count > 1 {
        reportAmbiguous(needle, fuzzy, reason: "是多个组的子串")
    }
    return fuzzy.first
}

func reportAmbiguous(_ needle: String, _ groups: [ToolGroup], reason: String) -> Never {
    FileHandle.standardError.write(Data("「\(needle)」\(reason)，请用更精确的组 id 或名字：\n".utf8))
    for group in groups {
        FileHandle.standardError.write(Data("  \(group.id)  \(group.name)\n".utf8))
    }
    exit(2)
}

// MARK: - 子命令

switch parsed.command {
case .help:
    break // 上面已经处理

case .scan(let json, let sizes, let verbose):
    var report = scanReport()
    if sizes {
        report = ToolScanner.measured(report, probe: DuSizeProbe())
    }
    print(json ? ReportRenderer.json(report) : ReportRenderer.text(report, home: env.home, verbose: verbose))

case .catalog(let json):
    if json {
        guard let data = try? encoder.encode(catalog) else { fail("目录清单编码失败", code: 1) }
        print(String(decoding: data, as: UTF8.self))
    } else {
        let products = catalog.products.sorted { $0.kind.rawValue < $1.kind.rawValue || ($0.kind == $1.kind && $0.name < $1.name) }
        for product in products {
            let bins = (product.binaries ?? []).joined(separator: ", ")
            let paths = (product.paths ?? []).map { "\($0.path)(\($0.kind.rawValue)\($0.shared == true ? ",共用" : ""))" }.joined(separator: " ")
            print("\(product.kind.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0)) \(product.id.padding(toLength: 18, withPad: " ", startingAt: 0)) \(product.name)")
            if !bins.isEmpty { print("     命令: \(bins)") }
            if !paths.isEmpty { print("     路径: \(paths)") }
            if let install = product.install, !install.isEmpty {
                for method in install { print("     安装[\(method.channel)]: \(method.command)") }
            }
        }
    }

case .plan(let needle, let all, let execute, let receiptsPath):
    if execute {
        if receiptsPath == nil {
            FileHandle.standardError.write(Data(
                "提示：没有指定 --receipts，这次移走的东西只能到废纸篓里手工放回。\n".utf8
            ))
        }
    }

    let report = scanReport()
    guard let group = selectGroup(needle, in: report) else {
        fail("没有找到「\(needle)」", code: 1)
    }
    let selected = Set(group.artifacts.filter {
        !$0.flags.contains(.credentials) && (all || $0.defaultSelected)
    }.map(\.path))
    let plan = UninstallPlanner.plan(group: group, selected: selected, env: env)
    print("计划：\(group.name)（id \(group.id)）—— 将移走 \(plan.steps.count) 项")
    for step in plan.steps {
        print("  → \(PathUtil.display(step.path, home: env.home))" + (step.size.map { "  \($0.display)" } ?? ""))
    }
    if let reclaimable = plan.reclaimable {
        print("  清空废纸篓后释放：\(reclaimable.display)")
    }
    for item in plan.skipped {
        print("  不动 \(PathUtil.display(item.path, home: env.home))：\(item.reason)")
    }
    for warning in plan.warnings {
        print("  ⚠ \(warning)")
    }
    for manual in plan.manualCommands {
        print("  需要你执行：\(manual)")
    }

    if execute {
        guard !plan.isEmpty else {
            fail("计划为空，没有可移走的条目；未执行任何操作", code: 1)
        }
        // 唯一目标及非空计划确定后才预留；预留失败绝不移动工具。
        let journal: ReceiptJournal?
        do {
            journal = try receiptsPath.map { try ReceiptJournal(reserving: $0) }
        } catch {
            fail("无法预留回执文件（\(error.localizedDescription)）；未执行任何移动", code: 2)
        }
        let result = Uninstaller.execute(
            plan, env: env, remover: TrashRemover(),
            processProbe: parsed.noProcesses ? nil : ProcessProbe.live
        )
        guard result.newlyRunningPIDs.isEmpty else {
            let pids = result.newlyRunningPIDs.map(String.init).joined(separator: "、")
            fail("生成计划之后 \(group.name) 被启动了（PID \(pids)），已中止，一项都没移走。请先退出它再试", code: 1)
        }
        print("已移走 \(result.receipts.count) 项，失败 \(result.failures.count) 项")
        for failure in result.failures {
            print("  失败 \(failure.path)：\(failure.reason)")
        }
        var ok = result.failures.isEmpty
        if let journal, !saveReceiptsAfterExecute(result.receipts, to: journal) {
            ok = false
        }
        exit(ok ? 0 : 1)
    } else if !plan.isEmpty {
        print("（这是演练。要真的执行请加 --execute）")
    }

case .undo(let inputPath):
    let receiptsPath = ReceiptJournal.absolutePath(inputPath)
    let receipts: [TrashReceipt]
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: receiptsPath))
        receipts = try JSONDecoder().decode([TrashReceipt].self, from: data)
    } catch {
        fail("读不出回执文件 \(receiptsPath)（\(error.localizedDescription)）", code: 1)
    }
    let outcome = Uninstaller.restore(receipts, env: env, remover: TrashRemover())
    print("放回 \(outcome.restored.count) 项，失败 \(outcome.failures.count) 项")
    for failure in outcome.failures {
        print("  失败 \(failure.path)：\(failure.reason)")
    }
    // 剩余回执写回同一个文件：处理完冲突后可以直接再跑一次 undo。
    // 全部放回就写成 []，下次再跑是空操作。
    do {
        try ReceiptJournal.saveRemaining(outcome.remaining, to: receiptsPath)
        if outcome.remaining.isEmpty {
            print("回执已清空（[]）：\(receiptsPath)")
        } else {
            print("剩余 \(outcome.remaining.count) 项的回执已写回 \(receiptsPath)，处理完上面的冲突后可再跑一次 undo")
        }
    } catch {
        fail("剩余回执写回 \(receiptsPath) 失败（\(error.localizedDescription)），原文件未更新，请先手工备份", code: 1)
    }
    exit(outcome.succeeded ? 0 : 1)
}
