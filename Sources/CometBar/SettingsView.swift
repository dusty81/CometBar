import CometKit
import SwiftUI

/// Host/user/password configuration, plus per-port friendly names.
///
/// The password field is intentionally never pre-filled from the Keychain —
/// it's write-only here. Leaving it blank keeps whatever password is already
/// stored; typing a new one and saving overwrites it.
///
/// Port names are NOT stored locally — they're read from and written to the
/// Comet X itself (`model.ports[].name` via `set_port_params`), so this view
/// seeds its fields from `model.state` and only pushes the ones that changed.
struct SettingsView: View {
    let model: AppModel

    @State private var host: String = ""
    @State private var user: String = ""
    @State private var password: String = ""
    @State private var portNames: [Int: String] = [:]
    @State private var refreshIntervalSeconds: Double = CometSettings.defaultRefreshIntervalSeconds
    @State private var clamshellEnabled = false
    @State private var lidSleepDisabled = false
    @State private var daemonInstalled = false
    @State private var saveError: String?
    @State private var didSave = false
    @State private var saving = false
    @State private var daemonActionInProgress = false
    @State private var daemonActionError: String?

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Host", text: $host)
                TextField("Username", text: $user)
                SecureField("Password", text: $password, prompt: Text("Unchanged"))
                Stepper(
                    "Refresh every \(Int(refreshIntervalSeconds))s",
                    value: $refreshIntervalSeconds,
                    in: CometSettings.minimumRefreshIntervalSeconds...300,
                    step: 15
                )
            }

            Section("Port names") {
                if model.state == nil {
                    Text("Connecting to read current names…").foregroundStyle(.secondary)
                }
                ForEach(1...4, id: \.self) { number in
                    TextField(
                        "Port \(number)",
                        text: Binding(
                            get: { portNames[number] ?? "" },
                            set: { portNames[number] = $0 }
                        ),
                        prompt: Text("e.g. Work MBP")
                    )
                }
                Text("Names are stored on the KVM itself, not just this Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Clamshell") {
                if daemonInstalled {
                    Toggle("Keep this Mac awake while docked", isOn: $clamshellEnabled)
                    Text(
                        "Currently: lid-close sleep is "
                            + (lidSleepDisabled ? "disabled (staying awake)." : "normal.")
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    HStack {
                        if daemonActionInProgress {
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                        Button("Uninstall background helper…", action: uninstallDaemonTapped)
                            .font(.footnote)
                            .disabled(daemonActionInProgress)
                    }
                } else {
                    Text("Keeping this Mac awake while docked needs a small background helper (a root LaunchDaemon) installed once. macOS will ask for your admin password.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        if daemonActionInProgress {
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                        Button("Install background helper…", action: installDaemonTapped)
                            .disabled(daemonActionInProgress)
                    }
                }
                if let daemonActionError {
                    Text(daemonActionError).font(.footnote).foregroundStyle(.red)
                }
            }

            if let saveError {
                Text(saveError).foregroundStyle(.red)
            }

            HStack {
                if saving {
                    ProgressView().controlSize(.small)
                } else if didSave {
                    Text("Saved").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(20)
        .frame(minWidth: 440, idealWidth: 440, minHeight: 420, idealHeight: 460)
        .onAppear(perform: load)
        .onChange(of: model.state) { _, _ in loadPortNames() }
    }

    private func load() {
        let settings = model.settings
        host = settings.host
        user = settings.user
        refreshIntervalSeconds = settings.refreshIntervalSeconds
        loadPortNames()
        loadClamshellStatus()
    }

    // Synchronous, not Task-wrapped: NSAppleScript's admin-privileges prompt
    // is already a blocking native modal (Authorization Services owns that
    // UI), and wrapping it in a Task would require capturing this non-Sendable
    // View struct across an @Sendable closure boundary under Swift 6 strict
    // concurrency. Blocking briefly on a system password prompt is normal —
    // it's the same UX as any other admin-authorization dialog in macOS.
    private func installDaemonTapped() {
        daemonActionError = nil
        daemonActionInProgress = true
        defer { daemonActionInProgress = false }
        do {
            try DaemonInstaller.installDaemon()
            loadClamshellStatus()
        } catch {
            daemonActionError = error.localizedDescription
        }
    }

    private func uninstallDaemonTapped() {
        daemonActionError = nil
        daemonActionInProgress = true
        defer { daemonActionInProgress = false }
        do {
            try DaemonInstaller.uninstallDaemon()
            loadClamshellStatus()
        } catch {
            daemonActionError = error.localizedDescription
        }
    }

    private func loadClamshellStatus() {
        daemonInstalled = ClamshellController.isDaemonInstalled()
        clamshellEnabled = ClamshellController.isControlEnabled()
        lidSleepDisabled = (try? ClamshellController.isLidSleepDisabled()) ?? false
    }

    private func loadPortNames() {
        guard let ports = model.state?.ports else { return }
        for port in ports {
            guard let number = port.number else { continue }
            portNames[number] = port.name
        }
    }

    private func save() {
        saveError = nil
        didSave = false

        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty, !trimmedUser.isEmpty else {
            saveError = "Host and username can't be empty."
            return
        }

        if !password.isEmpty {
            do {
                try Keychain(account: trimmedUser).savePassword(password)
                password = ""
            } catch {
                saveError = error.localizedDescription
                return
            }
        }

        if daemonInstalled {
            do {
                try ClamshellController.setControlEnabled(clamshellEnabled)
            } catch {
                saveError = error.localizedDescription
                return
            }
        }

        model.settings = CometSettings(
            host: trimmedHost,
            user: trimmedUser,
            refreshIntervalSeconds: refreshIntervalSeconds
        )

        saving = true
        Task {
            defer { saving = false }
            do {
                try await model.savePortNames(portNames)
                loadClamshellStatus()
                didSave = true
            } catch {
                saveError = "Connection settings saved, but port names failed: \(error.localizedDescription)"
            }
        }
    }
}
