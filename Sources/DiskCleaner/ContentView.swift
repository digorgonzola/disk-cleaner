import DiskCleanerCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
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
                            Label(category.rawValue, systemImage: category.symbol)
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
                StatusHeader()
                Divider()
                detail
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isScanning {
                    Button("Stop", systemImage: "stop.circle") { model.stopScan() }
                } else {
                    Button("Scan", systemImage: "arrow.clockwise") { model.startScan() }
                        .disabled(model.isCleaning)
                }
                Button {
                    isConfirming = true
                } label: {
                    Label("Clean \(Format.bytes(model.selectedBytes()))…", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
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
        .sheet(isPresented: $isEditingRoots) {
            ProjectRootsView().frame(width: 520, height: 360)
        }
        .task { if !model.hasScanned && !model.isScanning { model.startScan() } }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.sidebarSelection {
        case .category(let category): CategoryView(category: category)
        default: OverviewView()
        }
    }
}

struct StatusHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            if let volume = model.volume {
                let used = Double(volume.total - volume.available) / Double(max(volume.total, 1))
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Format.bytes(volume.available)) free of \(Format.bytes(volume.total))")
                        .font(.headline)
                    SizeBar(fraction: used, color: used > 0.9 ? .red : (used > 0.8 ? .orange : .accentColor))
                        .frame(width: 260)
                }
            }
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning… \(model.measuredCount) of \(model.items.count) measured")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if model.isCleaning {
                ProgressView().controlSize(.small)
                Text("Cleaning \(model.cleaningLabel ?? "")…").foregroundStyle(.secondary).lineLimit(1)
            } else if model.hasScanned {
                Text("\(Format.bytes(model.cleanableBytes)) found · \(Format.bytes(model.selectedBytes())) selected")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let categories = model.visibleCategories.filter { $0 != .reviewOnly }
        let maxBytes = categories.map { model.totalBytes(for: $0) }.max() ?? 1
        List {
            Section("By category") {
                ForEach(categories.sorted { model.totalBytes(for: $0) > model.totalBytes(for: $1) }) { category in
                    Button {
                        model.sidebarSelection = .category(category)
                    } label: {
                        HStack(spacing: 12) {
                            Label(category.rawValue, systemImage: category.symbol).frame(width: 220, alignment: .leading)
                            SizeBar(fraction: Double(model.totalBytes(for: category)) / Double(max(maxBytes, 1)))
                            Text(Format.bytes(model.totalBytes(for: category)))
                                .monospacedDigit().frame(width: 80, alignment: .trailing)
                            Text("\(Format.bytes(model.selectedBytes(in: category))) selected")
                                .font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                        }
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
        .overlay {
            if model.items.isEmpty && !model.isScanning {
                ContentUnavailableView("No scan yet", systemImage: "internaldrive", description: Text("Press Scan to measure caches and build artifacts."))
            }
        }
    }
}

struct CategoryView: View {
    @Environment(AppModel.self) private var model
    let category: RuleCategory

    var body: some View {
        List {
            ForEach(model.rules(in: category)) { rule in
                RuleSection(rule: rule)
            }
        }
        .navigationTitle(category.rawValue)
    }
}

struct RuleSection: View {
    @Environment(AppModel.self) private var model
    let rule: CleanupRule
    @State private var isExpanded = false

    var body: some View {
        let items = model.items(for: rule)
        Section {
            if items.count == 1, let item = items.first, item.worktree == nil {
                EmptyView()
            } else {
                DisclosureGroup("\(items.count) locations", isExpanded: $isExpanded) {
                    ForEach(items) { ItemRow(item: $0) }
                }
            }
        } header: {
            header(items: items)
        }
    }

    private func header(items: [ScanItem]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Checkbox(state: model.selectionState(for: rule), isEnabled: !rule.isReportOnly) { model.toggle(rule) }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(rule.name).font(.headline)
                    RiskBadge(risk: rule.risk)
                    if let command = rule.cleanCommand {
                        Text(command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(rule.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if items.count == 1, let item = items.first {
                    Text(Format.path(item.path)).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        .contextMenu { ItemContextMenu(path: item.path) }
                }
            }
            Spacer()
            Text(Format.bytes(model.totalBytes(for: rule)))
                .font(.title3.monospacedDigit())
        }
        .textCase(nil)
        .foregroundStyle(.primary)
        .padding(.vertical, 6)
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: ScanItem
    var showsRule = false

    var body: some View {
        HStack(spacing: 10) {
            Checkbox(state: model.selection.contains(item.path) ? .all : .none, isEnabled: model.canSelect(item)) {
                model.toggle(item)
            }
            VStack(alignment: .leading, spacing: 2) {
                if showsRule, let rule = model.rulesByID[item.ruleID] {
                    Text(rule.name).font(.callout.weight(.medium))
                }
                Text(Format.path(item.path)).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                if item.worktree == nil, let blocker = item.blocker {
                    Label(blocker, systemImage: "lock.fill").font(.caption).foregroundStyle(.red)
                }
                if let worktree = item.worktree {
                    HStack(spacing: 6) {
                        if let branch = worktree.branch {
                            Label(branch, systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                        }
                        if let blocker = item.blocker {
                            Label(blocker, systemImage: "lock.fill").font(.caption).foregroundStyle(.red)
                        } else if let warning = item.warning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            Spacer()
            Text(Format.age(item.usage?.lastModified))
                .font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                .help("Newest file inside was modified then")
            Group {
                if let usage = item.usage {
                    Text(Format.bytes(usage.bytes))
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .monospacedDigit()
            .frame(width: 80, alignment: .trailing)
        }
        .contextMenu { ItemContextMenu(path: item.path) }
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
