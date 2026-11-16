import Foundation

public enum ScanEvent: Sendable {
    case discovered([ScanItem])
    case measured(path: String, usage: Usage)
    case worktreeInspected(path: String, info: WorktreeInfo)
    case finished
}

public struct Scanner: Sendable {
    public let homePath: String
    public let projectRoots: [String]
    public let rules: [CleanupRule]
    public let concurrency: Int

    public init(
        homePath: String = NSHomeDirectory(),
        projectRoots: [String],
        rules: [CleanupRule] = RuleCatalog.all,
        concurrency: Int = 8
    ) {
        self.homePath = homePath
        self.projectRoots = projectRoots
        self.rules = rules
        self.concurrency = concurrency
    }

    public static let defaultProjectRootNames = [
        "repos", "PycharmProjects", "GolandProjects", "IdeaProjects", "WebstormProjects",
        "AndroidStudioProjects", "Projects", "Developer", "code", "src", "dev", "work", "git",
    ]

    public static func defaultProjectRoots(homePath: String = NSHomeDirectory()) -> [String] {
        defaultProjectRootNames
            .map { (homePath as NSString).appendingPathComponent($0) }
            .filter { isDirectory($0) }
    }

    public func scan() -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let fixed = homePathItems()
                continuation.yield(.discovered(fixed))
                let found = await projectItems()
                continuation.yield(.discovered(found))

                await inspectWorktrees(found.filter { $0.ruleID == "claude-worktrees" }, continuation)
                // Measure fixed caches first: few, often large, and quick to show.
                await measure(fixed + found, continuation)
                continuation.yield(.finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Discovery

    func homePathItems() -> [ScanItem] {
        rules.flatMap { rule -> [ScanItem] in
            guard case .homePaths(let relative) = rule.target else { return [] }
            return relative
                .map { (homePath as NSString).appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map { ScanItem(ruleID: rule.id, path: $0) }
        }
    }

    func projectItems() async -> [ScanItem] {
        let folderRules = Dictionary(grouping: rules.compactMap { rule -> (String, CleanupRule)? in
            guard case .projectFolder(let name, _, _) = rule.target else { return nil }
            return (name, rule)
        }, by: \.0).mapValues { $0.map(\.1) }
        let worktreeRule = rules.first { if case .claudeWorktrees = $0.target { true } else { false } }

        // SafePath only deletes inside the home folder, so roots elsewhere would only
        // produce items that fail to clean.
        let roots = PathOverlap.outermost(projectRoots.filter { $0.hasPrefix(homePath + "/") })
        return await withTaskGroup(of: [ScanItem].self) { group in
            for root in roots {
                group.addTask {
                    ProjectWalker(folderRules: folderRules, worktreeRuleID: worktreeRule?.id).walk(root)
                }
            }
            var all: [ScanItem] = []
            for await items in group { all += items }
            return all
        }
    }

    // MARK: Measuring

    private func measure(_ items: [ScanItem], _ continuation: AsyncStream<ScanEvent>.Continuation) async {
        let protected = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0.protectedFileNames) })
        await forEachConcurrently(items) { item in
            let usage = DiskUsage.usage(of: item.path, protectedNames: protected[item.ruleID] ?? [])
            continuation.yield(.measured(path: item.path, usage: usage))
        }
    }

    private func inspectWorktrees(_ items: [ScanItem], _ continuation: AsyncStream<ScanEvent>.Continuation) async {
        await forEachConcurrently(items) { item in
            guard let repo = item.worktree?.repoPath else { return }
            let info = await WorktreeInspector.inspect(path: item.path, repoPath: repo, rules: rules)
            continuation.yield(.worktreeInspected(path: item.path, info: info))
        }
    }

    private func forEachConcurrently(_ items: [ScanItem], _ body: @escaping @Sendable (ScanItem) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            for _ in 0..<concurrency {
                guard let item = iterator.next() else { break }
                group.addTask { await body(item) }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, let item = iterator.next() else { continue }
                group.addTask { await body(item) }
            }
        }
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

/// Walks a project tree once and collects every folder a rule matches. A matched folder is
/// not entered, so a `.terraform` inside a `.terragrunt-cache` is reported once, as part of
/// its parent.
struct ProjectWalker {
    let folderRules: [String: [CleanupRule]]
    let worktreeRuleID: String?

