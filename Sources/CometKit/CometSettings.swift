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

    public static let defaultHost = "glkvm.local"
    public static let defaultUser = "admin"
    /// This polls the KVM's HTTP API — unlike dock detection there's no push
    /// mechanism available, so some polling is unavoidable. Kept infrequent.
    public static let defaultRefreshIntervalSeconds: Double = 45
    public static let minimumRefreshIntervalSeconds: Double = 15

    public init(
        host: String = defaultHost,
        user: String = defaultUser,
        refreshIntervalSeconds: Double = defaultRefreshIntervalSeconds
    ) {
        self.host = host
        self.user = user
        self.refreshIntervalSeconds = refreshIntervalSeconds
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

    public static func load(from defaults: UserDefaults = .standard) -> CometSettings {
        let interval = defaults.double(forKey: refreshIntervalKey)
        return CometSettings(
            host: defaults.string(forKey: hostKey) ?? CometSettings.defaultHost,
            user: defaults.string(forKey: userKey) ?? CometSettings.defaultUser,
            refreshIntervalSeconds: interval > 0 ? interval : CometSettings.defaultRefreshIntervalSeconds
        )
    }

    public static func save(_ settings: CometSettings, to defaults: UserDefaults = .standard) {
        defaults.set(settings.host, forKey: hostKey)
        defaults.set(settings.user, forKey: userKey)
        defaults.set(settings.refreshIntervalSeconds, forKey: refreshIntervalKey)
    }
}
