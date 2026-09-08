import XCTest
@testable import CometKit

/// These tests exist because of the float trap documented in CLAUDE.md:
/// `set_active` wants the port ID ("1.4"), and sending a bare channel index
/// passes float validation server-side and then returns HTTP 500.
final class PortNumberTests: XCTestCase {

    func testPortIDIsOneBasedNotChannelIndex() throws {
        let port = try XCTUnwrap(PortNumber(4))
        XCTAssertEqual(port.id, "1.4", "set_active must receive the 1-based ID")
        XCTAssertEqual(port.apiValue, "1.4")
        XCTAssertEqual(port.channel, 3, "link arrays are indexed 0-based")
    }

    func testAllFourPortsMap() throws {
        let expected = [(1, "1.1", 0), (2, "1.2", 1), (3, "1.3", 2), (4, "1.4", 3)]
        for (number, id, channel) in expected {
            let port = try XCTUnwrap(PortNumber(number))
            XCTAssertEqual(port.id, id)
            XCTAssertEqual(port.channel, channel)
        }
    }

    func testOutOfRangePortsRejected() {
        XCTAssertNil(PortNumber(0), "0 would be a channel index, not a port")
        XCTAssertNil(PortNumber(5))
        XCTAssertNil(PortNumber(-1))
    }

    /// Guards the exact confusion that caused the 500 during API discovery.
    func testApiValueNeverEqualsChannelIndex() throws {
        for number in 1...4 {
            let port = try XCTUnwrap(PortNumber(number))
            XCTAssertNotEqual(
                port.apiValue, String(port.channel),
                "apiValue must be the '1.N' ID, never the raw channel index"
            )
        }
    }
}

final class SwitchStateTests: XCTestCase {

    func testActivePortDerivedFromActiveID() {
        let state = SwitchState(
            activeID: "1.4",
            activeChannel: 3,
            synced: true,
            ports: [],
            edidsInUse: []
        )
        XCTAssertEqual(state.activePort?.number, 4)
        XCTAssertEqual(state.activePort?.channel, state.activeChannel)
    }

    func testPortNumberParsedFromID() {
        let port = SwitchState.Port(
            id: "1.2", channel: 1, name: "", videoLinked: true, usbLinked: true
        )
        XCTAssertEqual(port.number, 2)
    }
}
