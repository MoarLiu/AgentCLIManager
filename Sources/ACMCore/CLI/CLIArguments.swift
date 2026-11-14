import Foundation

/// `acm` 的参数解析。纯逻辑：不碰文件系统、不读环境变量、不打印，
/// 用法错误一律以 `CLIArguments.Error` 抛出，由命令行入口统一转成退出码 2。
/// 单独放在 ACMCore 里是为了能用 Swift Testing 直接测。
public struct CLIArguments: Sendable {

    /// 用法错误（退出码 2）。
    public struct Error: Swift.Error, CustomStringConvertible, Equatable, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    public enum Command: Equatable, Sendable {
        /// 扫描并列出报告。`json` / `sizes` / `verbose` 只影响输出形式。
        case scan(json: Bool, sizes: Bool, verbose: Bool)
        /// 生成或执行某个工具的卸载计划。
        case plan(target: String, all: Bool, execute: Bool, receipts: String?)
        /// 按回执把移走的东西放回原处，回执路径必填。
        case undo(receipts: String)
        /// 列出目录清单认识的产品。
        case catalog(json: Bool)
        /// 打印用法。
        case help
    }

    public var command: Command
    /// 演练用的假家目录；nil 表示真实家目录。
    public var home: String?
    /// 不扫 ~/Library。
    public var noLibrary: Bool
    /// 不查进程表。
    public var noProcesses: Bool

    /// 已知的布尔 flag 全集，用来区分「--home 后面跟的是另一个选项」和「一个以 - 开头的目录名」。
    private static let knownFlags: Set<String> = [
        "--json", "--sizes", "--verbose", "--no-library", "--no-processes",
        "--all", "--execute", "--help", "-h",
    ]
    private static let valueOptionNames: Set<String> = ["--home", "--receipts"]

    public static func parse(_ arguments: [String]) throws -> CLIArguments {
        var args = arguments
        var commandName: String?
        var positionals: [String] = []
        // 带值选项：记录最后一次的值，重复给出直接报错。
        var values: [String: String] = [:]
        var flags: Set<String> = []

        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--home", "--receipts":
                // 先看到带值选项就当场吃掉它的值，不会像旧实现那样
                // 在 `--home --json` 里把「没值」当成「没给」，退回真实家目录。
                guard values[arg] == nil else { throw Error("\(arg) 给了两次") }
                // 后面是已知选项 → 缺值；是别的以 - 开头的词 → 既不是路径也不像值，同样拒绝。
                guard let value = args.first,
                      !knownFlags.contains(value), !valueOptionNames.contains(value),
                      !value.hasPrefix("-")
                else {
                    throw Error("\(arg) 需要一个值（后面不能紧跟另一个选项）")
                }
                args.removeFirst()
                values[arg] = value
            default:
                if arg.hasPrefix("-") {
                    guard flags.insert(arg).inserted else { throw Error("\(arg) 给了两次") }
                } else if commandName == nil {
                    commandName = arg
                } else {
                    positionals.append(arg)
                }
            }
        }

        let name = commandName ?? "scan"
        let isHelp = flags.contains("--help") || flags.contains("-h")
        flags.subtract(["--help", "-h"])

        let known: Set<String>
        switch name {
        case "scan": known = ["--json", "--sizes", "--verbose", "--no-library", "--no-processes"]
        case "plan": known = ["--all", "--execute", "--no-processes"]
        case "undo": known = []
        case "catalog": known = ["--json"]
        default: throw Error("不认识的子命令「\(name)」")
        }
        let valueOptions: Set<String> = name == "plan" ? ["--home", "--receipts"]
            : (name == "undo" ? ["--home", "--receipts"] : ["--home"])
        for option in Set(values.keys).union(flags).sorted() {
            guard known.contains(option) || valueOptions.contains(option) else {
                throw Error("\(name) 不认识选项 \(option)")
            }
        }

        func flag(_ name: String) -> Bool { flags.contains(name) }
        func value(_ name: String) -> String? { values[name] }
        // 多余的位置参数：plan 只要一个目标，其余子命令一个都不要。
        let requiredPositionals = name == "plan" ? 1 : 0
        if positionals.count < requiredPositionals {
            throw Error("plan 需要指定组 id 或名字")
        }
        if let extra = positionals.dropFirst(requiredPositionals).first {
            throw Error("多余的位置参数「\(extra)」")
        }
        // `--receipts` 只在真的执行时有意义；只演练时给了就报错，不静默忽略。
        if name == "plan", value("--receipts") != nil, !flag("--execute") {
            throw Error("--receipts 要和 --execute 一起用；只演练时不会写回执")
        }
        if name == "undo", value("--receipts") == nil {
            throw Error("undo 需要 --receipts <文件>")
        }

        let command: Command
        switch name {
        case "scan":
            command = .scan(json: flag("--json"), sizes: flag("--sizes"), verbose: flag("--verbose"))
        case "plan":
            command = .plan(
                target: positionals[0], all: flag("--all"),
                execute: flag("--execute"), receipts: value("--receipts")
            )
        case "undo":
            command = .undo(receipts: value("--receipts")!)
        default:
            command = .catalog(json: flag("--json"))
        }
        // `--help` 只看用法，不做事，这时候不必要求 --home 指向真实存在的目录。
        if isHelp { return CLIArguments(command: .help, home: nil, noLibrary: false, noProcesses: false) }

        return CLIArguments(
            command: command,
            home: value("--home"),
            noLibrary: flag("--no-library"),
            noProcesses: flag("--no-processes")
        )
    }
}
