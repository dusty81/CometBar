import CometKit
import ServiceManagement
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
    @State private var dockVendorID: Int = CometSettings.defaultDockVendorID
    @State private var detectedUSBDevices: [USBDeviceInfo] = []
    @State private var startAtLogin = false
    @State private var loginItemError: String?
    @State private var switchConfirmationEnabled = CometSettings.defaultSwitchConfirmationEnabled
    @State private var switchConfirmationDelaySeconds = CometSettings.defaultSwitchConfirmationDelaySeconds

    var body: some View {
        Form {
            Section("General") {
                Toggle("Start CometBar at login", isOn: $startAtLogin)
                    .onChange(of: startAtLogin, toggleStartAtLogin)
                if let loginItemError {
                    Text(loginItemError).font(.footnote).foregroundStyle(.red)
                }
            }

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

            Section("Switching") {
                Toggle("Show \"Switching to…\" confirmation", isOn: $switchConfirmationEnabled)
                if switchConfirmationEnabled {
                    Stepper(
                        "Wait \(switchConfirmationDelaySeconds.formatted(.number.precision(.fractionLength(0...1))))s before switching",
                        value: $switchConfirmationDelaySeconds,
                        in: CometSettings.minimumSwitchConfirmationDelaySeconds...CometSettings.maximumSwitchConfirmationDelaySeconds,
                        step: 0.5
                    )
                }
                Text("Gives you a moment to confirm a hotkey or click landed before the KVM actually switches — useful since switching moves your keyboard and mouse with it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

            Section("Dock") {
                Text("Used to detect whether this Mac is at its desk (for the clamshell workaround and dock status). Different dock hardware reports a different USB vendor ID, so this needs picking per machine — plug your dock in, then pick it below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("Dock device", selection: $dockVendorID) {
                    ForEach(detectedUSBDevices) { device in
                        Text("\(device.name)  (\(device.vendorIDHex))").tag(device.vendorID)
                    }
                    if !detectedUSBDevices.contains(where: { $0.vendorID == dockVendorID }) {
                        Text("Currently configured: \(hex(dockVendorID))").tag(dockVendorID)
                    }
                }

                HStack {
                    Text(model.dockPresent ? "Detected: attached" : "Detected: not attached")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Rescan USB devices", action: rescanUSBDevices)
                        .font(.footnote)
                }
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
        // No fixed height: sections come and go (daemon installed or not,
        // errors appearing) so a fixed/min height either clips new content
        // or leaves dead space. fixedSize lets the window match content
        // exactly, growing or shrinking as sections change.
        .frame(minWidth: 440, idealWidth: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: load)
        .onChange(of: model.state) { _, _ in loadPortNames() }
    }

    private func load() {
        let settings = model.settings
        host = settings.host
        user = settings.user
        refreshIntervalSeconds = settings.refreshIntervalSeconds
        dockVendorID = settings.dockVendorID
        switchConfirmationEnabled = settings.switchConfirmationEnabled
        switchConfirmationDelaySeconds = settings.switchConfirmationDelaySeconds
        startAtLogin = SMAppService.mainApp.status == .enabled
        rescanUSBDevices()
        loadPortNames()
        loadClamshellStatus()
    }

    private func toggleStartAtLogin(_ wasOn: Bool, _ isOn: Bool) {
        loginItemError = nil
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = error.localizedDescription
            // Reflect what actually happened rather than the failed intent.
            startAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func rescanUSBDevices() {
        detectedUSBDevices = USBDeviceLister.connectedDevices()
    }

    private func hex(_ vendorID: Int) -> String {
        "0x" + String(vendorID, radix: 16, uppercase: true)
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
            refreshIntervalSeconds: refreshIntervalSeconds,
            dockVendorID: dockVendorID,
            switchConfirmationEnabled: switchConfirmationEnabled,
            switchConfirmationDelaySeconds: switchConfirmationDelaySeconds
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
