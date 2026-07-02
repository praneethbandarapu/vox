import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

// Vox - menu-bar voice assistant.
// Trigger: hold Right Option (push-to-talk). Audio streams to Deepgram for
// transcription; optionally cleaned by Claude; then typed into the focused app.
// Secrets (Deepgram, Anthropic keys) live only in the macOS Keychain.

let logPath = "/tmp/vox.log"
let deepgramAccount = "deepgram-api-key"
let anthropicAccount = "anthropic-api-key"
let groqAccount = "groq-api-key"

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

// Device-dependent modifier bits for the RIGHT Option and RIGHT Command keys.
let kRightOptionBit: UInt = 0x40
let kRightCommandBit: UInt = 0x10

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var rightOptionDown = false
    private var rightCommandDown = false
    private enum Mode { case dictation, agent }
    private var mode: Mode = .dictation
    private var active = false
    private let capture = AudioCapture()
    private var transcriber: Transcriber?
    private let indicator = RecordingIndicator()
    private let agent = ClaudeAgent()
    private var historyWindow: NSWindow?
    private var pasteHotKeyRef: EventHotKeyRef?
    private var pasteHandlerRef: EventHandlerRef?

    private var cleanupEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "cleanupEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "cleanupEnabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logf("applicationDidFinishLaunching")
        setUpMainMenu()
        setUpMenuBar()
        requestAccessibility()
        requestMicrophone()
        startKeyMonitor()
        registerPasteHotKey()
        logf("launch complete. deepgramKeySet=\(Keychain.exists(account: deepgramAccount))")
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
        menu.addItem(NSMenuItem(title: "Vox v0.0.3", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Dictate: hold Right Option", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Command: hold Right Command", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        // Deepgram (speech-to-text)
        let hasDeepgram = Keychain.exists(account: deepgramAccount)
        menu.addItem(NSMenuItem(title: hasDeepgram ? "Deepgram key: set" : "Deepgram key: not set",
                                action: nil, keyEquivalent: ""))
        addItem(to: menu, title: "Set Deepgram API Key…", action: #selector(showSetDeepgramKey))
        if hasDeepgram {
            addItem(to: menu, title: "Clear Deepgram Key", action: #selector(clearDeepgramKey))
        }

        menu.addItem(.separator())

        // Cleanup (LLM) - provider-driven, swappable
        let cleaner = ProviderFactory.makeCleaner()
        menu.addItem(NSMenuItem(title: "\(cleaner.displayName) key: \(cleaner.isConfigured ? "set" : "not set")",
                                action: nil, keyEquivalent: ""))
        addItem(to: menu, title: "Set \(cleaner.displayName) API Key…", action: #selector(showSetCleanerKey))
        if cleaner.isConfigured {
            addItem(to: menu, title: "Clear \(cleaner.displayName) Key", action: #selector(clearCleanerKey))
        }
        let cleanup = addItem(to: menu, title: "Clean up with \(cleaner.displayName)", action: #selector(toggleCleanup))
        cleanup.state = cleanupEnabled ? .on : .off

        menu.addItem(.separator())
        addItem(to: menu, title: "Run Agent Test", action: #selector(runAgentTest))
        addItem(to: menu, title: "Dictation History…", action: #selector(showHistory))
        let login = addItem(to: menu, title: "Launch at Login", action: #selector(toggleLoginItem))
        login.state = loginEnabled ? .on : .off

        menu.addItem(.separator())
        addItem(to: menu, title: "Quit Vox", action: #selector(quit), key: "q")

        statusItem.menu = menu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func renderIcon() {
        guard let button = statusItem.button else { return }
        button.title = active ? "● Vox" : "Vox"
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: API key entry (stored in Keychain)

    @objc private func showSetDeepgramKey() { promptForKey(label: "Deepgram", account: deepgramAccount) }
    @objc private func clearDeepgramKey() { Keychain.delete(account: deepgramAccount); refreshMenu() }

    @objc private func showSetCleanerKey() {
        let c = ProviderFactory.makeCleaner()
        promptForKey(label: c.displayName, account: c.keyAccount)
    }
    @objc private func clearCleanerKey() {
        let c = ProviderFactory.makeCleaner()
        Keychain.delete(account: c.keyAccount)
        refreshMenu()
    }

    @objc private func toggleCleanup() {
        cleanupEnabled.toggle()
        logf("cleanup enabled=\(cleanupEnabled)")
        refreshMenu()
    }

    // MARK: Agent test (temporary, validates the Swift -> claude bridge)

    @objc private func runAgentTest() {
        logf("[agent] test starting")
        agent.run(prompt: "What is 2+2? Reply with only the number.", onEvent: { _ in }) { result in
            logf("[agent] test completed: \(result ?? "nil")")
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Agent result"
            alert.informativeText = result ?? "(no result, check /tmp/vox.log)"
            alert.runModal()
        }
    }

    // MARK: History window

    @objc private func showHistory() {
        let hosting = NSHostingController(rootView: HistoryView())
        if let window = historyWindow {
            window.contentViewController = hosting
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.title = "Vox - Dictation History"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            historyWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.center()
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Launch at login

    private var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @objc private func toggleLoginItem() {
        do {
            if loginEnabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            logf("login item enabled=\(loginEnabled)")
        } catch {
            logf("login item error: \(error.localizedDescription)")
        }
        refreshMenu()
    }

    // MARK: Paste-last hotkey (Cmd+Shift+V)

    private func registerPasteHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, userData) -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            me.pasteHotKeyFired()
            return noErr
        }, 1, &eventType, selfPtr, &pasteHandlerRef)

        let id = EventHotKeyID(signature: OSType(0x564F_5832), id: 2) // 'VOX2'
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey), id,
                            GetApplicationEventTarget(), 0, &pasteHotKeyRef)
        logf("paste hotkey (Cmd+Shift+V) registered")
    }

    private func pasteHotKeyFired() {
        logf("Cmd+Shift+V: paste last dictation")
        // Brief delay so the user's Shift is released before we synthesize Cmd+V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            TextInjector.pasteLast()
        }
    }

    private func playSound(_ name: String) {
        NSSound(named: name)?.play()
    }

    private func promptForKey(label: String, account: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Set \(label) API Key"
        alert.informativeText = "Paste your \(label) API key. It is stored only in your macOS Keychain, never in the app, the repo, or any file."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "\(label) API key"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { logf("set \(label) key: empty, ignored"); return }
            let ok = Keychain.set(key, account: account)
            logf("\(label) key saved=\(ok) length=\(key.count)")
            refreshMenu()
        }
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
        let flags = event.modifierFlags.rawValue
        let optDown = (flags & kRightOptionBit) != 0
        if optDown != rightOptionDown {
            rightOptionDown = optDown
            optDown ? startListening(.dictation) : stopListening()
        }
        let cmdDown = (flags & kRightCommandBit) != 0
        if cmdDown != rightCommandDown {
            rightCommandDown = cmdDown
            cmdDown ? startListening(.agent) : stopListening()
        }
    }

    private func startListening(_ mode: Mode) {
        guard transcriber == nil else { return } // already listening
        let t = ProviderFactory.makeTranscriber()
        guard t.isConfigured else {
            logf("STT provider not configured")
            NSSound.beep()
            return
        }
        self.mode = mode
        active = true
        renderIcon()
        indicator.show()
        playSound("Tink")
        logf("listening (mode=\(mode))")
        t.start()
        transcriber = t
        capture.onChunk = { [weak t] data in t?.send(data) }
        capture.start()
    }

    private func stopListening() {
        guard let t = transcriber else { return }
        active = false
        renderIcon()
        indicator.hide()
        _ = capture.stop()
        capture.onChunk = nil
        transcriber = nil
        let mode = self.mode

        Task {
            let text = (await t.finish()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { logf("empty transcript"); return }
            switch mode {
            case .dictation:
                var out = text
                let cleaner = ProviderFactory.makeCleaner()
                if cleanupEnabled && cleaner.isConfigured,
                   let cleaned = await cleaner.clean(text)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !cleaned.isEmpty {
                    out = cleaned
                }
                let finalText = out
                await MainActor.run {
                    HistoryStore.add(finalText)               // never lose it
                    let delivered = TextInjector.deliver(finalText)
                    self.playSound(delivered ? "Pop" : "Funk") // Funk = buffered, use Cmd+Shift+V
                }
            case .agent:
                await MainActor.run { self.runAgentCommand(text) }
            }
        }
    }

    // Sends a spoken command to Claude Code to perform a real action. For this
    // first test we allow the Bash tool so Claude can act via osascript/AppleScript
    // (e.g. create a Calendar event) with no MCP connector required.
    private func runAgentCommand(_ command: String) {
        logf("[agent] command: \(command)")
        indicator.show("● Working…")

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let mcpPath = home + "/.vox/vox-mcp.json"
        let env = [
            "GOOGLE_OAUTH_CREDENTIALS": "\(home)/.vox/gcp-oauth.keys.json",
            "GOOGLE_CALENDAR_MCP_TOKEN_PATH": "\(home)/.vox/tokens.json"
        ]
        let config: [String: Any] = [
            "mcpServers": [
                "google-calendar": [
                    "command": "npx",
                    "args": ["@cocal/google-calendar-mcp"],
                    "env": env
                ]
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: config) {
            try? data.write(to: URL(fileURLWithPath: mcpPath))
        }

        let prompt = """
        You are Vox, an assistant that performs actions on the user's Mac. You have a Google Calendar tool (list/create/update/delete events).
        The user's spoken command was: "\(command)"
        Carry it out now using your tools. Do not ask questions; make reasonable assumptions (default event duration 30 minutes; pick a sensible near-future time if unspecified). Then reply with ONE short sentence confirming exactly what you did.
        """

        agent.run(prompt: prompt,
                  allowedTools: ["mcp__google-calendar"],
                  mcpConfigPath: mcpPath,
                  strictMcp: true,
                  onEvent: { event in
            if case let .toolUse(name, input) = event.kind {
                logf("[agent] using \(name): \(input.prefix(160))")
            }
        }) { result in
            self.indicator.hide()
            self.playSound("Glass")
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Vox agent"
            alert.informativeText = result ?? "(no result, see /tmp/vox.log)"
            alert.runModal()
        }
    }
}

logf("=== Vox starting (pid \(ProcessInfo.processInfo.processIdentifier)) ===")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
