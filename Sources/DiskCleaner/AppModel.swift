import DiskCleanerCore
import Foundation
import Observation

enum SidebarEntry: Hashable {
    case overview
    case category(RuleCategory)

    /// Stable string form, so the last section survives relaunches.
    var storageKey: String {
        if case .category(let category) = self { return category.id }
        return "overview"
    }

    init(storageKey: String?) {
        self = RuleCategory(rawValue: storageKey ?? "").map(SidebarEntry.category) ?? .overview
    }
}

@MainActor
@Observable
final class AppModel {
    let rules = RuleCatalog.all
    let rulesByID = Dictionary(uniqueKeysWithValues: RuleCatalog.all.map { ($0.id, $0) })

    var sidebarSelection: SidebarEntry? {
        didSet { UserDefaults.standard.set(sidebarSelection?.storageKey, forKey: Self.sidebarKey) }
    }
    var items: [String: ScanItem] = [:] {
        didSet { itemsByRule = Dictionary(grouping: items.values, by: \.ruleID).mapValues { $0.sorted { $0.bytes > $1.bytes } } }
    }
    private(set) var itemsByRule: [String: [ScanItem]] = [:]
    var selection: Set<String> = []
    var isScanning = false
    var isCleaning = false
    var hasScanned = false
    var measuredCount = 0
    var volume = DiskUsage.volumeSpace()
    var outcomes: [CleanOutcome] = []
    var freedBytes: Int64?
    var cleaningLabel: String?

    var projectRoots: [String] {
        didSet { UserDefaults.standard.set(projectRoots, forKey: Self.rootsKey) }
    }

    private static let rootsKey = "projectRoots"
    private static let sidebarKey = "sidebarSelection"
    private static let staleDays: [RuleCategory: Double] = [.worktrees: 14]
    private static let defaultStaleDays = 30.0
    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?

    init() {
        projectRoots = UserDefaults.standard.stringArray(forKey: Self.rootsKey) ?? Scanner.defaultProjectRoots()
        sidebarSelection = SidebarEntry(storageKey: UserDefaults.standard.string(forKey: Self.sidebarKey))
    }

    // MARK: Scanning

    func startScan() {
        scanTask?.cancel()
        scanTask = Task { await scan() }
    }

    func stopScan() { scanTask?.cancel() }

    private func scan() async {
        items = [:]
        selection = []
        measuredCount = 0
        isScanning = true
        volume = DiskUsage.volumeSpace()
        defer {
            isScanning = false
            hasScanned = true
        }

        let stream = Scanner(projectRoots: projectRoots).scan()
        var pending: [ScanEvent] = []
        var lastFlush = Date()
        for await event in stream {
            pending.append(event)
            // Apply in batches so thousands of size updates do not re-render the list each time.
            // New locations are applied at once: the next event can be minutes away.
            let isDiscovery = if case .discovered = event { true } else { false }
            if isDiscovery || Date().timeIntervalSince(lastFlush) > 0.25 {
                apply(pending)
                pending.removeAll()
                lastFlush = Date()
            }
        }
        apply(pending)
        guard !Task.isCancelled else { return }
        selection = Set(items.values.filter(isSelectedByDefault).map(\.path))
    }

    private func apply(_ events: [ScanEvent]) {
        guard !events.isEmpty else { return }
        var items = self.items
        defer { self.items = items }
        for event in events {
            switch event {
            case .discovered(let found):
                for item in found { items[item.path] = item }
            case .measured(let path, let usage):
                items[path]?.usage = usage
                measuredCount += 1
            case .worktreeInspected(let path, let info):
                items[path]?.worktree = info
            case .finished:
                break
            }
        }
    }

    private func isSelectedByDefault(_ item: ScanItem) -> Bool {
        guard let rule = rulesByID[item.ruleID], !rule.isReportOnly, item.blocker == nil, item.warning == nil,
              item.bytes > 0
        else { return false }
        if rule.risk == .safe { return true }
        guard rule.category != .containers, let modified = item.usage?.lastModified else { return false }
        let days = Self.staleDays[rule.category] ?? Self.defaultStaleDays
        return Date().timeIntervalSince(modified) > days * 86_400
    }

    // MARK: Queries

    /// Categories with findings, largest first; "Review manually" always last.
    var visibleCategories: [RuleCategory] {
        let found = RuleCategory.allCases.filter { category in
            rules.contains { $0.category == category && !items(for: $0).isEmpty }
        }
        let sizes = Dictionary(uniqueKeysWithValues: found.map { ($0, totalBytes(for: $0)) })
        return found.sorted { lhs, rhs in
            if (lhs == .reviewOnly) != (rhs == .reviewOnly) { return rhs == .reviewOnly }
            return sizes[lhs, default: 0] > sizes[rhs, default: 0]
        }
    }

