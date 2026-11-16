import Foundation
import Testing
@testable import DiskCleanerCore

struct PathOverlapTests {
    @Test func dropsNestedPaths() {
        let result = PathOverlap.outermost([
            "/h/repo/.claude/worktrees/a/node_modules",
            "/h/repo/.claude/worktrees/a",
            "/h/repo/node_modules",
        ])
        #expect(result == ["/h/repo/.claude/worktrees/a", "/h/repo/node_modules"])
    }

    @Test func keepsSiblingsThatSharePrefix() {
        let result = PathOverlap.outermost(["/a/b", "/a/b-c", "/a/b/c"])
        #expect(Set(result) == ["/a/b", "/a/b-c"])
    }
}

struct SafePathTests {
    let home = "/Users/test"
    let cacheRule = CleanupRule(id: "c", name: "c", category: .system, detail: "", target: .homePaths(["Library/Caches/x"]))
    let folderRule = CleanupRule(id: "n", name: "n", category: .projectArtifacts, detail: "",
                                 target: .projectFolder(name: "node_modules", markers: []))

    @Test func allowsExactCatalogPath() {
        #expect(SafePath.isDeletable("/Users/test/Library/Caches/x", homePath: home, rule: cacheRule))
    }

    @Test func refusesHomeAndOtherPaths() {
        #expect(!SafePath.isDeletable("/Users/test", homePath: home, rule: cacheRule))
        #expect(!SafePath.isDeletable("/Users/test/Library/Caches", homePath: home, rule: cacheRule))
        #expect(!SafePath.isDeletable("/Users/test/Library/Caches/x/../..", homePath: home, rule: cacheRule))
        #expect(!SafePath.isDeletable("/opt/node_modules", homePath: home, rule: folderRule))
    }

    @Test func projectFolderMustHaveRuleName() {
        #expect(SafePath.isDeletable("/Users/test/repos/app/node_modules", homePath: home, rule: folderRule))
        #expect(!SafePath.isDeletable("/Users/test/repos/app", homePath: home, rule: folderRule))
    }
}

struct CatalogTests {
    @Test func ruleIDsAreUnique() {
        let ids = RuleCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func homePathsAreRelative() {
        for rule in RuleCatalog.all {
            guard case .homePaths(let paths) = rule.target else { continue }
            #expect(paths.allSatisfy { !$0.hasPrefix("/") && !$0.contains("..") }, "\(rule.id)")
        }
    }
}

struct ScannerTests {
    /// Builds a throwaway tree that looks like a home folder with one repo in it.
    func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dc-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repos/app")
        let files = [
            "repos/app/package.json": "{}",
            "repos/app/node_modules/left-pad/index.js": String(repeating: "x", count: 10_000),
            "repos/app/node_modules/nested/node_modules/a.js": "x",
            "repos/app/infra/.terragrunt-cache/abc/.terraform/providers/p": "x",
            "repos/other/node_modules/no-package-json.js": "x",
            "Library/Caches/terragrunt/providers/p": "x",
        ]
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        return root
    }

    @Test func findsProjectAndHomeItems() async throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.path

        let scanner = Scanner(homePath: home, projectRoots: [home + "/repos"])
        var found: [String: String] = [:]
        var sizes: [String: Int64] = [:]
        for await event in scanner.scan() {
            switch event {
            case .discovered(let items): items.forEach { found[$0.path] = $0.ruleID }
            case .measured(let path, let usage): sizes[path] = usage.bytes
            default: break
            }
        }

        #expect(found == [
            home + "/repos/app/node_modules": "node-modules",
            home + "/repos/app/infra/.terragrunt-cache": "terragrunt-cache",
            home + "/Library/Caches/terragrunt": "terragrunt-global",
        ])
        #expect((sizes[home + "/repos/app/node_modules"] ?? 0) >= 10_000)
    }

    @Test func deletesOnlyCatalogPaths() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cleaner = Cleaner(homePath: root.path)
        let rule = try #require(RuleCatalog.all.first { $0.id == "node-modules" })

        try cleaner.deletePath(root.path + "/repos/app/node_modules", rule: rule)
        #expect(!FileManager.default.fileExists(atPath: root.path + "/repos/app/node_modules"))
        #expect(throws: CleanError.self) { try cleaner.deletePath(root.path + "/repos/app", rule: rule) }
        #expect(FileManager.default.fileExists(atPath: root.path + "/repos/app/package.json"))
    }
}

