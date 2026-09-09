import XCTest
@testable import CometKit

final class CometSettingsTests: XCTestCase {

    func testSettingsStoreRoundTrip() throws {
        let suiteName = "CometSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = CometSettings(
            host: "10.0.1.173",
            user: "dusty",
            refreshIntervalSeconds: 90,
            dockVendorID: 0x05AC,
            switchConfirmationEnabled: false,
            switchConfirmationDelaySeconds: 4
        )
        SettingsStore.save(settings, to: defaults)

        XCTAssertEqual(SettingsStore.load(from: defaults), settings)
    }

    func testSettingsStoreLoadsDefaultsWhenEmpty() throws {
        let suiteName = "CometSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let loaded = SettingsStore.load(from: defaults)
        XCTAssertEqual(loaded.host, CometSettings.defaultHost)
        XCTAssertEqual(loaded.user, CometSettings.defaultUser)
        XCTAssertEqual(loaded.refreshIntervalSeconds, CometSettings.defaultRefreshIntervalSeconds)
        XCTAssertEqual(loaded.dockVendorID, CometSettings.defaultDockVendorID)
        XCTAssertEqual(loaded.switchConfirmationEnabled, CometSettings.defaultSwitchConfirmationEnabled)
        XCTAssertEqual(loaded.switchConfirmationDelaySeconds, CometSettings.defaultSwitchConfirmationDelaySeconds)
    }
}
