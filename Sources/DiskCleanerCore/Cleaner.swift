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

    public init(homePath: String = NSHomeDirectory(), rules: [CleanupRule] = RuleCatalog.all) {
        self.homePath = homePath
        self.rules = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
    }

    /// Cleans the items one rule at a time and reports each result through `onOutcome`.
    /// Nested selections are reduced to the outermost path first.
    public func clean(_ items: [ScanItem], onOutcome: @Sendable (CleanOutcome) async -> Void) async {
        let keep = Set(PathOverlap.outermost(items.map(\.path)))
        let selected = items.filter { keep.contains($0.path) }
        let byRule = Dictionary(grouping: selected, by: \.ruleID)

        for (ruleID, ruleItems) in byRule.sorted(by: { $0.key < $1.key }) {
            guard let rule = rules[ruleID] else { continue }
            if Task.isCancelled { return }
            if case .claudeWorktrees = rule.target {
                for item in ruleItems {
                    if Task.isCancelled { return }
                    await onOutcome(await removeWorktree(item))
                }
            } else if let command = rule.cleanCommand {
                await onOutcome(await runCommand(command, rule: rule, items: ruleItems))
            } else {
                for item in ruleItems {
                    if Task.isCancelled { return }
                    await onOutcome(delete(item, rule: rule))
                }
            }
        }
    }

    // MARK: Strategies

    func removeWorktree(_ item: ScanItem) async -> CleanOutcome {
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

        // Without submodules, no --force: git itself then refuses a worktree with changes.
        // With submodules git always refuses, so --force is used only after the checks above.
        let arguments = ["-C", repo, "worktree", "remove"] + (fresh.hasSubmodules ? ["--force"] : []) + [item.path]
        let output = try? await ProcessRunner.run("/usr/bin/git", arguments, timeout: .seconds(600))
        guard let output, output.succeeded else {
            let message = output?.stderr ?? "git could not start"
            return CleanOutcome(label: label, error: message.trimmingCharacters(in: .whitespacesAndNewlines), log: "")
        }
        return CleanOutcome(label: label, error: nil, log: "git " + arguments.joined(separator: " "))
    }

    private func runCommand(_ command: String, rule: CleanupRule, items: [ScanItem]) async -> CleanOutcome {
        let tool = String(command.split(separator: " ").first ?? "")
        guard await Shell.shared.isInstalled(tool) else {
            guard rule.canDeleteWithoutCommand else {
                return CleanOutcome(label: rule.name, error: CleanError.toolMissing(tool: tool).errorDescription, log: "")
            }
            let outcomes = items.map { delete($0, rule: rule) }
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

    func delete(_ item: ScanItem, rule: CleanupRule) -> CleanOutcome {
        let label = "\(rule.name): \(displayPath(item.path))"
        if let blocker = item.blocker {
            return CleanOutcome(label: label, error: CleanError.blocked(path: item.path, reason: blocker).errorDescription, log: "")
        }
        do {
            try deletePath(item.path, rule: rule)
            return CleanOutcome(label: label, error: nil, log: "deleted \(item.path)")
        } catch {
            return CleanOutcome(label: label, error: error.localizedDescription, log: "")
        }
    }

    /// - Throws: `CleanError` when the rule is report-only, the path fails the safety
    ///   check, or the file system refuses the delete.
    func deletePath(_ path: String, rule: CleanupRule) throws {
        guard !rule.isReportOnly else { throw CleanError.reportOnly(path: path) }
        guard SafePath.isDeletable(path, homePath: homePath, rule: rule) else { throw CleanError.unsafePath(path: path) }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            // Go's module cache and some tool caches are read-only; make them writable and retry.
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["-R", "u+w", path]
            try? chmod.run()
            chmod.waitUntilExit()
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                throw CleanError.deleteFailed(path: path, reason: error.localizedDescription)
            }
        }
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

    /// A worktree may only be removed when it is a direct child of `<repo>/.claude/worktrees`
    /// inside the home folder. Worktrees are never deleted with `removeItem`, only through git.
    public static func isClaudeWorktree(_ path: String, repoPath: String, homePath: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        return (path as NSString).standardizingPath == path
            && path.hasPrefix(homePath + "/")
            && parent == repoPath + "/.claude/worktrees"
    }
}
