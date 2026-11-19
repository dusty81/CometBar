import CometKit
import SwiftUI

/// Settings → Updates. Preferences apply immediately (no Save needed), like
/// the "Start at login" toggle.
struct UpdatesPane: View {
    let updates: UpdateChecker

    @State private var autoCheck = UpdatePreferences.autoCheck
    @State private var channel = UpdatePreferences.channel
    @State private var policy = UpdatePreferences.policy

    var body: some View {
        Form {
            Section {
                LabeledContent("Installed version", value: updates.currentVersion.description)
                Toggle("Check for updates daily", isOn: $autoCheck)
                    .onChange(of: autoCheck) { _, value in UpdatePreferences.autoCheck = value }
                Picker("Releases", selection: $channel) {
                    ForEach(UpdateChannel.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: channel) { _, value in UpdatePreferences.channel = value }
                Picker("When one is found", selection: $policy) {
                    ForEach(UpdateInstallPolicy.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: policy) { _, value in UpdatePreferences.policy = value }
            }

            Section {
                HStack {
                    Button(updates.isChecking ? "Checking…" : "Check Now") {
                        Task { await updates.checkNow() }
                    }
                    .disabled(updates.isChecking || updates.isInstalling)
                    Spacer()
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                if let update = updates.pendingUpdate {
                    HStack {
                        Button(updates.isInstalling ? "Installing…" : "Install \(update.version.description) and Relaunch") {
                            Task { await updates.installPendingUpdate(relaunch: true) }
                        }
                        .disabled(updates.isInstalling)
                        Button("What's New…") { updates.openReleasesPage() }
                    }
                }
                if let error = updates.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if updates.daemonOutdated {
                    Text("The clamshell background helper is older than this app. Choose \"Update Background Helper…\" in the menu; it asks for an administrator password.")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }

            Text("Updates come from github.com/\(CometGitHub.repoSlug). A download is only installed if it's signed by CometBar's developer.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var status: String {
        if let update = updates.pendingUpdate { return "Version \(update.version.description) is available." }
        if updates.upToDate { return "CometBar is up to date." }
        if let last = updates.lastCheckedAt {
            return "Last checked \(last.formatted(.relative(presentation: .named)))."
        }
        return "Not checked yet."
    }
}
