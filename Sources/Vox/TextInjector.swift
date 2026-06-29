import AppKit
import ApplicationServices
import Carbon.HIToolbox

// Delivers transcribed text. If a text field is focused, it pastes there.
// If not, it keeps the text in a recall buffer so nothing is lost; the user
// can drop it in later with Cmd+Shift+V.

enum TextInjector {
    private(set) static var lastDictation = ""

    // Returns true if pasted into a focused field, false if only buffered.
    @discardableResult
    static func deliver(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        lastDictation = trimmed

        if focusedElementIsTextInput() {
            paste(trimmed)
            logf("delivered \(trimmed.count) chars to focused field")
            return true
        }
        logf("no text field focused; buffered for Cmd+Shift+V")
        return false
    }

    // Pastes the last dictation on demand (Cmd+Shift+V handler).
    static func pasteLast() {
        guard !lastDictation.isEmpty else { return }
        paste(lastDictation)
    }

    // MARK: Internals

    private static func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        down?.flags = .maskCommand   // explicitly Cmd only, never Cmd+Shift
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }
    }

    private static func focusedElementIsTextInput() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return false }
        let element = focused as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        if role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String) {
            return true
        }

        // Catch web/editable views that expose a settable value.
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }
}
