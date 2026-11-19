import CometKit
import Foundation
import XCTest

/// GitHub issue #1: the root daemon can't read the user's UserDefaults, so
/// the dock vendor ID is shared through a file next to `clamshell-enabled`.
final class SharedDockVendorIDTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("dock-vendor-id") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedDockVendorIDTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRoundTrip() throws {
        XCTAssertTrue(try ClamshellController.writeSharedDockVendorID(8584, to: file))
        XCTAssertEqual(ClamshellController.sharedDockVendorID(at: file), 8584)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "8584")
    }

    func testMissingFileReadsNil() {
        XCTAssertNil(ClamshellController.sharedDockVendorID(at: file))
    }

    func testMalformedOrNonPositiveReadsNil() throws {
        for raw in ["", "abc", "0x2188", "0", "-5"] {
            try raw.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertNil(ClamshellController.sharedDockVendorID(at: file), "raw: \(raw)")
        }
    }

    func testToleratesWhitespace() throws {
        try " 8584\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClamshellController.sharedDockVendorID(at: file), 8584)
    }

    func testNoOpWhenDaemonDirectoryMissing() throws {
        let missing = dir.appendingPathComponent("nope/dock-vendor-id")
        XCTAssertFalse(try ClamshellController.writeSharedDockVendorID(8584, to: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
