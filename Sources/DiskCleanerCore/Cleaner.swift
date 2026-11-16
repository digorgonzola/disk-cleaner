import Foundation

public enum CleanError: LocalizedError, Equatable {
    case reportOnly(path: String)
    case blocked(path: String, reason: String)
    case unsafePath(path: String)
    case toolMissing(tool: String)
    case commandFailed(command: String, status: Int32, output: String)
    case deleteFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .reportOnly(let path): "Report-only item, not cleaned: \(path)"
        case .blocked(let path, let reason): "Skipped \(path): \(reason)"
        case .unsafePath(let path): "Refused to delete a path outside the allowed area: \(path)"
        case .toolMissing(let tool): "`\(tool)` is not installed, and this item is only cleaned through it"
        case .commandFailed(let command, let status, let output): "`\(command)` exited with \(status): \(output)"
        case .deleteFailed(let path, let reason): "Could not delete \(path): \(reason)"
        }
    }
}

public struct CleanOutcome: Sendable, Identifiable {
    public var id: String { label }
    public let label: String
    public let error: String?
    public let log: String

    public var succeeded: Bool { error == nil }
}

public struct Cleaner: Sendable {
    public let homePath: String
    public let rules: [String: CleanupRule]
    let purger: Purger

    /// Clean commands that may run at the same time (brew, pnpm, podman, …).
    static let commandWidth = 2
    /// Repositories whose worktrees are removed at the same time. Worktrees of one repo go
    /// one after another, so git never contends for that repo's locks.
    static let repoWidth = 4

    public init(homePath: String = NSHomeDirectory(), rules: [CleanupRule] = RuleCatalog.all, purgeWidth: Int = Purger.defaultWidth) {
        self.homePath = homePath
        self.rules = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        purger = Purger(homePath: homePath, width: purgeWidth)
    }

    /// How many outcomes a clean of `items` reports when nothing fails, for progress display.
    public func expectedOutcomeCount(_ items: [ScanItem]) -> Int {
        let plan = Plan(items: items, rules: rules)
        return plan.commands.count + plan.worktreesByRepo.values.reduce(0) { $0 + $1.count } + plan.deletes.count
    }

