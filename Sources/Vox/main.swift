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
let slackAccount = "slack-bot-token"

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
    private var cachedIntent: ParsedIntent?
    private var onIntentReady: ((ParsedIntent) -> Void)?
    private var parseGen = 0   // only the latest parse's result is accepted
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
        menu.addItem(NSMenuItem(title: "Connectors", action: nil, keyEquivalent: ""))
        for def in ConnectorManager.defs {
            menu.addItem(NSMenuItem(title: "  \(def.displayName): \(def.isConfigured() ? "connected" : "not connected")",
                                    action: nil, keyEquivalent: ""))
        }
        addItem(to: menu, title: "Connect Google (Calendar + Gmail)…", action: #selector(connectGoogle))
        addItem(to: menu, title: "Set Slack Token…", action: #selector(showSetSlackKey))
        addItem(to: menu, title: "Test Connectors", action: #selector(testConnectors))

        menu.addItem(.separator())
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

    // MARK: Connectors

    @objc private func showSetSlackKey() { promptForKey(label: "Slack", account: slackAccount) }

    @objc private func connectGoogle() {
        logf("[google] connect starting")
        Task {
            let ok = await GoogleAuth.connect()
            ConnectorManager.shared.shutdown()   // restart servers with the fresh token
            await MainActor.run {
                self.showAlert("Google", ok ? "Connected: Calendar + Gmail (via bridge)." : "Connection failed. See /tmp/vox.log.")
                self.refreshMenu()
            }
        }
    }

    @objc private func testConnectors() {
        logf("[conn] test starting")
        Task {
            var summary = ""
            for def in ConnectorManager.defs {
                guard def.isConfigured() else { summary += "\(def.displayName): not connected\n\n"; continue }
                let tools = await ConnectorManager.shared.listTools(def.id)
                summary += "\(def.displayName): \(tools.count) tools\n"
                if def.id == "google-calendar" {
                    let r = await ConnectorManager.shared.call(def.id, tool: "list-calendars", arguments: [:])
                    summary += "  list-calendars: \(r?.prefix(120) ?? "nil")\n"
                } else if def.id == "gmail" {
                    let listTool = tools.first { $0.lowercased().contains("label") }
                        ?? tools.first { $0.lowercased().contains("search") }
                    if let listTool {
                        let r = await ConnectorManager.shared.call(def.id, tool: listTool, arguments: [:])
                        summary += "  \(listTool): \(r?.prefix(120) ?? "nil/err")\n"
                    }
                } else if def.id == "slack" {
                    let listTool = tools.first { $0.lowercased().contains("channel") && $0.lowercased().contains("list") }
                        ?? tools.first { $0.lowercased().contains("conversation") }
                    if let listTool {
                        let r = await ConnectorManager.shared.call(def.id, tool: listTool, arguments: [:])
                        summary += "  \(listTool): \(r?.prefix(120) ?? "nil/err")\n"
                    }
                }
                summary += "\n"
            }
            await MainActor.run { self.showAlert("Connectors", summary.isEmpty ? "none" : summary) }
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
                await MainActor.run { self.startAgentFlow(text) }
            }
        }
    }

    // Sends a spoken command to Claude Code to perform a real action. For this
    // first test we allow the Bash tool so Claude can act via osascript/AppleScript
    // (e.g. create a Calendar event) with no MCP connector required.
    // Fast path: Groq parses the command into a structured calendar intent, then
    // Vox calls Google Calendar directly. Claude Code remains the future fallback.

    // Gate 1 + speculative Groq parse (runs in parallel with the transcript screen).
    private func startAgentFlow(_ originalTranscript: String) {
        cachedIntent = nil
        onIntentReady = nil
        parseIntent(originalTranscript)   // speculative

        guard let edited = promptEditableTranscript(originalTranscript) else {
            logf("[agent] cancelled at transcript")
            indicator.hide()
            return
        }

        if edited == originalTranscript {
            if let intent = cachedIntent {
                handleIntent(intent)
            } else {
                indicator.show("● Thinking…")
                onIntentReady = { [weak self] intent in self?.handleIntent(intent) }
            }
        } else {
            // Corrected text: re-parse.
            cachedIntent = nil
            indicator.show("● Thinking…")
            onIntentReady = { [weak self] intent in self?.handleIntent(intent) }
            parseIntent(edited)
        }
    }

    private func parseIntent(_ command: String) {
        parseGen += 1
        let gen = parseGen
        indicator.show("● Thinking…")
        Task {
            let intent = await GroqIntent.parse(command)
            await MainActor.run {
                guard gen == self.parseGen else { return }   // stale (input changed); drop
                if let cb = self.onIntentReady { self.onIntentReady = nil; cb(intent) }
                else { self.cachedIntent = intent }
            }
        }
    }

    private func handleIntent(_ intent: ParsedIntent) {
        switch intent {
        case .calendar(let ci):
            confirmAndCreate(ci)
        case .other:
            indicator.hide()
            showAlert("Vox", "That doesn't look like a calendar command. Slack, email, and a general fallback are coming next.")
        case .failed:
            indicator.hide()
            showAlert("Vox", "Sorry, couldn't understand that. See /tmp/vox.log.")
        }
    }

    // Gate 2: confirm the exact event, then call Google Calendar directly.
    private func confirmAndCreate(_ ci: CalendarIntent) {
        indicator.hide()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Create this calendar event?"
        alert.informativeText = describe(ci)
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            logf("[agent] calendar action cancelled")
            return
        }
        indicator.show("● Working…")
        Task {
            let args: [String: Any] = [
                "calendarId": "primary",
                "summary": ci.summary,
                "start": ci.startISO,
                "end": ci.endISO,
                "timeZone": ci.timeZone,
                "attendees": ci.attendees.map { ["email": $0] }
            ]
            let result = await ConnectorManager.shared.call("google-calendar", tool: "create-event", arguments: args)
            await MainActor.run {
                self.indicator.hide()
                self.playSound(result != nil ? "Glass" : "Funk")
                self.showAlert("Vox", result != nil ? "Created: \(ci.summary)" : "Failed to create the event. See /tmp/vox.log.")
            }
        }
    }

    private func describe(_ ci: CalendarIntent) -> String {
        let who = ci.attendees.isEmpty ? "just you (no invite)" : ci.attendees.joined(separator: ", ")
        return "\(ci.summary)\n\(prettyTime(ci.startISO)) to \(prettyTime(ci.endISO)) (\(ci.timeZone))\nAttendees: \(who)"
    }

    private func prettyTime(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let pretty = DateFormatter()
        pretty.dateFormat = "EEE MMM d, h:mm a"
        if let d = parser.date(from: iso) { return pretty.string(from: d) }
        return iso
    }

    private func promptEditableTranscript(_ transcript: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Command"
        alert.informativeText = "Vox heard this. Edit if needed, then Run."
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.stringValue = transcript
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn
            ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
    }

    private func showAlert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

logf("=== Vox starting (pid \(ProcessInfo.processInfo.processIdentifier)) ===")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
