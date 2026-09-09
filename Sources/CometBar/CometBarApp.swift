import CometKit
import SwiftUI

@main
struct CometBarApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            // The label is the menu bar item itself. Showing the active port
            // number is the whole value of this app at a glance.
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }
        // Without an explicit position, macOS can place this window using a
        // stale saved frame from a prior display arrangement — it opened
        // fully off-screen here, which is why port names looked "missing":
        // the window was never visible at all. Centering avoids that.
        .defaultPosition(.center)
        // Just an initial guess — SettingsView's .fixedSize corrects this to
        // match actual content on first layout and whenever sections change.
        .defaultSize(width: 440, height: 640)
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var state: SwitchState?
    private(set) var dockPresent = false
    private(set) var lastError: String?
    private(set) var busy = false

    var settings: CometSettings {
        didSet {
            guard settings != oldValue else { return }
            SettingsStore.save(settings)
            if settings.host != oldValue.host || settings.user != oldValue.user {
                rebuildClient()
            }
            if settings.refreshIntervalSeconds != oldValue.refreshIntervalSeconds {
                scheduleRefresh()
            }
            if settings.dockVendorID != oldValue.dockVendorID {
                rebuildDockWatcher()
            }
        }
    }

    private var client: CometClient
    private var dockWatcher: DockWatcher?
    private var refreshTask: Task<Void, Never>?
    private var hotKeyManager: HotKeyManager?
    private let switchingOverlay = SwitchingOverlay()

    init() {
        let loaded = SettingsStore.load()
        settings = loaded
        client = CometClient(host: loaded.host, user: loaded.user)

        // Re-read state on wake — the KVM may have been switched while asleep,
        // and interval timers are unreliable across sleep/wake.
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        rebuildDockWatcher()

        refresh()
        scheduleRefresh()

        // ⌘⌥1–⌘⌥4, system-wide. Can only ever switch away from this Mac —
        // see the switch-back constraint in CLAUDE.md.
        let hotKeys = HotKeyManager { [weak self] port in
            self?.select(port: port)
        }
        hotKeys.register()
        hotKeyManager = hotKeys
    }

    var menuBarSymbol: String {
        guard let number = state?.activePort?.number else {
            return "display.trianglebadge.exclamationmark"
        }
        return "\(number).square.fill"
    }

    /// Friendly name for a port. Names live on the device itself (see
    /// `savePortNames`); this just falls back to a generic label when unset.
    func displayName(for port: SwitchState.Port) -> String {
        port.name.isEmpty ? "Port \(port.number ?? 0)" : port.name
    }

    func refresh() {
        Task {
            do {
                state = try await client.switchState()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Switches the KVM. Note this is one-directional from this Mac's point of
    /// view — see the switch-back constraint in CLAUDE.md.
    func select(port: Int) {
        // Shown immediately, before the delay/API call — this can be
        // triggered by the global hotkey with no menu open, so without
        // instant feedback there's no way to tell a keystroke registered.
        // Both the overlay and its delay are configurable in Settings.
        let showConfirmation = settings.switchConfirmationEnabled
        if showConfirmation {
            let name = state?.ports.first(where: { $0.number == port }).map(displayName(for:)) ?? "Port \(port)"
            switchingOverlay.show(text: "Switching to \(name)…")
        }

        Task {
            busy = true
            defer {
                busy = false
                if showConfirmation { switchingOverlay.hide() }
            }
            if showConfirmation {
                try? await Task.sleep(for: .seconds(settings.switchConfirmationDelaySeconds))
            }
            do {
                try await client.setActive(portNumber: port)
                lastError = nil
                // The device takes a beat to settle before state reflects it.
                try? await Task.sleep(for: .milliseconds(600))
                state = try await client.switchState()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func rebuildClient() {
        client = CometClient(host: settings.host, user: settings.user)
        refresh()
    }

    /// (Re)starts the dock watcher with the currently-configured vendor ID.
    /// Different dock hardware — and the same dock model on a different
    /// Mac — can enumerate under a different vendor ID, so this isn't a
    /// fixed constant; see `USBDeviceLister` and the Settings "Dock" section.
    private func rebuildDockWatcher() {
        dockWatcher?.stop()
        let watcher = DockWatcher(vendorID: settings.dockVendorID) { [weak self] present in
            Task { @MainActor in
                self?.dockPresent = present
                self?.refresh()
            }
        }
        watcher.start()
        dockWatcher = watcher
        dockPresent = watcher.isDockPresent()
    }

    /// Writes changed port names to the device (skipping unchanged ones to
    /// avoid unnecessary live-device calls) and refreshes state afterward.
    func savePortNames(_ names: [Int: String]) async throws {
        let current = state?.ports.reduce(into: [Int: String]()) { result, port in
            if let number = port.number { result[number] = port.name }
        } ?? [:]

        for (number, name) in names where name != (current[number] ?? "") {
            guard let port = PortNumber(number) else { continue }
            try await client.setPortName(port, name: name)
        }
        refresh()
    }

    /// Polls `switchState` on a fixed interval. There's no push mechanism for
    /// the KVM's HTTP API (unlike dock detection, which is event-driven IOKit
    /// and must never poll), so this is unavoidable — kept infrequent by
    /// default and restarted whenever the interval setting changes.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        let interval = max(settings.refreshIntervalSeconds, CometSettings.minimumRefreshIntervalSeconds)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.refresh() }
            }
        }
    }
}

struct MenuContent: View {
    let model: AppModel

    var body: some View {
        if let state = model.state {
            ForEach(state.ports) { port in
                Button {
                    if let number = port.number { model.select(port: number) }
                } label: {
                    // Icon after the name, not via Label's icon slot (which
                    // is always leading and, being NSMenuItem's actual image
                    // slot, cropped a wider composite down to a sliver —
                    // confirmed empirically). Concatenating Text(Image) is
                    // inline within the title itself, so it can go anywhere,
                    // including after the text, and isn't subject to that
                    // crop. No keyboard-shortcut hint shown anymore — the
                    // real, system-wide binding is HotKeyManager (Carbon),
                    // registered once in AppModel.init and working whether or
                    // not the menu is open.
                    Text(name(for: port, state: state)) + Text("   ")
                        + Text(statusImage(video: port.videoLinked, usb: port.usbLinked))
                }
                .disabled(model.busy || port.id == state.activeID)
            }
        }

        if let error = model.lastError {
            Divider()
            Text("Error: \(error)")
        }

        Divider()
        Text(model.dockPresent ? "Dock: attached" : "Dock: not attached")
        Button("Refresh") { model.refresh() }
        // SettingsLink is what reliably opens the window (the private
        // showSettingsWindow: selector approach doesn't — it created zero
        // windows in testing). But two things then hide it from view:
        //  1. For an LSUIElement (accessory) app, SettingsLink alone doesn't
        //     activate the app, so the window can open behind everything
        //     else with no visible change.
        //  2. SwiftUI reuses the same NSWindow instance across opens. If it
        //     was first shown on a different macOS Space than the one
        //     currently active, it stays pinned there — clicking "Settings…"
        //     again looks like nothing happened, because on your current
        //     Space, nothing did.
        // Both looked like "Settings doesn't appear". Fix both explicitly.
        SettingsLink { Text("Settings…") }
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard let window = NSApp.windows.first(where: { $0.title == "CometBar Settings" }) else { return }
                    window.collectionBehavior.insert(.moveToActiveSpace)
                    window.makeKeyAndOrderFront(nil)
                }
            })
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func name(for port: SwitchState.Port, state: SwitchState) -> String {
        let marker = port.id == state.activeID ? "● " : "○ "
        return marker + model.displayName(for: port)
    }

    /// A single composite icon (display, keyboard, and mouse glyphs side by
    /// side, colored green/gray by connection), shown on every port every
    /// refresh — not just when something's down — so you can tell at a
    /// glance which port has a live monitor and keyboard/mouse before
    /// switching to it.
    ///
    /// Rendered once via `ImageRenderer` and embedded inline in the title
    /// text (`Text(Image)` concatenation) rather than through `Label`'s icon
    /// slot — that's NSMenuItem's actual image well, which expects roughly
    /// square dimensions and silently center-cropped a horizontal strip like
    /// this down to a sliver (confirmed empirically). An inline image inside
    /// the title isn't subject to that constraint.
    private func statusImage(video: Bool, usb: Bool) -> Image {
        let content = HStack(spacing: 3) {
            Image(systemName: "display")
                .foregroundStyle(video ? Color.green : Color.gray)
            Image(systemName: "keyboard")
                .foregroundStyle(usb ? Color.green : Color.gray)
            Image(systemName: "computermouse")
                .foregroundStyle(usb ? Color.green : Color.gray)
        }
        .font(.system(size: 13))

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let nsImage = renderer.nsImage else {
            return Image(systemName: "questionmark.circle")
        }
        return Image(nsImage: nsImage)
    }
}
