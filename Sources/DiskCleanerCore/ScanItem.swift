import Foundation

public struct WorktreeInfo: Sendable, Hashable {
    public let repoPath: String
    public let branch: String?
    /// Reasons removal would lose work or git would refuse. `nil` means not checked yet.
    public let problems: [String]?
    /// Things removal deletes that are not obviously build output. Selectable, not preselected.
    public let warnings: [String]
    /// Checked-out submodules make git refuse a plain `worktree remove`; the cleaner then
    /// uses `--force`, but only after a fresh inspection finds no problems.
    public let hasSubmodules: Bool
    /// Git-ignored build output inside the worktree (node_modules, .turbo, …), relative to it.
    /// The cleaner moves these to the purge area before `git worktree remove`.
    public let rebuildablePaths: [String]

    public init(
        repoPath: String, branch: String? = nil, problems: [String]? = nil,
        warnings: [String] = [], hasSubmodules: Bool = false, rebuildablePaths: [String] = []
    ) {
        self.repoPath = repoPath
        self.branch = branch
        self.problems = problems
        self.warnings = warnings
        self.hasSubmodules = hasSubmodules
        self.rebuildablePaths = rebuildablePaths
    }
}

public struct ScanItem: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let ruleID: String
    public let path: String
    public var usage: Usage?
    public var worktree: WorktreeInfo?
    /// Set for rules with a `reclaimableCommand`; replaces the folder size in `bytes`.
    public var reclaimable: Reclaimable?

    public init(ruleID: String, path: String, usage: Usage? = nil, worktree: WorktreeInfo? = nil) {
        self.ruleID = ruleID
        self.path = path
        self.usage = usage
        self.worktree = worktree
    }

    /// What cleaning frees: the tool's estimate when the rule has one, else the folder size.
    public var bytes: Int64 {
        switch reclaimable {
        case .bytes(let bytes): bytes
        case .unknown: 0
        case nil: usage?.bytes ?? 0
        }
    }

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
            && lhs.reclaimable == rhs.reclaimable
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