struct SafeguardTests {
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ root: URL, _ path: String, _ contents: String = "x") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func git(_ dir: URL, _ args: String...) async throws -> ProcessOutput {
        let output = try await ProcessRunner.run("/usr/bin/git", ["-C", dir.path, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"] + args)
        #expect(output.succeeded, "git \(args): \(output.stderr)")
        return output
    }

    @Test func localStateInTerragruntCacheIsProtected() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a/b/terraform.tfstate")
        try write(root, "c/d/.terraform/terraform.tfstate")
        let usage = DiskUsage.usage(of: root.path, protectedNames: ["terraform.tfstate"])
        #expect(usage.protectedFiles == ["a/b/terraform.tfstate"])
        #expect(ScanItem(ruleID: "x", path: root.path, usage: usage).blocker != nil)
    }

    @Test func venvNeedsPyvenvCfg() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "real/.venv/pyvenv.cfg")
        try write(root, "fake/.venv/notes.txt")
        let rule = try #require(RuleCatalog.all.first { $0.id == "python-venv" })
        let items = ProjectWalker(folderRules: [".venv": [rule]], worktreeRuleID: nil).walk(root.path)
        #expect(items.map(\.path) == [root.path + "/real/.venv"])
    }

    @Test func rebuildableIgnoredPaths() {
        let names: Set<String> = ["node_modules", ".turbo"]
        #expect(WorktreeInspector.isRebuildable("apps/web/node_modules", folderNames: names))
        #expect(WorktreeInspector.isRebuildable("tsconfig.tsbuildinfo", folderNames: names))
        #expect(!WorktreeInspector.isRebuildable(".env", folderNames: names))
        #expect(!WorktreeInspector.isRebuildable("infra/terraform.tfstate", folderNames: names))
    }

    @Test func worktreeProblems() async throws {
        let repo = try tempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await git(repo, "init", "-q", "-b", "main")
        try write(repo, ".gitignore", "node_modules/\n.env\n")
        try await git(repo, "add", ".")
        try await git(repo, "commit", "-qm", "init")
        let clean = repo.appendingPathComponent(".claude/worktrees/clean")
        let secrets = repo.appendingPathComponent(".claude/worktrees/secrets")
        let detached = repo.appendingPathComponent(".claude/worktrees/detached")
        try await git(repo, "worktree", "add", "-q", clean.path, "-b", "clean")
        try await git(repo, "worktree", "add", "-q", secrets.path, "-b", "secrets")
        try await git(repo, "worktree", "add", "-q", "--detach", detached.path)
        try write(clean, "node_modules/a.js")
        try write(secrets, ".env", "TOKEN=1")
        try await git(detached, "commit", "-q", "--allow-empty", "-m", "orphan")

        let rules = RuleCatalog.all
        let cleanInfo = await WorktreeInspector.inspect(path: clean.path, repoPath: repo.path, rules: rules)
        let secretsInfo = await WorktreeInspector.inspect(path: secrets.path, repoPath: repo.path, rules: rules)
        let detachedInfo = await WorktreeInspector.inspect(path: detached.path, repoPath: repo.path, rules: rules)
        #expect(cleanInfo.problems == [])
        #expect(secretsInfo.problems == [])
        #expect(secretsInfo.warnings.first?.contains(".env") == true)
        #expect(detachedInfo.problems == ["Detached HEAD with commits on no branch"])
        #expect(ScanItem(ruleID: "w", path: clean.path, worktree: WorktreeInfo(repoPath: repo.path)).blocker == "Not checked yet")
    }

    @Test func processTimeoutStopsCommand() async throws {
        let started = Date()
        let output = try await ProcessRunner.run("/bin/sleep", ["30"], timeout: .milliseconds(300))
        #expect(output.timedOut)
        #expect(!output.succeeded)
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

struct SubmoduleWorktreeTests {
    @discardableResult
    func git(_ dir: URL, _ args: String...) async throws -> ProcessOutput {
        let base = ["-C", dir.path, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "protocol.file.allow=always", "-c", "commit.gpgsign=false"]
        let output = try await ProcessRunner.run("/usr/bin/git", base + args)
        #expect(output.succeeded, "git \(args): \(output.stderr)")
        return output
    }

    /// upstream repo -> main repo with it as a submodule -> three worktrees with the submodule checked out.
    func makeFixture() async throws -> (root: URL, main: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dc-sub-\(UUID().uuidString)")
        let upstream = root.appendingPathComponent("upstream")
        let main = root.appendingPathComponent("main")
        for dir in [upstream, main] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try await git(upstream, "init", "-q", "-b", "main")
        try "hello".write(to: upstream.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try await git(upstream, "add", ".")
        try await git(upstream, "commit", "-qm", "upstream")
        try await git(main, "init", "-q", "-b", "main")
        try await git(main, "submodule", "add", "-q", upstream.path, "lib")
        try ".claude/\nnode_modules/\n".write(to: main.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try await git(main, "add", ".gitignore")
        try await git(main, "commit", "-qm", "add lib")
        for name in ["ok", "unpushed", "dirty"] {
            let worktree = main.appendingPathComponent(".claude/worktrees/\(name)")
            try await git(main, "worktree", "add", "-q", worktree.path, "-b", name)
            try await git(worktree, "submodule", "update", "-q", "--init")
        }
        let worktrees = main.appendingPathComponent(".claude/worktrees")
        // Ignored build output, which the cleaner hands to the purge pool before git runs.
        let packageFile = worktrees.appendingPathComponent("ok/node_modules/pkg/index.js")
        try FileManager.default.createDirectory(at: packageFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: packageFile, atomically: true, encoding: .utf8)
        try await git(worktrees.appendingPathComponent("unpushed/lib"), "commit", "-q", "--allow-empty", "-m", "local only")
        try "changed".write(to: worktrees.appendingPathComponent("dirty/lib/README"), atomically: true, encoding: .utf8)
        return (root, main)
    }

    @Test func inspectsSubmodules() async throws {
        let (root, main) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktrees = main.path + "/.claude/worktrees/"
        let rules = RuleCatalog.all

        let ok = await WorktreeInspector.inspect(path: worktrees + "ok", repoPath: main.path, rules: rules)
        #expect(ok.problems == [])
        #expect(ok.hasSubmodules)

        let unpushed = await WorktreeInspector.inspect(path: worktrees + "unpushed", repoPath: main.path, rules: rules)
        #expect(unpushed.problems?.contains("Submodule lib has commits on no remote") == true)
        #expect(unpushed.warnings.contains { $0.contains("submodule pointer") })

        let dirty = await WorktreeInspector.inspect(path: worktrees + "dirty", repoPath: main.path, rules: rules)
        #expect(dirty.problems == ["Submodule lib: 1 uncommitted file"])
    }

    @Test func removesCleanSubmoduleWorktreeAndRechecksStaleScans() async throws {
        let (root, main) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktrees = main.path + "/.claude/worktrees/"
        let cleaner = Cleaner(homePath: root.path)

        let ok = ScanItem(ruleID: "claude-worktrees", path: worktrees + "ok",
                          worktree: WorktreeInfo(repoPath: main.path, problems: [], hasSubmodules: true))
        // A scan result that predates the local-only commit must not lead to a forced removal.
        let stale = ScanItem(ruleID: "claude-worktrees", path: worktrees + "unpushed",
                             worktree: WorktreeInfo(repoPath: main.path, problems: [], hasSubmodules: true))
        let outcomes = await collect(cleaner, [ok, stale])

        #expect(outcomes.count == 2)
        #expect(outcomes.first { $0.label.hasSuffix("/ok") }?.succeeded == true)
        #expect(outcomes.first { $0.label.hasSuffix("/unpushed") }?.succeeded == false)
        #expect(outcomes.first { $0.label.hasSuffix("/ok") }?.log.contains("node_modules: moved to the purge area") == true)
        #expect(!FileManager.default.fileExists(atPath: worktrees + "ok"))
        #expect(FileManager.default.fileExists(atPath: worktrees + "unpushed/lib"))
        #expect(cleaner.purger.leftovers().isEmpty)
        try await git(main, "rev-parse", "--verify", "-q", "ok")
    }

    @Test func worktreePathMustBeDirectChildOfClaudeWorktrees() {
        let home = "/Users/t"
        let repo = "/Users/t/repos/app"
        #expect(SafePath.isClaudeWorktree("/Users/t/repos/app/.claude/worktrees/x", repoPath: repo, homePath: home))
        #expect(!SafePath.isClaudeWorktree("/Users/t/repos/app", repoPath: repo, homePath: home))
        #expect(!SafePath.isClaudeWorktree("/Users/t/repos/app/.claude/worktrees/x/y", repoPath: repo, homePath: home))
        #expect(!SafePath.isClaudeWorktree("/opt/app/.claude/worktrees/x", repoPath: "/opt/app", homePath: home))
    }
}

/// Runs a clean and returns every outcome it reported.
func collect(_ cleaner: Cleaner, _ items: [ScanItem]) async -> [CleanOutcome] {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var outcomes: [CleanOutcome] = []
    }
    let box = Box()
    await cleaner.clean(items) { outcome in box.lock.withLock { box.outcomes.append(outcome) } }
    return box.outcomes
}

struct ParallelCleanerTests {
    func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dc-clean-\(UUID().uuidString)")
        for project in 0..<12 {
            let base = home.appendingPathComponent("repos/p\(project)")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try "{}".write(to: base.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
            for file in 0..<50 {
                let url = base.appendingPathComponent("node_modules/pkg\(file % 5)/f\(file).js")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "x".write(to: url, atomically: true, encoding: .utf8)
            }
        }
        return home
    }

    @Test func cleansManyFoldersAndEmptiesThePurgeArea() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let items = (0..<12).map { ScanItem(ruleID: "node-modules", path: home.path + "/repos/p\($0)/node_modules") }
        let cleaner = Cleaner(homePath: home.path)

        let outcomes = await collect(cleaner, items)
        #expect(outcomes.count == cleaner.expectedOutcomeCount(items))
        #expect(outcomes.allSatisfy { $0.succeeded }, "\(outcomes.compactMap { $0.error })")
        #expect(items.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(items.allSatisfy { FileManager.default.fileExists(atPath: ($0.path as NSString).deletingLastPathComponent + "/package.json") })
        #expect(cleaner.purger.leftovers().isEmpty)
    }

    @Test func refusesUnsafePathsWithoutStagingThem() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = ScanItem(ruleID: "node-modules", path: home.path + "/repos/p0")
        let outcomes = await collect(Cleaner(homePath: home.path), [project])
        #expect(outcomes.first?.succeeded == false)
        #expect(FileManager.default.fileExists(atPath: home.path + "/repos/p0/package.json"))
        #expect(Purger(homePath: home.path).leftovers().isEmpty)
    }

    @Test func stagesWithOneRenameAndPurgesLeftovers() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let purger = Purger(homePath: home.path)
        let staged = try #require(try purger.stage(home.path + "/repos/p1/node_modules"))
        #expect(staged.hasPrefix(purger.root + "/"))
        #expect(!FileManager.default.fileExists(atPath: home.path + "/repos/p1/node_modules"))
        #expect(purger.leftovers() == [staged])
        for path in purger.leftovers() { try await purger.purge(path) }
        #expect(purger.leftovers().isEmpty)
    }
}

