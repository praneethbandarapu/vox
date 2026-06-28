import AppKit
import ApplicationServices
import Carbon.HIToolbox

// Vox - M0 scaffold.
// A menu-bar (accessory) app. Trigger key: hold Right Option (push-to-talk style).
// Detecting a lone modifier globally needs Accessibility permission, which we
// request on launch. For M0 the key just beeps + toggles the menu-bar glyph,
// proving the "invoke from anywhere" plumbing before the mic arrives in M1.

let logPath = "/tmp/vox.log"

func logf(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }
    NSLog("Vox: \(message)")
}

// Device-dependent modifier bit for the RIGHT Option key.
let kRightOptionBit: UInt = 0x40

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var rightOptionDown = false
    private var active = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        logf("applicationDidFinishLaunching")
        setUpMenuBar()
        requestAccessibility()
        startKeyMonitor()
        logf("launch complete. statusItem.button present=\(statusItem.button != nil)")
    }

    // MARK: Menu bar

    private func setUpMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        renderIcon()

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Vox v0.0.1 (M0 scaffold)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Trigger: hold Right Option", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Vox", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        logf("menu bar set up")
    }

    private func renderIcon() {
        guard let button = statusItem.button else { return }
        button.title = active ? "● Vox" : "Vox"
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Permissions

    private func requestAccessibility() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        logf("accessibility trusted=\(trusted)")
    }

    // MARK: Global key monitor (Right Option)

    private func startKeyMonitor() {
        // Global monitor fires when other apps are focused (needs Accessibility).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        // Local monitor fires when Vox itself is focused; must return the event.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        logf("key monitor installed. global=\(globalMonitor != nil) local=\(localMonitor != nil)")
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let isDown = (event.modifierFlags.rawValue & kRightOptionBit) != 0
        guard isDown != rightOptionDown else { return } // only on transitions
        rightOptionDown = isDown
        if isDown {
            rightOptionPressed()
        } else {
            rightOptionReleased()
        }
    }

    private func rightOptionPressed() {
        active = true
        renderIcon()
        NSSound.beep()
        logf("RIGHT OPTION DOWN (push-to-talk start)")
    }

    private func rightOptionReleased() {
        active = false
        renderIcon()
        logf("RIGHT OPTION UP (push-to-talk end)")
    }
}

logf("=== Vox starting (pid \(ProcessInfo.processInfo.processIdentifier)) ===")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no Dock icon, menu-bar only (LSUIElement equivalent)
app.run()
