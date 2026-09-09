import Foundation

/// Runs the bundled clamshell-daemon install/uninstall scripts with
/// administrator privileges, triggered by a button in Settings rather than
/// requiring the user to open Terminal.
///
/// Uses AppleScript's `do shell script ... with administrator privileges`,
/// which shows the standard macOS admin-password prompt (Authorization
/// Services) for this one command only. No persistent privileged helper, no
/// sudoers rule, no elevated code baked into the app — the user re-approves
/// every time. This is a different animal from the two options CLAUDE.md
/// says not to implement (SMAppService+XPC, sudoers NOPASSWD): those grant
/// standing privilege, this doesn't.
enum DaemonInstaller {
    enum InstallError: LocalizedError {
        case scriptNotFound(String)
        case scriptFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case let .scriptNotFound(name):
                return "\(name).sh isn't in this app bundle (Contents/Resources)."
            case let .scriptFailed(message):
                return message
            case .cancelled:
                return "Cancelled."
            }
        }
    }

    static func installDaemon() throws {
        try run(scriptName: "install-clamshell-daemon")
    }

    static func uninstallDaemon() throws {
        try run(scriptName: "uninstall-clamshell-daemon")
    }

    private static func run(scriptName: String) throws {
        guard let scriptURL = Bundle.main.url(forResource: scriptName, withExtension: "sh") else {
            throw InstallError.scriptNotFound(scriptName)
        }

        // Single-quote the path for the inner shell, escaping any embedded
        // single quotes defensively (install paths here never contain one,
        // but this makes the assumption explicit rather than silent).
        let shellSafePath = "'" + scriptURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let appleScriptSource = #"do shell script "/bin/bash \#(shellSafePath)" with administrator privileges"#

        guard let script = NSAppleScript(source: appleScriptSource) else {
            throw InstallError.scriptFailed("Could not construct the installer command.")
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            // -128 is the user cancelling the admin-password prompt.
            if let number = errorInfo[NSAppleScript.errorNumber] as? Int, number == -128 {
                throw InstallError.cancelled
            }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown error."
            throw InstallError.scriptFailed(message)
        }
    }
}
