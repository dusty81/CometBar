import Foundation
import Security

// Self-update from GitHub Releases. Adapted from Limbac's updater, with
// three deliberate differences because this repo is PUBLIC:
//
//  1. Plain unauthenticated HTTPS to api.github.com, not the `gh` CLI —
//     other people running CometBar won't have `gh` installed or logged in.
//  2. The downloaded app's code signature is verified (Developer ID, team
//     `CometGitHub.teamID`, bundle ID `com.djs.cometbar`) BEFORE it replaces
//     the installed one. A public auto-updater is otherwise a remote-code-
//     execution channel for anyone who can tamper with a release asset.
//  3. No Telegram notifier — CometBar has no bots.
//
// Pure selection logic lives here (and is unit-tested); the AppKit glue —
// relaunching, notifications, UI — is `UpdateChecker` in the app target.

public enum CometGitHub {
    public static let repoSlug = "dusty81/CometBar"
    public static let releasesAPI = URL(string: "https://api.github.com/repos/\(repoSlug)/releases?per_page=30")!
    public static let releasesPage = URL(string: "https://github.com/\(repoSlug)/releases")!
    /// Apple Developer team that signs every official build (see Makefile).
    public static let teamID = "7A5993N4F2"
    public static let bundleID = "com.djs.cometbar"
}

/// A parsed `major.minor.patch` version. Not full semver — every tag is a
/// plain `vMAJOR.MINOR.PATCH`.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `"1.2.3"` or `"v1.2.3"`; nil for anything else, so a malformed
    /// tag is skipped rather than crashing the checker.
    public init?(_ raw: String) {
        var s = Substring(raw.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0
        else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    /// Version of the bundle at `bundle` (default: the running app).
    public static func of(_ bundle: Bundle = .main) -> AppVersion? {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }
}

/// Which newer releases may be offered. Both only consider releases newer
/// than what's running.
public enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    /// Every release.
    case all
    /// Only `x.y.0` releases — skips patch-only bumps.
    case majorMinor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "Every release"
        case .majorMinor: return "Skip patch-only releases"
        }
    }

    public func allows(_ candidate: AppVersion) -> Bool {
        switch self {
        case .all: return true
        case .majorMinor: return candidate.patch == 0
        }
    }
}

/// What to do once an update is found.
public enum UpdateInstallPolicy: String, CaseIterable, Identifiable, Sendable {
    case notifyOnly
    case installOnQuit
    case installImmediately

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .notifyOnly: return "Notify me — I'll install it"
        case .installOnQuit: return "Install when I quit CometBar"
        case .installImmediately: return "Install and relaunch right away"
        }
    }
}

/// One entry of `GET /repos/:owner/:repo/releases`, only the fields used.
public struct GitHubRelease: Decodable, Sendable {
    public var tagName: String
    public var body: String?
    public var draft: Bool
    public var prerelease: Bool
    public var assets: [Asset]

    public struct Asset: Decodable, Sendable {
        public var name: String
        public var size: Int
        public var browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }

        public init(name: String, size: Int, browserDownloadURL: URL) {
            self.name = name
            self.size = size
            self.browserDownloadURL = browserDownloadURL
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body, draft, prerelease, assets
    }

    public init(tagName: String, body: String? = nil, draft: Bool = false, prerelease: Bool = false, assets: [Asset]) {
        self.tagName = tagName
        self.body = body
        self.draft = draft
        self.prerelease = prerelease
        self.assets = assets
    }

    public var version: AppVersion? { AppVersion(tagName) }

    /// Each release ships one `CometBar.zip` (`make release`). Matched by
    /// extension so a rename doesn't silently break updates.
    public var zipAsset: Asset? { assets.first { $0.name.lowercased().hasSuffix(".zip") } }
}

/// A release that's newer than what's running and allowed by the channel.
public struct PendingUpdate: Sendable, Equatable {
    public var version: AppVersion
    public var tagName: String
    public var releaseNotes: String
    public var downloadURL: URL
    public var size: Int

    /// Identity is the tag, so edited release notes aren't a "new" find.
    public static func == (lhs: PendingUpdate, rhs: PendingUpdate) -> Bool {
        lhs.tagName == rhs.tagName
    }
}

