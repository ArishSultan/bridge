import SwiftUI

/// The row of tabs, drawn in the title bar area next to the window buttons.
struct TabBar: View {
    let window: TerminalWindow
    let theme: ChromeTheme

    /// Room for the close, minimize and zoom buttons.
    private let trafficLightsWidth: CGFloat = 78
    static let height: CGFloat = 38

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: trafficLightsWidth)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(window.tabs) { tab in
                        TabButton(
                            tab: tab,
                            selected: tab.id == window.selectedTab?.id,
                            closable: window.tabs.count > 1,
                            theme: theme)
                    }
                }
                .padding(.vertical, 5)
            }
            .scrollBounceBehavior(.basedOnSize)
            Button {
                AppModel.shared.newTab(in: window)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Tab (⌘T)")
            .padding(.horizontal, 6)
        }
        .frame(height: Self.height)
        .background(theme.tabBar)
        .gesture(WindowDragGesture())
    }
}

private struct TabButton: View {
    let tab: Tab
    let selected: Bool
    let closable: Bool
    let theme: ChromeTheme

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if tab.bell && !selected {
                Circle().fill(theme.accent).frame(width: 6, height: 6)
            }
            Text(tab.title)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? theme.foreground : theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            if tab.panes.count > 1 {
                Text("\(tab.panes.count)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 4)
                    .background(theme.border, in: Capsule())
            }
            Spacer(minLength: 0)
            Button {
                AppModel.shared.requestClose(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(closable && (hovering || selected) ? 1 : 0)
            .disabled(!closable)
            .help("Close Tab")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minWidth: 120, maxWidth: 220, minHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? theme.selectedTab : hovering ? theme.border : .clear))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? theme.border : .clear))
        .contentShape(Rectangle())
        .onTapGesture { AppModel.shared.select(tab) }
        .onHover { hovering = $0 }
        .help(tab.focusedPane?.directory ?? tab.title)
    }
}
