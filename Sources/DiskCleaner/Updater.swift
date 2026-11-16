import AppKit
import DiskCleanerCore
import Foundation
import Observation
import SwiftUI
import UserNotifications
import os

/// Checks GitHub for a newer release: at launch, then at most once a day while the app runs.
@MainActor
@Observable
final class Updater {
    /// The newer release, when there is one the user has not skipped.
    private(set) var available: ReleaseInfo?
    private(set) var isChecking = false
    /// Where the result of a check the user started is shown.
    enum ResultPlace { case window, settings }

    /// Set after a check the user started: "up to date", or the error.
    var manualResult: String?
    private(set) var manualResultPlace: ResultPlace = .window

    /// UserNotifications needs an app bundle; under `swift run` it throws.
    static let canNotify = Bundle.main.bundleIdentifier != nil

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var checksAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Keys.automatic) }
    }

    private enum Keys {
        static let automatic = "checkForUpdates"
        static let skipped = "skippedVersion"
        static let notified = "notifiedVersion"
    }

    private static let interval: TimeInterval = 24 * 60 * 60
    nonisolated private static let log = Logger(subsystem: "local.disk-cleaner", category: "updates")

    init() {
        checksAutomatically = UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true
        Task { [weak self] in
            // Give launch a moment, then wake hourly and check when one is due.
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkIfDue()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    private var current: Version? { currentVersion.flatMap(Version.init) }

    /// Once per launch, then once a day after a successful check; a failed one (offline at
    /// login) is retried at the next hourly wake. Far below GitHub's 60 unauthenticated
    /// requests an hour.
    private func checkIfDue() async {
        guard checksAutomatically, current != nil else { return }
        if let lastSuccessfulCheck, Date().timeIntervalSince(lastSuccessfulCheck) < Self.interval { return }
        await check(userInitiated: false)
    }

    private var lastSuccessfulCheck: Date?

    /// Runs a check the user asked for and shows its result in `place`.
    func checkNow(showingResultIn place: ResultPlace) async {
        // Clear first: an old answer must not flash in the new place.
        manualResult = nil
        manualResultPlace = place
        await check(userInitiated: true)
    }

    private func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        guard let current, let currentVersion else {
            if userInitiated {
                manualResult = "This build's version (\(currentVersion ?? "none")) is not a release version, so it cannot be compared with releases."
            }
            return
        }
        isChecking = true
        defer { isChecking = false }
        do {
            let latest = try await UpdateChecker.fetchLatest(appVersion: currentVersion)
            lastSuccessfulCheck = Date()
            // A version the user skipped still shows when they ask explicitly.
            let skipped = userInitiated ? nil : UserDefaults.standard.string(forKey: Keys.skipped).flatMap(Version.init)
            if UpdateChecker.isUpdate(latest, current: current, skipped: skipped) {
                available = latest
                if !userInitiated { notifyOnce(latest) }
                if userInitiated { manualResult = nil }
            } else {
                available = nil
                if userInitiated { manualResult = "Disk Cleaner \(current) is the latest version." }
            }
        } catch {
            Self.log.warning("Update check failed: \(error.localizedDescription, privacy: .public)")
            if userInitiated { manualResult = "Could not check for updates: \(error.localizedDescription)" }
        }
    }

    func skip() {
        guard let available else { return }
        UserDefaults.standard.set(available.version.description, forKey: Keys.skipped)
        self.available = nil
    }

    func dismiss() { available = nil }

    func clearManualResult() { manualResult = nil }

    func openDownload() {
        guard let available else { return }
        NSWorkspace.shared.open(available.downloadURL ?? available.pageURL)
    }

    func openReleasePage() {
        guard let available else { return }
        NSWorkspace.shared.open(available.pageURL)
    }

    /// One system notification per new version; the banner and menu item cover the rest.
    private func notifyOnce(_ release: ReleaseInfo) {
        guard Self.canNotify else { return }
        let version = release.version.description
        guard UserDefaults.standard.string(forKey: Keys.notified) != version else { return }
        UserDefaults.standard.set(version, forKey: Keys.notified)

        let content = UNMutableNotificationContent()
        content.title = "Disk Cleaner \(version) is available"
        content.body = "Click to download the update."
        content.userInfo = [NotificationLink.key: (release.downloadURL ?? release.pageURL).absoluteString]
        let request = UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil)

        Task {
            // Notifications are optional: the banner and the menu item still show the update.
            do {
                let center = UNUserNotificationCenter.current()
                guard try await center.requestAuthorization(options: [.alert]) else { return }
                try await center.add(request)
            } catch {
                Self.log.warning("Could not post the update notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Opens the link from a clicked update notification, after checking it again: the
/// notification's user info is data the app stored, but it only ever opens release links.
enum NotificationLink {
    static let key = "url"

    static func open(_ link: String?) {
        guard let link, let url = UpdateChecker.trustedURL(link) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct UpdateBanner: View {
    @Environment(Updater.self) private var updater
    let release: ReleaseInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Disk Cleaner \(release.version.description) is available").font(.headline)
                Text("You have \(updater.currentVersion ?? "an unknown version").").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Release Notes") { updater.openReleasePage() }
                .buttonStyle(.link)
            Button("Skip This Version") { updater.skip() }
            Button("Download") { updater.openDownload() }
                .buttonStyle(.borderedProminent)
            Button {
                updater.dismiss()
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.borderless)
            .help("Hide until the next check")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.12))
    }
}
