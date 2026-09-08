import Foundation

/// A KVM port, addressed the way the user thinks about it: 1 through 4.
///
/// The device has two coexisting representations and mixing them up is the
/// most likely bug in this project:
///   - `id` — the string "1.4", 1-based channel. What `set_active` wants.
///   - `channel` — 0-based index into the `video.links` / `usb_otg.links` arrays.
public struct PortNumber: Hashable, Sendable, CustomStringConvertible {
    /// 1-based, as the user sees it.
    public let number: Int
    /// Unit. Always 1 on a single Comet X; multi-unit chains would vary.
    public let unit: Int

    public init?(_ number: Int, unit: Int = 1) {
        guard (1...4).contains(number) else { return nil }
        self.number = number
        self.unit = unit
    }

    /// 0-based index into the link arrays.
    public var channel: Int { number - 1 }

    /// The device's port ID, e.g. "1.4".
    public var id: String { "\(unit).\(number)" }

    /// The value `set_active` expects — the ID parsed as a float.
    ///
    /// Do NOT send the bare channel index here. `port=3` passes float
    /// validation and then returns 500 from the handler.
    public var apiValue: String { id }

    public var description: String { "port \(number)" }
}

/// The subset of `GET /api/switch` this app actually needs.
public struct SwitchState: Sendable, Equatable {
    public struct Port: Sendable, Equatable, Identifiable {
        public let id: String          // "1.4"
        public let channel: Int        // 0-based
        public let name: String        // empty on a fresh device
        public let videoLinked: Bool
        public let usbLinked: Bool

        /// 1-based port number, or nil if the ID isn't the expected "u.n" shape.
        public var number: Int? { Int(id.split(separator: ".").last ?? "") }
    }

    public let activeID: String        // summary.active_id, e.g. "1.4"
    public let activeChannel: Int      // summary.active_port, 0-based
    public let synced: Bool
    public let ports: [Port]

    public var activePort: PortNumber? {
        guard let n = Int(activeID.split(separator: ".").last ?? "") else { return nil }
        return PortNumber(n)
    }
}

public struct DeviceInfo: Sendable, Equatable {
    public let kvmdVersion: String
    public let kernelRelease: String
    public let platformModel: String
    public let cpuTempC: Double?
}

public enum CometError: Error, LocalizedError, Sendable {
    case missingCredential(service: String, account: String)
    case unauthorized
    /// The device returned HTTP 200 with `{"ok": false, ...}`.
    case apiError(code: String, message: String)
    case badPort(Int)
    case http(status: Int, body: String)
    case decoding(String)
    case keychainWrite(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .missingCredential(service, account):
            return """
            No Keychain entry for service '\(service)', account '\(account)'. \
            Add one with: security add-generic-password -a \(account) -s \(service) -w
            """
        case .unauthorized:
            return "The Comet X rejected the credentials."
        case let .apiError(code, message):
            return "Comet X API error \(code): \(message)"
        case let .badPort(n):
            return "Port \(n) is out of range; the Comet X has ports 1-4."
        case let .http(status, body):
            // A 500 here most often means a malformed port value.
            let hint = status == 500
                ? " (a 500 from set_active usually means a malformed port — see the float trap in CLAUDE.md)"
                : ""
            return "HTTP \(status)\(hint): \(body)"
        case let .decoding(what):
            return "Could not decode the device response: \(what)"
        case let .keychainWrite(status):
            return "Could not save the password to the Keychain (OSStatus \(status))."
        }
    }
}
