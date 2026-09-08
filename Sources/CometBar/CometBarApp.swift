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
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var state: SwitchState?
    private(set) var dockPresent = false
    private(set) var lastError: String?
    private(set) var busy = false

    private let client = CometClient()
    private var dockWatcher: DockWatcher?

    init() {
        // Re-read state on wake — the KVM may have been switched while asleep,
        // and interval timers are unreliable across sleep/wake.
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        let watcher = DockWatcher { [weak self] present in
            Task { @MainActor in
                self?.dockPresent = present
                self?.refresh()
            }
        }
        watcher.start()
        dockWatcher = watcher
        dockPresent = watcher.isDockPresent()

        refresh()
    }

    var menuBarSymbol: String {
        guard let number = state?.activePort?.number else {
            return "display.trianglebadge.exclamationmark"
        }
        return "\(number).square.fill"
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
        Task {
            busy = true
            defer { busy = false }
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
}

struct MenuContent: View {
    let model: AppModel

    var body: some View {
        if let state = model.state {
            ForEach(state.ports) { port in
                Button {
                    if let number = port.number { model.select(port: number) }
                } label: {
                    Text(label(for: port, state: state))
                }
                .disabled(model.busy || port.id == state.activeID)
            }
            Divider()
            Text(state.edidsInUse.isEmpty ? "EDID: none assigned" : "EDID: assigned")
        }

        if let error = model.lastError {
            Divider()
            Text("Error: \(error)")
        }

        Divider()
        Text(model.dockPresent ? "Dock: attached" : "Dock: not attached")
        Button("Refresh") { model.refresh() }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func label(for port: SwitchState.Port, state: SwitchState) -> String {
        let marker = port.id == state.activeID ? "● " : "○ "
        let name = port.name.isEmpty ? "Port \(port.number ?? 0)" : port.name
        let link = port.videoLinked ? "" : "  (no video)"
        return marker + name + link
    }
}
