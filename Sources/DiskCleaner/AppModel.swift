import DiskCleanerCore
import Foundation
import Observation
import os

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
    /// Outcomes a clean reports when nothing fails; the progress total.
    var expectedOutcomes = 0
    var freedBytes: Int64?
    var cleaningLabel: String?

    var projectRoots: [String] {
        didSet { UserDefaults.standard.set(projectRoots, forKey: Self.rootsKey) }
    }

    /// Below this share of free space the menu bar shows a warning symbol.
    static let lowSpaceFraction = 0.1
    private static let volumeRefreshInterval: Duration = .seconds(30)
    nonisolated static let log = Logger(subsystem: "local.disk-cleaner", category: "clean")
    private static let rootsKey = "projectRoots"
    private static let sidebarKey = "sidebarSelection"
    private static let staleDays: [RuleCategory: Double] = [.worktrees: 14]
    private static let defaultStaleDays = 30.0
    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?

    init() {
        projectRoots = UserDefaults.standard.stringArray(forKey: Self.rootsKey) ?? Scanner.defaultProjectRoots()
        sidebarSelection = SidebarEntry(storageKey: UserDefaults.standard.string(forKey: Self.sidebarKey))
        // Folders a crash left in the purge area. Ones that still fail stay there and show up
        // in the next scan as a "Review manually" item.
        Task.detached(priority: .utility) {
            for (path, reason) in await Purger().recoverLeftovers() {
                AppModel.log.warning("Could not delete \(path, privacy: .public): \(reason, privacy: .public)")
            }
        }
        // Keeps the menu bar figure current while the app sits in the background.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.volumeRefreshInterval)
                self?.volume = DiskUsage.volumeSpace()
            }
        }
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
            case .estimated(let path, let reclaimable):
                items[path]?.reclaimable = reclaimable
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
        let cleaner = Cleaner()
        isCleaning = true
        outcomes = []
        expectedOutcomes = cleaner.expectedOutcomeCount(toClean)
        freedBytes = 0
        let before = DiskUsage.volumeSpace()?.available

        // The cleaner reports from many tasks at once. Collect outcomes off the main actor
        // and publish them a few times a second: one list update per item made big cleans
        // spend more time re-rendering the sheet than deleting.
        let buffer = OutcomeBuffer()
        let publisher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await self?.publish(buffer.drain(), freedSince: before)
            }
        }
        await cleaner.clean(toClean) { outcome in buffer.append(outcome) }
        publisher.cancel()
        await publish(buffer.drain(), freedSince: before)

        await refresh(toClean)
        cleaningLabel = nil
        isCleaning = false
    }

    private func publish(_ batch: [CleanOutcome], freedSince before: Int64?) async {
        // The volume query can block, so it stays off the main actor.
        volume = await Task.detached { DiskUsage.volumeSpace() }.value
        if let before, let after = volume?.available { freedBytes = after - before }
        guard !batch.isEmpty else { return }
        outcomes += batch
        cleaningLabel = batch.last?.label
    }

    func cancelClean() { cleanTask?.cancel() }

    func startClean() {
        cleanTask = Task { await clean() }
    }

    /// Re-measures only what was cleaned, instead of a full rescan that can take minutes.
    private func refresh(_ cleaned: [ScanItem]) async {
        selection.subtract(cleaned.map(\.path))
        let remaining = cleaned.filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { ($0.path, rulesByID[$0.ruleID]?.protectedFileNames ?? []) }

        let measured = await Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: (String, Usage).self) { group in
                for (path, names) in remaining {
                    group.addTask { (path, DiskUsage.usage(of: path, protectedNames: names)) }
                }
                var results: [String: Usage] = [:]
                for await (path, usage) in group { results[path] = usage }
                return results
            }
        }.value

        // Removing a folder also removes everything found inside it.
        // Drop anything at or under a cleaned path that no longer exists. That includes a
        // node_modules moved out of a worktree whose removal git then refused. Walking each
        // item's few parents avoids comparing every pair.
        let cleanedRoots = Set(cleaned.map(\.path))
        var updated = items.filter { entry in
            var path = entry.key
            while path.count > 1 {
                if cleanedRoots.contains(path) { return FileManager.default.fileExists(atPath: entry.key) }
                path = (path as NSString).deletingLastPathComponent
            }
            return true
        }
        for (path, usage) in measured { updated[path]?.usage = usage }
        let queries = cleaned.compactMap { item in rulesByID[item.ruleID]?.reclaimable.map { (item.path, $0) } }
        for (path, _) in queries { updated[path]?.reclaimable = .pending }
        items = updated
        reestimate(queries)
    }

    /// Asks the tools again without holding up the end of the clean: `system df` can take
    /// half a minute.
    private func reestimate(_ queries: [(path: String, query: ReclaimableQuery)]) {
        for (path, query) in queries {
            Task { [weak self] in
                // Detached: a stopped clean must not turn into an "unknown" answer.
                let answer = await Task.detached(priority: .utility) { await query.estimate() }.value
                guard let self, self.items[path]?.reclaimable == .pending else { return }
                self.items[path]?.reclaimable = answer ?? .unknown(reason: "the check was stopped")
            }
        }
    }
}

/// Thread-safe outcome collector; the cleaner calls it from many tasks at once.
final class OutcomeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CleanOutcome] = []

    func append(_ outcome: CleanOutcome) { lock.withLock { pending.append(outcome) } }

    func drain() -> [CleanOutcome] {
        lock.withLock {
            defer { pending.removeAll() }
            return pending
        }
    }
}
