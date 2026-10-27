import BridgeCore
import SwiftUI

/// Command history (⌃R): fuzzy search over every command run, newest first. Return puts the
/// command at the prompt, ⌘Return runs it.
struct HistorySheet: View {
    let pane: ID

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: Int?
    @FocusState private var searchFocused: Bool

    private var store: Store { .shared }
    private static let limit = 5000

    var body: some View {
        let history = store.history
        let hits = history.search(query, limit: Self.limit)
        let total = history.recentUnique.count

        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search commands", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit { choose(hits, run: false) }
            }
            .padding(12)
            Divider()

            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(Array(hits.enumerated()), id: \.element.index) { offset, hit in
                        HistoryRow(entry: history.entries[hit.index], positions: hit.positions)
                            .tag(offset)
                            .id(offset)
                            .onTapGesture(count: 2) { choose(hits, at: offset, run: false) }
                    }
                }
                .listStyle(.plain)
                .onChange(of: selection) { if let selection { proxy.scrollTo(selection) } }
            }

            Divider()
            HStack {
                Text(query.isEmpty ? "\(total) commands" : "\(hits.count) of \(total) commands")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("↩ Insert   ⌘↩ Run   ⎋ Close").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 640, height: 480)
        .onAppear {
            searchFocused = true
            selection = 0
        }
        .onChange(of: query) { selection = 0 }
        .onKeyPress(.upArrow) { move(-1, hits.count) }
        .onKeyPress(.downArrow) { move(1, hits.count) }
        .onKeyPress(keys: ["p", "n", "r"], phases: .down) { press in
            guard press.modifiers == .control else { return .ignored }
            return move(press.key == "p" ? -1 : 1, hits.count)
        }
        .onKeyPress(.return, phases: .down) { press in
            choose(hits, run: press.modifiers.contains(.command))
            return .handled
        }
        .onExitCommand { dismiss() }
    }

    private func move(_ offset: Int, _ count: Int) -> KeyPress.Result {
        guard count > 0 else { return .handled }
        selection = min(max((selection ?? -1) + offset, 0), count - 1)
        return .handled
    }

    private func choose(_ hits: [History.Hit], at offset: Int? = nil, run: Bool) {
        let offset = offset ?? selection ?? 0
        guard hits.indices.contains(offset) else { return }
        let command = store.history.entries[hits[offset].index].command
        dismiss()
        // After the sheet is gone, so the terminal has the keyboard again.
        DispatchQueue.main.async {
            Store.shared.insertCommand(command, into: pane, run: run)
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let positions: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(highlighted)
                .font(.body.monospaced())
                .lineLimit(2)
            HStack(spacing: 6) {
                if let cwd = entry.cwd { Chip(Paths.tilde(cwd), systemImage: "folder") }
                if let started = entry.startedAt {
                    Chip(Date(timeIntervalSince1970: TimeInterval(started)).formatted(.relative(presentation: .named)),
                         systemImage: "clock")
                }
                if let code = entry.exitCode {
                    Chip(code == 0 ? "ok" : "exit \(code)", systemImage: code == 0 ? "checkmark" : "xmark")
                        .foregroundStyle(code == 0 ? Color.secondary : Color.red)
                }
                if let ms = entry.durationMS, ms >= 100 {
                    Chip(Duration.milliseconds(ms).formatted(.units(allowed: [.hours, .minutes, .seconds, .milliseconds], width: .narrow, maximumUnitCount: 2)),
                         systemImage: "timer")
                }
                if entry.imported { Chip("shell history", systemImage: "tray.and.arrow.down") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    /// The command with matched characters in bold, line breaks shown as ↵.
    private var highlighted: AttributedString {
        var text = AttributedString()
        let matched = Set(positions)
        for (offset, ch) in entry.command.enumerated() {
            var piece = AttributedString(ch == "\n" ? "↵ " : String(ch))
            if matched.contains(offset) {
                piece.font = .body.monospaced().bold()
                piece.foregroundColor = .accentColor
            }
            text += piece
        }
        return text
    }
}

private struct Chip: View {
    let text: String
    let systemImage: String

    init(_ text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}
