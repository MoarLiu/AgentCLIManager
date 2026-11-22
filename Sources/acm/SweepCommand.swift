import ACMCore
import Foundation

/// `acm sweep …`。scan / items / inspect 只读（scan 唯一会写的是 `--out` 指定的新计划文件）；
/// apply 和 restore 默认只预演，带 `--execute` 才移动或删除东西。
///
/// 返回退出码：0 成功，1 运行时失败（包括有任何一项被跳过或没走完），2 用法错误。
func runSweep(_ arguments: SweepArguments, env: HostEnvironment) -> Int32 {
    let cwd = FileManager.default.currentDirectoryPath
    func absolute(_ value: String) throws -> String {
        try SweepPath.rejectBlank(value)
        return SweepPath.absolute(value, home: env.home, cwd: cwd)
    }
    func confine(_ root: String) throws {
        if arguments.home != nil { try SweepPath.requireInside(root, home: env.home) }
    }
    func readPlan(_ file: String) throws -> SweepPlan {
        let plan = try SweepPlanStore.read(absolute(file), env: env)
        try confine(plan.root)
        return plan
    }

    do {
        switch arguments.command {
        case .scan(let root, let out, let idleHours, let maxEntries, let excludes):
            let scanRoot = try absolute(root)
            let outputPath = try out.map(absolute)
            try confine(scanRoot)
            var plan = try SweepScanner.scan(
                root: scanRoot,
                policy: SweepPolicy(idleHours: idleHours, maxEntries: maxEntries, excludes: try excludes.map(absolute)),
                env: env,
                now: Date()
            )
            if let outputPath {
                plan.planFile = try SweepPlanStore.write(plan, to: outputPath)
            }
            print(arguments.json ? SweepOutput.json(plan) : SweepOutput.text(plan))

        case .items(let file, let status, let limit, let offset):
            let plan = try readPlan(file)
            let page = try SweepPage(plan: plan, status: status, limit: limit, offset: offset)
            print(arguments.json ? SweepOutput.json(page) : SweepOutput.text(page))

        case .inspect(let file, let needle):
            let item = try readPlan(file).item(matching: needle)
            print(arguments.json ? SweepOutput.json(item) : SweepOutput.text(item))

        case .apply(let file, let ids, let execute, let permanent, let includeOldVersions):
            let plan = try readPlan(file)
            let result = try SweepExecutor.apply(
                plan, execute: execute, mode: permanent ? .permanent : .trash, identifiers: ids,
                includeOldVersions: includeOldVersions, env: env, now: Date()
            )
            print(arguments.json
                ? SweepOutput.json(result, incomplete: result.incomplete)
                : SweepOutput.text(result, plan: plan, requested: execute))
            return result.incomplete ? 1 : 0

        case .restore(let file, let execute):
            let result = try SweepRestorer.restore(
                receipt: absolute(file), execute: execute, env: env,
                confinedTo: arguments.home == nil ? nil : env.home
            )
            print(arguments.json
                ? SweepOutput.json(result, incomplete: result.incomplete)
                : SweepOutput.text(result, requested: execute))
            return result.incomplete ? 1 : 0
        }
        return 0
    } catch let error as SweepError {
        report(error, json: arguments.json)
        return error.isUsage ? 2 : 1
    } catch {
        report(SweepError("io_error", error.localizedDescription), json: arguments.json)
        return 1
    }
}

private func report(_ error: SweepError, json: Bool) {
    if json {
        print(SweepOutput.json(error))
    } else {
        var message = "错误：\(error.message)"
        if let path = error.details["path"] { message += "\n  \(path)" }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
