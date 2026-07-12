import SwiftUI
import AppKit

// The interactive command panel: a right-docked, collapsible chat window that
// owns the whole agent interaction (editable transcript, live status, inline
// tool approval, result, follow-ups). Borderless + material background for a
// "cloud chat" look.

// Borderless windows refuse key status by default; override so the input field
// can take focus and keystrokes.
final class PanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class VoxSession: ObservableObject {
    struct Line: Identifiable {
        enum Kind { case user, status, tool, result }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    @Published var command: String = ""
    @Published var lines: [Line] = []
    @Published var pending: Router.ProposedCall?
    @Published var running = false
    @Published var collapsed = false
    @Published var focusTick = 0   // bumps on reset so the view refocuses the field

    private var confirmCont: CheckedContinuation<Bool, Never>?

    func reset(command: String) {
        self.command = command
        lines = []
        pending = nil
        running = false
        collapsed = false
        confirmCont = nil
        focusTick += 1
    }

    func run() {
        guard !running, !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        running = true
        let cmd = command
        add(.user, cmd)
        // Defer the clear one tick: mutating the bound value mid-commit (while
        // the field is still first responder) gets swallowed by AppKit.
        Task { @MainActor [weak self] in self?.command = "" }
        Task { [weak self] in
            let result = await Router.run(
                command: cmd,
                confirm: { proposed in await self?.confirm(proposed) ?? false },
                onStatus: { status in Task { @MainActor in self?.add(.status, status) } }
            )
            self?.add(.result, result)
            self?.running = false
        }
    }

    func confirm(_ proposed: Router.ProposedCall) async -> Bool {
        pending = proposed
        return await withCheckedContinuation { cont in self.confirmCont = cont }
    }

    func resolve(_ approved: Bool) {
        if let p = pending {
            add(.tool, "\(approved ? "✓" : "✗") \(p.connector) · \(p.tool)")
        }
        pending = nil
        confirmCont?.resume(returning: approved)
        confirmCont = nil
    }

    private func add(_ kind: Line.Kind, _ text: String) {
        lines.append(Line(kind: kind, text: text))
    }
}

struct PromptView: View {
    @ObservedObject var session: VoxSession
    var onCollapse: () -> Void
    var onClose: () -> Void
    @FocusState private var commandFocused: Bool
    @Environment(\.colorScheme) private var scheme

    // Claude-like warm palette.
    private var paper: Color {
        scheme == .dark ? Color(red: 0.15, green: 0.15, blue: 0.14) : Color(red: 0.98, green: 0.97, blue: 0.945)
    }
    private var userBubble: Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color(red: 0.93, green: 0.92, blue: 0.885)
    }
    private var fieldBg: Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color.white
    }
    private let accent = Color(red: 0.80, green: 0.44, blue: 0.32) // Claude coral

    var body: some View {
        VStack(spacing: 0) {
            header
            if !session.collapsed {
                chat
                if let pending = session.pending { approvalCard(pending) }
                inputBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16).fill(paper))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.07)))
        .onChange(of: session.focusTick) { _ in commandFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(accent).frame(width: 7, height: 7)
            Text("Vox").font(.system(size: 13, weight: .semibold))
            Spacer()
            headerButton(session.collapsed ? "chevron.down" : "chevron.up") {
                session.collapsed.toggle(); onCollapse()
            }
            headerButton("xmark") { onClose() }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func headerButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
    }

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(session.lines) { row($0).id($0.id) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .onChange(of: session.lines.count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.pending?.tool) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(_ line: VoxSession.Line) -> some View {
        switch line.kind {
        case .user:
            HStack {
                Spacer(minLength: 56)
                Text(line.text)
                    .font(.system(size: 15))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(userBubble)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .textSelection(.enabled)
            }
        case .result:
            // Assistant: plain flowing text, no bubble (Claude style).
            Text(line.text)
                .font(.system(size: 15))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .status:
            Text(line.text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            HStack(spacing: 6) {
                Image(systemName: line.text.hasPrefix("✓") ? "checkmark" : "xmark")
                    .font(.system(size: 10, weight: .bold))
                Text(line.text.dropFirst(2))
                    .font(.system(size: 12, design: .monospaced))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func approvalCard(_ pending: Router.ProposedCall) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Approve action", systemImage: "hand.raised.fill")
                .font(.system(size: 13, weight: .semibold))
            Text("\(pending.connector) · \(pending.tool)")
                .font(.system(size: 12, design: .monospaced))
            Text(pending.argsJSON)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Approve") { session.resolve(true) }
                    .keyboardShortcut(.defaultAction)
                    .tint(accent)
                Button("Cancel") { session.resolve(false) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Reply to Vox…", text: $session.command, onCommit: { session.run() })
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($commandFocused)
                .disabled(session.running)
            Button { session.run() } label: {
                Image(systemName: session.running ? "ellipsis.circle" : "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(fieldBg))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
        .padding(16)
    }

    private var canSend: Bool {
        !session.running && !session.command.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