    /// Short human name for a row: the worktree name, the project a build folder belongs to,
    /// or the rule name for fixed cache locations.
    func title(for item: ScanItem) -> String {
        if item.worktree != nil { return (item.path as NSString).lastPathComponent }
        guard let rule = rulesByID[item.ruleID], case .projectFolder = rule.target else {
            return rulesByID[item.ruleID]?.name ?? item.path
        }
        let root = projectRoots.first { item.path.hasPrefix($0 + "/") }
        let relative = root.map { String(item.path.dropFirst($0.count + 1)) } ?? Format.path(item.path)
        return (relative as NSString).deletingLastPathComponent
            .replacingOccurrences(of: "/.claude/worktrees/", with: " › ")
    }

    var selectedCount: Int { selection.count }

    /// Free space after cleaning the current selection, ignoring APFS clone sharing.
    var projectedAvailable: Int64? { volume.map { $0.available + selectedBytes() } }

    func rules(in category: RuleCategory) -> [CleanupRule] {
        rules.filter { $0.category == category && !items(for: $0).isEmpty }
            .sorted { totalBytes(for: $0) > totalBytes(for: $1) }
    }

    func items(for rule: CleanupRule) -> [ScanItem] { itemsByRule[rule.id] ?? [] }

    func totalBytes(for rule: CleanupRule) -> Int64 { items(for: rule).reduce(0) { $0 + $1.bytes } }

    func totalBytes(for category: RuleCategory) -> Int64 {
        let paths = items.values.filter { rulesByID[$0.ruleID]?.category == category }.map(\.path)
        return bytes(of: paths)
    }

    func selectedBytes(in category: RuleCategory? = nil) -> Int64 {
        let paths = selection.filter { path in
            category == nil || items[path].flatMap { rulesByID[$0.ruleID]?.category } == category
        }
        return bytes(of: Array(paths))
    }

    var cleanableBytes: Int64 {
        let paths = items.values.filter { rulesByID[$0.ruleID]?.isReportOnly == false }.map(\.path)
        return bytes(of: paths)
    }

    /// Sums sizes without counting a folder twice when it sits inside another listed folder.
    private func bytes(of paths: [String]) -> Int64 {
        PathOverlap.outermost(paths).reduce(0) { $0 + (items[$1]?.bytes ?? 0) }
    }

    var largestItems: [ScanItem] {
        let cleanable = items.values.filter { rulesByID[$0.ruleID]?.isReportOnly == false }
        return Array(cleanable.sorted { $0.bytes > $1.bytes }.prefix(12))
    }

    var selectedItems: [ScanItem] { selection.compactMap { items[$0] } }

    // MARK: Selection

    func canSelect(_ item: ScanItem) -> Bool {
        item.blocker == nil && rulesByID[item.ruleID]?.isReportOnly == false
    }

    func toggle(_ item: ScanItem) {
        guard canSelect(item) else { return }
        if selection.contains(item.path) { selection.remove(item.path) } else { selection.insert(item.path) }
    }

    enum SelectionState { case none, some, all }

    func selectionState(for rule: CleanupRule) -> SelectionState {
        let selectable = items(for: rule).filter(canSelect)
        let selected = selectable.filter { selection.contains($0.path) }.count
        if selected == 0 { return .none }
        return selected == selectable.count ? .all : .some
    }

    func setSelection(_ isSelected: Bool, in category: RuleCategory) {
        let paths = rules(in: category).flatMap(items(for:)).filter(canSelect).map(\.path)
        if isSelected { selection.formUnion(paths) } else { selection.subtract(paths) }
    }

    func toggle(_ rule: CleanupRule) {
        let paths = items(for: rule).filter(canSelect).map(\.path)
        if selectionState(for: rule) == .all { selection.subtract(paths) } else { selection.formUnion(paths) }
    }

    // MARK: Cleaning

    private func clean() async {
        let toClean = selectedItems
        guard !toClean.isEmpty else { return }
        isCleaning = true
        outcomes = []
        freedBytes = nil
        let before = DiskUsage.volumeSpace()?.available

        await Cleaner().clean(toClean) { outcome in
            await MainActor.run {
                self.outcomes.append(outcome)
                self.cleaningLabel = outcome.label
            }
        }

        volume = DiskUsage.volumeSpace()
        if let before, let after = volume?.available { freedBytes = after - before }
        await refresh(toClean)
        cleaningLabel = nil
        isCleaning = false
    }

    func cancelClean() { cleanTask?.cancel() }

    func startClean() {
        cleanTask = Task { await clean() }
    }

    /// Re-measures only what was cleaned, instead of a full rescan that can take minutes.
    private func refresh(_ cleaned: [ScanItem]) async {
        var updated = items
        for item in cleaned {
            selection.remove(item.path)
            if FileManager.default.fileExists(atPath: item.path) {
                let path = item.path
                let protectedNames = rulesByID[item.ruleID]?.protectedFileNames ?? []
                updated[path]?.usage = await Task.detached { DiskUsage.usage(of: path, protectedNames: protectedNames) }.value
            } else {
                // Removing a worktree also removes everything found inside it.
                updated = updated.filter { !($0.key == item.path || $0.key.hasPrefix(item.path + "/")) }
            }
        }
        items = updated
    }
}
