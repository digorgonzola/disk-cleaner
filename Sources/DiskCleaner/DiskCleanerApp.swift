import AppKit
import SwiftUI
import UserNotifications

@main
struct DiskCleanerApp: App {
    static let mainWindowID = "main"

    @State private var model = AppModel()
    @State private var updater = Updater()
    @AppStorage("showMenuBarExtra") private var showsMenuBarExtra = true
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Disk Cleaner", id: Self.mainWindowID) {
            ContentView()
                .environment(model)
                .environment(updater)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await updater.check(userInitiated: true) } }
                    .disabled(updater.isChecking)
            }
            CommandGroup(after: .newItem) {
                Button("Scan") { model.startScan() }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning || model.isCleaning)
            }
        }

        MenuBarExtra(isInserted: $showsMenuBarExtra) {
            MenuBarContent().environment(model).environment(updater)
        } label: {
            MenuBarLabel(volume: model.volume)
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(updater)
                .frame(width: 520, height: 420)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        // Needed when started with `swift run` rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    // Show the update notification even while the app is in front.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // Take the String out first: the user-info dictionary cannot cross to the main actor.
        let link = response.notification.request.content.userInfo[NotificationLink.key] as? String
        await MainActor.run { NotificationLink.open(link) }
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
