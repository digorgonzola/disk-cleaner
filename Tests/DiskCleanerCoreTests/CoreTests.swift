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
        let output = try await ProcessRunner.run("/usr/bin/git", ["-C", dir.path, "-c", "user.email=t@t", "-c", "user.name=t"] + args)
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
