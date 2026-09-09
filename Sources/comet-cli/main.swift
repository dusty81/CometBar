import CometKit
import Foundation

// CLI front end. Fastest way to exercise CometKit against the live device
// without building an app bundle. Deliberately thin — all logic lives in the
// library so the CLI and the menu bar app test identical code paths.

func usage() -> Never {
    let name = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
    print("""
    Usage: \(name) <command>

      status          Show active port, link state and port names
      info            Firmware and health
      set <1-4>       Switch the KVM to a port
      name <1-4> <n>  Set a port's friendly name on the device
      dock            Report whether the configured dock is attached
      usb-devices     List connected USB devices (to find your dock's vendor ID)
      clamshell       Report macOS lid-close sleep state and control flag
      clamshell on|off  Turn the kvm-clamshelld workaround on/off

    Env: KVM_HOST (default glkvm.local), KVM_USER (default admin)
    """)
    exit(1)
}

func currentSettings() -> CometSettings {
    let env = ProcessInfo.processInfo.environment
    var settings = SettingsStore.load()
    if let host = env["KVM_HOST"] { settings.host = host }
    if let user = env["KVM_USER"] { settings.user = user }
    return settings
}

func makeClient(_ settings: CometSettings) -> CometClient {
    CometClient(host: settings.host, user: settings.user)
}

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(
        Data(("Error: " + (error.localizedDescription) + "\n").utf8)
    )
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }

let settings = currentSettings()

switch command {
case "status":
    do {
        let state = try await makeClient(settings).switchState()
        print("Active port : \(state.activeID) (channel \(state.activeChannel))  synced=\(state.synced)")
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
            let displayName = port.name.isEmpty ? "(unnamed)" : port.name
            print(marker
                + " " + pad(port.id, 6)
                + pad(port.videoLinked ? "up" : "--", 7)
                + pad(port.usbLinked ? "up" : "--", 6)
                + displayName)
        }
    } catch { fail(error) }

case "info":
    do {
        let info = try await makeClient(settings).info()
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
        try await makeClient(settings).setActive(portNumber: number)
        print("Switched to port \(number).")
        print("Note: keyboard and mouse have moved with it — this Mac can't switch back.")
    } catch { fail(error) }

case "name":
    guard arguments.count == 3,
          let number = Int(arguments[1]),
          let port = PortNumber(number)
    else { usage() }
    do {
        try await makeClient(settings).setPortName(port, name: arguments[2])
        print("Port \(number) renamed to \"\(arguments[2])\".")
    } catch { fail(error) }

case "dock":
    let watcher = DockWatcher(vendorID: settings.dockVendorID) { _ in }
    print("Configured vendor ID: \(String(format: "0x%X", settings.dockVendorID))")
    print(watcher.isDockPresent() ? "Dock: PRESENT" : "Dock: not detected")

case "usb-devices":
    let devices = USBDeviceLister.connectedDevices()
    if devices.isEmpty {
        print("No USB devices found.")
    } else {
        print("  vendor id  name")
        for device in devices {
            print("  \(device.vendorIDHex)     \(device.name)")
        }
        print("")
        print("Set the dock's vendor ID in CometBar's Settings pane, or:")
        print("  comet-cli dock   (after configuring it there)")
    }

case "clamshell":
    if arguments.count == 2 {
        guard arguments[1] == "on" || arguments[1] == "off" else { usage() }
        do {
            try ClamshellController.setControlEnabled(arguments[1] == "on")
            print("Clamshell control \(arguments[1]). The kvm-clamshelld daemon applies it on the next reconcile.")
        } catch { fail(error) }
    } else {
        do {
            let disabled = try ClamshellController.isLidSleepDisabled()
            print("Lid-close sleep : \(disabled ? "DISABLED (stays awake)" : "ENABLED (normal)")")
            print("Control flag    : \(ClamshellController.isControlEnabled() ? "on" : "off")")
            print("Daemon installed: \(ClamshellController.isDaemonInstalled() ? "yes" : "no")")
        } catch { fail(error) }
    }

default:
    usage()
}
