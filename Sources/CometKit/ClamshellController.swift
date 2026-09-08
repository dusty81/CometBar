import Foundation

/// Reads and writes macOS lid-close sleep behaviour.
///
/// Reading requires no privileges. Writing (`setLidSleepDisabled`) calls
/// `pmset -a`, which needs root — it is only ever invoked by the
/// `kvm-clamshelld` root LaunchDaemon (see `ClamshellDaemonLoop`), never
/// directly by CometBar or comet-cli, which run as the logged-in user.
///
/// The app and the daemon coordinate through `controlFlagURL`, a small
/// user-owned file: the app (unprivileged) writes "0"/"1" to say whether the
/// workaround should be active at all; the daemon (root) reads it, combines
/// it with live dock presence, and applies `pmset` accordingly. This avoids
/// any privilege-escalation code in the app itself, per CLAUDE.md's stated
/// preference.
public struct ClamshellController: Sendable {

    /// Reading requires no privileges.
    ///
    /// NOTE: `pmset -g` labels this **`SleepDisabled`**. `disablesleep` is only
    /// the argument name for `pmset -a`, and grepping for it — as the original
    /// shell script did — silently matches nothing and reports the status
    /// backwards, always. The section is also omitted entirely on some macOS
    /// builds when the value is 0, so absence means "enabled".
    public static func isLidSleepDisabled() throws -> Bool {
        let output = try run("/usr/bin/pmset", ["-g"])
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("SleepDisabled") else { continue }
            // pmset separates the label from the value with TABS, not spaces.
            // Splitting on " " returns the whole line as one element and the
            // check silently fails — verified against real output.
            return trimmed.split(whereSeparator: \.isWhitespace)
                .last.map(String.init) == "1"
        }
        return false
    }

    /// Writes `pmset -a disablesleep <0|1>`. Requires root.
    public static func setLidSleepDisabled(_ disabled: Bool) throws {
        _ = try run("/usr/bin/pmset", ["-a", "disablesleep", disabled ? "1" : "0"])
    }

    // MARK: - App <-> daemon coordination

    /// Owned by the primary user (set up by the daemon installer), so the
    /// unprivileged app can write it while the root daemon can always read
    /// it regardless of file permissions.
    public static let controlFlagURL = URL(
        fileURLWithPath: "/Library/Application Support/CometKit/clamshell-enabled"
    )

    public static let daemonPlistURL = URL(
        fileURLWithPath: "/Library/LaunchDaemons/com.djs.kvm-clamshell.plist"
    )

    /// Whether the clamshell workaround is turned on. Defaults to false
    /// (matching the old compile-time `FeatureFlags.clamshellControl`) if the
    /// control file is missing — e.g. the daemon hasn't been installed yet.
    public static func isControlEnabled() -> Bool {
        guard let raw = try? String(contentsOf: controlFlagURL, encoding: .utf8) else {
            return false
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// Flips the control flag. Throws if the control file doesn't exist yet
    /// (the daemon installer creates it) rather than silently no-opping.
    public static func setControlEnabled(_ enabled: Bool) throws {
        guard FileManager.default.fileExists(atPath: controlFlagURL.path) else {
            throw ClamshellError.daemonNotInstalled
        }
        try (enabled ? "1" : "0").write(to: controlFlagURL, atomically: false, encoding: .utf8)
    }

    public static func isDaemonInstalled() -> Bool {
        FileManager.default.fileExists(atPath: daemonPlistURL.path)
    }

    public enum ClamshellError: Error, LocalizedError {
        case daemonNotInstalled
        case commandFailed(String)

        public var errorDescription: String? {
            switch self {
            case .daemonNotInstalled:
                return """
                The kvm-clamshelld LaunchDaemon isn't installed yet. Run, with sudo, \
                install-clamshell-daemon.sh — either from the app bundle's \
                Contents/Resources, or scripts/ in a repo checkout.
                """
            case let .commandFailed(message):
                return message
            }
        }
    }

    private static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ClamshellError.commandFailed("\(path) exited \(process.terminationStatus)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public struct FeatureFlags {
    /// Off until the Flexbar is confirmed to sit off the KVM'd USB path.
    public static let flexbarIntegration = false
}
