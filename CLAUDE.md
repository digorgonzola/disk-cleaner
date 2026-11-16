# Disk Cleaner

Native macOS SwiftUI app (Swift 6, SwiftPM, macOS 14+) that finds and cleans developer caches. See README.md for usage.

## Commands

- `make build` / `make test` / `make app` / `make run`
- `.build/debug/disk-cleaner` prints a read-only scan report. Use it to check rule changes against the real disk.
- Only Command Line Tools are installed (no Xcode). `make test` adds the Swift Testing framework path; plain `swift test` fails with "no such module 'Testing'".

## Rules for this codebase

- New caches go in `RuleCatalog.swift` as data. Do not add per-rule logic in the cleaner.
- Never weaken `SafePath`, the worktree checks in `WorktreeInspector`, the re-inspection before `git worktree remove --force` (submodule worktrees only), or `canDeleteWithoutCommand: false` on live data (VM disks, pnpm store). Add a test for any change to them.
- Test git fixtures pass `-c commit.gpgsign=false`: the developer's global config signs commits through 1Password.
- Never run the clean path against the real home folder from tests or scripts. Tests use a temp-folder fixture.
