import CometKit
import Foundation
import XCTest

final class AppVersionTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(AppVersion("1.2.3"), AppVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(AppVersion("v0.9.3"), AppVersion(major: 0, minor: 9, patch: 3))
        for bad in ["", "1.2", "1.2.3.4", "v1.x.0", "1.2.3-beta", "-1.0.0", "latest"] {
            XCTAssertNil(AppVersion(bad), bad)
        }
    }

    func testOrdering() {
        XCTAssertLessThan(AppVersion("0.9.3")!, AppVersion("1.0.0")!)
        XCTAssertLessThan(AppVersion("1.0.9")!, AppVersion("1.0.10")!)  // numeric, not lexical
        XCTAssertEqual(AppVersion("1.0.0")!.description, "1.0.0")
    }
}

final class UpdateSelectorTests: XCTestCase {
    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, zip: Bool = true) -> GitHubRelease {
        let assets = zip
            ? [GitHubRelease.Asset(name: "CometBar.zip", size: 3_000_000, browserDownloadURL: URL(string: "https://example.invalid/\(tag).zip")!)]
            : []
        return GitHubRelease(tagName: tag, body: "notes \(tag)", draft: draft, prerelease: prerelease, assets: assets)
    }

    func testPicksNewest() {
        let releases = [release("v0.9.3"), release("v1.0.1"), release("v1.0.0")]
        let best = UpdateSelector.bestUpdate(from: releases, current: AppVersion("0.9.3")!, channel: .all)
        XCTAssertEqual(best?.tagName, "v1.0.1")
        XCTAssertEqual(best?.releaseNotes, "notes v1.0.1")
    }

    func testNothingWhenCurrentIsNewest() {
        XCTAssertNil(UpdateSelector.bestUpdate(from: [release("v1.0.0")], current: AppVersion("1.0.0")!, channel: .all))
        XCTAssertNil(UpdateSelector.bestUpdate(from: [release("v0.9.3")], current: AppVersion("1.0.0")!, channel: .all))
    }

    func testSkipsDraftsPrereleasesMissingZipAndBadTags() {
        let releases = [
            release("v2.0.0", draft: true),
            release("v1.9.0", prerelease: true),
            release("v1.8.0", zip: false),
            release("nightly"),
            release("v1.1.0"),
        ]
        XCTAssertEqual(UpdateSelector.bestUpdate(from: releases, current: AppVersion("1.0.0")!, channel: .all)?.tagName, "v1.1.0")
    }

    func testMajorMinorChannelSkipsPatches() {
        let releases = [release("v1.0.1"), release("v1.1.0"), release("v1.1.2")]
        let current = AppVersion("1.0.0")!
        XCTAssertEqual(UpdateSelector.bestUpdate(from: releases, current: current, channel: .majorMinor)?.tagName, "v1.1.0")
        XCTAssertNil(UpdateSelector.bestUpdate(from: [release("v1.0.1")], current: current, channel: .majorMinor))
    }

    func testDecodesGitHubJSON() throws {
        let json = #"""
        [{"tag_name":"v1.0.0","body":"hi","draft":false,"prerelease":false,"name":"v1.0.0",
          "assets":[{"name":"CometBar.zip","size":2950847,"browser_download_url":"https://github.com/dusty81/CometBar/releases/download/v1.0.0/CometBar.zip"}]}]
        """#
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: Data(json.utf8))
        XCTAssertEqual(releases.first?.version, AppVersion("1.0.0"))
        XCTAssertEqual(releases.first?.zipAsset?.size, 2950847)
    }
}

final class UpdateInstallerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func fakeApp(_ name: String, marker: String) throws -> URL {
        let app = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try marker.write(to: app.appendingPathComponent("Contents/marker"), atomically: true, encoding: .utf8)
        return app
    }

    func testSwapReplacesAndCleansUp() throws {
        let installed = try fakeApp("CometBar.app", marker: "old")
        let newApp = try fakeApp("New.app", marker: "new")
        try UpdateInstaller.swap(installed: installed, with: newApp)
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("Contents/marker"), encoding: .utf8), "new")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(leftovers, ["CometBar.app"])
    }

    func testSwapRollsBackWhenNewAppMissing() throws {
        let installed = try fakeApp("CometBar.app", marker: "old")
        XCTAssertThrowsError(try UpdateInstaller.swap(installed: installed, with: dir.appendingPathComponent("Missing.app")))
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("Contents/marker"), encoding: .utf8), "old")
    }

    func testInstallLocationProblems() {
        XCTAssertNotNil(UpdateInstaller.installLocationProblem(
            for: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/CometBar.app")))
        XCTAssertNotNil(UpdateInstaller.installLocationProblem(for: URL(fileURLWithPath: "/Volumes/CometBar/CometBar.app")))
        XCTAssertNil(UpdateInstaller.installLocationProblem(for: dir.appendingPathComponent("CometBar.app")))
    }

    func testUnsignedBundleIsRejected() throws {
        let app = try fakeApp("CometBar.app", marker: "x")
        XCTAssertThrowsError(try UpdateInstaller.verifySignature(of: app))
    }

    /// Uses the bundle `make app` produced, when present (skipped otherwise).
    func testRealSignedBuildPassesAndTamperedCopyFails() throws {
        let built = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/CometBar.app")
        guard FileManager.default.fileExists(atPath: built.path) else {
            throw XCTSkip("no build/CometBar.app — run `make app` first")
        }
        XCTAssertNoThrow(try UpdateInstaller.verifySignature(of: built))

        // Wrong team: same bundle must fail a requirement for someone else.
        XCTAssertThrowsError(try UpdateInstaller.verifySignature(
            of: built,
            requirement: #"anchor apple generic and certificate leaf[subject.OU] = "AAAAAAAAAA""#))

        // Tampered resource: copy, modify one sealed file, must fail.
        let copy = dir.appendingPathComponent("CometBar.app")
        XCTAssertTrue(UpdateInstallerTestsSupport.ditto(built, copy))
        let script = copy.appendingPathComponent("Contents/Resources/install-clamshell-daemon.sh")
        try ("echo pwned\n" + String(contentsOf: script, encoding: .utf8)).write(to: script, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try UpdateInstaller.verifySignature(of: copy))
    }
}

final class DaemonVersionCheckTests: XCTestCase {
    func testComparison() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DaemonCheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try "same".write(to: a, atomically: true, encoding: .utf8)
        try "same".write(to: b, atomically: true, encoding: .utf8)
        XCTAssertEqual(DaemonVersionCheck.isOutdated(bundled: a, installed: b), false)
        try "diff".write(to: b, atomically: true, encoding: .utf8)
        XCTAssertEqual(DaemonVersionCheck.isOutdated(bundled: a, installed: b), true)
        XCTAssertNil(DaemonVersionCheck.isOutdated(bundled: a, installed: dir.appendingPathComponent("none")))
        XCTAssertNil(DaemonVersionCheck.isOutdated(bundled: nil, installed: b))
    }
}

enum UpdateInstallerTestsSupport {
    static func ditto(_ from: URL, _ to: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = [from.path, to.path]
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// Live end-to-end check against the real GitHub releases. Opt-in, since it
/// hits the network: COMETBAR_NETWORK_TESTS=1 swift test --filter LiveUpdateTests
final class LiveUpdateTests: XCTestCase {
    func testFetchSelectAndInstallRealRelease() async throws {
        guard ProcessInfo.processInfo.environment["COMETBAR_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("set COMETBAR_NETWORK_TESTS=1 to run")
        }
        let releases = try await UpdateInstaller.fetchReleases(currentVersion: AppVersion("0.9.2"))
        let update = try XCTUnwrap(UpdateSelector.bestUpdate(
            from: releases.filter { $0.tagName == "v0.9.3" }, current: AppVersion("0.9.2")!, channel: .all))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LiveUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let installed = dir.appendingPathComponent("CometBar.app")
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("Contents"), withIntermediateDirectories: true)

        try await UpdateInstaller.install(update, over: installed)
        XCTAssertEqual(Bundle(url: installed).flatMap { AppVersion.of($0) }, AppVersion("0.9.3"))
        XCTAssertNoThrow(try UpdateInstaller.verifySignature(of: installed))
    }
}
