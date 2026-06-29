import AppKit
import Carbon.HIToolbox

// Inserts text into whatever app is currently focused, by putting it on the
// pasteboard and simulating Cmd+V, then restoring the previous clipboard.
// Posting key events requires Accessibility permission (already granted).

enum TextInjector {
    static func insert(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)

        logf("injected \(trimmed.count) chars")

        // Restore the user's previous clipboard shortly after the paste lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
        }
    }
}
