<img src="Resources/AppIcon-1024.png" alt="" width="128" align="right">

# Disk Cleaner

A native macOS app that finds and removes developer and DevOps caches that the
built-in Storage settings do not show: Claude Code worktrees, `node_modules`,
`.terragrunt-cache`, `.terraform`, the Terraform plugin cache, the pnpm store,
uv and pre-commit caches, the Podman VM disk, and more.

## Install

Download `DiskCleaner-<version>.zip` from the
[latest release](https://github.com/digorgonzola/disk-cleaner/releases/latest),
unzip it and move **Disk Cleaner** to `/Applications`. The app runs on Apple
silicon and Intel Macs with macOS 14 or later.

The app has an ad-hoc signature, not a Developer ID signature, so macOS blocks
the first launch of a downloaded copy. Either open System Settings → Privacy &
Security and click **Open Anyway**, or remove the quarantine flag:

```bash
xattr -dr com.apple.quarantine "/Applications/Disk Cleaner.app"
```

Each release lists a SHA-256 checksum for the zip.

### Updates

At launch and once a day, the app asks GitHub for the latest release
(`api.github.com/repos/digorgonzola/disk-cleaner/releases/latest`). Nothing else
is sent. When a newer version exists, a banner in the window and an item in the
menu bar menu link to the download, and macOS shows one notification for that
version. **Skip This Version** hides it until the next release. Turn the check
off in **Settings** (⌘,), or check now with **Disk Cleaner → Check for
Updates…**.

The app only opens https links on github.com under this repository's releases,
and only accepts plain `vX.Y.Z` release tags.

## Build from source

```bash
make app            # builds a universal "build/Disk Cleaner.app" (Command Line Tools are enough)
make install        # copies it to /Applications
make run            # runs from source without a bundle
make release        # also packs build/DiskCleaner-<version>.zip and its .sha256
.build/debug/disk-cleaner [root ...]   # read-only text report, deletes nothing
```

## Use

The app scans on launch. Pick items, then click **Clean**. A confirm sheet lists
every rule, the command it runs or the number of folders it deletes, and the
size.

- **Safe** items are pure caches. Tools rebuild them on demand.
- **Caution** items need a reinstall, rebuild or re-download (for example
  `pnpm install` after removing `node_modules`).
- **Review manually** items show a size but the app never cleans them.

By default the app selects safe caches, project artifacts not modified for 30
days, and clean worktrees not modified for 14 days.

The menu bar shows the free space on the start-up disk, refreshed every 30
seconds, with a warning symbol below 10% free. The app keeps running in the
menu bar when you close its window. Turn the menu bar item off in
**Settings** (⌘,).

## How cleaning works

1. A rule with a clean command runs that command through your login shell
   (`pnpm store prune`, `brew cleanup`, `uv cache clean`, `podman system prune`).
   If the tool is not installed, the app deletes the folders instead, except for
   rules marked `canDeleteWithoutCommand: false` (pnpm store, VM disks).
2. Claude Code worktrees are removed with `git worktree remove` without
   `--force`. The branch and its commits stay in the repository. A worktree
   cannot be selected when it has uncommitted or untracked changes, or a
   detached HEAD whose commits are on no branch. A worktree with ignored files
   that are not build output (`.env`, local state) can be selected, but is not
   preselected and is flagged in the confirm sheet.
   Git refuses to remove a worktree with checked-out submodules. The submodules'
   git data lives inside the worktree's admin folder and goes with it, so the
   app uses `--force` only when every submodule (nested ones too) has no
   uncommitted changes, no stashes, and no commits missing from a remote. It
   checks again just before removal, so changes made after the scan still
   block it.
   A `.terragrunt-cache` that holds a local `terraform.tfstate` cannot be
   selected either.
   A locked worktree (`git worktree lock`) cannot be selected.
3. Everything else is deleted permanently, not moved to the Trash. `SafePath`
   only allows a delete when the path is inside your home folder and matches the
   rule exactly (a catalog path, or a folder with the rule's name).

### Speed

Clean commands, worktree removals and deletes run at the same time. A deleted
folder first moves into a purge area (`~/Library/Caches/local.disk-cleaner/purge`)
with one rename, so it leaves its place at once. A pool of 4 then deletes the
files: on APFS, 4 parallel deletes were fastest, and 8 or 16 were slower. For a
worktree, the build output that git lists as ignored moves to the pool too, but
is only deleted after `git worktree remove` succeeds. If git refuses, it moves
back.

**Stop** starts no new work and moves every folder that is not yet deleted back
to its place. A folder that cannot be deleted (for example root-owned files)
also moves back and is reported. Commands time out after 30 minutes.

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
| `scripts/build-app.sh` | Builds the universal, ad-hoc signed `.app` and the release zip. |
| `scripts/make-icon.swift` | Draws `Resources/AppIcon.icns` (`make icon`). |
| `.github/workflows` | CI, release-please, release build, PR title check. |

## Releases

Releases are automated with [release-please](https://github.com/googleapis/release-please):

1. Commits on `main` follow Conventional Commits (`feat:`, `fix:`, …). PR titles
   are checked, because squash merges use them as the commit subject.
2. release-please keeps a release PR open with the next version and the
   changelog. Merging it tags `vX.Y.Z` and creates the GitHub release.
3. The tag runs `release.yml` on a macOS runner. It runs the tests, builds the
   universal app and attaches `DiskCleaner-X.Y.Z.zip` and its `.sha256` to the
   release.

release-please runs as a GitHub App, because GitHub starts no workflows for tags
that `GITHUB_TOKEN` creates. The repo needs the App installed, the
`RELEASE_PLEASE_CLIENT_ID` Actions variable and the
`RELEASE_PLEASE_APP_PRIVATE_KEY` Actions secret.

## Notes

- Sizes are allocated blocks, like `du`. APFS clones (pnpm `node_modules` are
  often clones of the store) count in full, so the space freed can be less than
  the size shown.
- Measuring `~/.Trash` and some `~/Library` folders needs Full Disk Access for
  the app (System Settings → Privacy & Security → Full Disk Access).

## Licence

Apache License 2.0. See [LICENSE](LICENSE).
