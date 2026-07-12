import SwiftUI
import AppKit

// The interactive command window: shows the (editable) transcript, live status,
// inline tool-call approvals, and the result. Replaces the stack of NSAlerts.

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
    @Published var focusTick = 0   // bumps on reset so the view refocuses the field

    private var confirmCont: CheckedContinuation<Bool, Never>?

    func reset(command: String) {
        self.command = command
        lines = []
        pending = nil
        running = false
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

    // Called by the router; shows the proposed tool call and waits for a button.
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
    @FocusState private var commandFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vox").font(.headline)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(session.lines) { line in row(line).id(line.id) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: session.lines.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: session.pending?.tool) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            if let pending = session.pending {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Run \(pending.connector) · \(pending.tool)?").font(.subheadline).bold()
                    Text(pending.argsJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Button("Approve") { session.resolve(true) }.keyboardShortcut(.defaultAction)
                        Button("Cancel") { session.resolve(false) }
                    }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(8)
            }

            HStack {
                TextField("Command…", text: $session.command, onCommit: { session.run() })
                    .textFieldStyle(.roundedBorder)
                    .focused($commandFocused)
                    .disabled(session.running)
                Button(session.running ? "Running…" : "Run") { session.run() }
                    .keyboardShortcut(.return)
                    .disabled(session.running)
            }
        }
        .padding(14)
        .frame(width: 480, height: 440)
        .onAppear { commandFocused = true }
        .onChange(of: session.focusTick) { _ in commandFocused = true }
    }

    @ViewBuilder
    private func row(_ line: VoxSession.Line) -> some View {
        switch line.kind {
        case .user:
            Text(line.text).bold()
        case .status:
            Text(line.text).font(.caption).foregroundStyle(.secondary)
        case .tool:
            Text(line.text).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        case .result:
            Text(line.text).padding(.top, 2)
        }
    }
}
