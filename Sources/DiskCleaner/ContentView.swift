import DiskCleanerCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    @State private var isConfirming = false
    @State private var isShowingResults = false
    @State private var isEditingRoots = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.sidebarSelection) {
                Label("Overview", systemImage: "chart.bar.xaxis").tag(SidebarEntry.overview)
                Section("Found") {
                    ForEach(model.visibleCategories) { category in
                        HStack {
                            Label {
                                Text(category.rawValue)
                            } icon: {
                                Image(systemName: category.symbol).foregroundStyle(category.tint)
                            }
                            Spacer()
                            Text(Format.bytes(model.totalBytes(for: category)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .tag(SidebarEntry.category(category))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260)
            .safeAreaInset(edge: .bottom) {
                Button {
                    isEditingRoots = true
                } label: {
                    Label("Project folders (\(model.projectRoots.count))", systemImage: "folder.badge.gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
        } detail: {
            VStack(spacing: 0) {
                if let release = updater.available {
                    UpdateBanner(release: release)
                    Divider()
                }
                SummaryHeader()
                Divider()
                detail
            }
        }
        .navigationTitle(navigationTitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isScanning {
                    Button("Stop", systemImage: "stop.circle") { model.stopScan() }
                        .help("Stop scanning")
                } else {
                    Button("Rescan", systemImage: "arrow.clockwise") { model.startScan() }
                        .disabled(model.isCleaning)
                        .help("Scan again (⌘R)")
                }
                Button {
                    isConfirming = true
                } label: {
                    Label(model.selection.isEmpty ? "Clean…" : "Clean \(Format.bytes(model.selectedBytes()))…", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.selection.isEmpty || model.isScanning || model.isCleaning)
            }
        }
        .sheet(isPresented: $isConfirming) {
            ConfirmCleanView {
                isConfirming = false
                isShowingResults = true
                model.startClean()
            }
        }
        .sheet(isPresented: $isShowingResults) { ResultsView() }
        .alert(
            "Software Update",
            isPresented: Binding(
                get: { updater.manualResultPlace == .window && updater.manualResult != nil },
                set: { if !$0 { updater.manualResult = nil } }
            )
        ) {
            Button("OK") { updater.manualResult = nil }
        } message: {
            Text(updater.manualResult ?? "")
        }
        .sheet(isPresented: $isEditingRoots) {
            ProjectRootsView().frame(width: 520, height: 360)
        }
        .task { if !model.hasScanned && !model.isScanning { model.startScan() } }
    }

    private var navigationTitle: String {
        if case .category(let category) = model.sidebarSelection { return category.rawValue }
        return "Disk Cleaner"
    }

    @ViewBuilder
    private var detail: some View {
        switch model.sidebarSelection {
        case .category(let category): CategoryView(category: category)
        default: OverviewView()
        }
    }
}

// MARK: Header

struct SummaryHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            if let volume = model.volume {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(Format.bytes(volume.available)) free").font(.title2.bold())
                        Text("of \(Format.bytes(volume.total))").foregroundStyle(.secondary)
                    }
                    DiskBar(total: volume.total, available: volume.available, selected: model.selectedBytes())
                        .frame(width: 320)
                    Group {
                        if model.selectedBytes() > 0, let projected = model.projectedAvailable {
                            Label("Up to \(Format.bytes(projected)) free after cleaning", systemImage: "arrow.right")
                                .foregroundStyle(.green)
                        } else {
                            Text(" ")
                        }
                    }
                    .font(.caption)
                }
            }

            Divider().frame(height: 56)

            Stat(title: "Found", value: Format.bytes(model.cleanableBytes),
                 detail: "\(model.items.count.formatted()) locations")
            Stat(title: "Selected", value: Format.bytes(model.selectedBytes()),
                 detail: "\(model.selectedCount.formatted()) item\(model.selectedCount == 1 ? "" : "s")",
                 color: model.selection.isEmpty ? .secondary : .green)

            Spacer(minLength: 12)
            ActivityStatus().frame(width: 230, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// Disk usage as one bar: used space, with the part the selection would free in green.
struct DiskBar: View {
    let total: Int64
    let available: Int64
    let selected: Int64

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let scale = width / Double(max(total, 1))
            let usedWidth = Double(total - available) * scale
            let selectedWidth = min(usedWidth, Double(selected) * scale)
            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary)
                Rectangle().fill(usedColor.gradient).frame(width: usedWidth)
                Rectangle().fill(Color.green.gradient)
                    .frame(width: selectedWidth)
                    .offset(x: usedWidth - selectedWidth)
            }
            .clipShape(Capsule())
        }
        .frame(height: 10)
        .accessibilityLabel("\(Format.bytes(available)) free of \(Format.bytes(total))")
    }

    private var usedColor: Color {
        let used = Double(total - available) / Double(max(total, 1))
        return used > 0.9 ? .red : (used > 0.8 ? .orange : .accentColor)
    }
}