    /// Cleans the items and reports each result through `onOutcome`, which may be called
    /// from several tasks at once. Clean commands, worktree removals and deletes run at the
    /// same time. Deleted folders are first moved to the purge area, so they leave their
    /// place at once; a pool then deletes them, and this returns when the pool is done.
    /// Nested selections are reduced to the outermost path first.
    ///
    /// Stop (task cancellation) starts no new work. Staged folders not yet deleted are moved
    /// back to where they came from, as is a folder whose delete fails.
    public func clean(_ items: [ScanItem], onOutcome: @escaping @Sendable (CleanOutcome) async -> Void) async {
        let plan = Plan(items: items, rules: rules)
        let ledger = StagingLedger()
        let (staged, sink) = AsyncStream.makeStream(of: String.self)
        let queue = PurgeQueue(sink: sink, ledger: ledger)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await purgeAll(staged, ledger: ledger, onOutcome: onOutcome) }
            group.addTask {
                await withTaskGroup(of: Void.self) { lanes in
                    lanes.addTask {
                        await forEachConcurrently(plan.commands, width: Self.commandWidth) { job in
                            await onOutcome(await runCommand(job.command, rule: job.rule, items: job.items, queue: queue))
                        }
                    }
                    lanes.addTask {
                        await forEachConcurrently(Array(plan.worktreesByRepo.values), width: Self.repoWidth) { worktrees in
                            for item in worktrees where !Task.isCancelled {
                                await onOutcome(await removeWorktree(item, queue: queue))
                            }
                        }
                    }
                    lanes.addTask {
                        // Staging is one rename per folder, so a plain loop empties the list fast.
                        for (item, rule) in plan.deletes where !Task.isCancelled {
                            await onOutcome(await delete(item, rule: rule, queue: queue))
                        }
                    }
                }
                sink.finish()
            }
        }

        // After Stop, folders still waiting in the purge area go back to where they were. Ones
        // whose place is gone (a removed worktree's node_modules) stay for the launch purge.
        for (stagedPath, entry) in ledger.drain() {
            if entry.canRestore {
                await onOutcome(restore(stagedPath, to: entry.original, reason: "Stopped before it was deleted"))
            } else {
                await onOutcome(CleanOutcome(
                    label: "Finish deleting \(displayPath(entry.original))",
                    error: nil,
                    log: "Stopped; its worktree is already removed, so the next launch deletes it."
                ))
            }
        }
        purger.removeAreaIfEmpty()
    }

    /// Selected items split by how they are cleaned.
    struct Plan {
        struct CommandJob: Sendable {
            let command: String
            let rule: CleanupRule
            let items: [ScanItem]
        }

        var commands: [CommandJob] = []
        var worktreesByRepo: [String: [ScanItem]] = [:]
        var deletes: [(ScanItem, CleanupRule)] = []

        init(items: [ScanItem], rules: [String: CleanupRule]) {
            let keep = Set(PathOverlap.outermost(items.map(\.path)))
            let selected = items.filter { keep.contains($0.path) }
            for (ruleID, ruleItems) in Dictionary(grouping: selected, by: \.ruleID).sorted(by: { $0.key < $1.key }) {
                guard let rule = rules[ruleID] else { continue }
                if case .claudeWorktrees = rule.target {
                    for item in ruleItems { worktreesByRepo[item.worktree?.repoPath ?? "", default: []].append(item) }
                } else if let command = rule.cleanCommand {
                    commands.append(CommandJob(command: command, rule: rule, items: ruleItems))
                } else {
                    deletes += ruleItems.map { ($0, rule) }
                }
            }
        }
    }

    // MARK: Purging

    /// Staged folders and their original paths, until each is deleted or moved back.
    final class StagingLedger: @unchecked Sendable {
        struct Entry {
            let original: String
            /// False when the original place is gone (its worktree was removed): the folder
            /// can only be deleted, never moved back.
            let canRestore: Bool
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func record(_ staged: String, _ entry: Entry) { lock.withLock { entries[staged] = entry } }

        /// Removes and returns the entry of a staged folder.
        func take(_ staged: String) -> Entry? { lock.withLock { entries.removeValue(forKey: staged) } }

        func drain() -> [(String, Entry)] {
            lock.withLock {
                defer { entries.removeAll() }
                return entries.map { ($0.key, $0.value) }
            }
        }
    }

    /// Hands staged folders to the purge pool, and records where each came from first.
    struct PurgeQueue: Sendable {
        let sink: AsyncStream<String>.Continuation
        let ledger: StagingLedger

        func enqueue(_ staged: String, original: String, canRestore: Bool = true) {
            ledger.record(staged, .init(original: original, canRestore: canRestore))
            sink.yield(staged)
        }
    }

    /// Deletes everything that arrives on `staged`, through the purger's limited pool.
    private func purgeAll(_ staged: AsyncStream<String>, ledger: StagingLedger, onOutcome: @escaping @Sendable (CleanOutcome) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            for await path in staged {
                group.addTask {
                    do {
                        try await purger.purge(path)
                        _ = ledger.take(path)
                    } catch is CancellationError {
                        // Stopped: clean() moves it back from the ledger.
                    } catch {
                        // Never leave data hidden in the purge area: put it back where it was.
                        guard let entry = ledger.take(path) else { return }
                        let reason = "Could not delete: \(error.localizedDescription)"
                        if entry.canRestore {
                            await onOutcome(restore(path, to: entry.original, reason: reason))
                        } else {
                            await onOutcome(CleanOutcome(
                                label: "Finish deleting \(displayPath(entry.original))",
                                error: reason + ". It stays in \(displayPath(path)) and shows under Review manually.",
                                log: ""
                            ))
                        }
                    }
                }
            }
        }
    }

    /// Moves a staged folder back and reports it as not cleaned.
    private func restore(_ staged: String, to original: String, reason: String) -> CleanOutcome {
        let label = "Kept \(displayPath(original))"
        do {
            try purger.restore(staged, to: original)
            return CleanOutcome(label: label, error: reason + ". Moved back.", log: "")
        } catch {
            return CleanOutcome(
                label: label,
                error: reason + ". It could not be moved back and stays in \(displayPath(staged)): \(error.localizedDescription)",
                log: ""
            )
        }
    }

    // MARK: Strategies

    func removeWorktree(_ item: ScanItem, queue: PurgeQueue) async -> CleanOutcome {
        let label = "Worktree \(displayPath(item.path))"
        if let blocker = item.blocker {
            return CleanOutcome(label: label, error: CleanError.blocked(path: item.path, reason: blocker).errorDescription, log: "")
        }
        guard let repo = item.worktree?.repoPath, SafePath.isClaudeWorktree(item.path, repoPath: repo, homePath: homePath) else {
            return CleanOutcome(label: label, error: CleanError.unsafePath(path: item.path).errorDescription, log: "")
        }

        // Inspect again right before removal: the scan may be minutes or hours old.
        let fresh = await WorktreeInspector.inspect(path: item.path, repoPath: repo, rules: Array(rules.values))
        if let problems = fresh.problems, !problems.isEmpty {
            let reason = "changed since the scan: " + problems.joined(separator: "; ")
            return CleanOutcome(label: label, error: CleanError.blocked(path: item.path, reason: reason).errorDescription, log: "")
        }

        // git deletes a worktree one file at a time, and its ignored build output (git listed
        // it as ignored and rebuildable just now) is most of the files. Move that out first so
        // git only deletes the rest, but delete it only once git has removed the worktree:
        // if git refuses, it all goes back.
        var moved: [(staged: String, original: String, relative: String)] = []
        for relative in fresh.rebuildablePaths where !Task.isCancelled {
            let path = item.path + "/" + relative
            guard SafePath.isInside(path, folder: item.path), FileManager.default.fileExists(atPath: path) else { continue }
            // nil means another volume: leave it for git.
            if let staged = try? purger.stage(path, keepOrigin: true) { moved.append((staged, path, relative)) }
        }

        // Without submodules, no --force: git itself then refuses a worktree with changes.
        // With submodules git always refuses, so --force is used only after the checks above.
        let arguments = ["-C", repo, "worktree", "remove"] + (fresh.hasSubmodules ? ["--force"] : []) + [item.path]
        let output = Task.isCancelled ? nil : try? await ProcessRunner.run("/usr/bin/git", arguments, timeout: .seconds(600))
        guard let output, output.succeeded else {
            let restored = moved.map { entry -> String in
                if (try? purger.restore(entry.staged, to: entry.original)) != nil { return "\(entry.relative): moved back" }
                // git got far enough to delete the folder's parent, so finish the delete.
                purger.confirmDelete(entry.staged)
                queue.enqueue(entry.staged, original: entry.original, canRestore: false)
                return "\(entry.relative): parent gone, deleting"
            }
            let message = output?.stderr ?? (Task.isCancelled ? "Stopped" : "git could not start")
            return CleanOutcome(label: label, error: message.trimmingCharacters(in: .whitespacesAndNewlines), log: restored.joined(separator: "\n"))
        }
        for entry in moved {
            purger.confirmDelete(entry.staged)
            queue.enqueue(entry.staged, original: entry.original, canRestore: false)
        }
        let log = moved.map { "\($0.relative): moved to the purge area" } + ["git " + arguments.joined(separator: " ")]
        return CleanOutcome(label: label, error: nil, log: log.joined(separator: "\n"))
    }

    private func runCommand(_ command: String, rule: CleanupRule, items: [ScanItem], queue: PurgeQueue) async -> CleanOutcome {
        let tool = String(command.split(separator: " ").first ?? "")
        guard await Shell.shared.isInstalled(tool) else {
            // A stop during the check makes it fail; that is not a missing tool.
            if Task.isCancelled { return CleanOutcome(label: rule.name, error: "Stopped", log: "") }
            guard rule.canDeleteWithoutCommand else {
                return CleanOutcome(label: rule.name, error: CleanError.toolMissing(tool: tool).errorDescription, log: "")
            }
            var outcomes: [CleanOutcome] = []
            for item in items { outcomes.append(await delete(item, rule: rule, queue: queue)) }
            let errors = outcomes.compactMap(\.error)
            return CleanOutcome(
                label: rule.name,
                error: errors.isEmpty ? nil : errors.joined(separator: "\n"),
                log: "`\(tool)` not found; deleted the folders instead.\n" + outcomes.map(\.log).joined(separator: "\n")
            )
        }
        do {
            let output = try await Shell.shared.run(command)
            let log = "$ \(command)\n\(output.stdout)\(output.stderr)"
            guard output.succeeded else {
                if output.timedOut {
                    return CleanOutcome(label: rule.name, error: "`\(command)` timed out and was stopped", log: log)
                }
                let error = CleanError.commandFailed(command: command, status: output.status, output: lastLines(output.stderr))
                return CleanOutcome(label: rule.name, error: error.errorDescription, log: log)
            }
            return CleanOutcome(label: rule.name, error: nil, log: log)
        } catch {
            return CleanOutcome(label: rule.name, error: error.localizedDescription, log: "")
        }
    }

    /// Checks an item and moves it to the purge area. Staging is a rename, so this does not
    /// wait for the delete itself.
    func delete(_ item: ScanItem, rule: CleanupRule, queue: PurgeQueue) async -> CleanOutcome {
        let label = "\(rule.name): \(displayPath(item.path))"
        if let blocker = item.blocker {
            return CleanOutcome(label: label, error: CleanError.blocked(path: item.path, reason: blocker).errorDescription, log: "")
        }
        do {
            try checkDeletable(item.path, rule: rule)
            if let staged = try purger.stage(item.path) {
                queue.enqueue(staged, original: item.path)
                return CleanOutcome(label: label, error: nil, log: "moved \(item.path) to the purge area")
            }
            // Another volume: no rename is possible, so delete in place through the pool.
            try await purger.purge(item.path)
            return CleanOutcome(label: label, error: nil, log: "deleted \(item.path) in place")
        } catch {
            return CleanOutcome(label: label, error: error.localizedDescription, log: "")
        }
    }

    /// - Throws: `CleanError` when the rule is report-only or the path fails the safety check.
    func checkDeletable(_ path: String, rule: CleanupRule) throws {
        guard !rule.isReportOnly else { throw CleanError.reportOnly(path: path) }
        guard SafePath.isDeletable(path, homePath: homePath, rule: rule) else { throw CleanError.unsafePath(path: path) }
    }

    /// Deletes one catalog path synchronously, after the safety checks.
    /// - Throws: `CleanError` when the checks fail or the file system refuses the delete.
    func deletePath(_ path: String, rule: CleanupRule) throws {
        try checkDeletable(path, rule: rule)
        try Purger.removeTree(path)
    }

    private func displayPath(_ path: String) -> String {
        path.hasPrefix(homePath) ? "~" + path.dropFirst(homePath.count) : path
    }

    private func lastLines(_ text: String, count: Int = 5) -> String {
        text.split(separator: "\n").suffix(count).joined(separator: "\n")
    }
}

