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

// A cleaned dictation should keep most of the words that were actually said and
// not invent new ones; cleanup only drops fillers, fixes spelling, and adds a
// few small connecting words. We reject a "cleaning" that fails either side:
//  - recall: too few of the spoken words survive (model answered/echoed), or
//  - precision: too many foreign content words were added (model prepended an
//    answer/preamble). Digits (list numbers) and small function words are
//    excused so numbered lists and article-fixes still pass.
// On reject we keep the raw transcript, so a weak model can't type words the
// user never said.
func cleaningIsFaithful(raw: String, cleaned: String) -> Bool {
    let stop: Set<String> = ["a","an","the","to","of","in","on","for","and","or","is","are","was","were","at","by","with","as","it","that","this","include","includes"]
    func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    let rawWords = words(raw)
    guard !rawWords.isEmpty else { return true }
    let rawSet = Set(rawWords)
    let cleanedWords = words(cleaned)
    let matched = rawWords.filter { Set(cleanedWords).contains($0) }.count
    let recall = Double(matched) / Double(rawWords.count)
    let added = Set(cleanedWords).filter { !rawSet.contains($0) && Int($0) == nil && !stop.contains($0) }.count
    let addBudget = max(2, rawWords.count / 4)
    return recall >= 0.6 && added <= addBudget
}

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
    private let voxSession: VoxSession = MainActor.assumeIsolated { VoxSession() }
    private var promptWindow: NSWindow?
    private var active = false
    private let capture = AudioCapture()
    private var soundCache: [String: NSSound] = [:]
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
        // Preload cue sounds so the first keypress doesn't pay NSSound's load.
        for name in ["Tink", "Pop", "Funk", "Glass"] { soundCache[name] = NSSound(named: name) }
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
        let sound = soundCache[name] ?? NSSound(named: name)
        soundCache[name] = sound
        // Off the main thread: playback must never delay the icon paint.
        DispatchQueue.global(qos: .userInitiated).async { sound?.stop(); sound?.play() }
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
            optDown ? startListening(.dictation, eventTime: event.timestamp) : stopListening()
        }
        let cmdDown = (flags & kRightCommandBit) != 0
        if cmdDown != rightCommandDown {
            rightCommandDown = cmdDown
            cmdDown ? startListening(.agent, eventTime: event.timestamp) : stopListening()
        }
    }

    private func startListening(_ mode: Mode, eventTime: TimeInterval? = nil) {
        guard transcriber == nil else { return } // already listening
        let t0 = ProcessInfo.processInfo.systemUptime
        func ms() -> Int { Int((ProcessInfo.processInfo.systemUptime - t0) * 1000) }
        // Instant feedback first: show the icon and play the cue before any
        // transcriber/network setup, so the UI never trails the keypress.
        self.mode = mode
        active = true
        renderIcon(); logf("t.renderIcon=\(ms())ms")
        indicator.show(); logf("t.indicatorShow=\(ms())ms")
        playSound("Tink"); logf("t.playSound=\(ms())ms")
        if let et = eventTime {
            logf("key->icon \(Int((t0 - et) * 1000))ms (event delivery)")
        }
        let t = ProviderFactory.makeTranscriber(); logf("t.makeTranscriber=\(ms())ms")
        let configured = t.isConfigured; logf("t.isConfigured=\(ms())ms cfg=\(configured)")
        guard configured else {
            logf("STT provider not configured")
            NSSound.beep()
            indicator.hide(); active = false; renderIcon()
            return
        }
        logf("listening (mode=\(mode)) setup \(ms())ms")
        t.start(); logf("t.start=\(ms())ms")
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
            logf("[dictation] raw=\"\(text.prefix(200))\"")
            switch mode {
            case .dictation:
                var out = text
                let cleaner = ProviderFactory.makeCleaner()
                if cleanupEnabled && cleaner.isConfigured,
                   let cleaned = await cleaner.clean(text)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !cleaned.isEmpty {
                    if cleaningIsFaithful(raw: text, cleaned: cleaned) {
                        out = cleaned
                        logf("[dictation] cleaned=\"\(cleaned.prefix(200))\"")
                    } else {
                        // Weak model answered/echoed/hallucinated. Trust the raw transcript.
                        logf("[dictation] cleaning REJECTED, using raw. rejected=\"\(cleaned.prefix(200))\"")
                    }
                } else {
                    logf("[dictation] cleanup skipped (enabled=\(cleanupEnabled))")
                }
                let finalText = out
                await MainActor.run {
                    HistoryStore.add(finalText)               // never lose it
                    let delivered = TextInjector.deliver(finalText)
                    self.playSound(delivered ? "Pop" : "Funk") // Funk = buffered, use Cmd+Shift+V
                }
            case .agent:
                await MainActor.run { self.showPrompt(text) }
            }
        }
    }

    // Sends a spoken command to Claude Code to perform a real action. For this
    // first test we allow the Bash tool so Claude can act via osascript/AppleScript
    // (e.g. create a Calendar event) with no MCP connector required.
    // Fast path: Groq parses the command into a structured calendar intent, then
    // Vox calls Google Calendar directly. Claude Code remains the future fallback.

    // Gate 1 (editable transcript) -> Router (tool-calling over all connectors)
    // -> per-tool confirm -> execute via the bridge -> result.
    // Open the interactive command window with the heard transcript prefilled.
    // The window owns the whole agent interaction: edit, run, approve, result.
    @MainActor
    private func showPrompt(_ transcript: String) {
        indicator.hide()
        voxSession.reset(command: transcript)
        if promptWindow == nil {
            let root = PromptView(
                session: voxSession,
                onCollapse: { [weak self] in self?.layoutPrompt() },
                onClose: { [weak self] in self?.promptWindow?.orderOut(nil) }
            )
            let hosting = NSHostingController(rootView: root)
            hosting.view.wantsLayer = true
            hosting.view.layer?.backgroundColor = .clear
            let w = PanelWindow(contentViewController: hosting)
            w.styleMask = [.borderless]
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.level = .floating
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            promptWindow = w
        }
        layoutPrompt()
        NSApp.activate(ignoringOtherApps: true)
        promptWindow?.makeKeyAndOrderFront(nil)
    }

    // Dock the panel to the right edge; collapsed = a slim bar anchored at the
    // top-right, expanded = near full height. Animated.
    @MainActor
    private func layoutPrompt() {
        guard let w = promptWindow, let vf = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
        let width: CGFloat = 400, margin: CGFloat = 16
        let height: CGFloat = voxSession.collapsed ? 52 : vf.height - margin * 2
        let x = vf.maxX - width - margin
        let y = vf.maxY - margin - height   // top-anchored
        w.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true, animate: true)
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
