import Foundation
import IOKit
import IOKit.usb

/// Watches for the OWC Thunderbolt 3 Dock attaching or detaching, event-driven.
///
/// This replaces the shell version's 30-second launchd `StartInterval` poll,
/// which both burned cycles and left a gap across sleep/wake (interval timers
/// don't fire reliably on wake). Do not reintroduce polling.
///
/// Matches on vendor ID only — the dock exposes several devices (SD reader
/// 0x4002, audio 0x4001) and product IDs are less stable across dock firmware
/// than the vendor ID is.
public final class DockWatcher {
    /// OWC, 0x1E91.
    public static let owcVendorID = 0x1E91

    /// The IOKit class the dock's devices actually register under.
    ///
    /// NOT `kIOUSBDeviceClassName` ("IOUSBDevice"), which is the legacy class
    /// and matches nothing here — using it made `isDockPresent()` return false
    /// with the dock plainly attached. Verified: the OWC devices appear under
    /// `IOUSBHostDevice` in `ioreg`.
    private static let usbDeviceClass = "IOUSBHostDevice"

    /// Builds a matching dictionary for USB devices with the given vendor ID.
    ///
    /// ⚠️ `idVendor` must go inside an `IOPropertyMatch` SUB-DICTIONARY. The
    /// top level of a matching dictionary only accepts IOKit's own reserved
    /// keys (`IOProviderClass`, `IOClass`, `IONameMatch`, `IOPropertyMatch`,
    /// …), and an unrecognised key there does not get ignored — it makes the
    /// match fail silently and return ZERO results. Setting it at the top
    /// level is what made dock detection report "not detected" with the dock
    /// plainly attached. Verified working: this returns the OWC SD Card Reader
    /// and Audio Device.
    ///
    /// Each call returns a fresh dictionary because
    /// `IOServiceAddMatchingNotification` consumes a reference to the one it
    /// is handed, so the matched and terminated registrations cannot share one.
    private static func matchingDictionary(vendorID: Int) -> CFMutableDictionary? {
        guard let matching = IOServiceMatching(usbDeviceClass) else { return nil }
        (matching as NSMutableDictionary)[kIOPropertyMatchKey] = [kUSBVendorID: vendorID]
        return matching
    }

    private let vendorID: Int
    private let onChange: @Sendable (Bool) -> Void

    private var notifyPort: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0

    /// - Parameter onChange: called with `true` when the dock appears, `false`
    ///   when the last matching device disappears. Delivered on the main queue.
    public init(
        vendorID: Int = DockWatcher.owcVendorID,
        onChange: @escaping @Sendable (Bool) -> Void
    ) {
        self.vendorID = vendorID
        self.onChange = onChange
    }

    deinit { stop() }

    /// True if a matching device is currently present.
    ///
    /// Safe to call before `start()` — useful for establishing initial state.
    public func isDockPresent() -> Bool {
        guard let matching = Self.matchingDictionary(vendorID: vendorID) else { return false }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return false }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return false }
        IOObjectRelease(service)
        // Drain the rest so the iterator is fully consumed.
        while case let next = IOIteratorNext(iterator), next != 0 {
            IOObjectRelease(next)
        }
        return true
    }

    /// Registers IOKit notifications on the current run loop.
    ///
    /// Must be called from a thread with a running run loop (the main thread in
    /// an AppKit/SwiftUI app).
    public func start() {
        guard notifyPort == nil else { return }

        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort else { return }
        IONotificationPortSetDispatchQueue(notifyPort, .main)

        let context = Unmanaged.passUnretained(self).toOpaque()

        // Two separate matching dictionaries: IOServiceAddMatchingNotification
        // consumes a reference to the dictionary it is handed, so they cannot
        // be shared between the matched and terminated registrations.
        for (type, iterator) in [
            (kIOMatchedNotification, \DockWatcher.matchedIterator),
            (kIOTerminatedNotification, \DockWatcher.terminatedIterator),
        ] {
            guard let matching = Self.matchingDictionary(vendorID: vendorID) else { continue }

            var iter: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(
                notifyPort,
                type,
                matching,
                { context, iterator in
                    guard let context else { return }
                    let watcher = Unmanaged<DockWatcher>.fromOpaque(context).takeUnretainedValue()
                    watcher.drain(iterator)
                    watcher.emitCurrentState()
                },
                context,
                &iter
            )
            guard result == KERN_SUCCESS else { continue }
            self[keyPath: iterator] = iter
            // IOKit only starts delivering after the initial iterator is drained.
            drain(iter)
        }

        emitCurrentState()
    }

    public func stop() {
        for iterator in [matchedIterator, terminatedIterator] where iterator != 0 {
            IOObjectRelease(iterator)
        }
        matchedIterator = 0
        terminatedIterator = 0
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
        }
        notifyPort = nil
    }

    private func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    /// Re-reads presence from IOKit rather than trusting the callback type.
    ///
    /// The dock exposes multiple devices, so a single termination does not mean
    /// the dock is gone. Asking IOKit is cheap and avoids reference counting.
    private func emitCurrentState() {
        let present = isDockPresent()
        onChange(present)
    }
}
