import AppKit
import BridgeCore
import SwiftUI

/// A terminal window: the tab bar in the title bar area, and the selected tab's panes below.
struct TerminalWindowView: View {
    let id: UUID

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var window: TerminalWindow?

    private var model: AppModel { AppModel.shared }

    var body: some View {
        let theme = ChromeTheme(model.scheme)
        VStack(spacing: 0) {
            if let window {
                TabBar(window: window, theme: theme)
                Rectangle().fill(theme.border).frame(height: 1)
                ZStack {
                    // Only the selected tab is in the window; the others keep running.
                    if let tab = window.selectedTab {
                        TabContentView(tab: tab, theme: theme)
                            .id(tab.id)
                    }
                }
            } else if let error = model.startupError {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            }
        }
        .background(theme.background.opacity(model.settings.backgroundEffect == .opaque ? 1 : 0))
        .background {
            if model.settings.backgroundEffect == .blurred {
                VisualEffectBackground()
            }
        }
        .background(WindowAccessor { nsWindow in
            window?.nsWindow = nsWindow
            configure(nsWindow)
        })
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(theme.isLight ? .light : .dark)
        .navigationTitle(window?.selectedTab?.title ?? "Bridge")
        .onAppear {
            model.openWindow = { [openWindow] id in openWindow(id: "terminal", value: id) }
            model.openSettings = { [openSettings] in openSettings() }
            if window == nil {
                window = model.window(for: id)
            }
        }
        .onDisappear {
            model.windowClosed(id)
        }
    }

    /// Transparent backgrounds need a non-opaque window.
    private func configure(_ nsWindow: NSWindow) {
        let opaque = model.settings.backgroundEffect == .opaque
        nsWindow.isOpaque = opaque
        nsWindow.backgroundColor = opaque ? NSColor(ChromeTheme(model.scheme).background) : .clear
        nsWindow.titlebarAppearsTransparent = true
        nsWindow.tabbingMode = .disallowed
    }
}

/// A tab's panes, laid out by its split tree (or just the zoomed pane).
struct TabContentView: View {
    let tab: Tab
    let theme: ChromeTheme

    var body: some View {
        if let zoomed = tab.zoomedPaneID, let pane = tab.panes[zoomed] {
            PaneView(pane: pane, tab: tab, theme: theme)
        } else {
            SplitNodeView(node: tab.tree.root, tab: tab, theme: theme)
        }
    }
}

/// Hands back the NSWindow a view is in, whenever it changes.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        WindowReportingView(onWindow: onWindow)
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? WindowReportingView else { return }
        view.onWindow = onWindow
        if let window = view.window { onWindow(window) }
    }

    final class WindowReportingView: NSView {
        var onWindow: (NSWindow) -> Void

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}

/// The desktop showing through, blurred, behind translucent terminals.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
