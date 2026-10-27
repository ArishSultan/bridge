import AppKit
import BridgeCore
import BridgeTerm
import Observation

/// The app's state: settings, the libghostty app and every window, tab and pane. It performs
/// the actions libghostty's key bindings produce (split, close, move focus…).
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var settings: BridgeCore.Settings {
        didSet {
            guard settings != oldValue else { return }
            settings.sanitize()
            settingsChanged()
        }
    }

    /// Whether the window chrome and "match app" schemes are currently dark.
    private(set) var isDark: Bool

    /// The libghostty app, or nil if it failed to start.
    @ObservationIgnored private(set) var terminal: TerminalApp?
    private(set) var startupError: String?

    @ObservationIgnored private var windows: [UUID: TerminalWindow] = [:]
    /// Options for windows opened by an action, keyed by the new window's id.
    @ObservationIgnored private var pendingWindowOptions: [UUID: TerminalSurfaceView.Options] = [:]
    /// Finds the pane of a surface libghostty reports about.
    @ObservationIgnored private var panesBySurface: [ObjectIdentifier: Pane] = [:]

    /// Set by the first window, since SwiftUI only hands these to views.
    @ObservationIgnored var openWindow: ((UUID) -> Void)?
    @ObservationIgnored var openSettings: (() -> Void)?

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?

    private init() {
        var settings = BridgeCore.Settings.load()
        settings.sanitize()
        self.settings = settings
        isDark = Self.computeDark(settings.appTheme)
        applyAppTheme()

        do {
            let terminal = try TerminalApp(configuration: terminalConfiguration)
            terminal.setColorScheme(dark: isDark)
            self.terminal = terminal
            terminal.delegate = self
        } catch {
            startupError = "The terminal engine (libghostty) failed to start."
        }

        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in AppModel.shared.appearanceChanged() }
        }
    }

    // MARK: - Settings and appearance

    var scheme: ColorScheme {
        ColorScheme.resolve(settings.colorScheme, dark: isDark)
    }

    private var terminalConfiguration: String {
        TerminalConfig.fileContents(for: settings, dark: isDark)
    }

    private func settingsChanged() {
        applyAppTheme()
        isDark = Self.computeDark(settings.appTheme)
        terminal?.setColorScheme(dark: isDark)
        terminal?.update(configuration: terminalConfiguration)

        // Write the file once edits settle, not on every slider step.
        saveTask?.cancel()
        let settings = settings
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                try settings.save()
            } catch {
                NSLog("Bridge: could not save settings: %@", String(describing: error))
            }
        }
    }

    private func appearanceChanged() {
        let dark = Self.computeDark(settings.appTheme)
        guard dark != isDark else { return }
        isDark = dark
        terminal?.setColorScheme(dark: dark)
        terminal?.update(configuration: terminalConfiguration)
    }

    private func applyAppTheme() {
        NSApp.appearance = switch settings.appTheme {
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
    }

    private static func computeDark(_ theme: AppTheme) -> Bool {
        switch theme {
        case .dark: true
        case .light: false
        case .system: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    // MARK: - Windows, tabs and panes

    /// The model for a window SwiftUI is showing, creating it (with one tab) the first time.
    func window(for id: UUID) -> TerminalWindow {
        if let window = windows[id] { return window }
        let window = TerminalWindow(id: id)
        windows[id] = window
        if let pane = makePane(options: pendingWindowOptions.removeValue(forKey: id) ?? .init(), context: .window) {
            window.add(Tab(pane: pane))
        }
        return window
    }

    /// The window was closed: its terminals end.
    func windowClosed(_ id: UUID) {
        guard let window = windows.removeValue(forKey: id) else { return }
        for tab in window.tabs {
            for pane in tab.panes.values {
                panesBySurface[ObjectIdentifier(pane.surface)] = nil
            }
        }
    }

    private func makePane(options: TerminalSurfaceView.Options, context: TerminalSurfaceView.Context) -> Pane? {
        guard let terminal else { return nil }
        do {
            let surface = try TerminalSurfaceView(app: terminal, options: options, context: context)
            let pane = Pane(surface: surface)
            surface.onChange = { [weak pane] in pane?.refresh() }
            surface.onFocus = { [weak pane] in
                guard let pane, let tab = pane.tab else { return }
                tab.focusedPaneID = pane.id
                tab.window?.selectedTabID = tab.id
            }
            panesBySurface[ObjectIdentifier(surface)] = pane
            return pane
        } catch {
            NSLog("Bridge: could not create a terminal: %@", String(describing: error))
            return nil
        }
    }

    /// The window the user is working in.
    var keyWindow: TerminalWindow? {
        let key = NSApp.keyWindow ?? NSApp.mainWindow
        return windows.values.first { $0.nsWindow === key } ?? windows.values.first
    }

    var focusedPane: Pane? { keyWindow?.selectedTab?.focusedPane }

    func newWindow(from pane: Pane? = nil) {
        let id = UUID()
        if let pane {
            pendingWindowOptions[id] = pane.surface.inheritedOptions(for: .window)
        }
        if let openWindow {
            openWindow(id)
        } else {
            NSLog("Bridge: no way to open a window yet")
        }
    }

    func newTab(in window: TerminalWindow? = nil, from pane: Pane? = nil) {
        guard let window = window ?? keyWindow else {
            newWindow()
            return
        }
        let source = pane ?? window.selectedTab?.focusedPane
        let options = source?.surface.inheritedOptions(for: .tab) ?? .init()
        guard let newPane = makePane(options: options, context: .tab) else { return }
        window.add(Tab(pane: newPane), after: window.selectedTab)
    }

    func split(_ pane: Pane, side: SplitDirection) {
        guard let tab = pane.tab,
              let newPane = makePane(options: pane.surface.inheritedOptions(for: .split), context: .split)
        else { return }
        tab.split(pane.id, side: side, with: newPane)
    }

    /// Close a pane right away (its program has exited, or the user confirmed).
    func close(_ pane: Pane) {
        panesBySurface[ObjectIdentifier(pane.surface)] = nil
        guard let tab = pane.tab else { return }
        if !tab.remove(pane.id) {
            close(tab)
        }
    }

    func close(_ tab: Tab) {
        for pane in tab.panes.values {
            panesBySurface[ObjectIdentifier(pane.surface)] = nil
        }
        guard let window = tab.window else { return }
        if !window.remove(tab) {
            window.nsWindow?.close()
        }
    }

    /// Close a tab after confirming, if any of its programs are still running.
    func requestClose(_ tab: Tab) {
        let running = tab.panes.values.contains { $0.surface.needsConfirmQuit }
        if running && !confirm(
            "Close this tab?",
            detail: "A program is still running in it and will be stopped.",
            button: "Close", window: tab.window?.nsWindow) {
            return
        }
        close(tab)
    }

    func select(_ tab: Tab) {
        tab.window?.selectedTabID = tab.id
    }

    private func confirm(_ message: String, detail: String, button: String, window: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Before quitting: confirm if a program is running anywhere.
    func shouldQuit() -> Bool {
        guard terminal?.needsConfirmQuit == true else { return true }
        return confirm(
            "Quit Bridge?",
            detail: "Programs are still running in some terminals and will be stopped.",
            button: "Quit", window: nil)
    }
}

// MARK: - libghostty actions

extension AppModel: TerminalAppDelegate {
    func terminalApp(_ app: TerminalApp, perform action: TerminalAction, surface: TerminalSurfaceView?) -> Bool {
        let pane = surface.flatMap { panesBySurface[ObjectIdentifier($0)] } ?? focusedPane
        let tab = pane?.tab
        let window = tab?.window

        switch action {
        case .quit:
            NSApp.terminate(nil)
        case .newWindow:
            newWindow(from: pane)
        case .newTab:
            newTab(in: window, from: pane)
        case .closeTab(let mode):
            guard let tab, let window else { return false }
            switch mode {
            case .this:
                close(tab)
            case .others:
                window.tabs.filter { $0 !== tab }.forEach(close)
            case .right:
                if let index = window.tabs.firstIndex(where: { $0 === tab }) {
                    window.tabs.suffix(from: index + 1).forEach(close)
                }
            }
        case .closeWindow:
            window?.nsWindow?.performClose(nil)
        case .closeAllWindows:
            for window in windows.values {
                window.nsWindow?.performClose(nil)
            }
        case .newSplit(let side):
            guard let pane else { return false }
            split(pane, side: SplitDirection(side))
        case .gotoSplit(let direction):
            guard let pane, let tab,
                  let target = tab.tree.neighbor(of: pane.id, FocusDirection(direction)),
                  let targetPane = tab.panes[target]
            else { return false }
            tab.zoomedPaneID = nil
            tab.focusedPaneID = target
            targetPane.surface.window?.makeFirstResponder(targetPane.surface)
        case .resizeSplit(let side, let amount):
            guard let pane, let tab, let size = pane.surface.superview?.window?.contentView?.bounds.size else {
                return false
            }
            tab.updateTree { $0.resize(pane.id, direction: SplitDirection(side), points: Double(amount), in: size) }
        case .equalizeSplits:
            guard let tab else { return false }
            tab.updateTree { $0.equalize() }
        case .toggleSplitZoom:
            guard let pane, let tab, tab.panes.count > 1 else { return false }
            tab.zoomedPaneID = tab.zoomedPaneID == nil ? pane.id : nil
        case .gotoTab(let target):
            guard let window, let tab, !window.tabs.isEmpty else { return false }
            let index = window.tabs.firstIndex { $0 === tab } ?? 0
            let count = window.tabs.count
            let newIndex: Int
            switch target {
            case .previous: newIndex = (index - 1 + count) % count
            case .next: newIndex = (index + 1) % count
            case .last: newIndex = count - 1
            case .index(let value):
                guard value < count else { return false }
                newIndex = value
            }
            window.selectedTabID = window.tabs[newIndex].id
        case .moveTab(let offset):
            guard let window, let tab else { return false }
            window.move(tab, by: offset)
        case .toggleFullscreen:
            window?.nsWindow?.toggleFullScreen(nil)
        case .openURL(let link):
            let url = URL(string: link).flatMap { $0.scheme == nil ? nil : $0 } ?? URL(fileURLWithPath: link)
            NSWorkspace.shared.open(url)
        case .openConfig:
            openSettings?()
        case .ringBell:
            if !NSApp.isActive {
                NSApp.requestUserAttention(.informationalRequest)
            }
        default:
            return false
        }
        return true
    }

    func terminalApp(_ app: TerminalApp, closeSurface surface: TerminalSurfaceView, processAlive: Bool) {
        guard let pane = panesBySurface[ObjectIdentifier(surface)] else { return }
        if processAlive && !confirm(
            "Close this terminal?",
            detail: "A program is still running in it and will be stopped.",
            button: "Close", window: surface.window) {
            return
        }
        close(pane)
    }
}

extension SplitDirection {
    init(_ side: TerminalAction.SplitSide) {
        switch side {
        case .right: self = .right
        case .down: self = .down
        case .left: self = .left
        case .up: self = .up
        }
    }
}

extension FocusDirection {
    init(_ focus: TerminalAction.SplitFocus) {
        switch focus {
        case .previous: self = .previous
        case .next: self = .next
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        }
    }
}
