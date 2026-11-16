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
        await forEachConcurrently(items, width: concurrency) { item in
            let usage = DiskUsage.usage(of: item.path, protectedNames: protected[item.ruleID] ?? [])
            continuation.yield(.measured(path: item.path, usage: usage))
        }
    }

    private func inspectWorktrees(_ items: [ScanItem], _ continuation: AsyncStream<ScanEvent>.Continuation) async {
        await forEachConcurrently(items, width: concurrency) { item in
            guard let repo = item.worktree?.repoPath else { return }
            let info = await WorktreeInspector.inspect(path: item.path, repoPath: repo, rules: rules)
            continuation.yield(.worktreeInspected(path: item.path, info: info))
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

/// One entry of `git status --porcelain -z`. `-z` output is never quoted, so paths with
/// spaces, quotes or non-ASCII characters come through as they are.
struct PorcelainEntry: Equatable {
    let code: String
    let path: String

    var isIgnored: Bool { code == "!!" }

    static func parse(_ output: String) -> [PorcelainEntry] {
        var entries: [PorcelainEntry] = []
        // Split on bytes: a path that starts with a combining mark would merge with the
        // separator space as one Character and be cut short.
        var fields = output.utf8.split(separator: 0, omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            guard field.count > 3 else { continue }
            let code = String(decoding: field.prefix(2), as: UTF8.self)
            var path = String(decoding: field.dropFirst(3), as: UTF8.self)
            if path.hasSuffix("/") { path.removeLast() }
            entries.append(PorcelainEntry(code: code, path: path))
            // A rename or copy is followed by a second field: the original path.
            if code.contains("R") || code.contains("C") { _ = fields.next() }
        }
        return entries
    }
}

enum WorktreeInspector {
    /// Ignored folders that are only build output, so losing them with the worktree is fine.
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
        let protectedFolders = Dictionary(rules.compactMap { rule -> (String, Set<String>)? in
            guard case .projectFolder(let name, _, _) = rule.target, !rule.protectedFileNames.isEmpty else { return nil }
            return (name, rule.protectedFileNames)
        }, uniquingKeysWith: { $0.union($1) })
        let allProtectedNames = protectedFolders.values.reduce(into: Set<String>()) { $0.formUnion($1) }

        var problems: [String] = []
        var warnings: [String] = []

        // Every git failure is a problem: a missing answer must never read as "all clear".
        guard let branchOutput = try? await git(path, "rev-parse", "--abbrev-ref", "HEAD"), branchOutput.succeeded else {
            return WorktreeInfo(repoPath: repoPath, problems: ["git rev-parse failed"])
        }
        let branch = branchOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // --ignored=matching with -uall lists an ignored folder nested in untracked folders
        // (live/unit/.terragrunt-cache) on its own line, instead of folding it into "live/".
        guard let status = try? await git(path, "status", "--porcelain", "-z", "--ignored=matching", "--untracked-files=all"),
              status.succeeded
        else {
            return WorktreeInfo(repoPath: repoPath, branch: branch, problems: ["git status failed"])
        }

        if let lock = await lockReason(worktree: path, repoPath: repoPath) {
            problems.append(lock)
        }

        let submodules: [Submodule]
        do {
            submodules = try await initializedSubmodules(path)
        } catch {
            return WorktreeInfo(repoPath: repoPath, branch: branch, problems: ["git submodule status failed"])
        }
        let submodulePaths = Set(submodules.map(\.path))

        let summary = summarize(PorcelainEntry.parse(status.stdout), prefix: "", skipping: submodulePaths, folderNames: folderNames)
        if !summary.changed.isEmpty {
            problems.append("\(summary.changed.count) uncommitted file\(summary.changed.count == 1 ? "" : "s")")
        }
        var ignored = summary.ignored
        var rebuildable = summary.rebuildable
        // A changed gitlink only means the submodule moved to another commit. The commit itself
        // is checked below; what is lost is the uncommitted pointer, so warn instead of block.
        if !summary.changedSubmodules.isEmpty {
            warnings.append("Uncommitted submodule pointer: \(summary.changedSubmodules.prefix(2).joined(separator: ", "))")
        }

        for submodule in submodules {
            let check = await inspectSubmodule(submodule, worktreePath: path, allSubmodules: submodulePaths, folderNames: folderNames)
            problems += check.problems
            ignored += check.ignored
            rebuildable += check.rebuildable
        }

        // Ignored folders go with the worktree, but local Terraform state is real data. Look
        // inside protected folders (.terragrunt-cache), generic build folders and any other
        // ignored entry, where git can fold a nested .terragrunt-cache into one line. Tool
        // folders such as node_modules are skipped: they are large and hold no user state.
        for relative in rebuildable + ignored {
            let name = (relative as NSString).lastPathComponent
            let isToolFolder = folderNames.contains(name) && protectedFolders[name] == nil
            guard !isToolFolder else { continue }
            let folder = path + "/" + relative
            let found = await runBlocking { DiskUsage.usage(of: folder, protectedNames: allProtectedNames).protectedFiles }
            if let first = found.first {
                // A protected file listed on its own reports an empty name relative to itself.
                problems.append("Holds local state: " + (first.isEmpty ? relative : "\(relative)/\(first)"))
            }
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
            hasSubmodules: !submodules.isEmpty, rebuildablePaths: rebuildable
        )
    }

    /// The lock reason when `git worktree lock` was used on this worktree; git refuses to
    /// remove a locked worktree. A failed listing also counts as locked.
    private static func lockReason(worktree: String, repoPath: String) async -> String? {
        guard let output = try? await git(repoPath, "worktree", "list", "--porcelain", "-z"), output.succeeded else {
            return "git worktree list failed"
        }
        // git prints resolved paths (/private/var/… for /var/…).
        let target = realPath(worktree)
        // Records are separated by an empty field; each field is "key value".
        var current: String?
        for field in output.stdout.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.isEmpty { current = nil; continue }
            if field.hasPrefix("worktree ") { current = realPath(String(field.dropFirst(9))) }
            if current == target, field == "locked" || field.hasPrefix("locked ") {
                let reason = field.dropFirst(6).trimmingCharacters(in: .whitespaces)
                return reason.isEmpty ? "Locked (git worktree lock)" : "Locked: \(reason)"
            }
        }
        return nil
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
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
        /// Ignored paths that are build output, relative to the worktree.
        var rebuildable: [String] = []
    }

    /// Sorts porcelain entries. Paths become relative to the worktree by adding `prefix`, so
    /// nested submodule entries can be recognised.
    private static func summarize(_ entries: [PorcelainEntry], prefix: String, skipping submodules: Set<String>, folderNames: Set<String>) -> StatusSummary {
        var summary = StatusSummary()
        for entry in entries {
            let path = prefix + entry.path
            if entry.isIgnored {
                if isRebuildable(path, folderNames: folderNames) {
                    summary.rebuildable.append(path)
                } else {
                    summary.ignored.append(path)
                }
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
    ) async -> (problems: [String], ignored: [String], rebuildable: [String]) {
        let name = submodule.path
        let fullPath = worktreePath + "/" + name
        if submodule.hasConflict { return (["Submodule \(name) has merge conflicts"], [], []) }

        guard let status = try? await git(fullPath, "status", "--porcelain", "-z", "--ignored=matching", "--untracked-files=all"),
              status.succeeded
        else {
            return (["Submodule \(name): git status failed"], [], [])
        }
        let summary = summarize(PorcelainEntry.parse(status.stdout), prefix: name + "/", skipping: allSubmodules, folderNames: folderNames)
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
        return (problems, summary.ignored, summary.rebuildable)
    }

    /// True for ignored paths that are themselves build output: a rule's folder (node_modules)
    /// or a generic build folder as the entry's own name, a known log or cache file, or a
    /// per-developer settings file. A file inside a folder named "build" does not count.
    static func isRebuildable(_ path: String, folderNames: Set<String>) -> Bool {
        if disposablePaths.contains(path) { return true }
        let name = (path as NSString).lastPathComponent
        if folderNames.contains(name) || rebuildableNames.contains(name) { return true }
        return rebuildableSuffixes.contains { path.hasSuffix($0) }
    }

    private static func git(_ path: String, _ arguments: String...) async throws -> ProcessOutput {
        try await ProcessRunner.run("/usr/bin/git", ["-C", path] + arguments)
    }
}