/// A plain repo (no submodules) with one worktree, for the review-finding tests.
struct WorktreeSafetyTests {
    @discardableResult
    func git(_ dir: URL, _ args: String...) async throws -> ProcessOutput {
        let base = ["-C", dir.path, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"]
        let output = try await ProcessRunner.run("/usr/bin/git", base + args)
        #expect(output.succeeded, "git \(args): \(output.stderr)")
        return output
    }

    func write(_ url: URL, _ text: String = "x") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func makeRepo() async throws -> (root: URL, repo: URL, worktree: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dc-wt-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await git(repo, "init", "-q", "-b", "main")
        try write(repo.appendingPathComponent(".gitignore"), ".claude/\nnode_modules/\n.terragrunt-cache/\nbuild/\n")
        try await git(repo, "add", ".")
        try await git(repo, "commit", "-qm", "init")
        let worktree = repo.appendingPathComponent(".claude/worktrees/wt")
        try await git(repo, "worktree", "add", "-q", worktree.path, "-b", "wt")
        try write(worktree.appendingPathComponent("node_modules/pkg/index.js"))
        return (root, repo, worktree)
    }

    @Test func nestedAndFoldedTerraformStateBlocksTheWorktree() async throws {
        let (root, repo, worktree) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        // Nested in an untracked folder, which plain --ignored folds into "live/".
        try write(worktree.appendingPathComponent("live/unit/.terragrunt-cache/a/terraform.tfstate"), "{}")
        let nested = await WorktreeInspector.inspect(path: worktree.path, repoPath: repo.path, rules: RuleCatalog.all)
        #expect(nested.problems == ["Holds local state: live/unit/.terragrunt-cache/a/terraform.tfstate"])

        // Inside a generic build folder, which git reports as one ignored entry.
        try FileManager.default.removeItem(at: worktree.appendingPathComponent("live"))
        try write(worktree.appendingPathComponent("build/.terragrunt-cache/b/terraform.tfstate"), "{}")
        let folded = await WorktreeInspector.inspect(path: worktree.path, repoPath: repo.path, rules: RuleCatalog.all)
        #expect(folded.problems == ["Holds local state: build/.terragrunt-cache/b/terraform.tfstate"])

        // Inside a folder ignored by a plain pattern, which is not build output.
        try FileManager.default.removeItem(at: worktree.appendingPathComponent("build"))
        try write(worktree.appendingPathComponent(".git-exclude-test"), "")
        let exclude = try await git(worktree, "rev-parse", "--git-path", "info/exclude").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try write(URL(fileURLWithPath: exclude, relativeTo: worktree), "live/\n.git-exclude-test\n")
        try write(worktree.appendingPathComponent("live/.terragrunt-cache/c/terraform.tfstate"), "{}")
        let plain = await WorktreeInspector.inspect(path: worktree.path, repoPath: repo.path, rules: RuleCatalog.all)
        #expect(plain.problems == ["Holds local state: live/.terragrunt-cache/c/terraform.tfstate"])
    }

    @Test func lockedWorktreeIsBlockedAndKeepsItsBuildOutput() async throws {
        let (root, repo, worktree) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try await git(repo, "worktree", "lock", "--reason", "agent running", worktree.path)

        let info = await WorktreeInspector.inspect(path: worktree.path, repoPath: repo.path, rules: RuleCatalog.all)
        #expect(info.problems == ["Locked: agent running"])

        let item = ScanItem(ruleID: "claude-worktrees", path: worktree.path, worktree: WorktreeInfo(repoPath: repo.path, problems: []))
        let outcomes = await collect(Cleaner(homePath: root.path), [item])
        #expect(outcomes.count == 1 && outcomes[0].succeeded == false)
        #expect(FileManager.default.fileExists(atPath: worktree.path + "/node_modules/pkg/index.js"))
    }

    @Test func cancelledInspectionNeverReadsAsClean() async throws {
        let (root, repo, worktree) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task { await WorktreeInspector.inspect(path: worktree.path, repoPath: repo.path, rules: RuleCatalog.all) }
        task.cancel()
        let info = await task.value
        #expect(info.problems?.isEmpty == false)
    }
}

struct PurgeSafetyTests {
    func makeItems(_ count: Int, files: Int) throws -> (home: URL, items: [ScanItem]) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dc-purge-\(UUID().uuidString)")
        var items: [ScanItem] = []
        for index in 0..<count {
            let folder = home.appendingPathComponent("repos/p\(index)/node_modules")
            for file in 0..<files {
                let url = folder.appendingPathComponent("d\(file % 10)/f\(file).js")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "x".write(to: url, atomically: true, encoding: .utf8)
            }
            items.append(ScanItem(ruleID: "node-modules", path: folder.path))
        }
        return (home, items)
    }

