import AppKit

/// A brief, centered on-screen "Switching to X…" message.
///
/// Exists because switching is one-way and can be triggered blind — from
/// the global ⌘⌥1-4 hotkey with the menu closed, or from another app
/// entirely. Without immediate feedback there's no way to tell "did that
/// keystroke even register?" before the KVM actually cuts over.
///
/// A non-activating borderless panel: shown without stealing focus from
/// whatever app the hotkey was pressed in, on whichever Space is currently
/// active.
///
/// `AppModel.select` explicitly calls `hide()` once the (deliberately
/// delayed) switch finishes, so this timer is a safety net, not the primary
/// dismissal path — kept longer than the confirmation delay plus a normal
/// API round trip so it doesn't disappear mid-delay if something in the
/// caller's own flow (e.g. a caught exception) skips the explicit hide.
@MainActor
final class SwitchingOverlay {
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?

    private let displayDuration: TimeInterval = 6

    func show(text: String) {
        dismissWorkItem?.cancel()

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 32, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()

        let horizontalPadding: CGFloat = 36
        let verticalPadding: CGFloat = 28
        let size = NSSize(
            width: label.frame.width + horizontalPadding * 2,
            height: label.frame.height + verticalPadding * 2
        )

        let panel = self.panel ?? makePanel()
        label.frame = NSRect(
            x: horizontalPadding,
            y: verticalPadding,
            width: label.frame.width,
            height: label.frame.height
        )
        panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
        panel.contentView?.addSubview(label)
        panel.setContentSize(size)

        if let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.frame {
            panel.setFrameOrigin(NSPoint(
                x: screenFrame.midX - size.width / 2,
                y: screenFrame.midY - size.height / 2
            ))
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()
        self.panel = panel

        let workItem = DispatchWorkItem { [weak self] in self?.hide() }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration, execute: workItem)
    }

    func hide() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            Task { @MainActor in panel?.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let effectView = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 18
        effectView.layer?.masksToBounds = true
        panel.contentView = effectView

        return panel
    }
}
