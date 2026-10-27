import AppKit
import BridgeCore
import BridgeSystem
import SwiftUI

/// zsh suggestions and the completion menu: the shell sends its line, the app answers.
extension Store {
    /// A gray suggestion for the line (the shell draws it). Empty for none.
    func suggestion(for session: PaneSession, line: String, cwd: String, path: String) -> String {
        guard settings.autosuggestions else { return "" }
        return Completion.suggestion(
            line: line, cwd: URL(fileURLWithPath: cwd), history: visibleHistory(for: session),
            executables: executables(path), readableRoots: readableRoots(for: session))
    }

    /// Tab: one candidate is inserted by the shell (`replace`, the typed word's length and the
    /// new text), several open the menu (`menu`), none lets zsh complete (empty).
    func complete(for session: PaneSession, line: String, cwd: String, path: String) -> String {
        guard settings.tabCompletions else { return "" }
        let result = completions(for: session, line: line, cwd: cwd, path: path)
        guard !result.candidates.isEmpty else { return "" }
        if result.candidates.count == 1, let only = result.candidates.first {
            if only.kind == .directory { session.reopenMenu = true }
            return ["replace", "\(result.word.count)", only.replacement + only.suffix].joined(separator: "\u{1F}")
        }
        CompletionMenu.shared.show(result, for: session)
        return "menu"
    }

    /// The line changed: keep an open menu up to date, or open one as you type.
    func lineChanged(for session: PaneSession, line: String, cwd: String, path: String) {
        let menu = CompletionMenu.shared
        let open = menu.session === session
        let reopen = session.reopenMenu
        session.reopenMenu = false
        let asYouType = settings.completionsAsYouType
            && ((!line.isEmpty && !line.hasSuffix(" ")) || Completion.opensAfterSpace(line))
        guard open || reopen || asYouType else { return }
        let result = completions(for: session, line: line, cwd: cwd, path: path)
        // Nothing to offer, or only what's already typed: no menu.
        if result.candidates.isEmpty || (result.candidates.count == 1 && result.candidates[0].replacement == result.word) {
            if open { menu.close() }
            return
        }
        menu.show(result, for: session)
    }

    private func completions(for session: PaneSession, line: String, cwd: String, path: String) -> Completion.Result {
        session.path = path
        return Completion.complete(Completion.Context(
            line: line, cwd: URL(fileURLWithPath: cwd), executables: executables(path),
            history: visibleHistory(for: session), readableRoots: readableRoots(for: session)))
    }

    /// Whether a terminal runs in a sandbox.
    func isSandboxed(_ session: PaneSession) -> Bool {
        guard let spec = project(session.projectID)?.terminal(session.id), case .sandboxed = spec.effectiveIsolation else {
            return false
        }
        return !isGlobal(session.projectID)
    }

    /// The history a terminal's suggestions and completions draw on. A sandboxed terminal only
    /// sees commands run in its own project, so a program in the sandbox can't read other
    /// history through suggestions; an open terminal never sees what sandboxed ones reported,
    /// which a program in a sandbox could have made up.
    func visibleHistory(for session: PaneSession) -> History {
        let key: String
        let keep: (HistoryEntry) -> Bool
        if isSandboxed(session), let project = project(session.projectID) {
            let root = project.root.standardizedFileURL.path
            key = "project:" + root
            keep = { entry in entry.cwd.map { $0 == root || $0.hasPrefix(root + "/") } ?? false }
        } else {
            key = "open"
            keep = { !$0.sandboxed }
        }
        if let cached = historyViews[key], cached.count == history.entries.count {
            return cached.history
        }
        let view = History(entries: history.entries.filter(keep))
        historyViews[key] = (history.entries.count, view)
        return view
    }

    /// The folders a sandboxed terminal may list (its project, and what its sandbox lets it
    /// read); nil for an open one.
    func readableRoots(for session: PaneSession) -> [String]? {
        guard isSandboxed(session), let project = project(session.projectID),
              let spec = project.terminal(session.id), case .sandboxed(let profile) = spec.effectiveIsolation
        else { return nil }
        var roots = [project.root.path]
        if case .seatbelt(let seatbelt) = profiles.engine(for: profile) {
            let hidden = seatbelt.hidden.map(Paths.expandHome) + [Paths.home + "/.ssh", Paths.home + "/.config/bridge"]
            roots += (seatbelt.writable + seatbelt.readable).map(Paths.expandHome)
                .filter { path in !hidden.contains { path == $0 || path.hasPrefix($0 + "/") } }
        }
        return roots
    }

