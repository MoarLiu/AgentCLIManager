import Darwin
import Foundation

/// 计划文件的存取。
///
/// 扫描和执行是分开的两步，中间隔着一份落盘的计划：先看清楚要动什么，再决定动不动。
/// 文件里带一个内容摘要，读的时候核对，手工改过或写坏了的计划一律不认。
/// 这个摘要防的是误改和损坏，不是防伪——能改文件的人也能重算摘要，
/// 所以执行前还要对着磁盘重新核对每一项。
public enum SweepPlanStore {

    private static var canonicalEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func integrity(of plan: SweepPlan) throws -> String {
        var content = plan
        content.planFile = nil
        return SweepCanonical.sha256(try canonicalEncoder.encode(content))
    }

    private struct Stored: Codable {
        var plan: SweepPlan
        var integrity: String

        private enum CodingKeys: String, CodingKey { case integrity }

        init(plan: SweepPlan, integrity: String) {
            self.plan = plan
            self.integrity = integrity
        }

        init(from decoder: Decoder) throws {
            plan = try SweepPlan(from: decoder)
            integrity = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .integrity)
        }

        func encode(to encoder: Encoder) throws {
            try plan.encode(to: encoder)
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(integrity, forKey: .integrity)
        }
    }

    /// 把计划写成一个新文件，返回它的绝对路径。已有同名文件（包括软链）时拒绝，绝不覆盖。
    @discardableResult
    public static func write(_ plan: SweepPlan, to destination: String) throws -> String {
        guard destination.hasPrefix("/") else {
            throw SweepError("unsafe_plan_path", "计划文件需要绝对路径。")
        }
        let path = PathUtil.standardize(destination)
        let resolved = SweepPath.resolveLenient(path)
        for item in plan.items where item.status == .cleanup {
            let target = plan.absolutePath(of: item)
            if SweepPath.isInside(path, target) || SweepPath.isInside(resolved, target) {
                throw SweepError("unsafe_plan_path", "计划文件不能放在待清理目录内部。")
            }
        }
        var content = plan
        content.planFile = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(Stored(plan: content, integrity: try integrity(of: content)))
        data.append(0x0A)

        try FileManager.default.createDirectory(
            atPath: SweepPath.parent(path), withIntermediateDirectories: true
        )
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            if errno == EEXIST { throw SweepError("plan_exists", "计划文件已存在，请使用新文件名。") }
            throw SweepError.posix("无法创建计划文件", errno)
        }
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SweepError.posix("无法写入计划文件", count == 0 ? EIO : errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw SweepError.posix("无法写入计划文件", errno) }
        return path
    }

    public static func read(_ source: String, env: HostEnvironment) throws -> SweepPlan {
        let invalid = SweepError("invalid_plan", "计划文件已修改、损坏或版本不受支持，请重新扫描。")
        guard let info = SweepFS.lstat(source) else {
            throw SweepError.posix("读不出计划文件", errno)
        }
        guard SweepFS.isRegular(info), info.st_size <= off_t(SweepEngine.maxPlanBytes) else {
            throw SweepError("invalid_plan", "计划文件不符合大小或路径要求。")
        }
        guard let data = FileManager.default.contents(atPath: source) else {
            throw SweepError("io_error", "读不出计划文件。")
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let expected = try? integrity(of: stored.plan), expected == stored.integrity
        else { throw invalid }

        let plan = stored.plan
        guard plan.schemaVersion == SweepEngine.schemaVersion,
              plan.items.count <= SweepEngine.maxItems,
              Set(plan.items.map(\.id)).count == plan.items.count,
              plan.createdAt.isFinite
        else { throw invalid }
        for item in plan.items {
            let parts = item.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !item.path.hasPrefix("/"), !parts.isEmpty,
                  !parts.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." })
            else { throw invalid }
        }
        // 扫描根要现在仍然合法，而且写法没被改过。
        guard try SweepPath.normalizedRoot(plan.root, env: env) == plan.root else { throw invalid }
        return plan
    }
}
