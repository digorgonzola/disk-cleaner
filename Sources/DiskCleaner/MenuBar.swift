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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Show free space in the menu bar", isOn: $showsMenuBarExtra)
                .padding([.horizontal, .top], 20)
            ProjectRootsView()
        }
    }
}
