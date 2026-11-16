import AppKit
import DiskCleanerCore
import SwiftUI

struct MenuBarLabel: View {
    let volume: DiskUsage.VolumeSpace?

    var body: some View {
        // Menu bar labels render as a template, so low space is shown with a symbol, not colour.
        Image(systemName: isLow ? "exclamationmark.triangle.fill" : "internaldrive")
        Text(volume.map { Format.compactBytes($0.available) } ?? "–")
    }

    private var isLow: Bool {
        guard let volume, volume.total > 0 else { return false }
        return Double(volume.available) / Double(volume.total) < AppModel.lowSpaceFraction
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let release = updater.available {
            Button("Download Disk Cleaner \(release.version.description)…") { updater.openDownload() }
            Divider()
        }
        if let volume = model.volume {
            Text("\(Format.bytes(volume.available)) free of \(Format.bytes(volume.total))")
        }
        if model.isScanning {
            Text("Scanning…")
        } else if model.hasScanned {
            Text("\(Format.bytes(model.cleanableBytes)) cleanable · \(Format.bytes(model.selectedBytes())) selected")
        }
        Divider()
        Button("Open Disk Cleaner") {
            openWindow(id: DiskCleanerApp.mainWindowID)
            NSApp.activate()
        }
        Button(model.isScanning ? "Scanning…" : "Rescan") { model.startScan() }
            .disabled(model.isScanning || model.isCleaning)
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Disk Cleaner") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct SettingsView: View {
    @AppStorage("showMenuBarExtra") private var showsMenuBarExtra = true
    @Environment(Updater.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show free space in the menu bar", isOn: $showsMenuBarExtra)
            HStack {
                Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                    .help("Asks GitHub for the latest release at launch and once a day. Nothing else is sent.")
                Spacer()
                Text("Version \(updater.currentVersion ?? "unknown")").foregroundStyle(.secondary)
                Button("Check Now") { Task { await updater.checkNow(showingResultIn: .settings) } }
                    .disabled(updater.isChecking)
            }
            if updater.isChecking {
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            } else if updater.manualResultPlace == .settings, let result = updater.manualResult {
                Text(result).font(.caption).foregroundStyle(.secondary)
            } else if updater.manualResultPlace == .settings, let release = updater.available {
                Button("Disk Cleaner \(release.version.description) is available. Download…") { updater.openDownload() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding([.horizontal, .top], 20)
        .onDisappear { if updater.manualResultPlace == .settings { updater.clearManualResult() } }
        ProjectRootsView()
    }
}
