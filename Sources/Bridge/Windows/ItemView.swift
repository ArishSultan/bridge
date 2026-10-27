import AppKit
import BridgeCore
import SwiftUI
import UniformTypeIdentifiers

/// The item on screen: one terminal filling the area, or a view's terminals in their layout, each
/// with a header.
struct ItemView: View {
    let project: Project
    let view: ProjectItem
    let controller: WindowController

    var body: some View {
        if let pane = view.single {
            PaneContainer(project: project, pane: pane, controller: controller, focused: true)
        } else {
            LayoutView(project: project, item: view.id, layout: view.layout, focused: view.focused, controller: controller)
        }
    }
}

private struct LayoutView: View {
    let project: Project
    let item: ID
    let layout: BridgeCore.Layout
    let focused: ID?
    let controller: WindowController

    var body: some View {
        switch layout {
        case .pane(let id, _):
            HeaderedPane(project: project, item: item, pane: id, focused: focused == id, controller: controller)
        case .split(let id, let axis, let ratio, let first, let second):
            SplitContainer(splitID: id, axis: axis, ratio: ratio, project: project, item: item) {
                LayoutView(project: project, item: item, layout: first, focused: focused, controller: controller)
            } second: {
                LayoutView(project: project, item: item, layout: second, focused: focused, controller: controller)
            }
        }
    }
}

/// Two halves with a draggable divider; double-click the divider to even them out.
private struct SplitContainer<First: View, Second: View>: View {
    let splitID: ID
    let axis: SplitAxis
    let ratio: Double
    let project: Project
    let item: ID
    @ViewBuilder let first: First
    @ViewBuilder let second: Second

    private let divider: CGFloat = 1
    private let grab: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let horizontal = axis == .horizontal
            let total = horizontal ? geometry.size.width : geometry.size.height
            let firstLength = max(0, (total - divider) * ratio)
            let secondLength = max(0, total - divider - firstLength)

            ZStack(alignment: .topLeading) {
                first
                    .frame(width: horizontal ? firstLength : geometry.size.width,
                           height: horizontal ? geometry.size.height : firstLength)
                second
                    .frame(width: horizontal ? secondLength : geometry.size.width,
                           height: horizontal ? geometry.size.height : secondLength)
                    .offset(x: horizontal ? firstLength + divider : 0, y: horizontal ? 0 : firstLength + divider)
                Rectangle()
                    .fill(Store.shared.chrome.border)
                    .frame(width: horizontal ? divider : geometry.size.width,
                           height: horizontal ? geometry.size.height : divider)
                    .offset(x: horizontal ? firstLength : 0, y: horizontal ? 0 : firstLength)
                    .allowsHitTesting(false)
                Color.clear
                    .frame(width: horizontal ? grab : geometry.size.width, height: horizontal ? geometry.size.height : grab)
                    .contentShape(Rectangle())
                    .offset(x: horizontal ? firstLength - (grab - divider) / 2 : 0,
                            y: horizontal ? 0 : firstLength - (grab - divider) / 2)
                    .pointerStyle(horizontal ? .frameResize(position: .trailing) : .frameResize(position: .bottom))
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(splitID)).onChanged { value in
                        guard total > 0 else { return }
                        let position = horizontal ? value.location.x : value.location.y
                        Store.shared.updateLayout(project.id, item: item) { $0.setRatio(position / total, of: splitID) }
                    })
                    .onTapGesture(count: 2) {
                        Store.shared.updateLayout(project.id, item: item) { $0.setRatio(0.5, of: splitID) }
                    }
            }
            .coordinateSpace(.named(splitID))
        }
    }
}

/// A terminal of a view: its header, and the terminal, which other panes can be dropped on.
private struct HeaderedPane: View {
    let project: Project
    let item: ID
    let pane: ID
    let focused: Bool
    let controller: WindowController

