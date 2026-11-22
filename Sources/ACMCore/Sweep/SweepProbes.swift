import Darwin
import Foundation

/// 某个进程打开着的一个路径。
public struct SweepOpenPath: Sendable, Hashable {
    public var pid: Int32
    public var command: String
    public var path: String
    /// 这个路径是进程的工作目录
    public var isCwd: Bool

    public init(pid: Int32, command: String, path: String, isCwd: Bool) {
        self.pid = pid
        self.command = command
        self.path = path
        self.isCwd = isCwd
    }
}

public enum SweepGitAnswer: Sendable, Equatable {
    /// 仓库索引里没有这个路径下的文件
    case untracked
    /// 有文件被 Git 跟踪着
    case tracked
    /// 问不出来（超时、仓库读不了）。按「可能被跟踪」处理。
    case failed
    /// 本机没有可用的 git。同样不放行，但原因和「仓库读不了」分开。
    case missing
}

/// 一次 `git ls-files -z` 的结果。扫描一轮里按仓库缓存；执行前的复核不用它。
public enum SweepGitIndex: Sendable, Equatable {
    case files([String])
    case failed
    case missing
}

/// 扫描要向外部问的两件事。测试里换成假的，引擎本身不启动任何子进程。
public struct SweepProbes: Sendable {
    /// 当前用户的进程打开了哪些路径。问不全就抛错——那时所有候选项都不会被判成可清理。
    public var openPaths: @Sendable () throws -> [SweepOpenPath]
    /// `repository` 里 `relative` 这个路径下有没有被跟踪的文件。
    public var gitTracked: @Sendable (_ repository: String, _ relative: String) -> SweepGitAnswer
    /// 列出仓库里全部已跟踪路径。只给一轮扫描做内存查询；不提供时扫描退回逐项 `gitTracked`。
    public var gitIndex: (@Sendable (String) -> SweepGitIndex)?

    public init(
        openPaths: @escaping @Sendable () throws -> [SweepOpenPath],
        gitTracked: @escaping @Sendable (_ repository: String, _ relative: String) -> SweepGitAnswer,
        gitIndex: (@Sendable (String) -> SweepGitIndex)? = nil
    ) {
        self.openPaths = openPaths
        self.gitTracked = gitTracked
        self.gitIndex = gitIndex
    }

    public static var live: SweepProbes {
        let git = LiveGit()
        return SweepProbes(
            openPaths: LiveOpenPaths.probe,
            gitTracked: { git.tracked($0, $1) },
            gitIndex: { git.index($0) }
        )
    }
}

// MARK: - 进程占用

enum LiveOpenPaths {
    /// 用系统自带的 lsof 列出当前用户所有进程打开的文件、工作目录和映射的可执行文件。
    ///
    /// 自己和自己的上级进程不算：从某个项目目录里运行本工具的那个终端，
    /// 工作目录当然在项目里，那不是「项目正在使用」。
    static let probe: @Sendable () throws -> [SweepOpenPath] = {
        let failure = SweepError("process_probe_failed", "进程占用检查未完成。")
        let executable = "/usr/sbin/lsof"
        guard access(executable, X_OK) == 0 else {
            throw SweepError("process_probe_failed", "缺少 lsof，无法核对进程占用。")
        }
        var excluded = ancestry(of: getpid())
        guard let result = SweepSubprocess.run(
            executable, ["-nP", "-F0pcfn", "-a", "-u", String(getuid())], timeout: 45
        ) else { throw failure }
        excluded.insert(result.pid)
        // lsof 只要有一处没读全就会在 stderr 里说；宁可整体作废，也不拿不完整的结果放行。
        guard result.status == 0,
              result.stderr.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x09 || $0 == 0x0D })
        else {
            throw SweepError("process_probe_failed", "lsof 未完整完成，执行已阻止。")
        }
        return parse(result.stdout, excluding: excluded)
    }

    /// `-F0` 的输出：每个字段以 NUL 结尾，首字节是字段类型（p 进程号、c 命令名、f 描述符、n 路径）。
    static func parse(_ output: Data, excluding excluded: Set<Int32>) -> [SweepOpenPath] {
        var records: [SweepOpenPath] = []
        var pid: Int32?
        var command = ""
        var descriptor = ""
        for raw in output.split(separator: 0, omittingEmptySubsequences: true) {
            let field = raw.drop(while: { $0 == 0x0A })
            guard let key = field.first else { continue }
            let value = String(decoding: field.dropFirst(), as: UTF8.self)
            switch key {
            case UInt8(ascii: "p"):
                pid = Int32(value)
                descriptor = ""
            case UInt8(ascii: "c"):
                command = value
            case UInt8(ascii: "f"):
                descriptor = value
            case UInt8(ascii: "n"):
                guard value.hasPrefix("/"), let pid, !excluded.contains(pid) else { continue }
                records.append(SweepOpenPath(pid: pid, command: command, path: value, isCwd: descriptor == "cwd"))
            default:
                continue
            }
        }
        return records
    }

    /// 自己和所有上级进程。
    static func ancestry(of start: pid_t) -> Set<Int32> {
        var out: Set<Int32> = [start]
        var current = start
        while current > 1 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
            let parent = info.kp_eproc.e_ppid
            guard out.insert(parent).inserted else { break }
            current = parent
        }
        return out
    }
}

