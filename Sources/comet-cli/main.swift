import CometKit
import Foundation

// CLI front end. Fastest way to exercise CometKit against the live device
// without building an app bundle. Deliberately thin — all logic lives in the
// library so the CLI and the menu bar app test identical code paths.

func usage() -> Never {
    let name = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    print("""
    Usage: \(name) <command>

      status          Show active port, link state and EDID assignment
      info            Firmware and health
      set <1-4>       Switch the KVM to a port
      dock            Report whether the OWC dock is attached
      clamshell       Report macOS lid-close sleep state

    Env: KVM_HOST (default glkvm.local), KVM_USER (default admin)
    """)
    exit(1)
}

func makeClient() -> CometClient {
    let env = ProcessInfo.processInfo.environment
    return CometClient(
        host: env["KVM_HOST"] ?? "glkvm.local",
        user: env["KVM_USER"] ?? "admin"
    )
}

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(
        Data(("Error: " + (error.localizedDescription) + "\n").utf8)
    )
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

switch command {
case "status":
    do {
        let state = try await makeClient().switchState()
        print("Active port : \(state.activeID) (channel \(state.activeChannel))  synced=\(state.synced)")
        print("EDID in use : \(state.edidsInUse.isEmpty ? "NONE" : state.edidsInUse.joined(separator: ", "))")
        print("")
        print("  port  video  usb   name")
        for port in state.ports {
            let marker = port.id == state.activeID ? "*" : " "
            // String(format:) with %-5@ does not pad NSString — pad manually.
            func pad(_ text: String, _ width: Int) -> String {
                text.count >= width
                    ? text
                    : text + String(repeating: " ", count: width - text.count)
            }
            print(marker
                + " " + pad(port.id, 6)
                + pad(port.videoLinked ? "up" : "--", 7)
                + pad(port.usbLinked ? "up" : "--", 6)
                + (port.name.isEmpty ? "(unnamed)" : port.name))
        }
    } catch { fail(error) }

case "info":
    do {
        let info = try await makeClient().info()
        print("kvmd      : \(info.kvmdVersion)")
        print("kernel    : \(info.kernelRelease)")
        print("platform  : \(info.platformModel)")
        if let temp = info.cpuTempC {
            print("cpu temp  : \(String(format: "%.1f", temp)) C")
        }
    } catch { fail(error) }

case "set":
    guard arguments.count == 2, let number = Int(arguments[1]) else { usage() }
    do {
        try await makeClient().setActive(portNumber: number)
        print("Switched to port \(number).")
        print("Note: keyboard and mouse have moved with it — this Mac can't switch back.")
    } catch { fail(error) }

case "dock":
    let watcher = DockWatcher { _ in }
    print(watcher.isDockPresent()
        ? "OWC Thunderbolt 3 Dock: PRESENT"
        : "OWC Thunderbolt 3 Dock: not detected")

case "clamshell":
    do {
        let disabled = try ClamshellController.isLidSleepDisabled()
        print("Lid-close sleep: \(disabled ? "DISABLED (stays awake)" : "ENABLED (normal)")")
        print("Control flag   : \(FeatureFlags.clamshellControl ? "on" : "off (read-only)")")
    } catch { fail(error) }

default:
    usage()
}