    @State private var dropSide: DropZone?
    @State private var size: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(project: project, pane: pane, focused: focused, controller: controller)
            PaneContainer(project: project, pane: pane, controller: controller, focused: focused)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .overlay { DropHighlight(zone: dropSide) }
                .onDrop(of: [.text], delegate: PaneDropDelegate(
                    project: project, item: item, target: pane, size: size, zone: $dropSide))
        }
    }
}

/// Where a dragged pane lands: next to the target on a side, or swapped with it.
enum DropZone: Equatable {
    case side(Side)
    case center
}

private struct DropHighlight: View {
    let zone: DropZone?

    var body: some View {
        GeometryReader { geometry in
            if let zone {
                let size = geometry.size
                let rect: CGRect = switch zone {
                case .center: CGRect(origin: .zero, size: size)
                case .side(.left): CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
                case .side(.right): CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
                case .side(.top): CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
                case .side(.bottom): CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
                }
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.18))
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .animation(.easeOut(duration: 0.12), value: zone)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Dropping a pane's header onto another pane: near an edge (within a third) splits there, the
/// middle swaps the two.
private struct PaneDropDelegate: DropDelegate {
    let project: Project
    let item: ID
    let target: ID
    let size: CGSize
    @Binding var zone: DropZone?

    static let prefix = "bridge-pane:"

    func dropUpdated(info: DropInfo) -> DropProposal? {
        zone = Self.zone(for: info.location, in: size)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let zone = zone ?? .center
        self.zone = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        let projectID = project.id
        let item = item
        let target = target
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, text.hasPrefix(Self.prefix),
                  let pane = ID(text.dropFirst(Self.prefix.count)), pane != target
            else { return }
            Task { @MainActor in
                let store = Store.shared
                switch zone {
                case .center:
                    store.updateLayout(projectID, item: item) { $0.swap(pane, target) }
                case .side(let side):
                    let splitID = store.newID()
                    store.updateLayout(projectID, item: item) { $0.move(pane, to: target, side: side, splitID: splitID) }
                }
            }
        }
        return true
    }

    static func zone(for point: CGPoint, in size: CGSize) -> DropZone {
        guard size.width > 0, size.height > 0 else { return .center }
        let distances: [(Side, CGFloat)] = [
            (.left, point.x / size.width), (.right, 1 - point.x / size.width),
            (.top, point.y / size.height), (.bottom, 1 - point.y / size.height),
        ]
        let nearest = distances.min { $0.1 < $1.1 }!
        return nearest.1 < 1.0 / 3 ? .side(nearest.0) : .center
    }
}

/// The header of a terminal in a view: drag handle, status, name, tag, isolation, controls.
private struct PaneHeader: View {
    let project: Project
    let pane: ID
    let focused: Bool
    let controller: WindowController

    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var editing: Bool

    private var store: Store { .shared }

    var body: some View {
        let spec = project.terminal(pane) ?? TerminalSpec()
        let session = store.sessions[pane]

        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .onDrag { NSItemProvider(object: "\(PaneDropDelegate.prefix)\(pane)" as NSString) }
                .help("Drag onto another terminal: an edge splits there, the middle swaps them")
            StatusDot(status: session?.status ?? .notStarted)
            if controller.renaming == .pane(pane) {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($editing)
                    .onSubmit(commit)
                    .onExitCommand { controller.renaming = nil }
                    .onAppear { draft = spec.name; editing = true }
                    .onChange(of: editing) { if !editing { commit() } }
            } else {
                Text(store.label(of: pane, in: project) ?? "Terminal")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fontWeight(focused ? .semibold : .regular)
            }
            if let tag = spec.tag, !tag.isEmpty {
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 5)
                    .background(.quaternary, in: Capsule())
            }
            IsolationBadge(spec: spec)
            Spacer(minLength: 4)
            PaneControls(project: project, pane: pane, controller: controller, compact: true)
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
            Button("Close", systemImage: "xmark") { store.closePane(project.id, pane: pane) }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .opacity(hovering || focused ? 1 : 0)
                .help("Close terminal")
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(focused ? Store.shared.chrome.active : Store.shared.chrome.surface)
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { controller.renaming = .pane(pane) }
        .onTapGesture { controller.focus(pane) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Edit Terminal…") { controller.edit(pane) }
            Button("Rename") { controller.renaming = .pane(pane) }
            Toggle("Keep Alive", isOn: Binding(
                get: { spec.background }, set: { store.setKeepAlive(project.id, panes: [pane], $0) }))
            Divider()
            Button("Close", role: .destructive) { store.closePane(project.id, pane: pane) }
        }
    }