struct Stat: View {
    let title: String
    let value: String
    let detail: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit()).foregroundStyle(color)
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

struct ActivityStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if model.isCleaning {
                ProgressView().controlSize(.small)
                Text(model.isMeasuringCleanSizes ? "Measuring sizes…" : "Cleaning \(model.cleaningLabel ?? "")…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if model.isScanning {
                if model.measuredCount == 0 {
                    ProgressView().controlSize(.small)
                    Text("Finding caches…").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView(value: Double(model.measuredCount), total: Double(max(model.items.count, 1)))
                    Text("Measuring \(model.measuredCount.formatted()) of \(model.items.count.formatted())")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else if model.hasScanned {
                Label("Scan complete", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Overview

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let categories = model.visibleCategories.filter { $0 != .reviewOnly }
        let maxBytes = Double(max(categories.map { model.totalBytes(for: $0) }.max() ?? 1, 1))
        List {
            if !categories.isEmpty {
                Section("Where the space is") {
                ForEach(categories) { category in
                    let total = model.totalBytes(for: category)
                    let selected = model.selectedBytes(in: category)
                    Button {
                        model.sidebarSelection = .category(category)
                    } label: {
                        HStack(spacing: 12) {
                            Label {
                                Text(category.rawValue)
                            } icon: {
                                Image(systemName: category.symbol).foregroundStyle(category.tint)
                            }
                            .frame(width: 210, alignment: .leading)
                            SizeBar(fraction: Double(total) / maxBytes, selectedFraction: Double(selected) / maxBytes,
                                    color: category.tint, height: 8)
                            Text(Format.bytes(total))
                                .font(.body.monospacedDigit()).frame(width: 84, alignment: .trailing)
                            Text(selected > 0 ? "\(Format.bytes(selected)) selected" : "")
                                .font(.caption.monospacedDigit()).foregroundStyle(.green)
                                .frame(width: 120, alignment: .trailing)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    }
                }
                Section("Largest items") {
                    ForEach(model.largestItems) { item in
                        ItemRow(item: item, showsRule: true)
                    }
                }
            }
        }
        .overlay { ScanPlaceholder() }
    }
}

struct ScanPlaceholder: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.items.isEmpty {
            if model.isScanning {
                ContentUnavailableView {
                    Label("Looking for caches…", systemImage: "magnifyingglass")
                } description: {
                    Text("Checking \(model.projectRoots.count) project folders and known cache locations.")
                }
            } else {
                ContentUnavailableView("No scan yet", systemImage: "internaldrive",
                                       description: Text("Press Rescan to measure caches and build artifacts."))
            }
        }
    }
}

// MARK: Category

struct CategoryView: View {
    @Environment(AppModel.self) private var model
    let category: RuleCategory
    @State private var showingAll: Set<String> = []

    private static let previewCount = 25

    var body: some View {
        List {
            HStack {
                Label(category.rawValue, systemImage: category.symbol)
                    .font(.title3.bold())
                    .foregroundStyle(category.tint)
                Spacer()
                if category != .reviewOnly {
                    Button("Select all") { model.setSelection(true, in: category) }
                    Button("Select none") { model.setSelection(false, in: category) }
                }
            }
            .buttonStyle(.borderless)
            .listRowSeparator(.hidden)

            // One section per rule keeps rows lazy: node_modules alone can be over a thousand.
            ForEach(model.rules(in: category)) { rule in
                let items = model.items(for: rule)
                let listsItems = items.count > 1 || items.first?.worktree != nil
                Section {
                    if listsItems {
                        let isShowingAll = showingAll.contains(rule.id)
                        ForEach(isShowingAll ? items : Array(items.prefix(Self.previewCount))) { item in
                            ItemRow(item: item)
                        }
                        if items.count > Self.previewCount {
                            Button(isShowingAll ? "Show fewer" : "Show all \(items.count.formatted()) locations") {
                                if isShowingAll { showingAll.remove(rule.id) } else { showingAll.insert(rule.id) }
                            }
                            .buttonStyle(.link)
                            .padding(.leading, 56)
                        }
                    }
                } header: {
                    RuleHeader(rule: rule)
                }
            }
        }
        .overlay { ScanPlaceholder() }
    }
}

struct RuleHeader: View {
    @Environment(AppModel.self) private var model
    let rule: CleanupRule

    var body: some View {
        header(items: model.items(for: rule))
            .textCase(nil)
            .foregroundStyle(.primary)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func header(items: [ScanItem]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Checkbox(state: model.selectionState(for: rule), isEnabled: !rule.isReportOnly) { model.toggle(rule) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(rule.name).font(.headline)
                    if !rule.isReportOnly { RiskBadge(risk: rule.risk) }
                    if let command = rule.cleanCommand {
                        Text(command)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                            .lineLimit(1)
                            .help("Cleaned by running this command")
                    }
                }
                Text(rule.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(rule.detail)
                if items.count == 1, let item = items.first, item.worktree == nil {
                    Text(Format.path(item.path)).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        .contextMenu { ItemContextMenu(path: item.path) }
                    if let blocker = item.blocker {
                        Label(blocker, systemImage: "lock.fill").font(.caption).foregroundStyle(.red)
                    }
                    ReclaimableNote(item: item).font(.caption)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(model.totalBytes(for: rule)))
                    .font(.title3.monospacedDigit().weight(.semibold))
                if items.count > 1 {
                    let selected = items.filter { model.selection.contains($0.path) }.count
                    Text("\(items.count.formatted()) found" + (selected > 0 ? " · \(selected.formatted()) selected" : ""))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Rows

/// For a rule whose tool estimates what cleaning frees: that estimate against the folder size.
struct ReclaimableNote: View {
    let item: ScanItem

    var body: some View {
        switch item.reclaimable {
        case .pending:
            Label("Asking the tool what cleaning can free…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .bytes(let bytes):
            let image = item.usage.map { " of the \(Format.bytes($0.bytes)) disk image" } ?? ""
            Label(bytes == 0 ? "The tool reports nothing to free" + (item.usage.map { " in the \(Format.bytes($0.bytes)) disk image" } ?? "")
                             : "Can free about \(Format.bytes(bytes))" + image,
                  systemImage: "internaldrive")
                .foregroundStyle(.secondary)
        case .unknown(let reason):
            let text = "Cannot tell what cleaning frees: \(reason)"
            Label(text, systemImage: "questionmark.circle")
                .foregroundStyle(.orange)
                .help(text)
        case nil:
            EmptyView()
        }
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: ScanItem
    var showsRule = false

    var body: some View {
        let rule = model.rulesByID[item.ruleID]
        let tint = rule?.category.tint ?? .secondary
        let title = model.title(for: item)
        HStack(spacing: 10) {
            Checkbox(state: model.selection.contains(item.path) ? .all : .none, isEnabled: model.canSelect(item)) {
                model.toggle(item)
            }
            Image(systemName: rule?.category.symbol ?? "folder")
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if showsRule, let rule {
                        if rule.name != title { Tag(text: rule.name, color: tint) }
                        if rule.risk == .caution { RiskBadge(risk: .caution) }
                    }
                }
                Text(Format.path(item.path))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusLine
            }
            Spacer(minLength: 12)
            Text(Format.age(item.usage?.lastModified))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
                .help("Newest file inside was modified then")
            Group {
                if item.usage != nil, item.reclaimable != .pending {
                    Text(Format.bytes(item.bytes))
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.body.monospacedDigit().weight(.semibold))
            .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(item) }
        .contextMenu { ItemContextMenu(path: item.path) }
    }

    @ViewBuilder
    private var statusLine: some View {
        let branch = item.worktree?.branch
        if branch != nil || item.blocker != nil || item.warning != nil || item.reclaimable != nil {
            HStack(spacing: 8) {
                if let branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                if let blocker = item.blocker {
                    Label(blocker, systemImage: "lock.fill")
                        .foregroundStyle(.red)
                        .help(blocker)
                } else if let warning = item.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(warning)
                }
                ReclaimableNote(item: item)
            }
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.tail)
        }
    }
}

struct ItemContextMenu: View {
    let path: String

    var body: some View {
        Button("Reveal in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
    }
}
