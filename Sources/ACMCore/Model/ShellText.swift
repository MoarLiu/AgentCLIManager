import Foundation

/// 把动态内容放进「给用户复制或在终端运行」的命令行时用的引号处理。
///
/// 凡是来自文件系统的字符串（目录名、包名、路径）都必须经过这里，
/// 否则一个叫 `evil;rm -rf ~` 的目录就能改写命令的含义。
public enum ShellText {
    private static let safe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")

    /// 只含安全字符时原样返回（`@openai/codex` 不必加引号），否则用单引号包起来。
    public static func quote(_ s: String) -> String {
        if !s.isEmpty, !s.hasPrefix("-"), s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// npm 包名：`name` 或 `@scope/name`，小写字母、数字和 `-._~`。
    public static func isValidNpmPackage(_ s: String) -> Bool {
        matches(s, #"^(@[a-z0-9~-][a-z0-9._~-]*/)?[a-z0-9~-][a-z0-9._~-]*$"#) && s.count <= 214
    }

    /// Homebrew formula / cask 名（可带 `@版本`）。
    public static func isValidBrewName(_ s: String) -> Bool {
        matches(s, #"^[A-Za-z0-9][A-Za-z0-9+._@-]*$"#) && s.count <= 128
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }
}