public enum UpdateSelector {
    /// Newest non-draft, non-prerelease release that's newer than `current`,
    /// allowed by `channel`, and has a `.zip` asset. Pure — no network.
    public static func bestUpdate(from releases: [GitHubRelease], current: AppVersion, channel: UpdateChannel) -> PendingUpdate? {
        let candidates = releases.compactMap { release -> (GitHubRelease, AppVersion, GitHubRelease.Asset)? in
            guard !release.draft, !release.prerelease,
                  let version = release.version, version > current,
                  channel.allows(version),
                  let zip = release.zipAsset
            else { return nil }
            return (release, version, zip)
        }
        guard let (release, version, zip) = candidates.max(by: { $0.1 < $1.1 }) else { return nil }
        return PendingUpdate(
            version: version,
            tagName: release.tagName,
            releaseNotes: release.body ?? "",
            downloadURL: zip.browserDownloadURL,
            size: zip.size
        )
    }
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case http(Int)
    case rateLimited
    case downloadTooLarge(Int)
    case unzipFailed
    case appNotFoundInArchive
    case signatureInvalid(String)
    case versionMismatch(expected: AppVersion, found: AppVersion?)
    case notInstalledInPlace(String)
    case swapFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .http(code):
            return "GitHub returned HTTP \(code)."
        case .rateLimited:
            return "GitHub's API rate limit was hit — it'll retry on the next check."
        case let .downloadTooLarge(bytes):
            return "The update download is unexpectedly large (\(bytes) bytes); refusing it."
        case .unzipFailed:
            return "Couldn't unpack the update archive."
        case .appNotFoundInArchive:
            return "The update archive doesn't contain CometBar.app."
        case let .signatureInvalid(detail):
            return "The downloaded update isn't signed by CometBar's developer, so it wasn't installed. (\(detail))"
        case let .versionMismatch(expected, found):
            return "The downloaded app is version \(found.map(\.description) ?? "unknown"), not \(expected); refusing it."
        case let .notInstalledInPlace(detail):
            return detail
        case let .swapFailed(detail):
            return "Couldn't replace the installed app: \(detail)"
        }
    }
}

/// Network + filesystem half of updating. No AppKit: the caller relaunches.
public enum UpdateInstaller {
    /// Hard cap on the download; the real zip is ~3 MB.
    public static let maxDownloadBytes = 100 * 1024 * 1024

    public static func fetchReleases(session: URLSession = .shared, currentVersion: AppVersion?) async throws -> [GitHubRelease] {
        var request = URLRequest(url: CometGitHub.releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // GitHub requires a User-Agent; identify the app, nothing about the user.
        request.setValue("CometBar/\(currentVersion?.description ?? "dev")", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let exhausted = http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
            if http.statusCode == 429 || (http.statusCode == 403 && exhausted) {
                throw UpdateError.rateLimited
            }
            throw UpdateError.http(http.statusCode)
        }
        return try JSONDecoder().decode([GitHubRelease].self, from: data)
    }

    /// Refuses to self-update when the running copy can't be replaced in
    /// place: run from a translocated (quarantined, never-moved) location,
    /// from inside a disk image, or from a build directory.
    public static func installLocationProblem(for bundleURL: URL) -> String? {
        let path = bundleURL.path
        if path.contains("/AppTranslocation/") {
            return "CometBar is running from a temporary location macOS assigned it. Move CometBar.app to /Applications, open it from there, then update."
        }
        if path.hasPrefix("/Volumes/") {
            return "CometBar is running from a disk image or external volume. Copy it to /Applications first."
        }
        if !FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) {
            return "This account can't write to \(bundleURL.deletingLastPathComponent().path), so CometBar can't replace itself. Download the update from GitHub instead."
        }
        return nil
    }