    func walk(_ root: String) -> [ScanItem] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        // The enumerator reports resolved paths (/var → /private/var). Map them back onto the
        // root as given so item paths stay under the home folder that SafePath checks.
        // realpath, not URL.resolvingSymlinksInPath, which strips /private again.
        let resolvedRoot = realpath(root, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? root
        func reportedPath(_ url: URL) -> String {
            let path = url.path
            guard path.hasPrefix(resolvedRoot + "/") else { return path }
            return root + path.dropFirst(resolvedRoot.count)
        }

        var items: [ScanItem] = []
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true
            else { continue }

            let name = url.lastPathComponent
            if name == ".git" {
                enumerator.skipDescendants()
                continue
            }
            if let worktreeRuleID, name == "worktrees", url.deletingLastPathComponent().lastPathComponent == ".claude" {
                items += worktrees(in: url, ruleID: worktreeRuleID).map {
                    ScanItem(ruleID: $0.ruleID, path: reportedPath(URL(fileURLWithPath: $0.path)), worktree: $0.worktree.map {
                        WorktreeInfo(repoPath: reportedPath(URL(fileURLWithPath: $0.repoPath)))
                    })
                }
                continue
            }
            if let rule = folderRules[name]?.first(where: { matches($0, folder: url) }) {
                items.append(ScanItem(ruleID: rule.id, path: reportedPath(url)))
                enumerator.skipDescendants()
            }
        }
        return items
    }

    private func matches(_ rule: CleanupRule, folder: URL) -> Bool {
        guard case .projectFolder(_, let markers, let contains) = rule.target else { return true }
        let fileManager = FileManager.default
        let parent = folder.deletingLastPathComponent()
        let hasMarker = markers.isEmpty || markers.contains { fileManager.fileExists(atPath: parent.appendingPathComponent($0).path) }
        let hasContents = contains.allSatisfy { fileManager.fileExists(atPath: folder.appendingPathComponent($0).path) }
        return hasMarker && hasContents
    }

    private func worktrees(in folder: URL, ruleID: String) -> [ScanItem] {
        let repo = folder.deletingLastPathComponent().deletingLastPathComponent().path
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return children
            // A worktree has a `.git` file that points back to the main repository.
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".git").path) }
            .map {
                ScanItem(
                    ruleID: ruleID, path: $0.path,
                    worktree: WorktreeInfo(repoPath: repo)
                )
            }
    }
}

enum WorktreeInspector {
    /// Ignored paths that are only build output, so losing them with the worktree is fine.
    static let rebuildableNames: Set<String> = [
        "dist", "build", "out", "coverage", ".cache", ".DS_Store", ".eslintcache",
    ]
    static let rebuildableSuffixes = [".tsbuildinfo", ".log"]
    static let disposablePaths: Set<String> = [".claude/settings.local.json"]

    static func inspect(path: String, repoPath: String, rules: [CleanupRule]) async -> WorktreeInfo {
        let folderNames = Set(rules.compactMap { rule -> String? in
            guard case .projectFolder(let name, _, _) = rule.target else { return nil }
            return name
        })
        let branchOutput = try? await git(path, "rev-parse", "--abbrev-ref", "HEAD")
        let branch = branchOutput?.succeeded == true
            ? branchOutput?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil

        guard let status = try? await git(path, "status", "--porcelain", "--ignored"), status.succeeded else {
            // An unreadable worktree counts as dirty so the app never removes it blind.
            return WorktreeInfo(repoPath: repoPath, branch: branch, problems: ["git status failed"])
        }

        var problems: [String] = []
        var warnings: [String] = []
        let submodules: [Submodule]
        do {
            submodules = try await initializedSubmodules(path)
        } catch {
            return WorktreeInfo(repoPath: repoPath, branch: branch, problems: ["git submodule status failed"])
        }
        let submodulePaths = Set(submodules.map(\.path))

        let summary = summarize(status.stdout, prefix: "", skipping: submodulePaths, folderNames: folderNames)
        if !summary.changed.isEmpty {
            problems.append("\(summary.changed.count) uncommitted file\(summary.changed.count == 1 ? "" : "s")")
        }
        var ignored = summary.ignored
        // A changed gitlink only means the submodule moved to another commit. The commit itself
        // is checked below; what is lost is the uncommitted pointer, so warn instead of block.
        let movedPointers = summary.changedSubmodules
        if !movedPointers.isEmpty {
            warnings.append("Uncommitted submodule pointer: \(movedPointers.prefix(2).joined(separator: ", "))")
        }

        for submodule in submodules {
            let check = await inspectSubmodule(submodule, worktreePath: path, allSubmodules: submodulePaths, folderNames: folderNames)
            problems += check.problems
            ignored += check.ignored
        }

        if !ignored.isEmpty {
            warnings.append("Also deletes ignored \(ignored.prefix(3).joined(separator: ", "))\(ignored.count > 3 ? "…" : "")")
        }

        if branch == "HEAD" {
            let containing = try? await git(path, "for-each-ref", "--contains", "HEAD", "--count=1", "refs/heads", "refs/remotes")
            if containing?.succeeded != true || containing?.stdout.isEmpty == true {
                problems.append("Detached HEAD with commits on no branch")
            }
        }
        return WorktreeInfo(
            repoPath: repoPath, branch: branch, problems: problems, warnings: warnings,
            hasSubmodules: !submodules.isEmpty
        )
    }

