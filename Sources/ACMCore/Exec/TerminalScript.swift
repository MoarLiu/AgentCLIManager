import Foundation

/// 「在终端运行」的包装脚本。只是生成文本，不执行命令，方便独立验证退出码。
public enum TerminalScript {
    public static func body(for command: String) -> String {
        // 命令本身按原样写入：它来自目录清单，或调用方已经做过引号处理。
        // 只有回显那一行需要把它当作单引号字符串处理。
        let quoted = "'" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/zsh -l
        print -r -- "$ "\(quoted)
        print
        \(command)
        acm_exit_status=$?
        print
        if [ "$acm_exit_status" -eq 0 ]; then
            print -r -- "—— 命令已成功结束（退出码 $acm_exit_status）。可以关闭这个窗口，回到 Agent CLI Manager 点「重新扫描」。——"
        else
            print -r -- "—— 命令未成功（退出码 $acm_exit_status）。可以关闭这个窗口，回到 Agent CLI Manager 点「重新扫描」。——"
        fi
        exit "$acm_exit_status"
        """
    }
}
