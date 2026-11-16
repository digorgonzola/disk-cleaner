import Foundation

public enum RuleCategory: String, CaseIterable, Sendable, Identifiable {
    case worktrees = "Agent worktrees"
    case projectArtifacts = "Project build artifacts"
    case packageManagers = "Package managers"
    case infrastructure = "Infrastructure & DevOps"
    case containers = "Containers"
    case testing = "Test & browser binaries"
    case editors = "IDEs & editors"
    case browsers = "Web browsers"
    case system = "System"
    case reviewOnly = "Review manually"

    public var id: String { rawValue }

    public var symbol: String { RuleCategory.symbols[self] ?? "folder" }

    private static let symbols: [RuleCategory: String] = [
        .worktrees: "arrow.triangle.branch",
        .projectArtifacts: "hammer",
        .packageManagers: "shippingbox",
        .infrastructure: "server.rack",
        .containers: "cube.box",
        .testing: "testtube.2",
        .editors: "chevron.left.forwardslash.chevron.right",
        .browsers: "globe",
        .system: "gearshape",
        .reviewOnly: "eye",
    ]
}

/// How much work it takes to get the data back after a clean.
public enum Risk: String, Sendable, Comparable {
    /// Pure cache. Tools rebuild it on demand with no user action.
    case safe
    /// Needs a reinstall, rebuild or re-download (e.g. `pnpm install`), or holds data the user may want.
    case caution

    public static func < (lhs: Risk, rhs: Risk) -> Bool { lhs == .safe && rhs == .caution }
}

public enum RuleTarget: Sendable {
    /// Fixed locations, relative to the home folder.
    case homePaths([String])
    /// Folders with this name found under the project roots. When `markers` is not empty,
    /// the parent folder must hold at least one of them. When `contains` is not empty, the
    /// folder itself must hold all of them.
    case projectFolder(name: String, markers: [String], contains: [String] = [])
    /// Git worktrees that Claude Code creates in `<repo>/.claude/worktrees/`.
    case claudeWorktrees
}

public struct CleanupRule: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let category: RuleCategory
    public let detail: String
    public let risk: Risk
    public let target: RuleTarget
    /// Preferred clean command, run through the login shell. Falls back to deleting the
    /// paths when the tool is not installed. `nil` means delete the paths directly.
    public let cleanCommand: String?
    /// When `false`, a missing clean-command tool is an error instead of a reason to delete.
    /// Use it where the path is live data that only the tool may touch (a VM disk image).
    public let canDeleteWithoutCommand: Bool
    /// Asks the tool what the clean command can free. The app shows that instead of the
    /// folder size, which for a VM disk image includes data in use.
    public let reclaimable: ReclaimableQuery?
    /// Report the size but never clean it from the app.
    public let isReportOnly: Bool
    /// File names that block the clean when found inside an item (e.g. local Terraform state).
    public let protectedFileNames: Set<String>

    public init(
        id: String,
        name: String,
        category: RuleCategory,
        detail: String,
        risk: Risk = .safe,
        target: RuleTarget,
        cleanCommand: String? = nil,
        canDeleteWithoutCommand: Bool = true,
        reclaimable: ReclaimableQuery? = nil,
        isReportOnly: Bool = false,
        protectedFileNames: Set<String> = []
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.detail = detail
        self.risk = risk
        self.target = target
        self.cleanCommand = cleanCommand
        self.canDeleteWithoutCommand = canDeleteWithoutCommand
        self.reclaimable = reclaimable
        self.isReportOnly = isReportOnly
        self.protectedFileNames = protectedFileNames
    }
}
