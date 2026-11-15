import DiskCleanerCore
import Foundation

// Read-only report: lists what the app would find, largest first. It never deletes anything.
let arguments = CommandLine.arguments.dropFirst()
let roots = arguments.isEmpty ? Scanner.defaultProjectRoots() : arguments.map { ($0 as NSString).expandingTildeInPath }
let rules = Dictionary(uniqueKeysWithValues: RuleCatalog.all.map { ($0.id, $0) })
let home = NSHomeDirectory()

func format(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
func pad(_ text: String, _ width: Int) -> String { text.count >= width ? text : String(repeating: " ", count: width - text.count) + text }

var items: [String: ScanItem] = [:]
let started = Date()
for await event in Scanner(projectRoots: roots).scan() {
    switch event {
    case .discovered(let found): found.forEach { items[$0.path] = $0 }
    case .measured(let path, let usage): items[path]?.usage = usage
    case .worktreeInspected(let path, let info): items[path]?.worktree = info
    case .finished: break
    }
}

print("Scanned \(items.count) locations in \(Int(Date().timeIntervalSince(started)))s. Project roots: \(roots.joined(separator: ", "))\n")
let byRule = Dictionary(grouping: items.values, by: \.ruleID)
for (ruleID, ruleItems) in byRule.sorted(by: { $0.value.reduce(0) { $0 + $1.bytes } > $1.value.reduce(0) { $0 + $1.bytes } }) {
    guard let rule = rules[ruleID] else { continue }
    let total = ruleItems.reduce(0) { $0 + $1.bytes }
    let tag = rule.isReportOnly ? "review" : rule.risk.rawValue
    print("\(pad(format(total), 10))  \(rule.name) [\(rule.category.rawValue), \(tag)]  ×\(ruleItems.count)")
    for item in ruleItems.sorted(by: { $0.bytes > $1.bytes }).prefix(ruleItems.count > 1 ? 5 : 0) {
        let shown = item.path.hasPrefix(home) ? "~" + item.path.dropFirst(home.count) : item.path
        let blocker = item.blocker.map { "  ⛔ \($0)" } ?? item.warning.map { "  ⚠ \($0)" } ?? ""
        print("\(pad(format(item.bytes), 22))  \(shown)\(blocker)")
    }
}
let cleanable = PathOverlap.outermost(items.values.filter { rules[$0.ruleID]?.isReportOnly == false }.map(\.path))
print("\nTotal cleanable (no double counting): \(format(cleanable.reduce(0) { $0 + (items[$1]?.bytes ?? 0) }))")
let worktrees = items.values.filter { $0.worktree != nil }
print("Worktrees: \(worktrees.count) total, \(worktrees.filter { $0.blocker != nil }.count) blocked, \(worktrees.filter { $0.blocker == nil && $0.warning != nil }.count) with warnings")
for (reason, count) in Dictionary(grouping: worktrees.compactMap(\.worktree?.problems).flatMap { $0 }.map { $0.components(separatedBy: " (").first ?? $0 }, by: { $0 }).mapValues(\.count).sorted(by: { $0.value > $1.value }).prefix(6) {
    print("  \(count)× \(reason)")
}
