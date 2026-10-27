import AppKit
import BridgeCore
import SwiftUI

/// Watches the system log for what Bridge's sandboxes refuse, so a terminal can say why a
/// program failed ("couldn't read ~/.ssh/config") instead of leaving only "Operation not
/// permitted". Runs `log stream` while the app runs, from the first sandboxed terminal on.
@MainActor
final class DenialMonitor {
    static let shared = DenialMonitor()

    private var process: Process?
    private var partial = Data()

    func start() {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--level", "default", "--predicate", SandboxDenial.logPredicate]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in DenialMonitor.shared.received(data) }
        }
        process.terminationHandler = { _ in
            Task { @MainActor in DenialMonitor.shared.process = nil }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            NSLog("Bridge: can't watch sandbox denials: %@", "\(error)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private func received(_ data: Data) {
        partial.append(data)
        // Lines of JSON; keep an unfinished one for next time (and never let it grow unbounded).
        while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
            let line = partial[partial.startIndex..<newline]
            partial.removeSubrange(partial.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = object["eventMessage"] as? String,
                  let denial = SandboxDenial.parse(message)
            else { continue }
            Store.shared.denied(denial)
        }
        if partial.count > 1 << 20 { partial.removeAll() }
    }
}

extension Store {
    /// A sandbox refused something in one of the terminals.
    func denied(_ denial: SandboxDenial) {
        guard let session = sessions[denial.pane] else { return }
        session.record(denial)
    }

    /// Let a sandbox profile read (or also write) a path it refused, from a denial. A path the
    /// sandbox always hides (keys, the app's records) can't be allowed this way.
    func allow(_ denial: SandboxDenial, write: Bool) {
        guard let project = project(sessions[denial.pane]?.projectID ?? 0),
              let spec = project.terminal(denial.pane), case .sandboxed(let profileID) = spec.effectiveIsolation
        else { return }
        let path = Paths.tilde(denial.target)
        func change(_ engine: inout SandboxEngine) {
            guard case .seatbelt(var seatbelt) = engine else { return }
            var list = write ? seatbelt.writable : seatbelt.readable
            if !list.contains(path) { list.append(path) }
            if write { seatbelt.writable = list } else { seatbelt.readable = list }
            engine = .seatbelt(seatbelt)
        }
        if let profileID, let index = profiles.sandboxes.firstIndex(where: { $0.id == profileID }) {
            change(&profiles.sandboxes[index].engine)
        } else {
            var engine = profiles.projectEngine
            change(&engine)
            profiles.projectSandbox = engine
        }
        sessions[denial.pane]?.dismiss(denial)
    }

    /// Whether a refused path can be allowed: never what every sandbox hides (keys, the app's
    /// records), and never changes to what runs outside the sandbox later.
    func canAllow(_ denial: SandboxDenial, write: Bool = false) -> Bool {
        guard denial.isPath else { return false }
        let path = denial.target
        func under(_ list: [String]) -> Bool { list.contains { path == $0 || path.hasPrefix($0 + "/") } }
        if under(Sandbox.alwaysHidden(home: Paths.home)) { return false }
        return !write || !under(Sandbox.neverWritable(home: Paths.home))
    }

    /// The same terminal's folder, in an open (unsandboxed) shell, for what the sandbox can't do.
    func openTerminalInstead(for pane: ID) {
        guard let session = sessions[pane], let spec = project(session.projectID)?.terminal(pane) else { return }
        addItem(session.projectID, spec: TerminalSpec(folder: spec.folder, isolation: .open))
    }
}

/// What a sandbox refused in one terminal, as a small button on it; its popover says what and
/// offers the ways forward.
struct DenialBadge: View {
    let session: PaneSession

    @State private var shown = false
    private var store: Store { .shared }

    var body: some View {
        Button {
            shown = true
            session.denialsSeen()
        } label: {
            Label(session.unseenDenials > 0 ? "\(session.unseenDenials) blocked" : "Blocked",
                  systemImage: "hand.raised.fill")
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(in: Capsule())
        .padding(8)
        .help("The sandbox refused something in this terminal")
        .accessibilityLabel("Sandbox blocked \(session.denials.count) actions")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            DenialList(session: session)
        }
    }
}

private struct DenialList: View {
    let session: PaneSession
    private var store: Store { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The sandbox refused").font(.headline)
            ForEach(session.denials.suffix(8)) { denial in
                VStack(alignment: .leading, spacing: 4) {
                    Text(denial.summary + (denial.count > 1 ? " (\(denial.count)×)" : ""))
                        .font(.callout)
                        .textSelection(.enabled)
                    HStack {
                        if store.canAllow(denial) {
                            Button("Allow Reading") { store.allow(denial, write: false) }
                            if denial.kind == .write, store.canAllow(denial, write: true) {
                                Button("Allow Changes") { store.allow(denial, write: true) }
                            }
                        }
                        Button("Dismiss") { session.dismiss(denial) }
                    }
                    .controlSize(.small)
                }
                Divider()
            }
            HStack {
                Button("Open Terminal Instead") { store.openTerminalInstead(for: session.id) }
                    .help("A terminal in the same folder that isn't sandboxed, for SSH keys, Docker and logins")
                Spacer()
                Link("Learn More", destination: Links.sandbox)
            }
            .controlSize(.small)
            Text("Allowing changes the sandbox for every terminal that uses it; it takes effect when a terminal restarts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 380)
    }
}
