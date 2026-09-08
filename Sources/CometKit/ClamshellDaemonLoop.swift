import Foundation

/// The root-daemon reconciliation loop. Keeps lid-close sleep disabled
/// exactly while the OWC dock is attached AND the control flag says the
/// workaround is turned on; restores normal sleep otherwise. This is the
/// entire body of the `kvm-clamshelld` LaunchDaemon.
///
/// Dock presence is event-driven via `DockWatcher` (never polled, per
/// CLAUDE.md). The control flag IS polled, on a slow timer — it's one small
/// file read for a value that changes rarely, not the kind of polling that
/// guidance is about.
/// `@unchecked Sendable`: all mutable state is only ever touched from the
/// main queue — `DockWatcher`'s notification port and the timer are both
/// dispatched onto `.main`, and `run()` parks the thread in `RunLoop.main`.
public final class ClamshellDaemonLoop: @unchecked Sendable {
    private let pollInterval: TimeInterval
    private let log: @Sendable (String) -> Void

    private var dockWatcher: DockWatcher?
    private var dockPresent = false
    private var timer: DispatchSourceTimer?

    public init(
        pollInterval: TimeInterval = 10,
        log: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.pollInterval = pollInterval
        self.log = log
    }

    /// Blocks forever running the reconciliation loop on the current run loop.
    public func run() -> Never {
        let watcher = DockWatcher { [weak self] present in
            guard let self else { return }
            if present != self.dockPresent {
                self.dockPresent = present
                self.log("Dock \(present ? "attached" : "detached") — reconciling.")
                self.reconcile()
            }
        }
        watcher.start()
        dockPresent = watcher.isDockPresent()
        dockWatcher = watcher

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.reconcile() }
        timer.resume()
        self.timer = timer

        log("kvm-clamshelld started. Dock present: \(dockPresent).")
        reconcile()
        RunLoop.main.run()
        fatalError("RunLoop.main.run() returned, which should never happen")
    }

    private func reconcile() {
        guard ClamshellController.isControlEnabled() else {
            // Control was turned off (or never on) — make sure we're not
            // leaving the Mac stuck awake, then go idle.
            if (try? ClamshellController.isLidSleepDisabled()) == true {
                log("Control disabled but sleep was disabled — restoring normal sleep.")
                try? ClamshellController.setLidSleepDisabled(false)
            }
            return
        }

        let desired = dockPresent
        let current = (try? ClamshellController.isLidSleepDisabled()) ?? false
        guard current != desired else { return }

        log("Setting disablesleep=\(desired ? 1 : 0) (dock present=\(dockPresent)).")
        do {
            try ClamshellController.setLidSleepDisabled(desired)
        } catch {
            log("Failed to set lid-sleep state: \(error.localizedDescription)")
        }
    }
}