    /// Downloads, unpacks, verifies, and swaps in `update` over the app at
    /// `installedURL`. On any failure the installed app is left untouched.
    public static func install(_ update: PendingUpdate, over installedURL: URL, session: URLSession = .shared) async throws {
        if let problem = installLocationProblem(for: installedURL) {
            throw UpdateError.notInstalledInPlace(problem)
        }
        if update.size > maxDownloadBytes { throw UpdateError.downloadTooLarge(update.size) }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("cometbar-update-\(UUID().uuidString)")
        let extractDir = workDir.appendingPathComponent("extracted")
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let (downloaded, response) = try await session.download(from: update.downloadURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.http(http.statusCode)
        }
        let zipURL = workDir.appendingPathComponent("CometBar.zip")
        try fm.moveItem(at: downloaded, to: zipURL)
        let bytes = (try? fm.attributesOfItem(atPath: zipURL.path)[.size] as? Int) ?? 0
        if bytes > maxDownloadBytes { throw UpdateError.downloadTooLarge(bytes) }

        // ditto, not unzip: it's what produced the archive and it preserves
        // the bundle's extended attributes and signature layout.
        guard runTool("/usr/bin/ditto", ["-x", "-k", zipURL.path, extractDir.path]) else {
            throw UpdateError.unzipFailed
        }
        let newApp = extractDir.appendingPathComponent("CometBar.app")
        guard fm.fileExists(atPath: newApp.appendingPathComponent("Contents/Info.plist").path) else {
            throw UpdateError.appNotFoundInArchive
        }

        try verifySignature(of: newApp)
        let found = Bundle(url: newApp).flatMap { AppVersion.of($0) }
        guard found == update.version else {
            throw UpdateError.versionMismatch(expected: update.version, found: found)
        }

        // URLSession downloads don't get quarantined, but be certain the
        // swapped-in build never re-prompts Gatekeeper.
        _ = runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        try swap(installed: installedURL, with: newApp)
    }

    /// Code-signing requirement every official build satisfies: Apple-
    /// anchored Developer ID chain, our team, our bundle identifier.
    public static let designatedRequirement =
        #"anchor apple generic and identifier "\#(CometGitHub.bundleID)" and certificate leaf[subject.OU] = "\#(CometGitHub.teamID)""#

    /// Throws unless the bundle at `appURL` is intact and signed per
    /// `designatedRequirement`. Checks every nested file (strict, all
    /// architectures), so a modified binary or resource fails too.
    public static func verifySignature(of appURL: URL, requirement: String = designatedRequirement) throws {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw UpdateError.signatureInvalid("unreadable bundle, OSStatus \(status)")
        }
        var req: SecRequirement?
        status = SecRequirementCreateWithString(requirement as CFString, [], &req)
        guard status == errSecSuccess, let req else {
            throw UpdateError.signatureInvalid("bad requirement, OSStatus \(status)")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var cfError: Unmanaged<CFError>?
        status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, req, &cfError)
        guard status == errSecSuccess else {
            let detail = cfError.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "OSStatus \(status)"
            throw UpdateError.signatureInvalid(detail)
        }
    }

    /// Replaces `installed` with `newApp`, rolling back if the second move
    /// fails so the install location is never left empty. Safe while the old
    /// copy is running: the process keeps its open executable across a rename.
    public static func swap(installed: URL, with newApp: URL) throws {
        let fm = FileManager.default
        let backup = installed.deletingLastPathComponent()
            .appendingPathComponent(".\(installed.lastPathComponent).prev-\(UUID().uuidString.prefix(8))")
        do {
            try fm.moveItem(at: installed, to: backup)
        } catch {
            throw UpdateError.swapFailed(error.localizedDescription)
        }
        do {
            try fm.moveItem(at: newApp, to: installed)
        } catch {
            try? fm.moveItem(at: backup, to: installed)
            throw UpdateError.swapFailed(error.localizedDescription)
        }
        try? fm.removeItem(at: backup)
    }

    @discardableResult
    static func runTool(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// Whether the installed clamshell daemon matches the one bundled with this
/// app. An app update can't replace it (it's root-owned), so the UI offers
/// the bundled installer — which asks for an admin password — instead.
public enum DaemonVersionCheck {
    public static let installedBinary = URL(fileURLWithPath: "/usr/local/libexec/kvm-clamshelld")

    /// nil when there's nothing to compare (daemon not installed, or no
    /// bundled copy, e.g. a `swift run` build); otherwise whether they differ.
    public static func isOutdated(bundled: URL?, installed: URL = installedBinary) -> Bool? {
        guard let bundled,
              FileManager.default.fileExists(atPath: installed.path),
              FileManager.default.fileExists(atPath: bundled.path)
        else { return nil }
        return !FileManager.default.contentsEqual(atPath: bundled.path, andPath: installed.path)
    }
}
