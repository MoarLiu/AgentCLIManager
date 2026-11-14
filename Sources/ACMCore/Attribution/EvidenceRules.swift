import Foundation

/// 目录内容标记：不认识的目录是不是 Agent 工具留下的。
///
/// 只产生「推测」级证据。它决定一个目录要不要出现在「未识别」里供人判断，
/// 永远不会让任何东西被默认勾选。
public enum ContentMarkers {
    /// 单独出现就够说明问题的名字
    static let strong: Set<String> = [
        "mcp.json", "mcp_config.json", "mcp_settings.json", "agents", "agent", "skills",
        "history.jsonl", ".skill-lock.json", "agent-hooks",
    ]
    static let strongPrefixes = ["skills-", "ai-", "mcp-", "mcp_"]
    /// 太常见，单独一个不算，两个以上才算。
    /// `AGENTS.md` 也在这里：任何一个源码仓库都可能带它（`~/.nvm` 就是个 git 仓库）。
    static let weak: Set<String> = [
        "sessions", "projects", "conversations", "prompts", "memory", "plugins", "agents.md", "claude.md",
    ]

    static let nameHints = ["agent", "copilot", "claude", "codex", "gpt", "llm", "mcp", "gemini", "qwen"]

    public struct Result: Sendable {
        public var hits: [String]
        public var nameHint: String?
        public var isAgentLike: Bool
    }

    public static func evaluate(name: String, children: [String]) -> Result {
        var strongHits: [String] = []
        var weakHits: [String] = []
        for child in children {
            let lower = child.lowercased()
            if strong.contains(lower) || strongPrefixes.contains(where: { lower.hasPrefix($0) }) {
                strongHits.append(child)
            } else if weak.contains(lower) {
                weakHits.append(child)
            }
        }
        let key = PathUtil.nameKey(name)
        let hint = nameHints.first { key.contains($0) }
        let agentLike = !strongHits.isEmpty || weakHits.count >= 2 || hint != nil
        return Result(hits: strongHits + weakHits, nameHint: hint, isAgentLike: agentLike)
    }
}

/// 归属结论 → 界面默认勾不勾。安全策略集中在这一个文件里。
public enum EvidenceRules {

    /// 补全与安全有关的标记：顶层目录、最近写入、root 属主、悬空、护栏是否放行。
    public static func applyFlags(_ artifact: inout Artifact, env: HostEnvironment) {
        if let info = FileProbe.lstat(artifact.path) {
            artifact.isSymlink = info.isSymlink
            artifact.isDirectory = info.isDirectory
            if info.ownerUID == 0 { artifact.flags.insert(.rootOwned) }
            if info.isSymlink && !FileProbe.exists(artifact.path) { artifact.flags.insert(.danglingSymlink) }
        }
        // 异常入口的目录目标不是工具目录，不能通过展开把其数据变成可清理子项。
        artifact.expandable = artifact.isDirectory && !artifact.isSymlink
            && !artifact.flags.contains(.invalidLauncher)
        artifact.lastModified = FileProbe.latestActivity(artifact.path)

        if PathUtil.key(PathUtil.parent(artifact.path)) == PathUtil.key(env.home) {
            artifact.flags.insert(.topLevelRoot)
        }
        if let modified = artifact.lastModified, env.now.timeIntervalSince(modified) < env.recentWindow {
            artifact.flags.insert(.recentlyModified)
        }
        if artifact.kind == .credentials {
            artifact.flags.insert(.credentials)
        }

        let decision = PathSafety.check(artifact.path, env: env)
        if !decision.allowed {
            artifact.flags.insert(.notRemovable)
            artifact.notRemovableReason = decision.reason
        }
    }

    /// 默认勾选规则。原则：只有「确定」的归属才可能被默认勾选；
    /// 任何一条保护标记都会否决。
    public static func defaultSelected(_ a: Artifact, in section: Section) -> Bool {
        let vetoes: Set<ArtifactFlag> = [
            .notRemovable, .manualOnly, .shared, .inUse, .credentials, .rootOwned,
            .invalidLauncher, .usedByOthers,
        ]
        if !a.flags.isDisjoint(with: vetoes) { return false }
        // 里面有属于别人的东西：整个带走会连累它们，必须由用户自己决定。
        if !a.foreignChildren.isEmpty { return false }
        guard a.strength == .certain else { return false }

        switch section {
        case .installed:
            // 卸载一个在用的工具：默认只带走程序和可再生的东西，配置与数据要用户主动勾。
            return [.program, .launcher, .cache, .logs].contains(a.kind)

        case .residue:
            guard a.claim == .residue else { return false }
            if a.flags.contains(.recentlyModified) { return false }
            // 顶层目录是放大错误的地方（几个 GB 都在这一层），必须清单声明独占才默认勾。
            if a.flags.contains(.topLevelRoot) && a.isDirectory && !a.declaredExclusive { return false }
            return true

        case .unidentified, .otherCLI, .managedByApp:
            return false
        }
    }
}
