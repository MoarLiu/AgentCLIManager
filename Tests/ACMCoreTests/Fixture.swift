import Foundation
@testable import ACMCore

/// 在临时目录里搭一个假家目录。所有测试都只在这里面读写。
final class Fixture {
    let root: String
    let home: String

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("acm-tests-" + UUID().uuidString)
        root = base.path
        home = root + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    deinit {
        // 测试里可能改过权限，先放开再删
        _ = try? FileManager.default.subpathsOfDirectory(atPath: root).map { sub in
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/" + sub)
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ rel: String) -> String { home + "/" + rel }

    @discardableResult
    func dir(_ rel: String) -> String {
        let p = path(rel)
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    @discardableResult
    func file(_ rel: String, _ content: String = "data", executable: Bool = false) -> String {
        let p = path(rel)
        try! FileManager.default.createDirectory(
            atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: p, contents: Data(content.utf8))
        if executable {
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p)
        }
        return p
    }

    /// `target` 可以是相对路径（相对于链接所在目录）或绝对路径。
    @discardableResult
    func link(_ rel: String, to target: String) -> String {
        let p = path(rel)
        try! FileManager.default.createDirectory(
            atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try! FileManager.default.createSymbolicLink(atPath: p, withDestinationPath: target)
        return p
    }

    func app(_ name: String, bundleID: String) {
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name]
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let p = path("Applications/\(name).app/Contents/Info.plist")
        try! FileManager.default.createDirectory(
            atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: p, contents: data)
    }

    /// `daysLater` 把「现在」往后拨，让刚创建的文件看起来是很久以前的。
    /// `trashDirs` 不给时是假家目录里的 `.Trash`；用 MoveRemover 时要传它的假废纸篓。
    func env(daysLater: Int = 60, selfPaths: [String] = [], trashDirs: [String]? = nil) -> HostEnvironment {
        HostEnvironment(
            home: home,
            appDirs: [home + "/Applications"],
            systemBinDirs: [],
            now: Date().addingTimeInterval(Double(daysLater) * 86_400),
            selfPaths: selfPaths,
            signProbe: nil,
            trashDirs: trashDirs
        )
    }
}

let testCatalog: Catalog = {
    let json = """
    {
      "schemaVersion": 1,
      "products": [
        { "id": "claude-code", "name": "Claude Code", "kind": "cli", "binaries": ["claude"],
          "companionApps": ["com.anthropic.claudefordesktop"],
          "paths": [
            { "path": "~/.local/share/claude", "kind": "program", "exclusive": true },
            { "path": "~/.claude", "kind": "data", "shared": true }
          ] },
        { "id": "codex", "name": "Codex CLI", "kind": "cli", "binaries": ["codex"],
          "packages": ["@openai/codex"], "companionApps": ["com.openai.codex"],
          "paths": [ { "path": "~/.codex", "kind": "data", "shared": true } ] },
        { "id": "qoder-cli", "name": "Qoder CLI", "kind": "cli", "binaries": ["qodercli"],
          "companionApps": ["com.qoder.app"],
          "paths": [
            { "path": "~/.qoder/bin/qodercli", "kind": "program" },
            { "path": "~/.qoder", "kind": "data", "shared": true }
          ] },
        { "id": "cursor-cli", "name": "Cursor CLI", "kind": "cli", "binaries": ["cursor-agent"],
          "companionApps": ["com.todesktop.230313mzl4w4u92"],
          "paths": [ { "path": "~/.cursor", "kind": "data", "shared": true } ] },
        { "id": "codexbar", "name": "CodexBar", "kind": "app", "bundleIDs": ["com.steipete.codexbar"],
          "paths": [ { "path": "~/.codexbar", "kind": "data", "exclusive": true } ] },
        { "id": "grok-cli", "name": "Grok CLI", "kind": "cli", "binaries": ["grok"],
          "paths": [
            { "path": "~/.grok/downloads", "kind": "program" },
            { "path": "~/.grok/auth.json", "kind": "credentials" },
            { "path": "~/.grok", "kind": "data" }
          ] },
        { "id": "gemini-cli", "name": "Gemini CLI", "kind": "cli", "binaries": ["gemini"],
          "paths": [ { "path": "~/.gemini", "kind": "data" } ] }
      ]
    }
    """
    return try! Catalog.decode(Data(json.utf8))
}()

func scan(
    _ fx: Fixture,
    daysLater: Int = 60,
    processes: [RunningProcess] = [],
    catalog: Catalog = testCatalog
) -> ScanReport {
    let env = fx.env(daysLater: daysLater)
    let probe: (@Sendable () -> [RunningProcess])?
    if processes.isEmpty {
        probe = nil
    } else {
        probe = { processes }
    }
    return ToolScanner.scan(ScanOptions(env: env, catalog: catalog, processProbe: probe))
}

struct Hit {
    var group: ToolGroup
    var artifact: Artifact
}

func find(_ report: ScanReport, _ path: String) -> Hit? {
    for group in report.groups {
        if let artifact = group.artifacts.first(where: { $0.path == path }) {
            return Hit(group: group, artifact: artifact)
        }
    }
    return nil
}

/// 把东西挪进假家目录外的一个假废纸篓，用来验证「放回原处」。
final class MoveRemover: Remover, @unchecked Sendable {
    let trashDir: String
    init(trashDir: String) {
        self.trashDir = trashDir
        try! FileManager.default.createDirectory(atPath: trashDir, withIntermediateDirectories: true)
    }

    func trash(_ path: String) throws -> String? {
        let destination = trashDir + "/" + UUID().uuidString + "-" + (path as NSString).lastPathComponent
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        return destination
    }

    func restore(from trashed: String, to original: String) throws {
        try TrashRemover().restore(from: trashed, to: original)
    }
}