    struct Submodule: Equatable {
        let path: String
        let hasConflict: Bool
    }

    /// Checked-out submodules, nested ones included, as paths relative to the worktree.
    /// - Throws: `CleanError.commandFailed` when git fails, so a failed listing never reads as "none".
    static func initializedSubmodules(_ path: String) async throws -> [Submodule] {
        guard FileManager.default.fileExists(atPath: path + "/.gitmodules") else { return [] }
        let output = try await git(path, "submodule", "status", "--recursive")
        guard output.succeeded else { throw CleanError.commandFailed(command: "git submodule status", status: output.status, output: output.stderr) }
        // Each line is "<state><sha> <path> (<describe>)"; state "-" means not checked out.
        return output.stdout.split(separator: "\n").compactMap { line in
            guard let state = line.first, state != "-" else { return nil }
            let fields = line.dropFirst().split(separator: " ")
            guard fields.count >= 2 else { return nil }
            return Submodule(path: String(fields[1]), hasConflict: state == "U")
        }
    }

    private struct StatusSummary {
        var changed: [String] = []
        var changedSubmodules: [String] = []
        var ignored: [String] = []
    }

    /// Splits `git status --porcelain --ignored` output. Paths are reported relative to the
    /// worktree by adding `prefix`, so nested submodule entries can be recognised.
    private static func summarize(_ output: String, prefix: String, skipping submodules: Set<String>, folderNames: Set<String>) -> StatusSummary {
        var summary = StatusSummary()
        for line in output.split(separator: "\n").map(String.init) {
            let path = prefix + String(line.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "/\""))
            if line.hasPrefix("!! ") {
                if !isRebuildable(path, folderNames: folderNames) { summary.ignored.append(path) }
            } else if submodules.contains(path) {
                summary.changedSubmodules.append(path)
            } else {
                summary.changed.append(path)
            }
        }
        return summary
    }

    /// A linked worktree keeps its submodules' git data under `.git/worktrees/<name>/modules`,
    /// which `git worktree remove --force` deletes. Anything not on a remote is lost with it.
    private static func inspectSubmodule(
        _ submodule: Submodule, worktreePath: String, allSubmodules: Set<String>, folderNames: Set<String>
    ) async -> (problems: [String], ignored: [String]) {
        let name = submodule.path
        let fullPath = worktreePath + "/" + name
        if submodule.hasConflict { return (["Submodule \(name) has merge conflicts"], []) }

        guard let status = try? await git(fullPath, "status", "--porcelain", "--ignored"), status.succeeded else {
            return (["Submodule \(name): git status failed"], [])
        }
        let summary = summarize(status.stdout, prefix: name + "/", skipping: allSubmodules, folderNames: folderNames)
        var problems: [String] = []
        if !summary.changed.isEmpty {
            problems.append("Submodule \(name): \(summary.changed.count) uncommitted file\(summary.changed.count == 1 ? "" : "s")")
        }

        // Commits reachable from HEAD or a local branch but from no remote-tracking ref.
        let unpushed = try? await git(fullPath, "rev-list", "--max-count=1", "HEAD", "--branches", "--not", "--remotes")
        if unpushed?.succeeded != true || unpushed?.stdout.isEmpty == false {
            problems.append("Submodule \(name) has commits on no remote")
        }
        let stashes = try? await git(fullPath, "stash", "list")
        if stashes?.succeeded != true || stashes?.stdout.isEmpty == false {
            problems.append("Submodule \(name) has stashes")
        }
        return (problems, summary.ignored)
    }

    static func isRebuildable(_ path: String, folderNames: Set<String>) -> Bool {
        if disposablePaths.contains(path) { return true }
        let components = path.split(separator: "/").map(String.init)
        if components.contains(where: { folderNames.contains($0) || rebuildableNames.contains($0) }) { return true }
        return rebuildableSuffixes.contains { path.hasSuffix($0) }
    }

    private static func git(_ path: String, _ arguments: String...) async throws -> ProcessOutput {
        try await ProcessRunner.run("/usr/bin/git", ["-C", path] + arguments)
    }
}
