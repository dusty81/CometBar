import CometKit
import Foundation

// Entire body of the com.djs.kvm-clamshell LaunchDaemon. Runs as root,
// started at boot (RunAtLoad + KeepAlive). Deliberately does nothing until
// the control flag at ClamshellController.controlFlagURL is set to "1" —
// see scripts/install-clamshell-daemon.sh.

// stdout is redirected to a regular file (StandardOutPath in the plist),
// which makes it fully buffered by default — log lines would sit unflushed
// for a daemon that runs forever. Line-buffer instead.
setvbuf(stdout, nil, _IOLBF, 0)

ClamshellDaemonLoop().run()
