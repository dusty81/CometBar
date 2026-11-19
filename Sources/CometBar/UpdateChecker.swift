import AppKit
import CometKit
import Foundation
import UserNotifications

/// Update preferences, persisted in UserDefaults alongside `SettingsStore`'s keys.
enum UpdatePreferences {
    private static let autoCheckKey = "comet.update.autoCheck"
    private static let channelKey = "comet.update.channel"
    private static let policyKey = "comet.update.policy"
    private static let lastCheckKey = "comet.update.lastCheck"

    static var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }
    static var channel: UpdateChannel {
        get { UserDefaults.standard.string(forKey: channelKey).flatMap(UpdateChannel.init) ?? .all }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: channelKey) }
    }
    static var policy: UpdateInstallPolicy {
        get { UserDefaults.standard.string(forKey: policyKey).flatMap(UpdateInstallPolicy.init) ?? .notifyOnly }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: policyKey) }
    }
    static var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: lastCheckKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastCheckKey) }
    }
}

/// Checks GitHub Releases daily and notifies/installs per `UpdatePreferences`.
/// The heavy lifting (fetch, verify, swap) is `CometKit.UpdateInstaller`.
@MainActor
@Observable
final class UpdateChecker {
    static let checkInterval: TimeInterval = 24 * 60 * 60

    private(set) var pendingUpdate: PendingUpdate?
    private(set) var isChecking = false
    private(set) var isInstalling = false
    private(set) var lastCheckedAt: Date? = UpdatePreferences.lastCheck
    private(set) var lastError: String?
    /// Set by a successful "Check Now" that found nothing, for the Settings pane.
    private(set) var upToDate = false
    /// The installed clamshell daemon differs from the one in this bundle.
    private(set) var daemonOutdated = false

    let currentVersion = AppVersion.of() ?? AppVersion(major: 0, minor: 0, patch: 0)
    private var loopTask: Task<Void, Never>?
    private var notifiedTag: String?

    func start() {
        refreshDaemonStatus()
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            // Let launch settle (and the network come up after login) first.
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                guard let self else { return }
                if UpdatePreferences.autoCheck, self.isDue { await self.checkNow() }
                // Wake hourly and compare against the last check, rather than
                // sleeping a whole day: Task.sleep doesn't advance while the
                // Mac is asleep, so a 24h sleep could stretch to days.
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    private var isDue: Bool {
        guard let last = lastCheckedAt else { return true }
        return Date().timeIntervalSince(last) >= Self.checkInterval
    }

    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        upToDate = false
        defer { isChecking = false }
        do {
            let releases = try await UpdateInstaller.fetchReleases(currentVersion: currentVersion)
            lastCheckedAt = Date()
            UpdatePreferences.lastCheck = lastCheckedAt
            lastError = nil
            pendingUpdate = UpdateSelector.bestUpdate(
                from: releases, current: currentVersion, channel: UpdatePreferences.channel
            )
            guard let update = pendingUpdate else {
                upToDate = true
                return
            }
            guard update.tagName != notifiedTag else { return }
            notifiedTag = update.tagName
            if UpdatePreferences.policy == .installImmediately {
                await installPendingUpdate(relaunch: true)
            } else {
                notify(title: "CometBar \(update.version.description) is available",
                       body: "Choose \"Update to \(update.version.description)\" in the CometBar menu.")
            }
        } catch {
            lastError = error.localizedDescription
            NSLog("CometBar: update check failed: \(error.localizedDescription)")
        }
    }

    /// Downloads, verifies, and swaps in the pending update. With `relaunch`,
    /// starts the new copy and quits this one.
    func installPendingUpdate(relaunch: Bool) async {
        guard let update = pendingUpdate, !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        let bundleURL = Bundle.main.bundleURL
        do {
            try await UpdateInstaller.install(update, over: bundleURL)
            pendingUpdate = nil
            lastError = nil
            if relaunch { Self.relaunch(bundleURL) }
        } catch {
            lastError = error.localizedDescription
            NSLog("CometBar: update install failed: \(error.localizedDescription)")
            notify(title: "CometBar update failed", body: error.localizedDescription)
        }
    }

    /// Called by the Quit menu item before terminating.
    func installBeforeQuittingIfNeeded() async {
        guard UpdatePreferences.policy == .installOnQuit, pendingUpdate != nil else { return }
        await installPendingUpdate(relaunch: false)
    }

    func refreshDaemonStatus() {
        let bundled = Bundle.main.url(forResource: "kvm-clamshelld", withExtension: nil)
        daemonOutdated = DaemonVersionCheck.isOutdated(bundled: bundled) ?? false
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(CometGitHub.releasesPage)
    }

    /// Starts the freshly installed copy once this process is gone (so its
    /// global hotkeys can register — a second live instance would collide),
    /// then quits. The path goes in as `$0`, never interpolated into the
    /// script, so no quoting issues.
    private static func relaunch(_ bundleURL: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", bundleURL.path]
        try? p.run()
        NSApplication.shared.terminate(nil)
    }

    private func notify(title: String, body: String) {
        // UNUserNotificationCenter traps outside a real app bundle (swift run).
        guard Bundle.main.bundleIdentifier != nil else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: "cometbar.update", content: content, trigger: nil))
        }
    }
}
