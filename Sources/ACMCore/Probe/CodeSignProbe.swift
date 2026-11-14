import Foundation
import Security

/// 读取二进制的代码签名身份。进程内完成，不启动子进程。
public enum CodeSignProbe {
    public static let probe: @Sendable (String) -> CodeSignInfo? = { path in
        var code: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, SecCSFlags(), &code) == errSecSuccess, let code else {
            return nil
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return nil }
        let identifier = dict[kSecCodeInfoIdentifier as String] as? String
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        if identifier == nil && team == nil { return nil }
        return CodeSignInfo(identifier: identifier, teamID: team)
    }
}
