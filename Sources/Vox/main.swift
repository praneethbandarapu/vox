import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox

// Vox - menu-bar voice assistant.
// Trigger: hold Right Option (push-to-talk). Detecting a lone modifier
// globally needs Accessibility permission, requested on launch.
// Secrets (e.g. Deepgram key) live only in the macOS Keychain.

let logPath = "/tmp/vox.log"
let deepgramAccount = "deepgram-api-key"

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
    private let capture = AudioCapture()
    private var stream: DeepgramStream?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logf("applicationDidFinishLaunching")
        setUpMainMenu()
        setUpMenuBar()
        requestAccessibility()
        requestMicrophone()
        startKeyMonitor()
        logf("launch complete. deepgramKeySet=\(Keychain.get(account: deepgramAccount) != nil)")
    }

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            logf("microphone access granted=\(granted)")
        }
    }

    // MARK: Main menu (enables Cmd+C/V/X/A in text fields)

    private func setUpMainMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)

        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    // MARK: Menu bar

    private func setUpMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        renderIcon()
        refreshMenu()
        logf("menu bar set up")
    }

    private func refreshMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Vox v0.0.2", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Trigger: hold Right Option", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let hasKey = Keychain.get(account: deepgramAccount) != nil
        menu.addItem(NSMenuItem(title: hasKey ? "Deepgram key: set" : "Deepgram key: not set",
                                action: nil, keyEquivalent: ""))
        let setKey = NSMenuItem(title: "Set Deepgram API Key…", action: #selector(showSetKey), keyEquivalent: "")
        setKey.target = self
        menu.addItem(setKey)
        if hasKey {
            let clear = NSMenuItem(title: "Clear Deepgram Key", action: #selector(clearKey), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Vox", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func renderIcon() {
        guard let button = statusItem.button else { return }
        button.title = active ? "● Vox" : "Vox"
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Deepgram key entry (stored in Keychain)

    @objc private func showSetKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Set Deepgram API Key"
        alert.informativeText = "Paste your Deepgram API key. It is stored only in your macOS Keychain, never in the app, the repo, or any file."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Deepgram API key"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                logf("set key: empty, ignored")
                return
            }
            let ok = Keychain.set(key, account: deepgramAccount)
            // Never log the key itself, only that it saved and its length.
            logf("Deepgram key saved=\(ok) length=\(key.count)")
            refreshMenu()
        }
    }

    @objc private func clearKey() {
        Keychain.delete(account: deepgramAccount)
        logf("Deepgram key cleared")
        refreshMenu()
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
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        logf("key monitor installed. global=\(globalMonitor != nil) local=\(localMonitor != nil)")
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let isDown = (event.modifierFlags.rawValue & kRightOptionBit) != 0
        guard isDown != rightOptionDown else { return }
        rightOptionDown = isDown
        if isDown { rightOptionPressed() } else { rightOptionReleased() }
    }

    private func rightOptionPressed() {
        guard Keychain.get(account: deepgramAccount) != nil else {
            logf("dictation: no Deepgram key set")
            NSSound.beep()
            return
        }
        active = true
        renderIcon()
        logf("RIGHT OPTION DOWN (start dictation)")

        let dg = DeepgramStream()
        dg.start()
        stream = dg
        capture.onChunk = { [weak dg] data in dg?.send(data) }
        capture.start()
    }

    private func rightOptionReleased() {
        active = false
        renderIcon()
        logf("RIGHT OPTION UP (end dictation)")
        _ = capture.stop()
        capture.onChunk = nil
        let dg = stream
        stream = nil
        Task {
            let text = (await dg?.finish() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                logf("dictation: empty transcript")
                return
            }
            await MainActor.run { TextInjector.insert(text) }
        }
    }
}

logf("=== Vox starting (pid \(ProcessInfo.processInfo.processIdentifier)) ===")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
