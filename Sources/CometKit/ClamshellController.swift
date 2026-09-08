import Foundation

/// Reads and (optionally) changes macOS lid-close sleep behaviour.
///
/// SCOPE: this whole type is behind `FeatureFlags.clamshellControl`, which is
/// OFF by default. Dusty's EDID config currently works and he has not yet
/// confirmed whether clamshell survives repeated switch cycles. Reading status
/// is always safe; writing is not wired up yet on purpose.
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

    /// Writing requires root, which a GUI app does not have.
    ///
    /// Three options are on the table; see the "unresolved design question"
    /// section of CLAUDE.md. Dusty's stated preference is (1): signal the
    /// existing root LaunchDaemon `com.djs.kvm-clamshell` rather than
    /// implementing privilege escalation in the app.
    ///
    /// Do NOT implement SMAppService or a sudoers rule without asking him.
    public static func setLidSleepDisabled(_ disabled: Bool) throws {
        throw ClamshellError.notImplemented
    }

    public enum ClamshellError: Error, LocalizedError {
        case notImplemented
        case commandFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notImplemented:
                return """
                Changing lid-sleep needs root. Decide the privilege approach \
                first — see CLAUDE.md.
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
    /// Off until Dusty confirms clamshell behaviour across switch cycles.
    public static let clamshellControl = false
    /// Off until the Flexbar is confirmed to sit off the KVM'd USB path.
    public static let flexbarIntegration = false
}