    /// Executable names on a PATH, cached per PATH.
    func executables(_ path: String) -> [String] {
        if let cached = executableCache[path] { return cached }
        let names = Completion.executables(path: path)
        executableCache[path] = names
        return names
    }
}

/// The completion menu: a popover at the terminal's cursor. While it's open, ↑ ↓ (and ⇧Tab)
/// move, Return or Tab accepts, Escape closes; typing goes on to the shell, which reports the
/// new line so the menu follows.
@MainActor
@Observable
final class CompletionMenu {
    static let shared = CompletionMenu()

    private(set) var result = Completion.Result(word: "", candidates: [])
    var selected = 0
    @ObservationIgnored private(set) weak var session: PaneSession?
    @ObservationIgnored private var popover: NSPopover?

    func show(_ result: Completion.Result, for session: PaneSession) {
        guard let surface = session.surface, surface.window != nil else { return }
        let sameWord = self.session === session && self.result.word == result.word
        self.result = result
        if !sameWord || selected >= result.candidates.count { selected = 0 }
        self.session = session
        let popover = popover ?? makePopover()
        let anchor = surface.cursorRect
        if popover.isShown {
            popover.positioningRect = anchor
        } else {
            popover.show(relativeTo: anchor, of: surface, preferredEdge: .minY)
            // Keep typing in the terminal.
            surface.window?.makeFirstResponder(surface)
        }
    }

    func close() {
        popover?.performClose(nil)
        session = nil
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: CompletionList(menu: self))
        self.popover = popover
        return popover
    }

    /// Keys while the menu is open; returns true when handled here.
    func handle(_ event: NSEvent) -> Bool {
        guard popover?.isShown == true, !result.candidates.isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 126: move(-1) // ↑
        case 125: move(1) // ↓
        case 48: shift ? move(-1) : accept() // Tab
        case 36, 76: accept() // Return
        case 53: close() // Escape
        default: return false
        }
        return true
    }

    private func move(_ offset: Int) {
        let count = result.candidates.count
        selected = ((selected + offset) % count + count) % count
    }

    /// Type what the chosen candidate adds: the missing rest, or the word retyped.
    func accept(_ index: Int? = nil) {
        guard let session, let surface = session.surface else { return }
        let candidate = result.candidates[index ?? selected]
        let word = result.word
        var text: String
        if candidate.replacement.hasPrefix(word) {
            text = String(candidate.replacement.dropFirst(word.count))
        } else {
            text = String(repeating: "\u{7f}", count: word.count) + candidate.replacement
        }
        text += candidate.suffix
        if candidate.kind == .directory { session.reopenMenu = true }
        close()
        surface.typeText(text)
    }
}

private struct CompletionList: View {
    let menu: CompletionMenu

    var body: some View {
        let result = menu.result
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(result.candidates.enumerated()), id: \.element.id) { index, candidate in
                        CompletionRow(candidate: candidate, selected: index == menu.selected)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { menu.accept(index) }
                    }
                }
                .padding(4)
            }
            .onChange(of: menu.selected) { proxy.scrollTo(menu.selected) }
        }
        // Eight rows, as in v1.
        .frame(width: 380, height: min(CGFloat(result.candidates.count), 8) * 24 + 8)
    }
}

private struct CompletionRow: View {
    let candidate: Completion.Candidate
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(highlighted)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let description = candidate.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }

    private var icon: String {
        switch candidate.kind {
        case .command: "terminal"
        case .subcommand: "chevron.right"
        case .branch: "arrow.triangle.branch"
        case .script: "play"
        case .directory: "folder"
        case .file: "doc"
        case .argument: "clock.arrow.circlepath"
        }
    }

    private var highlighted: AttributedString {
        var text = AttributedString()
        let matched = Set(candidate.positions)
        for (offset, ch) in candidate.display.enumerated() {
            var piece = AttributedString(String(ch))
            if matched.contains(offset) {
                piece.foregroundColor = .accentColor
                piece.font = .system(.body, design: .monospaced).bold()
            }
            text += piece
        }
        return text
    }
}
