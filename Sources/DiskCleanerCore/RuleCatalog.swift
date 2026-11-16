import Foundation

/// Every location the scanner knows about. Add a new cache here; the UI picks it up.
public enum RuleCatalog {
    public static let all: [CleanupRule] = worktrees + projectArtifacts + packageManagers
        + infrastructure + containers + testing + editors + browsers + system + reviewOnly

    static let worktrees: [CleanupRule] = [
        CleanupRule(
            id: "claude-worktrees", name: "Claude Code worktrees", category: .worktrees,
            detail: "Git worktrees in <repo>/.claude/worktrees, removed with `git worktree remove`. The branch and its commits stay in the repo. Worktrees with uncommitted changes or a detached HEAD with commits on no branch cannot be selected. Worktrees with submodules are removed with --force, but only when every submodule is clean, has no stashes, and has all its commits on a remote.",
            risk: .caution, target: .claudeWorktrees),
    ]

    static let projectArtifacts: [CleanupRule] = [
        CleanupRule(
            id: "node-modules", name: "node_modules", category: .projectArtifacts,
            detail: "Installed JavaScript packages. Run your package manager's install to restore.",
            risk: .caution, target: .projectFolder(name: "node_modules", markers: ["package.json"])),
        CleanupRule(
            id: "terragrunt-cache", name: ".terragrunt-cache", category: .projectArtifacts,
            detail: "Per-unit Terragrunt working copies of modules and providers. Recreated on the next plan or apply. Caches that hold a local terraform.tfstate cannot be selected.",
            target: .projectFolder(name: ".terragrunt-cache", markers: []),
            protectedFileNames: ["terraform.tfstate", "terraform.tfstate.backup"]),
        CleanupRule(
            id: "terraform-dir", name: ".terraform", category: .projectArtifacts,
            detail: "Terraform/OpenTofu providers and modules from `init`. Run `init` again with the same -backend-config to restore; the selected workspace resets to default.",
            risk: .caution, target: .projectFolder(name: ".terraform", markers: [])),
        CleanupRule(
            id: "turbo", name: ".turbo", category: .projectArtifacts,
            detail: "Turborepo local task cache.",
            target: .projectFolder(name: ".turbo", markers: [])),
        CleanupRule(
            id: "next", name: ".next", category: .projectArtifacts,
            detail: "Next.js build output and cache.",
            target: .projectFolder(name: ".next", markers: ["package.json"])),
        CleanupRule(
            id: "python-venv", name: ".venv", category: .projectArtifacts,
            detail: "Python virtual environments. Recreate with `uv sync` or `pip install`.",
            risk: .caution, target: .projectFolder(name: ".venv", markers: [], contains: ["pyvenv.cfg"])),
        CleanupRule(
            id: "pycache", name: "__pycache__", category: .projectArtifacts,
            detail: "Compiled Python bytecode.",
            target: .projectFolder(name: "__pycache__", markers: [])),
        CleanupRule(
            id: "pytest-cache", name: ".pytest_cache", category: .projectArtifacts,
            detail: "pytest run cache.",
            target: .projectFolder(name: ".pytest_cache", markers: [])),
        CleanupRule(
            id: "mypy-cache", name: ".mypy_cache", category: .projectArtifacts,
            detail: "mypy incremental cache.",
            target: .projectFolder(name: ".mypy_cache", markers: [])),
        CleanupRule(
            id: "ruff-cache", name: ".ruff_cache", category: .projectArtifacts,
            detail: "Ruff lint cache.",
            target: .projectFolder(name: ".ruff_cache", markers: [])),
        CleanupRule(
            id: "cargo-target", name: "Rust target", category: .projectArtifacts,
            detail: "Cargo build output.",
            target: .projectFolder(name: "target", markers: ["Cargo.toml"])),
        CleanupRule(
            id: "gradle-project", name: ".gradle (project)", category: .projectArtifacts,
            detail: "Per-project Gradle cache.",
            target: .projectFolder(name: ".gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"])),
    ]

    static let packageManagers: [CleanupRule] = [
        CleanupRule(
            id: "pnpm-store", name: "pnpm store", category: .packageManagers,
            detail: "Content-addressed package store. `pnpm store prune` removes only packages no project references.",
            target: .homePaths(["Library/pnpm/store"]),
            cleanCommand: "pnpm store prune", canDeleteWithoutCommand: false),
        CleanupRule(
            id: "pnpm-metadata", name: "pnpm metadata cache", category: .packageManagers,
            detail: "Registry metadata that pnpm re-fetches on demand.",
            target: .homePaths(["Library/Caches/pnpm"])),
        CleanupRule(
            id: "npm-cache", name: "npm cache", category: .packageManagers,
            detail: "npm download cache.",
            target: .homePaths([".npm/_cacache"]), cleanCommand: "npm cache clean --force"),
        CleanupRule(
            id: "npx-cache", name: "npx cache", category: .packageManagers,
            detail: "Packages fetched by `npx`. Re-downloaded on next use.",
            target: .homePaths([".npm/_npx"])),
        CleanupRule(
            id: "yarn-cache", name: "Yarn cache", category: .packageManagers,
            detail: "Yarn classic global cache.",
            target: .homePaths(["Library/Caches/Yarn"]), cleanCommand: "yarn cache clean"),
        CleanupRule(
            id: "yarn-berry-cache", name: "Yarn Berry cache", category: .packageManagers,
            detail: "Yarn 2+ global mirror.",
            target: .homePaths([".yarn/berry/cache"])),
        CleanupRule(
            id: "corepack", name: "Corepack / node cache", category: .packageManagers,
            detail: "Package-manager binaries that Corepack downloads.",
            target: .homePaths([".cache/node"])),
        CleanupRule(
            id: "node-gyp", name: "node-gyp headers", category: .packageManagers,
            detail: "Node headers for native module builds.",
            target: .homePaths(["Library/Caches/node-gyp"])),
        CleanupRule(
            id: "homebrew", name: "Homebrew downloads", category: .packageManagers,
            detail: "All cached downloads, and installed versions older than the current one of each formula.",
            target: .homePaths(["Library/Caches/Homebrew"]), cleanCommand: "brew cleanup --prune=all -s"),
        CleanupRule(
            id: "uv-cache", name: "uv cache", category: .packageManagers,
            detail: "uv wheel and source cache.",
            target: .homePaths([".cache/uv"]), cleanCommand: "uv cache clean"),
        CleanupRule(
            id: "pip-cache", name: "pip cache", category: .packageManagers,
            detail: "pip HTTP and wheel cache.",
            target: .homePaths(["Library/Caches/pip"])),
        CleanupRule(
            id: "pre-commit", name: "pre-commit environments", category: .packageManagers,
            detail: "Hook environments. pre-commit rebuilds them on the next run.",
            target: .homePaths([".cache/pre-commit"]), cleanCommand: "pre-commit clean"),
        CleanupRule(
            id: "go-build", name: "Go build cache", category: .packageManagers,
            detail: "Compiled Go packages.",
            target: .homePaths(["Library/Caches/go-build"]), cleanCommand: "go clean -cache"),
        CleanupRule(
            id: "go-mod", name: "Go module cache", category: .packageManagers,
            detail: "Downloaded Go modules. Re-downloaded on the next build.",
            risk: .caution, target: .homePaths(["go/pkg/mod"]), cleanCommand: "go clean -modcache"),
        CleanupRule(
            id: "gradle", name: "Gradle caches", category: .packageManagers,
            detail: "Global Gradle dependency and build cache.",
            target: .homePaths([".gradle/caches"])),
        CleanupRule(
            id: "maven", name: "Maven repository", category: .packageManagers,
            detail: "Local Maven artifacts. Re-downloaded on the next build.",
            risk: .caution, target: .homePaths([".m2/repository"])),
        CleanupRule(
            id: "cargo-registry", name: "Cargo registry", category: .packageManagers,
            detail: "Downloaded crate sources.",
            target: .homePaths([".cargo/registry/cache", ".cargo/registry/src"])),
    ]

    static let infrastructure: [CleanupRule] = [
        CleanupRule(
            id: "terragrunt-global", name: "Terragrunt cache", category: .infrastructure,
            detail: "Terragrunt provider cache and downloaded module sources.",
            target: .homePaths(["Library/Caches/terragrunt", ".terragrunt-cache"])),
        CleanupRule(
            id: "terraform-plugin-cache", name: "Terraform plugin cache", category: .infrastructure,
            detail: "TF_PLUGIN_CACHE_DIR provider binaries. Every provider version ever used stays here until removed.",
            target: .homePaths([".terraform.d/plugin-cache"])),
        CleanupRule(
            id: "trivy", name: "Trivy databases", category: .infrastructure,
            detail: "Vulnerability and Java index databases. Re-downloaded on the next scan.",
            target: .homePaths(["Library/Caches/trivy", "Library/Caches/java-db"])),
        CleanupRule(
            id: "act", name: "act action cache", category: .infrastructure,
            detail: "GitHub Actions cloned by `act`.",
            target: .homePaths([".cache/act"])),
        CleanupRule(
            id: "aws-toolkits", name: "AWS toolkit cache", category: .infrastructure,
            detail: "AWS IDE toolkit downloads (language servers).",
            target: .homePaths(["Library/Caches/aws/toolkits"])),
        CleanupRule(
            id: "helm", name: "Helm cache", category: .infrastructure,
            detail: "Downloaded charts and repo indexes.",
            target: .homePaths(["Library/Caches/helm"])),
    ]

    static let containers: [CleanupRule] = [
        CleanupRule(
            id: "podman", name: "Podman machine", category: .containers,
            detail: "The Podman VM disk image. Cleaning runs `podman system prune --all` (unused images, stopped containers, build cache; volumes are kept), then `fstrim` so the host gets the space back. The machine must be running.",
            risk: .caution, target: .homePaths([".local/share/containers/podman/machine"]),
            cleanCommand: "podman system prune --all --force && podman machine ssh -- sudo fstrim -av",
            canDeleteWithoutCommand: false),
        CleanupRule(
            id: "docker-desktop", name: "Docker Desktop", category: .containers,
            detail: "The Docker Desktop VM disk. Cleaning runs `docker system prune --all` against the desktop-linux context: stopped containers, unused images and networks, build cache. Volumes are kept.",
            risk: .caution, target: .homePaths(["Library/Containers/com.docker.docker/Data/vms"]),
            cleanCommand: "docker --context desktop-linux system prune --all --force",
            canDeleteWithoutCommand: false),
    ]

    static let testing: [CleanupRule] = [
        CleanupRule(
            id: "playwright", name: "Playwright browsers", category: .testing,
            detail: "Browser builds. Restore with `npx playwright install`.",
            risk: .caution, target: .homePaths(["Library/Caches/ms-playwright"])),
        CleanupRule(
            id: "puppeteer", name: "Puppeteer browsers", category: .testing,
            detail: "Chrome builds that Puppeteer downloads.",
            target: .homePaths([".cache/puppeteer"])),
        CleanupRule(
            id: "mongodb-binaries", name: "mongodb-memory-server binaries", category: .testing,
            detail: "MongoDB binaries for in-memory test servers.",
            target: .homePaths([".cache/mongodb-binaries"])),
        CleanupRule(
            id: "prisma", name: "Prisma engines", category: .testing,
            detail: "Prisma query engine downloads.",
            target: .homePaths([".cache/prisma"])),
        CleanupRule(
            id: "cypress", name: "Cypress binaries", category: .testing,
            detail: "Cypress app downloads.",
            target: .homePaths(["Library/Caches/Cypress"])),
    ]

    static let editors: [CleanupRule] = [
        CleanupRule(
            id: "jetbrains", name: "JetBrains caches", category: .editors,
            detail: "IDE indexes and caches. Quit JetBrains IDEs first.",
            target: .homePaths(["Library/Caches/JetBrains"])),
        CleanupRule(
            id: "xcode-derived", name: "Xcode DerivedData", category: .editors,
            detail: "Xcode build products and indexes.",
            target: .homePaths(["Library/Developer/Xcode/DerivedData"])),
        CleanupRule(
            id: "xcode-device-support", name: "Xcode device support", category: .editors,
            detail: "Debug symbols for old iOS versions.",
            risk: .caution, target: .homePaths(["Library/Developer/Xcode/iOS DeviceSupport"])),
        CleanupRule(
            id: "simulator-caches", name: "Simulator caches", category: .editors,
            detail: "CoreSimulator caches.",
            target: .homePaths(["Library/Developer/CoreSimulator/Caches"])),
        CleanupRule(
            id: "vscode-cache", name: "VS Code caches", category: .editors,
            detail: "VS Code renderer and extension download caches.",
            target: .homePaths([
                "Library/Application Support/Code/Cache",
                "Library/Application Support/Code/CachedData",
                "Library/Application Support/Code/CachedExtensionVSIXs",
            ])),
        CleanupRule(
            id: "cursor-cache", name: "Cursor caches", category: .editors,
            detail: "Cursor renderer and extension download caches.",
            target: .homePaths([
                "Library/Application Support/Cursor/Cache",
                "Library/Application Support/Cursor/CachedData",
            ])),
        CleanupRule(
            id: "codex-runtimes", name: "Codex runtimes", category: .editors,
            detail: "Runtime downloads for the Codex CLI.",
            target: .homePaths([".cache/codex-runtimes"])),
    ]

    static let browsers: [CleanupRule] = [
        CleanupRule(
            id: "chrome-cache", name: "Chrome cache", category: .browsers,
            detail: "Google Chrome HTTP cache. Profiles and logins are not touched.",
            target: .homePaths(["Library/Caches/Google"])),
        CleanupRule(
            id: "brave-cache", name: "Brave cache", category: .browsers,
            detail: "Brave HTTP cache. Profiles and logins are not touched.",
            target: .homePaths(["Library/Caches/BraveSoftware"])),
        CleanupRule(
            id: "firefox-cache", name: "Firefox cache", category: .browsers,
            detail: "Firefox HTTP cache. Profiles and logins are not touched.",
            target: .homePaths(["Library/Caches/Firefox"])),
    ]

    static let system: [CleanupRule] = [
        CleanupRule(
            id: "user-logs", name: "User logs", category: .system,
            detail: "Application logs and crash reports (DiagnosticReports) in ~/Library/Logs.",
            risk: .caution, target: .homePaths(["Library/Logs"])),
        CleanupRule(
            id: "trash", name: "Trash", category: .system,
            detail: "Files already in the Trash of your home folder. Deleted directly, including locked items. Needs Full Disk Access.",
            risk: .caution, target: .homePaths([".Trash"]),
            // Not Finder's `empty trash`: it fails with -128 when one Trash entry points to a
            // volume that is gone, and it also empties other volumes' Trash, which the scan
            // does not measure. The .Trash folder itself stays, because macOS owns it. Absolute
            // paths: GNU tools from Homebrew can come first in PATH and follow symlinks differently.
            cleanCommand: "/usr/bin/chflags -R nouchg,nouappnd \"$HOME/.Trash\" 2>/dev/null; /bin/chmod -R u+w \"$HOME/.Trash\" 2>/dev/null; /usr/bin/find \"$HOME/.Trash\" -mindepth 1 -maxdepth 1 -exec /bin/rm -rf {} +",
            canDeleteWithoutCommand: false),
    ]

    static let reviewOnly: [CleanupRule] = [
        CleanupRule(
            id: "purge-area", name: "Disk Cleaner purge area", category: .reviewOnly,
            detail: "Folders a clean moved aside but could not delete, for example root-owned files from `sudo npm`. The app retries them at launch; delete them in Finder or with sudo if they stay.",
            target: .homePaths(["Library/Caches/local.disk-cleaner/purge"]), isReportOnly: true),
        CleanupRule(
            id: "claude-vm", name: "Claude desktop VM bundles", category: .reviewOnly,
            detail: "VM images for Claude's sandboxed sessions. Remove from inside the Claude app if needed.",
            target: .homePaths(["Library/Application Support/Claude/vm_bundles"]), isReportOnly: true),
        CleanupRule(
            id: "downloads", name: "Downloads", category: .reviewOnly,
            detail: "Your Downloads folder.",
            target: .homePaths(["Downloads"]), isReportOnly: true),
        CleanupRule(
            id: "virtualbox", name: "VirtualBox VMs", category: .reviewOnly,
            detail: "VirtualBox virtual machines.",
            target: .homePaths(["VirtualBox VMs"]), isReportOnly: true),
        CleanupRule(
            id: "ios-backups", name: "iOS device backups", category: .reviewOnly,
            detail: "Manage in Finder → device → Manage Backups.",
            target: .homePaths(["Library/Application Support/MobileSync/Backup"]), isReportOnly: true),
    ]
}