/// Last line of defence before a recursive delete. The scanner only reports matching paths,
/// but a bug there must never turn into deleting the home folder or a project.
public enum SafePath {
    public static func isDeletable(_ path: String, homePath: String, rule: CleanupRule) -> Bool {
        let standardized = (path as NSString).standardizingPath
        guard standardized == path, !path.contains("/../"), path.hasPrefix(homePath + "/") else { return false }

        switch rule.target {
        case .homePaths(let relative):
            let allowed = relative.map { (homePath as NSString).appendingPathComponent($0) }
            return allowed.contains(path)
        case .projectFolder(let name, _, _):
            return (path as NSString).lastPathComponent == name
        case .claudeWorktrees:
            return false
        }
    }

    /// True when `path` is strictly inside `folder`, after normalising both.
    public static func isInside(_ path: String, folder: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        return standardized == path && path.hasPrefix(folder + "/") && !path.contains("/../")
    }

    /// A worktree may only be removed when it is a direct child of `<repo>/.claude/worktrees`
    /// inside the home folder. Worktrees are never deleted with `removeItem`, only through git.
    public static func isClaudeWorktree(_ path: String, repoPath: String, homePath: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        return (path as NSString).standardizingPath == path
            && path.hasPrefix(homePath + "/")
            && parent == repoPath + "/.claude/worktrees"
    }
}
