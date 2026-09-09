import Foundation

/// User-configurable connection settings.
///
/// The password is deliberately NOT part of this type — it stays in the
/// Keychain via `Keychain`, keyed by `user`, so changing `user` here also
/// changes which Keychain entry gets read.
///
/// Port friendly names are NOT here either — they're written to and read
/// from the Comet X itself via `CometClient.setPortName`/`switchState`
/// (`model.ports[].name`), confirmed live on 2026-09-08 to round-trip
/// cleanly through `set_port_params`. See `AppModel.savePortNames`.
public struct CometSettings: Equatable, Sendable {
    public var host: String
    public var user: String
    public var refreshIntervalSeconds: Double
    /// USB vendor ID used to detect dock presence (`DockWatcher`). Different
    /// dock models — and the same model across different Macs — enumerate
    /// under different vendor IDs, so this can't be one hardcoded constant;
    /// see `USBDeviceLister` for how the Settings UI helps pick the right one.
    public var dockVendorID: Int

    public static let defaultHost = "glkvm.local"
    public static let defaultUser = "admin"
    /// This polls the KVM's HTTP API — unlike dock detection there's no push
    /// mechanism available, so some polling is unavoidable. Kept infrequent.
    public static let defaultRefreshIntervalSeconds: Double = 45
    public static let minimumRefreshIntervalSeconds: Double = 15
    /// OWC Thunderbolt 3 Dock — Dusty's original hardware. Just a starting
    /// default; machines with a different dock need to reconfigure this.
    public static let defaultDockVendorID = 0x1E91

    public init(
        host: String = defaultHost,
        user: String = defaultUser,
        refreshIntervalSeconds: Double = defaultRefreshIntervalSeconds,
        dockVendorID: Int = defaultDockVendorID
    ) {
        self.host = host
        self.user = user
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.dockVendorID = dockVendorID
    }
}

/// Persists `CometSettings` in UserDefaults.
///
/// The password never passes through here — see `Keychain`. Pass a custom
/// `defaults` suite in tests to avoid touching the user's real preferences.
public enum SettingsStore {
    private static let hostKey = "comet.host"
    private static let userKey = "comet.user"
    private static let refreshIntervalKey = "comet.refreshIntervalSeconds"
    private static let dockVendorIDKey = "comet.dockVendorID"

    public static func load(from defaults: UserDefaults = .standard) -> CometSettings {
        let interval = defaults.double(forKey: refreshIntervalKey)
        let vendorID = defaults.object(forKey: dockVendorIDKey) as? Int
        return CometSettings(
            host: defaults.string(forKey: hostKey) ?? CometSettings.defaultHost,
            user: defaults.string(forKey: userKey) ?? CometSettings.defaultUser,
            refreshIntervalSeconds: interval > 0 ? interval : CometSettings.defaultRefreshIntervalSeconds,
            dockVendorID: vendorID ?? CometSettings.defaultDockVendorID
        )
    }

    public static func save(_ settings: CometSettings, to defaults: UserDefaults = .standard) {
        defaults.set(settings.host, forKey: hostKey)
        defaults.set(settings.user, forKey: userKey)
        defaults.set(settings.refreshIntervalSeconds, forKey: refreshIntervalKey)
        defaults.set(settings.dockVendorID, forKey: dockVendorIDKey)
    }
}
