import AppKit
import BridgeCore
import BridgeTerm
import SwiftUI

/// Puts a terminal's AppKit view into SwiftUI.
///
/// The terminal view lives as long as its session: SwiftUI creates and drops this container
/// whenever the layout changes, and each new container adopts the same terminal view, so the
/// program and its scrollback are untouched.
struct SurfaceHost: NSViewRepresentable {
    let surface: TerminalSurfaceView
    let focused: Bool

    /// What the latest update said, read when the deferred focus change runs: an update that
    /// was queued before the user clicked another pane mustn't take the keyboard back.
    final class Coordinator {
        var focused = false
        var adopted: ObjectIdentifier?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        let wasFocused = coordinator.focused
        let newSurface = coordinator.adopted != ObjectIdentifier(surface)
        adopt(into: container)
        coordinator.adopted = ObjectIdentifier(surface)
        coordinator.focused = focused
        // Only when this pane becomes the focused one (or its terminal is new), not on every
        // redraw: otherwise it takes the keyboard from whatever the user moved to.
        guard focused, !wasFocused || newSurface else { return }
        // Wait until the view is in the window before giving it the keyboard.
        DispatchQueue.main.async { [surface, weak coordinator] in
            guard let coordinator, coordinator.focused, coordinator.adopted == ObjectIdentifier(surface),
                  let window = surface.window, window.firstResponder !== surface,
                  !(window.firstResponder is NSText) // Leave a text field being edited alone.
            else { return }
            window.makeFirstResponder(surface)
        }
    }

    private func adopt(into container: NSView) {
        guard surface.superview !== container else { return }
        surface.removeFromSuperview()
        surface.frame = container.bounds
        surface.autoresizingMask = [.width, .height]
        container.addSubview(surface)
    }
}

/// Hands back the NSWindow a view is in, once it is in one.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        ReportingView(onWindow: onWindow)
    }

    func updateNSView(_ view: NSView, context: Context) {}

    final class ReportingView: NSView {
        let onWindow: (NSWindow) -> Void
        private var reported = false

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, !reported {
                reported = true
                onWindow(window)
            }
        }
    }
}

/// Project colors, as v1 named them.
enum ProjectColor: String, CaseIterable, Identifiable {
    case red, orange, amber, green, teal, blue, violet, pink

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .amber: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .violet: .purple
        case .pink: .pink
        }
    }

    static func color(_ id: String?) -> Color? {
        id.flatMap(ProjectColor.init(rawValue:))?.color
    }
}

/// A project's icon: its emoji or imported image on its color, or a folder.
struct ProjectIcon: View {
    let project: Project
    var size: CGFloat = 18

    var body: some View {
        let tint = ProjectColor.color(project.color) ?? .secondary
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(tint.opacity(0.18))
            content(tint: tint)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func content(tint: Color) -> some View {
        if let icon = project.icon, icon.hasPrefix("file:") {
            let url = ProjectIcons.url(for: String(icon.dropFirst(5)))
            if let image = NSImage(contentsOf: url) {
                if url.pathExtension == "svg" {
                    // One-color SVGs are drawn in the project color.
                    Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                        .foregroundStyle(tint).padding(size * 0.18)
                } else {
                    Image(nsImage: image).resizable().scaledToFit().padding(size * 0.12)
                }
            } else {
                folder(tint: tint)
            }
        } else if let icon = project.icon, !icon.isEmpty {
            Text(icon).font(.system(size: size * 0.62))
        } else {
            folder(tint: tint)
        }
    }

    private func folder(tint: Color) -> some View {
        Image(systemName: "folder.fill")
            .font(.system(size: size * 0.5))
            .foregroundStyle(tint)
    }
}

/// Icons imported for projects, in `~/.config/bridge/icons`.
enum ProjectIcons {
    static var directory: URL { BridgeCore.Settings.configDirectory.appendingPathComponent("icons") }

    static func url(for name: String) -> URL { directory.appendingPathComponent(name) }

    /// Copy an image into the icons folder, named after a hash of its contents. Multi-color SVGs
    /// are rasterized to PNG so they keep their colors. Returns the `file:` icon value.
    static func importIcon(from source: URL) throws -> String {
        let data = try Data(contentsOf: source)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = IconHash.fnv1a(data)
        if source.pathExtension.lowercased() == "svg", IconHash.isOneColorSVG(String(decoding: data, as: UTF8.self)) {
            let name = "\(hash).svg"
            try data.write(to: url(for: name), options: .atomic)
            return "file:\(name)"
        }
        guard let image = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        let name = "\(hash).png"
        let size = NSSize(width: 128, height: 128)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])?.write(to: url(for: name), options: .atomic)
        return "file:\(name)"
    }
}

extension View {
    /// A label-style section heading for sidebars.
    func sidebarHeading() -> some View {
        font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }
}

/// Reports a window's frame when the user has finished moving or resizing it.
@MainActor
final class FrameObserver {
    private var tokens: [NSObjectProtocol] = []

    init(window: NSWindow, changed: @escaping @MainActor (NSRect) -> Void) {
        for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didMoveNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated {
                    if let window, !window.styleMask.contains(.fullScreen) { changed(window.frame) }
                }
            })
        }
    }

    isolated deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}

extension View {
    /// A floating control's background: Liquid Glass on macOS 26 and later, a material before.
    @ViewBuilder
    func floatingBackground<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}
