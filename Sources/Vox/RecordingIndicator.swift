import AppKit

// A small floating "listening" pill shown near the bottom of the screen while
// recording. Non-activating and click-through, so it never steals focus.
// Also solves the menu-bar-hidden-behind-the-notch problem.

final class RecordingIndicator {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "● Listening…")

    func show(_ text: String = "● Listening…") {
        let p = panel ?? makePanel()
        panel = p
        label.stringValue = text
        position(p)
        p.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 160, height: 44)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        container.layer?.cornerRadius = 14

        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 12, width: size.width, height: 20)
        container.addSubview(label)

        p.contentView = container
        return p
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - panel.frame.width / 2
        let y = visible.minY + 90
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