    private func commit() {
        guard controller.renaming == .pane(pane) else { return }
        store.renamePane(project.id, pane: pane, to: draft)
        controller.renaming = nil
    }
}

struct StatusDot: View {
    let color: Color
    let help: String

    init(color: Color, help: String) {
        self.color = color
        self.help = help
    }

    init(status: PaneSession.Status) {
        switch status {
        case .running: self.init(color: .green, help: "Running")
        case .exited(let code?) where code != 0: self.init(color: .red, help: "Exited with code \(code)")
        case .exited: self.init(color: .gray, help: "Exited")
        case .stopped: self.init(color: .gray, help: "Stopped")
        case .notStarted: self.init(color: .gray, help: "Not started")
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7).help(help)
    }
}

/// "Sandboxed" or "open", shown on terminals in views.
struct IsolationBadge: View {
    let spec: TerminalSpec

    var body: some View {
        if spec.effectiveIsolation.isOpen {
            Text("open")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 5)
                .background(.orange.opacity(0.15), in: Capsule())
                .help("Not sandboxed")
        } else {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.secondary)
                .help("Sandboxed: writes only inside the project")
        }
    }
}

/// A terminal, or what stands in for it when it isn't running.
struct PaneContainer: View {
    let project: Project
    let pane: ID
    let controller: WindowController
    let focused: Bool

    private var store: Store { .shared }

    var body: some View {
        let session = store.session(pane, in: project.id)
        let spec = project.terminal(pane)
        ZStack(alignment: .bottom) {
            Color(store.scheme.background)
            if let surface = session.surface {
                SurfaceHost(surface: surface, focused: focused)
            } else {
                ContentUnavailableView {
                    Label(session.status == .stopped ? "Stopped" : "Not started", systemImage: "play.circle")
                } description: {
                    if case .task(let command, _, _) = spec?.kind {
                        Text(command).font(.body.monospaced())
                    }
                } actions: {
                    Button("Start") { store.start(pane, in: project.id) }
                        .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(Color(store.scheme.foreground))
            }
            // Open (unsandboxed) terminals in a project get v1's amber edge.
            if spec?.effectiveIsolation.isOpen == true, !store.isGlobal(project.id) {
                HStack(spacing: 0) {
                    Rectangle().fill(Color.orange.opacity(0.85)).frame(width: 2)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)
                .help("Open: not sandboxed")
            }
            if case .exited(let code) = session.status {
                ExitedBar(code: code, ssh: spec?.kind.isSSH ?? false) { store.start(pane, in: project.id) }
            }
            if let link = session.hoveredLink {
                Text(link)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(in: Capsule())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Shown when a program has exited: its code, and starting it again.
private struct ExitedBar: View {
    let code: Int?
    let ssh: Bool
    let restart: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: code == 0 || code == nil ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(code == 0 || code == nil ? Color.secondary : Color.orange)
            Text(code.map { "Exited with code \($0)" } ?? "Exited")
            Text("Press Return to \(ssh ? "reconnect" : "restart")")
                .foregroundStyle(.secondary)
            Button(ssh ? "Reconnect" : "Restart", action: restart)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(in: Capsule())
        .padding(12)
    }
}

extension Color {
    init(_ rgb: RGB) {
        self.init(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }
}
