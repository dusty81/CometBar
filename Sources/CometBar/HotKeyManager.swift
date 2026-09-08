import AppKit
import Carbon.HIToolbox

/// Registers ⌘⌥1–⌘⌥4 as system-wide hotkeys to switch KVM ports, working even
/// when CometBar isn't the frontmost app.
///
/// Uses the classic Carbon hotkey API (`RegisterEventHotKey`) rather than an
/// `NSEvent` global monitor — Carbon hotkeys don't require Input
/// Monitoring/Accessibility permission, which a raw key-event monitor would.
///
/// Only ever switches AWAY from this Mac: once the KVM switches away, this
/// Mac's keyboard physically leaves with it, so a hotkey pressed elsewhere
/// can never reach this Mac's OS to switch back. See CLAUDE.md's
/// switch-back constraint. All 4 ports are bound regardless of which one is
/// currently active — switching to the active port is a harmless no-op.
final class HotKeyManager {
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private let onPortSelected: (Int) -> Void

    private static let signature: FourCharCode = 0x434D_4254 // 'CMBT'
    private static let keyCodes: [Int: Int] = [
        1: kVK_ANSI_1, 2: kVK_ANSI_2, 3: kVK_ANSI_3, 4: kVK_ANSI_4,
    ]

    init(onPortSelected: @escaping (Int) -> Void) {
        self.onPortSelected = onPortSelected
    }

    func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &eventType, selfPtr, &eventHandler)

        for (port, keyCode) in Self.keyCodes.sorted(by: { $0.key < $1.key }) {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: UInt32(port))
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                UInt32(cmdKey | optionKey),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
                NSLog("CometBar: registered ⌘⌥\(port) for port \(port).")
            } else {
                NSLog("CometBar: FAILED to register ⌘⌥\(port) for port \(port) (OSStatus \(status)).")
            }
        }
    }

    func unregister() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
    }

    deinit { unregister() }

    fileprivate func handleHotKey(portID: Int) {
        NSLog("CometBar: ⌘⌥\(portID) pressed — switching to port \(portID).")
        onPortSelected(portID)
    }
}

/// Free function, not a closure — `InstallEventHandler` requires a
/// `@convention(c)` callback, which can't capture context. `self` travels
/// through as `userData` instead.
private func hotKeyCallback(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }
    var hotKeyID = EventHotKeyID()
    GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
        .handleHotKey(portID: Int(hotKeyID.id))
    return noErr
}
