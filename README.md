# Disk Cleaner

A native macOS app that finds and removes developer and DevOps caches that the
built-in Storage settings do not show: Claude Code worktrees, `node_modules`,
`.terragrunt-cache`, `.terraform`, the Terraform plugin cache, the pnpm store,
uv and pre-commit caches, the Podman VM disk, and more.

## Use

```bash
make app            # builds "build/Disk Cleaner.app" (Command Line Tools are enough)
make install        # copies it to /Applications
make run            # runs from source without a bundle
.build/debug/disk-cleaner [root ...]   # read-only text report, deletes nothing
```

The app scans on launch. Pick items, then click **Clean**. A confirm sheet lists
every rule, the command it runs or the number of folders it deletes, and the
size.

- **Safe** items are pure caches. Tools rebuild them on demand.
- **Caution** items need a reinstall, rebuild or re-download (for example
  `pnpm install` after removing `node_modules`).
- **Review manually** items show a size but the app never cleans them.

By default the app selects safe caches, project artifacts not modified for 30
days, and clean worktrees not modified for 14 days.

## How cleaning works

1. A rule with a clean command runs that command through your login shell
   (`pnpm store prune`, `brew cleanup`, `uv cache clean`, `podman system prune`).
   If the tool is not installed, the app deletes the folders instead, except for
   rules marked `canDeleteWithoutCommand: false` (pnpm store, VM disks).
2. Claude Code worktrees are removed with `git worktree remove` without
   `--force`. The branch and its commits stay in the repository. A worktree
   cannot be selected when it has uncommitted or untracked changes, ignored files
   that are not build output (`.env`, local state), or a detached HEAD whose
   commits are on no branch.
   A `.terragrunt-cache` that holds a local `terraform.tfstate` cannot be
   selected either.
   Commands time out after 30 minutes, and **Stop** cancels a clean between items.
3. Everything else is deleted permanently, not moved to the Trash. `SafePath`
   only allows a delete when the path is inside your home folder and matches the
   rule exactly (a catalog path, or a folder with the rule's name).

Nested selections are counted and cleaned once: a `node_modules` inside a
selected worktree goes with the worktree.

## Project folders

The scan walks these folders for build artifacts and worktrees. Defaults are
the ones that exist of `~/repos`, `~/PycharmProjects`, `~/GolandProjects`,
`~/IdeaProjects`, `~/Projects`, `~/Developer`, `~/code`, `~/src` and similar.
Change them with **Project folders** in the sidebar.

## Add a cache

Add a `CleanupRule` to `Sources/DiskCleanerCore/RuleCatalog.swift`. Use
`.homePaths` for a fixed location and `.projectFolder(name:markers:)` for a
folder found inside projects. Run `make test`.

## Layout

| Path | Contents |
| --- | --- |
| `Sources/DiskCleanerCore` | Rules, scanner, size measurement, cleaner. No UI. |
| `Sources/DiskCleaner` | SwiftUI app. |
| `Sources/disk-cleaner-cli` | Read-only report. |
| `Tests/DiskCleanerCoreTests` | Swift Testing tests (`make test`). |
| `scripts/build-app.sh` | Wraps the release binary in an ad-hoc signed `.app`. |

## Notes

- Sizes are allocated blocks, like `du`. APFS clones (pnpm `node_modules` are
  often clones of the store) count in full, so the space freed can be less than
  the size shown.
- Measuring `~/.Trash` and some `~/Library` folders needs Full Disk Access for
  the app (System Settings → Privacy & Security → Full Disk Access).