// MARK: - Git

/// 用 Git 自己来回答「有没有被跟踪」，这样 worktree、忽略规则都按 Git 的语义算。
final class LiveGit: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private var executable: String?

    func tracked(_ repository: String, _ relative: String) -> SweepGitAnswer {
        guard let result = run(repository, ["ls-files", "-z", "--", relative]) else {
            return path() == nil ? .missing : .failed
        }
        guard result.status == 0 else { return .failed }
        return result.stdout.isEmpty ? .untracked : .tracked
    }

    /// 整个索引，路径相对于仓库根。调用方按扫描轮次自己缓存。
    func index(_ repository: String) -> SweepGitIndex {
        guard let result = run(repository, ["ls-files", "-z"]) else {
            return path() == nil ? .missing : .failed
        }
        guard result.status == 0 else { return .failed }
        var files: [String] = []
        for slice in result.stdout.split(separator: 0, omittingEmptySubsequences: true) {
            guard let file = String(bytes: slice, encoding: .utf8) else { return .failed }
            files.append(file)
        }
        return .files(files)
    }

    /// 待查的目录可能是从网上下载的仓库：关掉会执行外部程序的配置项，
    /// 不取可选锁，也不让调用方环境里的 GIT_DIR 之类把查询引到别的仓库去。
    private func run(_ repository: String, _ arguments: [String]) -> SweepSubprocess.Output? {
        guard let git = path() else { return nil }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        return SweepSubprocess.run(
            git,
            [
                "--literal-pathspecs", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                "-C", repository,
            ] + arguments,
            environment: environment, timeout: 30, keepStderr: false
        )
    }

    private func path() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if !resolved {
            executable = Self.locate()
            resolved = true
        }
        return executable
    }

    private static func locate() -> String? {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            .split(separator: ":").map(String.init)
        guard let found = (directories + ["/usr/bin"]).map({ $0 + "/git" })
            .first(where: { $0.hasPrefix("/") && access($0, X_OK) == 0 && !SweepFS.isDirectory($0) })
        else { return nil }
        // /usr/bin/git 只是个转发器：没装开发者工具时运行它会弹出安装对话框。
        if found == "/usr/bin/git" {
            guard let check = SweepSubprocess.run("/usr/bin/xcode-select", ["-p"], timeout: 5, keepStderr: false),
                  check.status == 0
            else { return nil }
        }
        return found
    }
}

// MARK: - 子进程

enum SweepSubprocess {
    struct Output {
        var pid: Int32
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    /// 运行并等它结束；启动不了或超时返回 nil（超时会先把它结束掉）。
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        keepStderr: Bool = true
    ) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = keepStderr ? err : FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        // 两个管道同时读，免得其中一个写满后互相卡住。
        let outBox = Box()
        let errBox = Box()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.data = out.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        if keepStderr {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                readers.leave()
            }
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        readers.wait()
        if timedOut { return nil }
        return Output(
            pid: process.processIdentifier, status: process.terminationStatus,
            stdout: outBox.data, stderr: errBox.data
        )
    }

    private final class Box: @unchecked Sendable {
        var data = Data()
    }
}
