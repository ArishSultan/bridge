import AppKit
import BridgeCore
import BridgeTerm
import SwiftUI

/// Lays out a split tree node: a pane, or two children with a draggable divider between them.
struct SplitNodeView: View {
    let node: SplitNode
    let tab: Tab
    let theme: ChromeTheme

    var body: some View {
        switch node {
        case .leaf(let id):
            if let pane = tab.panes[id] {
                PaneView(pane: pane, tab: tab, theme: theme)
            }
        case .split(let split):
            SplitContainer(split: split, tab: tab, theme: theme)
        }
    }
}

private struct SplitContainer: View {
    let split: Split
    let tab: Tab
    let theme: ChromeTheme

    /// The visible line between panes.
    private let dividerThickness: CGFloat = 1
    /// The area around it that responds to dragging.
    private let grabThickness: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let horizontal = split.axis == .horizontal
            let total = horizontal ? geometry.size.width : geometry.size.height
            let firstLength = max(0, (total - dividerThickness) * split.ratio)
            let secondLength = max(0, total - dividerThickness - firstLength)

            ZStack(alignment: .topLeading) {
                SplitNodeView(node: split.first, tab: tab, theme: theme)
                    .frame(
                        width: horizontal ? firstLength : geometry.size.width,
                        height: horizontal ? geometry.size.height : firstLength)

                SplitNodeView(node: split.second, tab: tab, theme: theme)
                    .frame(
                        width: horizontal ? secondLength : geometry.size.width,
                        height: horizontal ? geometry.size.height : secondLength)
                    .offset(
                        x: horizontal ? firstLength + dividerThickness : 0,
                        y: horizontal ? 0 : firstLength + dividerThickness)

                Rectangle()
                    .fill(theme.border)
                    .frame(
                        width: horizontal ? dividerThickness : geometry.size.width,
                        height: horizontal ? geometry.size.height : dividerThickness)
                    .offset(x: horizontal ? firstLength : 0, y: horizontal ? 0 : firstLength)
                    .allowsHitTesting(false)

                // An invisible, wider handle centered on the divider.
                Color.clear
                    .frame(
                        width: horizontal ? grabThickness : geometry.size.width,
                        height: horizontal ? geometry.size.height : grabThickness)
                    .contentShape(Rectangle())
                    .offset(
                        x: horizontal ? firstLength - (grabThickness - dividerThickness) / 2 : 0,
                        y: horizontal ? 0 : firstLength - (grabThickness - dividerThickness) / 2)
                    .pointerStyle(horizontal ? .frameResize(position: .trailing) : .frameResize(position: .bottom))
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(split.id))
                            .onChanged { value in
                                let position = horizontal ? value.location.x : value.location.y
                                guard total > 0 else { return }
                                tab.updateTree { $0.setRatio(position / total, of: split.id) }
                            })
                    .onTapGesture(count: 2) {
                        tab.updateTree { $0.setRatio(0.5, of: split.id) }
                    }
            }
            .coordinateSpace(.named(split.id))
        }
    }
}

/// One terminal, plus the dimming that marks it unfocused when the tab has several.
struct PaneView: View {
    let pane: Pane
    let tab: Tab
    let theme: ChromeTheme

    var body: some View {
        let focused = tab.focusedPaneID == pane.id
        SurfaceHost(surface: pane.surface, focused: focused)
            .overlay {
                if !focused && tab.panes.count > 1 && tab.zoomedPaneID == nil {
                    theme.background.opacity(0.35).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let link = pane.hoveredLink {
                    Text(link)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .id(pane.id)
    }
}

/// Puts a terminal's AppKit view into SwiftUI.
///
/// The terminal view itself lives as long as its pane: SwiftUI creates and drops this container
/// whenever the layout changes, and each new container adopts the same terminal view, so the
/// program and its scrollback are untouched.
private struct SurfaceHost: NSViewRepresentable {
    let surface: TerminalSurfaceView
    let focused: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        adopt(into: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        adopt(into: container)
        if focused {
            // Wait for the view to be in the window before giving it the keyboard.
            DispatchQueue.main.async { [surface] in
                guard let window = surface.window, window.firstResponder !== surface else { return }
                window.makeFirstResponder(surface)
            }
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