    @Test func stopLeavesNothingHiddenInThePurgeArea() async throws {
        let (home, items) = try makeItems(20, files: 400)
        defer { try? FileManager.default.removeItem(at: home) }
        let cleaner = Cleaner(homePath: home.path, purgeWidth: 1)
        let task = Task { await collect(cleaner, items) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        let outcomes = await task.value

        #expect(cleaner.purger.leftovers().isEmpty)
        // An item may be gone only if its delete reported success and it was not kept.
        let kept = Set(outcomes.filter { $0.label.hasPrefix("Kept ") }.map { $0.label })
        for item in items where !FileManager.default.fileExists(atPath: item.path) {
            #expect(!kept.contains { $0.hasSuffix(item.path.replacingOccurrences(of: home.path, with: "~")) })
        }
    }

    @Test func undeletableFolderIsMovedBack() async throws {
        let (home, items) = try makeItems(1, files: 3)
        let locked = items[0].path + "/d0/f0.js"
        defer {
            runTool("/usr/bin/chflags", ["-R", "nouchg", home.path])
            try? FileManager.default.removeItem(at: home)
        }
        runTool("/usr/bin/chflags", ["uchg", locked])

        let cleaner = Cleaner(homePath: home.path)
        let outcomes = await collect(cleaner, items)
        #expect(outcomes.contains { $0.label.hasPrefix("Kept ") && $0.error?.contains("Moved back") == true })
        #expect(FileManager.default.fileExists(atPath: locked))
        #expect(cleaner.purger.leftovers().isEmpty)
    }
}

struct ConcurrencyTests {
    @Test func porcelainZParsesUnquotedPathsAndSkipsRenameSources() {
        let output = "?? caf\u{e9}/a b.txt\0R  new name.txt\0old name.txt\0!! node_modules/\0!! we\"ird.log\0"
        #expect(PorcelainEntry.parse(output) == [
            PorcelainEntry(code: "??", path: "caf\u{e9}/a b.txt"),
            PorcelainEntry(code: "R ", path: "new name.txt"),
            PorcelainEntry(code: "!!", path: "node_modules"),
            PorcelainEntry(code: "!!", path: "we\"ird.log"),
        ])
    }

    @Test func porcelainZKeepsAPathThatStartsWithACombiningMark() {
        let output = "?? \u{301}accent.txt\0"
        #expect(PorcelainEntry.parse(output) == [PorcelainEntry(code: "??", path: "\u{301}accent.txt")])
    }

    @Test func crashRecoveryMovesUnconfirmedFoldersBackAndDeletesTheRest() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dc-recover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let keep = home.appendingPathComponent("wt/node_modules")
        let drop = home.appendingPathComponent("p/node_modules")
        for folder in [keep, drop] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "x".write(to: folder.appendingPathComponent("f.js"), atomically: true, encoding: .utf8)
        }
        let purger = Purger(homePath: home.path)
        _ = try purger.stage(keep.path, keepOrigin: true)
        let staged = try purger.stage(drop.path, keepOrigin: true)
        let confirmed = try #require(staged)
        purger.confirmDelete(confirmed)

        let failures = await purger.recoverLeftovers()
        #expect(failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: keep.path + "/f.js"))
        #expect(!FileManager.default.fileExists(atPath: drop.path))
        #expect(!FileManager.default.fileExists(atPath: purger.root))
    }

    @Test func limiterNeverExceedsItsWidth() async {
        final class Gauge: @unchecked Sendable {
            let lock = NSLock()
            var current = 0
            var peak = 0
            func change(_ delta: Int) { lock.withLock { current += delta; peak = max(peak, current) } }
        }
        let limiter = AsyncLimiter(width: 3)
        let gauge = Gauge()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await limiter.acquire()
                    gauge.change(1)
                    try? await Task.sleep(for: .milliseconds(5))
                    gauge.change(-1)
                    await limiter.release()
                }
            }
        }
        #expect(gauge.peak == 3)
    }
}

