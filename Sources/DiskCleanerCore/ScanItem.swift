import Foundation

public struct WorktreeInfo: Sendable, Hashable {
    public let repoPath: String
    public let branch: String?
    /// Reasons removal would lose work or git would refuse. `nil` means not checked yet.
    public let problems: [String]?
    /// Things removal deletes that are not obviously build output. Selectable, not preselected.
    public let warnings: [String]

    public init(repoPath: String, branch: String? = nil, problems: [String]? = nil, warnings: [String] = []) {
        self.repoPath = repoPath
        self.branch = branch
        self.problems = problems
        self.warnings = warnings
    }
}

public struct ScanItem: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let ruleID: String
    public let path: String
    public var usage: Usage?
    public var worktree: WorktreeInfo?

    public init(ruleID: String, path: String, usage: Usage? = nil, worktree: WorktreeInfo? = nil) {
        self.ruleID = ruleID
        self.path = path
        self.usage = usage
        self.worktree = worktree
    }

    public var bytes: Int64 { usage?.bytes ?? 0 }

    /// Why the app will not clean this item, if anything stops it.
    public var blocker: String? {
        var reasons: [String] = []
        if let worktree {
            reasons += worktree.problems ?? ["Not checked yet"]
        }
        if let files = usage?.protectedFiles, !files.isEmpty {
            reasons.append("Holds \(files.prefix(3).joined(separator: ", "))")
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }

    public var warning: String? {
        guard let warnings = worktree?.warnings, !warnings.isEmpty else { return nil }
        return warnings.joined(separator: "; ")
    }

    public static func == (lhs: ScanItem, rhs: ScanItem) -> Bool {
        lhs.path == rhs.path && lhs.usage == rhs.usage && lhs.worktree == rhs.worktree
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(path) }
}

extension Usage: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(bytes) }
}

public enum PathOverlap {
    /// Drops paths that sit inside another path in the list, so a node_modules inside a
    /// worktree that is also selected is not counted or deleted twice.
    public static func outermost(_ paths: [String]) -> [String] {
        // Sort with a trailing slash so "/a/b/" sorts directly before its children,
        // not after a sibling such as "/a/b-c/".
        let keys = paths.map { normalized($0) + "/" }.sorted()
        var result: [String] = []
        for key in keys {
            if let last = result.last, key.hasPrefix(last) { continue }
            result.append(key)
        }
        return result.map { String($0.dropLast()) }
    }

    static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
