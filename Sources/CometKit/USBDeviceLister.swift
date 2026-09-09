import Foundation
import IOKit
import IOKit.usb

/// One connected USB device, deduplicated by vendor ID — enough to let a
/// user pick "that's my dock" without knowing hex vendor IDs by heart.
public struct USBDeviceInfo: Identifiable, Hashable, Sendable {
    public var id: Int { vendorID }
    public let vendorID: Int
    public let name: String

    public var vendorIDHex: String {
        "0x" + String(vendorID, radix: 16, uppercase: true)
    }
}

/// Lists currently attached USB devices. Different docks — and the same
/// dock model across different Macs — can enumerate under different vendor
/// IDs, so `DockWatcher`'s vendor ID can't be a single hardcoded constant
/// for everyone; this is how the Settings UI lets you pick the right one
/// instead of guessing.
public enum USBDeviceLister {
    public static func connectedDevices() -> [USBDeviceInfo] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var seenVendors = Set<Int>()
        var results: [USBDeviceInfo] = []

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let vendorID = intProperty(service, "idVendor"), !seenVendors.contains(vendorID) else {
                continue
            }
            seenVendors.insert(vendorID)
            let name = stringProperty(service, "USB Product Name")
                ?? stringProperty(service, "kUSBProductString")
                ?? "Unknown device"
            results.append(USBDeviceInfo(vendorID: vendorID, name: name))
        }
        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func intProperty(_ service: io_service_t, _ key: String) -> Int? {
        guard let cf = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        else { return nil }
        return (cf as? NSNumber)?.intValue
    }

    private static func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}