/// Runs a tool and waits; for test setup only.
func runTool(_ path: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try? process.run()
    process.waitUntilExit()
}

struct UpdateCheckerTests {
    func release(tag: String = "v0.2.0", page: String? = nil, asset: String? = nil,
                 draft: Bool = false, prerelease: Bool = false) -> Data {
        let page = page ?? "https://github.com/digorgonzola/disk-cleaner/releases/tag/\(tag)"
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let asset = asset ?? "https://github.com/digorgonzola/disk-cleaner/releases/download/\(tag)/DiskCleaner-\(version).zip"
        let json: [String: Any] = [
            "tag_name": tag, "html_url": page, "draft": draft, "prerelease": prerelease, "body": "notes",
            "assets": [
                ["name": "DiskCleaner-\(version).zip", "browser_download_url": asset],
                ["name": "DiskCleaner-\(version).zip.sha256", "browser_download_url": asset + ".sha256"],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func versionsParseAndCompare() {
        #expect(Version("v1.2.3") == Version("1.2.3"))
        #expect(Version("0.10.0")! > Version("0.9.9")!)
        #expect(Version("1.2") == nil)
        #expect(Version("1.2.3-beta") == nil)
        #expect(Version("1.٢.3") == nil) // non-ASCII digits
    }

    @Test func parsesAValidRelease() throws {
        let info = try UpdateChecker.parse(release())
        #expect(info.version == Version("0.2.0"))
        #expect(info.pageURL.absoluteString == "https://github.com/digorgonzola/disk-cleaner/releases/tag/v0.2.0")
        #expect(info.downloadURL?.absoluteString == "https://github.com/digorgonzola/disk-cleaner/releases/download/v0.2.0/DiskCleaner-0.2.0.zip")
    }

    @Test func rejectsUntrustedOrOddReleases() {
        #expect(throws: UpdateCheckError.self) { try UpdateChecker.parse(release(tag: "0.2.0")) }
        #expect(throws: UpdateCheckError.self) { try UpdateChecker.parse(release(tag: "v0.2.0-rc1")) }
        #expect(throws: UpdateCheckError.self) { try UpdateChecker.parse(release(draft: true)) }
        #expect(throws: UpdateCheckError.self) { try UpdateChecker.parse(release(prerelease: true)) }
        #expect(throws: UpdateCheckError.self) { try UpdateChecker.parse(Data("not json".utf8)) }
    }

    @Test func linksComeFromTheVersionNotTheResponse() throws {
        let info = try UpdateChecker.parse(release(
            page: "https://evil.example/disk-cleaner/releases/tag/v0.2.0",
            asset: "https://evil.example/DiskCleaner-0.2.0.zip"
        ))
        #expect(info.pageURL.absoluteString == "https://github.com/digorgonzola/disk-cleaner/releases/tag/v0.2.0")
        #expect(info.downloadURL?.absoluteString == "https://github.com/digorgonzola/disk-cleaner/releases/download/v0.2.0/DiskCleaner-0.2.0.zip")
    }

    @Test func noZipMeansNoDownloadLink() throws {
        let json = #"{"tag_name":"v0.2.0","draft":false,"prerelease":false,"body":null,"assets":[]}"#
        let info = try UpdateChecker.parse(Data(json.utf8))
        #expect(info.downloadURL == nil)
        #expect(info.pageURL.absoluteString.hasSuffix("/releases/tag/v0.2.0"))
    }

    @Test func notificationLinksMustStayInTheReleases() {
        let releases = "https://github.com/digorgonzola/disk-cleaner/releases/"
        #expect(UpdateChecker.trustedURL(releases + "tag/v0.2.0") != nil)
        #expect(UpdateChecker.trustedURL("https://user@github.com/digorgonzola/disk-cleaner/releases/x") == nil)
        #expect(UpdateChecker.trustedURL(releases + "../../evil") == nil)
        #expect(UpdateChecker.trustedURL(releases + "tag/v0.2.0?u=https://evil.example") == nil)
        #expect(UpdateChecker.trustedURL(releases + "tag/v0.2.0#@evil.example") == nil)
        #expect(UpdateChecker.trustedURL("http://github.com/digorgonzola/disk-cleaner/releases/x") == nil)
    }

    @Test func updateLogicRespectsCurrentAndSkippedVersions() throws {
        let latest = try UpdateChecker.parse(release(tag: "v0.2.0"))
        #expect(UpdateChecker.isUpdate(latest, current: Version("0.1.1")!, skipped: nil))
        #expect(!UpdateChecker.isUpdate(latest, current: Version("0.2.0")!, skipped: nil))
        #expect(!UpdateChecker.isUpdate(latest, current: Version("0.3.0")!, skipped: nil))
        #expect(!UpdateChecker.isUpdate(latest, current: Version("0.1.1")!, skipped: Version("0.2.0")))
    }
}

struct ReclaimableTests {
    let query = ReclaimableQuery(command: "", excludedLabels: ["Local Volumes"])

    func output(_ stdout: String, status: Int32 = 0, stderr: String = "", timedOut: Bool = false) -> ProcessOutput {
        ProcessOutput(status: status, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }

    @Test func parsesSizesAndLeavesOutExcludedLabels() {
        #expect(query.parse(output("Images=510825984\nContainers=0\nLocal Volumes=11732066549\n")) == .bytes(510_825_984))
        #expect(query.parse(output("Images=1.5GB (45%)\nContainers=0B (0%)\nLocal Volumes=3GB (100%)\nBuild Cache=512kB\n"))
            == .bytes(1_500_512_000))
        #expect(query.parse(output("banner\n")) == .unknown(reason: "the tool's answer was not a size"))
        #expect(query.parse(output("Images=lots\n")) == .unknown(reason: "the tool's answer was not a size"))
    }

    @Test func failuresGiveTheReason() {
        #expect(query.parse(output("", status: 125, stderr: "Error: cannot connect to Podman\n"))
            == .unknown(reason: "Error: cannot connect to Podman"))
        #expect(query.parse(output("Images=1", status: 15, timedOut: true)) == .unknown(reason: "the tool did not answer in time"))
    }

    @Test func itemSizeIsTheEstimateWhenThereIsOne() {
        var item = ScanItem(ruleID: "podman", path: "/x", usage: Usage(bytes: 50_000, lastModified: nil, protectedFiles: []))
        #expect(item.bytes == 50_000)
        item.reclaimable = .pending
        #expect(item.bytes == 0)
        item.reclaimable = .bytes(1_000)
        #expect(item.bytes == 1_000)
        item.reclaimable = .unknown(reason: "stopped")
        #expect(item.bytes == 0)
    }

    /// Runs a rule's query with fake tools that print what the real ones print.
    func estimate(_ ruleID: String, tools: [String: String]) async throws -> Reclaimable {
        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("dc-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bin) }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, script) in tools {
            let url = bin.appendingPathComponent(name)
            try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let rule = try #require(RuleCatalog.all.first { $0.id == ruleID })
        let query = try #require(rule.reclaimable)
        let output = try await ProcessRunner.run("/bin/zsh", ["-c", query.command],
                                                 environment: ["HOME": bin.path, "PATH": bin.path + ":/usr/bin:/bin"])
        return query.parse(output)
    }

    @Test func podmanQueryLeavesOutVolumes() async throws {
        // The fake prints its arguments' format back, so a changed format string fails here.
        let podman = """
        [ "$*" = "system df --format {{.Type}}={{.RawReclaimable}}" ] || { echo "unexpected: $*" >&2; exit 2; }
        printf 'Images=510825984\\nContainers=0\\nLocal Volumes=11732066549\\n'
        """
        #expect(try await estimate("podman", tools: ["podman": podman]) == .bytes(510_825_984))
    }

    @Test func dockerQueryReadsDecimalUnits() async throws {
        let docker = """
        [ "$*" = "--context desktop-linux system df --format {{.Type}}={{.Reclaimable}}" ] || { echo "unexpected: $*" >&2; exit 2; }
        printf 'Images=1.5GB (45%%)\\nContainers=0B (0%%)\\nLocal Volumes=3GB (100%%)\\nBuild Cache=512kB\\n'
        """
        #expect(try await estimate("docker-desktop", tools: ["docker": docker]) == .bytes(1_500_512_000))
    }

    @Test func stoppedMachineGivesNoEstimate() async throws {
        let podman = "echo 'Error: unable to connect to Podman socket' >&2; exit 125"
        #expect(try await estimate("podman", tools: ["podman": podman])
            == .unknown(reason: "Error: unable to connect to Podman socket"))
    }

    @Test func scanNeverCountsTheDiskImageBeforeTheToolAnswers() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("dc-vm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let disk = home.appendingPathComponent("vm/disk.raw")
        try FileManager.default.createDirectory(at: disk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: disk)
        let rule = CleanupRule(
            id: "vm", name: "VM", category: .containers, detail: "", target: .homePaths(["vm"]),
            cleanCommand: "true", canDeleteWithoutCommand: false,
            reclaimable: ReclaimableQuery(command: "sleep 1; exec /bin/echo 'Images=42'"))

        var item: ScanItem?
        var sizesSeen: [Int64] = []
        for await event in Scanner(homePath: home.path, projectRoots: [], rules: [rule]).scan() {
            switch event {
            case .discovered(let found): item = found.first ?? item
            case .measured(_, let usage): item?.usage = usage
            case .estimated(_, let reclaimable): item?.reclaimable = reclaimable
            default: break
            }
            if let item { sizesSeen.append(item.bytes) }
        }
        #expect(item?.usage?.bytes ?? 0 >= 100_000)
        #expect(item?.reclaimable == .bytes(42))
        #expect(sizesSeen.allSatisfy { $0 == 0 || $0 == 42 }, "\(sizesSeen)")
    }
}
