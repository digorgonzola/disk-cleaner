import AppKit
import DiskCleanerCore
import SwiftUI

struct ConfirmCleanView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onConfirm: () -> Void

    var body: some View {
        let byRule = Dictionary(grouping: model.selectedItems, by: \.ruleID)
        let rules = byRule.keys.compactMap { model.rulesByID[$0] }.sorted { $0.name < $1.name }
        VStack(alignment: .leading, spacing: 14) {
            Text("Clean \(Format.bytes(model.selectedBytes()))?").font(.title2.bold())
            Text("Files are deleted, not moved to the Trash. Where a tool has its own clean command, the app runs that instead.")
                .foregroundStyle(.secondary)
            List(rules) { rule in
                let items = byRule[rule.id] ?? []
                HStack {
                    VStack(alignment: .leading) {
                        HStack {
                            Text(rule.name).font(.headline)
                            RiskBadge(risk: rule.risk)
                        }
                        Text(rule.cleanCommand.map { "Runs: \($0)" } ?? "Deletes \(items.count) folder\(items.count == 1 ? "" : "s")")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Format.bytes(items.reduce(0) { $0 + $1.bytes })).monospacedDigit()
                }
            }
            .frame(minHeight: 220)
            let warned = model.selectedItems.filter { $0.warning != nil }
            if !warned.isEmpty {
                Label("\(warned.count) worktree\(warned.count == 1 ? "" : "s") also hold ignored files that are not build output (for example .env). They will be deleted.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if rules.contains(where: { $0.risk == .caution }) {
                Label("Items marked Caution need a reinstall, rebuild or re-download afterwards.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Clean", role: .destructive, action: onConfirm).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 480)
    }
}

struct ResultsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.isCleaning ? "Cleaning…" : "Done").font(.title2.bold())
                if model.isCleaning { ProgressView().controlSize(.small) }
                Spacer()
                if let freed = model.freedBytes {
                    Text("\(Format.bytes(max(freed, 0))) freed").font(.title3).foregroundStyle(.green)
                }
            }
            List(model.outcomes) { outcome in
                DisclosureGroup {
                    Text(outcome.log.isEmpty ? "No output" : outcome.log)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(outcome.label, systemImage: outcome.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(outcome.succeeded ? .green : .red)
                        if let error = outcome.error {
                            Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            HStack {
                Text("Free space can lag by a minute while APFS releases blocks and Time Machine local snapshots expire.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.isCleaning {
                    Button("Stop") { model.cancelClean() }
                } else {
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 480)
    }
}

struct ProjectRootsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Project folders").font(.title3.bold())
            Text("The scan looks inside these folders for node_modules, .terragrunt-cache, .terraform, Claude Code worktrees and other build artifacts.")
                .foregroundStyle(.secondary)
            List(model.projectRoots, id: \.self, selection: $selected) { root in
                Text(Format.path(root)).font(.body.monospaced())
            }
            HStack {
                Button("Add…", systemImage: "plus") { addRoot() }
                Button("Remove", systemImage: "minus") {
                    model.projectRoots.removeAll { $0 == selected }
                }
                .disabled(selected == nil)
                Button("Reset to defaults") { model.projectRoots = Scanner.defaultProjectRoots() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map(\.path).filter { !model.projectRoots.contains($0) }
        model.projectRoots += added
    }
}
