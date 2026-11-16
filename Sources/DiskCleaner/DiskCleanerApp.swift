import AppKit
import SwiftUI

@main
struct DiskCleanerApp: App {
    static let mainWindowID = "main"

    @State private var model = AppModel()
    @AppStorage("showMenuBarExtra") private var showsMenuBarExtra = true
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Disk Cleaner", id: Self.mainWindowID) {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan") { model.startScan() }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning || model.isCleaning)
            }
        }

        MenuBarExtra(isInserted: $showsMenuBarExtra) {
            MenuBarContent().environment(model)
        } label: {
            MenuBarLabel(volume: model.volume)
        }

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 520, height: 420)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started with `swift run` rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    // The menu bar item keeps showing free space after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: "showMenuBarExtra", default: true)
    }
}

private extension UserDefaults {
    func bool(forKey key: String, default value: Bool) -> Bool {
        object(forKey: key) == nil ? value : bool(forKey: key)
    }
}
