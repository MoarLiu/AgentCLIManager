import Foundation

/// `acm sweep …` 的参数解析。和 `CLIArguments` 一样是纯逻辑：不碰文件系统、不打印。
public struct SweepArguments: Equatable, Sendable {

    public enum Command: Equatable, Sendable {
        /// 只读扫描一个目录；`out` 给了就把计划另存为新文件。
        case scan(root: String, out: String?, idleHours: Double, maxEntries: Int, excludes: [String])
        /// 分页列出计划里的候选项。
        case items(plan: String, status: SweepStatus?, limit: Int, offset: Int)
        /// 按 id 或相对路径查看计划里的一项。
        case inspect(plan: String, item: String)
        /// 按计划清理。默认只预演；`execute` 才动手，`permanent` 表示直接删除而不是进废纸篓。
        case apply(plan: String, ids: [String], execute: Bool, permanent: Bool, includeOldVersions: Bool)
        /// 按回执把还在暂存位置的内容放回原处。默认只预演。
        case restore(receipt: String, execute: Bool)
    }

    public var command: Command
    /// stdout 只输出一个 JSON 对象。
    public var json: Bool
    /// 演练用的假家目录；nil 表示真实家目录。
    public var home: String?

    private static let pathOptions: Set<String> = ["--home", "--out", "--exclude"]
    private static let numberOptions: Set<String> = ["--idle-hours", "--max-entries", "--limit", "--offset"]
    private static let wordOptions: Set<String> = ["--status", "--id"]
    private static let flags: Set<String> = [
        "--json", "--help", "-h", "--execute", "--permanent", "--include-old-versions",
    ]
    /// 可以给多次的选项。
    private static let repeatable: Set<String> = ["--exclude", "--id"]

    private static let allowed: [String: Set<String>] = [
        "scan": ["--out", "--idle-hours", "--max-entries", "--exclude"],
        "items": ["--status", "--limit", "--offset"],
        "inspect": [],
        "apply": ["--id", "--execute", "--permanent", "--include-old-versions"],
        "restore": ["--execute"],
    ]

    /// 解析 `sweep` 后面的全部参数。返回 nil 表示用户要的是帮助。
    public static func parse(_ arguments: [String]) throws -> SweepArguments? {
        let json = arguments.contains("--json")
        func usage(_ message: String) -> CLIArguments.Error {
            CLIArguments.Error(message, sweepJSON: json)
        }

        var args = arguments
        var positionals: [String] = []
        var values: [String: String] = [:]
        var repeated: [String: [String]] = [:]
        var seenFlags: Set<String> = []

        while !args.isEmpty {
            let arg = args.removeFirst()
            if pathOptions.contains(arg) || numberOptions.contains(arg) || wordOptions.contains(arg) {
                // 值的位置上是另一个选项，就是缺值。数值选项允许负数，好让它得到
                // 「不能小于零」而不是「缺值」这样的报错。
                guard let value = args.first,
                      !value.hasPrefix("-") || (numberOptions.contains(arg) && Double(value) != nil)
                else {
                    throw usage("\(arg) 需要一个值（后面不能紧跟另一个选项）")
                }
                args.removeFirst()
                if repeatable.contains(arg) {
                    repeated[arg, default: []].append(value)
                } else {
                    guard values[arg] == nil else { throw usage("\(arg) 给了两次") }
                    values[arg] = value
                }
            } else if arg.hasPrefix("-") {
                guard flags.contains(arg) else { throw usage("sweep 不认识选项 \(arg)") }
                guard seenFlags.insert(arg).inserted else { throw usage("\(arg) 给了两次") }
            } else {
                positionals.append(arg)
            }
        }
        if seenFlags.contains("--help") || seenFlags.contains("-h") { return nil }

        guard let name = positionals.first else {
            throw usage("sweep 需要子命令：scan、items、inspect、apply 或 restore")
        }
        guard let options = allowed[name] else {
            throw usage("sweep 不认识的子命令「\(name)」")
        }
        let given = Set(values.keys).union(repeated.keys)
            .union(seenFlags.subtracting(["--json", "--help", "-h"]))
        for option in given.sorted() where option != "--home" {
            guard options.contains(option) else { throw usage("sweep \(name) 不认识选项 \(option)") }
        }

        func integer(_ option: String, default fallback: Int) throws -> Int {
            guard let text = values[option] else { return fallback }
            guard let number = Int(text) else { throw usage("\(option) 需要一个整数") }
            return number
        }
        let operands = Array(positionals.dropFirst())
        func expect(_ count: Int, _ what: String) throws {
            if operands.count < count { throw usage("sweep \(name) 需要指定\(what)") }
            if operands.count > count { throw usage("多余的位置参数「\(operands[count])」") }
        }

        let command: Command
        switch name {
        case "scan":
            try expect(1, "要扫描的目录")
            var idleHours = 24.0
            if let text = values["--idle-hours"] {
                guard let number = Double(text) else { throw usage("--idle-hours 需要一个数字") }
                idleHours = number
            }
            command = .scan(
                root: operands[0], out: values["--out"], idleHours: idleHours,
                maxEntries: try integer("--max-entries", default: 500_000),
                excludes: repeated["--exclude"] ?? []
            )
        case "items":
            try expect(1, "计划文件")
            var status: SweepStatus?
            if let text = values["--status"] {
                guard let parsed = SweepStatus(rawValue: text) else {
                    throw usage("--status 只能是 cleanup、keep、review 或 blocked")
                }
                status = parsed
            }
            command = .items(
                plan: operands[0], status: status,
                limit: try integer("--limit", default: 50), offset: try integer("--offset", default: 0)
            )
        case "inspect":
            try expect(2, "计划文件和项目（id 或相对路径）")
            command = .inspect(plan: operands[0], item: operands[1])
        case "apply":
            try expect(1, "计划文件")
            let ids = repeated["--id"] ?? []
            // 点了名就只动点名的那些，「连旧版本一起」这句话没有对象。
            guard ids.isEmpty || !seenFlags.contains("--include-old-versions") else {
                throw usage("--id 和 --include-old-versions 不能同时给")
            }
            command = .apply(
                plan: operands[0], ids: ids, execute: seenFlags.contains("--execute"),
                permanent: seenFlags.contains("--permanent"),
                includeOldVersions: seenFlags.contains("--include-old-versions")
            )
        default:
            try expect(1, "回执文件")
            command = .restore(receipt: operands[0], execute: seenFlags.contains("--execute"))
        }
        return SweepArguments(command: command, json: json, home: values["--home"])
    }
}
