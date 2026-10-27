import AppKit
import BridgeCore
import BridgeSystem
import BridgeTerm
import Observation

/// The app's state: settings, projects, the running terminals, and which windows are open. Every
/// window reads from it, and it performs the actions libghostty's key bindings produce.
@MainActor
@Observable
final class Store {
    static let shared = Store()

    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            settings.sanitize()
            settingsChanged(from: oldValue)
        }
    }

    private(set) var projects: Projects {
        didSet { scheduleSave() }
    }

    /// SSH hosts and forwards, sandbox profiles, the Vaultwarden account.
    var profiles: Profiles {
        didSet {
            guard profiles != oldValue else { return }
            store { try $0.save(profiles) }
        }
    }

    /// Whether "match app" schemes are currently dark.
    private(set) var isDark: Bool
    /// Something at launch the user needs to know: the terminal engine or the data store failed.
    private(set) var startupError: String?
    /// The data store (nil only when it couldn't be opened even in memory).
    @ObservationIgnored private(set) var persistence: Persistence?
    @ObservationIgnored private(set) var terminal: TerminalApp?

    /// Port forwards, running in the background.
    let forwards = Forwards()

    /// The SSH keys in the unlocked vault (empty while locked).
    var vaultKeys: [VaultKey] = []
    /// The unlocked vault: its agent and the public half of each key.
    @ObservationIgnored var vaultSession: VaultSession?
    @ObservationIgnored var vaultLastUsed = Date()
    @ObservationIgnored var vaultTimer: Timer?

    /// Running (or stopped) terminals by pane id.
    private(set) var sessions: [ID: PaneSession] = [:]
    /// Projects with a window on screen.
    private(set) var openWindows: Set<ID> = []
    /// The window controllers, to route actions to the right window.
    @ObservationIgnored var controllers: [ID: WindowController] = [:]

    /// Set by the first window, since SwiftUI only hands these to views.
    @ObservationIgnored var openProjectWindow: ((ID) -> Void)?
    @ObservationIgnored var openWelcomeWindow: (() -> Void)?
    @ObservationIgnored var closeWelcomeWindow: (() -> Void)?
    @ObservationIgnored var openSettingsWindow: (() -> Void)?
    /// The Settings window's page.
    var settingsTab: SettingsTab = .appearance

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var settingsSaveTask: Task<Void, Never>?
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var restored = false

    /// Every command run in Bridge's terminals (and the shell's own history, if imported).
    @ObservationIgnored private(set) var history = History() {
        didSet { historyViews = [:] }
    }
    /// Filtered copies of the history (per project for sandboxed terminals, and one for open
    /// ones), rebuilt when the history grows.
    @ObservationIgnored var historyViews: [String: (count: Int, history: History)] = [:]
    /// Where shells report prompts and commands.
    @ObservationIgnored private var shellServer: ShellEventServer?
    /// Pane of each shell token.
    @ObservationIgnored private var tokens: [String: ID] = [:]
    /// Single-use nonces for ssh askpass requests, with their host.
    @ObservationIgnored var askpassNonces: [String: (host: ID, issued: Date)] = [:]
    /// Executable names per PATH, for completing command names.
    @ObservationIgnored var executableCache: [String: [String]] = [:]
    var shellSocketPath: String? { shellServer?.path }

    private init() {
        let persistence: Persistence?
        var storeError: String?
        do {
            persistence = try Persistence()
        } catch {
            // Keep working for this session, in memory.
            persistence = try? Persistence(url: nil)
            storeError = "Bridge couldn't open its data in \(Paths.tilde(Persistence.storeURL.path)) "
                + "(\(error.localizedDescription)). Changes made now won't be kept after you quit."
        }
        self.persistence = persistence
        // Before the settings are read: a Ghostty theme chosen as the color scheme must be known.
        if let themes = TerminalApp.resourcesDirectory?.appendingPathComponent("themes") {
            BridgeCore.ColorScheme.loadGhosttyThemes(from: themes)
        }
        _ = persistence?.importJSONIfNeeded()
        var settings = persistence?.loadSettings() ?? Settings()
        settings.sanitize()
        self.settings = settings
        projects = persistence?.loadProjects() ?? Projects()
        profiles = persistence?.loadProfiles() ?? Profiles()
        startupError = storeError
        isDark = Self.computeDark(settings.appTheme)
        applyAppTheme()

        do {
            let terminal = try TerminalApp(configuration: terminalConfiguration)
            terminal.setColorScheme(dark: isDark)
            terminal.delegate = self
            self.terminal = terminal
        } catch {
            startupError = "The terminal engine (libghostty) failed to start, so terminals can't open."
        }

        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in Store.shared.appearanceChanged() }
        }

        do {
            try ShellIntegration.install(settings)
            shellServer = try ShellEventServer { connection, fields in
                Store.shared.shellMessage(connection, fields)
            }
        } catch {
            NSLog("Bridge: shell integration unavailable: %@", "\(error)")
            launchNotices.append("Shell integration is off for this session (\(error.localizedDescription)): "
                + "no command history, suggestions or prompt settings in new terminals.")
        }
        Task.detached(priority: .utility) { Store.cleanUpAfterLastRun() }
        loadHistory()
        Attention.shared.start()
        Task { @MainActor in Store.shared.forwards.startEnabled() }
    }

    /// After launch: tell the user what went wrong while starting, once.
    func reportLaunchProblems() {
        let problems = [startupError].compactMap { $0 } + (persistence?.problems ?? []) + launchNotices
        guard !problems.isEmpty else { return }
        launchNotices = []
        let alert = NSAlert()
        alert.alertStyle = startupError == nil ? .informational : .warning
        alert.messageText = problems.count == 1 ? "Bridge started with a problem" : "Bridge started with \(problems.count) problems"
        alert.informativeText = problems.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Before quitting.
    func shutdown() {
        DenialMonitor.shared.stop()
        forwards.stopAll()
        lockVault()
        shellServer?.shutdown()
    }

    func tokensLookup(_ token: String) -> ID? { tokens[token] }

    func record(_ entry: HistoryEntry) {
        history.record(entry)
        store { try $0.append(entry) }
    }

    /// Problems found at launch that aren't fatal (unreadable records, no shell integration).
    @ObservationIgnored var launchNotices: [String] = []

    /// Read the history in the background: the recorded commands, and the shell's own history.
    private func loadHistory() {
        let importShellHistory = settings.importShellHistory
        let container = persistence?.container
        Task.detached {
            let recorded = container.map { Persistence.loadHistory(from: $0) } ?? []
            let history = History.load(importShellHistory: importShellHistory, recorded: recorded)
            await MainActor.run {
                // Commands recorded while it loaded come after.
                let since = Store.shared.history.entries
                var all = history
                for entry in since { all.record(entry) }
                Store.shared.history = all
            }
        }
    }

    /// Save something; a failure is shown in the window in front.
    func store(_ save: (Persistence) throws -> Void) {
        guard let persistence else { return }
        do {
            try save(persistence)
        } catch {
            NSLog("Bridge: could not save: %@", "\(error)")
            let window = NSApp.keyWindow
            let controller = controllers.values.first { $0.window === window } ?? controllers.values.first
            controller?.toast = "Couldn't save: \(error.localizedDescription)"
        }
    }

    // MARK: - Settings and appearance

    var scheme: BridgeCore.ColorScheme { BridgeCore.ColorScheme.resolve(settings.colorScheme, dark: isDark) }

    private var terminalConfiguration: String {
        TerminalConfig.fileContents(for: settings, dark: isDark, naturalLineHeight: Self.naturalLineHeight(settings))
    }

    /// The font's own line height (ascent, descent and leading) as a multiple of its size.
    static func naturalLineHeight(_ settings: BridgeCore.Settings) -> Double {
        let size = CGFloat(settings.fontSize)
        guard let font = NSFont(name: settings.fontFamily, size: size) ?? NSFont.userFixedPitchFont(ofSize: size) else { return 1.2 }
        let ctFont = font as CTFont
        let height = CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont)
        return Double(height / size)
    }

    /// The window chrome, derived from the terminal's colors as v1 did: everything but the
    /// terminal is one surface a step toward the foreground; borders and the active row are mixes.
    var chrome: Chrome { Chrome(scheme) }

    private func settingsChanged(from old: BridgeCore.Settings) {
        applyAppTheme()
        try? ShellIntegration.writePrompts(settings)
        if settings.importShellHistory != old.importShellHistory {
            history = History()
            loadHistory()
        }
        isDark = Self.computeDark(settings.appTheme)
        terminal?.setColorScheme(dark: isDark)
        terminal?.update(configuration: terminalConfiguration)

        // Write the file once edits settle, not on every slider step.
        settingsSaveTask?.cancel()
        let settings = settings
        settingsSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self.store { try $0.save(settings) }
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

    // MARK: - Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        store { try $0.save(projects) }
    }

    // MARK: - Projects

    var globalID: ID {
        if let id = projects.global?.id { return id }
        return projects.globalID()
    }

    func project(_ id: ID) -> Project? { projects.project(id) }
    func isGlobal(_ id: ID) -> Bool { projects.isGlobal(id) }

    /// Change a project and save.
    func update(_ projectID: ID, _ change: (inout Project) -> Void) {
        guard var project = projects.project(projectID) else { return }
        change(&project)
        projects.put(project)
    }

    var sidebarOpen: Bool {
        get { projects.sidebarOpen }
        set { projects.sidebarOpen = newValue }
    }

    func moveProjects(fromOffsets source: IndexSet, toOffset destination: Int) {
        projects.projects.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Windows

    /// At launch: reopen the windows that were open when the app quit. Returns whether any did.
    func restoreWindows() -> Bool {
        guard !restored else { return !openWindows.isEmpty }
        restored = true
        var ids = projects.open.filter { projects.project($0) != nil }
        if projects.globalOpen { ids.append(globalID) }
        for id in ids { openProjectWindow?(id) }
        return !ids.isEmpty
    }

    func open(_ projectID: ID) {
        openProjectWindow?(projectID)
    }

    func openGlobal() {
        open(globalID)
    }

    /// Open a folder as a project: the existing one for that folder, or a new one, which then
    /// asks for its first terminal.
    func openFolder(_ url: URL) {
        if let id = projects.project(dir: url) {
            open(id)
            return
        }
        let id = projects.addProject(name: url.lastPathComponent, dir: Paths.tilde(url.path))
        pendingFirstTerminal.insert(id)
        open(id)
    }

    /// New projects open with a sandboxed shell.
    @ObservationIgnored var pendingFirstTerminal: Set<ID> = []

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to open as a project."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFolder(url)
    }

    func windowOpened(_ projectID: ID, controller: WindowController) {
        openWindows.insert(projectID)
        update(projectID) { $0.lastOpened = Date() }
        controllers[projectID] = controller
        closeWelcomeWindow?()
    }

    /// A project window closed: its terminals stop.
    func windowClosed(_ projectID: ID) {
        openWindows.remove(projectID)
        controllers[projectID] = nil
        for (id, session) in sessions where session.projectID == projectID {
            session.detach(status: .stopped)
            sessions[id] = nil
        }
        if openWindows.isEmpty {
            openWelcomeWindow?()
        }
    }

    /// The running terminals of a project.
    func runningPanes(of projectID: ID) -> [ID] {
        sessions.values.filter { $0.projectID == projectID && $0.status.isRunning }.map(\.id)
    }

    /// Remove a project from the app (its folder is untouched) and close its window.
    func removeProject(_ id: ID) {
        controllers[id]?.window?.close()
        projects.removeProject(id)
    }

    /// Before quitting: remember the open windows.
    func rememberOpenWindows() {
        projects.open = openWindows.filter { !projects.isGlobal($0) }.sorted()
        projects.globalOpen = openWindows.contains(globalID)
        saveNow()
    }

    var anyRunning: Bool { sessions.values.contains { $0.status.isRunning } }

    // MARK: - Items and terminals

    /// Add a terminal as a new item, and show it.
    @discardableResult
    func addItem(_ projectID: ID, spec: TerminalSpec) -> ID {
        let viewID = projects.nextID()
        let pane = projects.nextID()
        update(projectID) { project in
            project.views.append(ProjectItem(id: viewID, layout: .pane(id: pane, terminal: spec), focused: pane))
        }
        activate(projectID, item: viewID)
        return pane
    }

    /// Add a terminal next to `pane` (or the focused one) in the item on screen.
    @discardableResult
    func addPane(_ projectID: ID, spec: TerminalSpec, axis: SplitAxis, nextTo pane: ID?) -> ID? {
        guard let project = project(projectID), let active = project.active, let view = project.view(active) else {
            return addItem(projectID, spec: spec)
        }
        let newPane = projects.nextID()
        let splitID = projects.nextID()
        let firstLabel = view.single.flatMap { label(of: $0, in: project) }
        update(projectID) { project in
            guard let index = project.viewIndex(active) else { return }
            // A terminal becoming a view takes its name from the first terminal.
            if project.views[index].single != nil, project.views[index].name.isEmpty, let firstLabel {
                project.views[index].name = firstLabel
            }
            project.views[index].add(pane: newPane, splitID: splitID, axis: axis, nextTo: pane, terminal: spec)
        }
        startIfNeeded(newPane, in: projectID)
        return newPane
    }

    /// Show an item; its terminals start. Leaving the old one stops its terminals that aren't
    /// kept alive (the caller asked first if any were running).
    func activate(_ projectID: ID, item: ID) {
        guard let project = project(projectID) else { return }
        if let old = project.active, old != item, let oldView = project.view(old) {
            for pane in oldView.panes where !(oldView.terminal(pane)?.background ?? false) {
                stop(pane, byHand: false)
            }
        }
        update(projectID) { $0.active = item }
        for pane in project.view(item)?.panes ?? [] {
            startIfNeeded(pane, in: projectID)
            if let session = sessions[pane] { Attention.shared.clear(session) }
        }
    }

    /// Terminals that leaving the item on screen would stop: running, and not kept alive.
    func stoppingOnLeave(_ projectID: ID) -> [ID] {
        guard let project = project(projectID), let active = project.active, let view = project.view(active) else {
            return []
        }
        return view.panes.filter { pane in
            !(view.terminal(pane)?.background ?? false) && (sessions[pane]?.status.isRunning ?? false)
        }
    }

    func setKeepAlive(_ projectID: ID, panes: [ID], _ keep: Bool) {
        update(projectID) { project in
            for index in project.views.indices {
                for pane in panes {
                    guard var spec = project.views[index].terminal(pane) else { continue }
                    spec.background = keep
                    project.views[index].layout.setTerminal(pane, spec)
                }
            }
        }
    }

    /// Delete an item and stop its terminals. With an undo manager, Undo puts it back where it
    /// was (its terminals start again).
    func deleteItem(_ projectID: ID, item: ID, undo: UndoManager? = nil) {
        guard let project = project(projectID), let index = project.viewIndex(item) else { return }
        let removed = project.views[index]
        let name = itemName(removed, in: project)
        for pane in removed.panes { discard(pane) }
        update(projectID) { $0.removeView(item) }
        if let active = self.project(projectID)?.active {
            activate(projectID, item: active)
        }
        undo?.registerUndo(withTarget: self) { store in
            store.update(projectID) { $0.views.insert(removed, at: min(index, $0.views.count)) }
            store.activate(projectID, item: removed.id)
        }
        undo?.setActionName("Close “\(name)”")
    }

    /// Close one terminal of a view. The only terminal of an item can't be closed this way.
    func closePane(_ projectID: ID, pane: ID, undo: UndoManager? = nil) {
        guard let project = project(projectID), let view = project.view(ofPane: pane), view.single == nil else { return }
        let name = label(of: pane, in: project) ?? "Terminal"
        discard(pane)
        update(projectID) { project in
            guard let index = project.viewIndex(view.id) else { return }
            _ = project.views[index].remove(pane)
        }
        undo?.registerUndo(withTarget: self) { store in
            // The view as it was, with the terminal in its place.
            store.update(projectID) { project in
                if let index = project.viewIndex(view.id) { project.views[index] = view }
            }
            store.startIfNeeded(pane, in: projectID)
        }
        undo?.setActionName("Close “\(name)”")
    }

    func moveItems(_ projectID: ID, fromOffsets source: IndexSet, toOffset destination: Int) {
        update(projectID) { $0.views.move(fromOffsets: source, toOffset: destination) }
    }

    func rename(_ projectID: ID, item: ID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        update(projectID) { project in
            guard let index = project.viewIndex(item) else { return }
            if let pane = project.views[index].single, var spec = project.views[index].terminal(pane) {
                // An empty terminal name goes back to the automatic label.
                spec.name = name
                project.views[index].layout.setTerminal(pane, spec)
            } else if !name.isEmpty {
                project.views[index].name = name
            }
        }
    }

    func renamePane(_ projectID: ID, pane: ID, to name: String) {
        updateSpec(projectID, pane: pane) { $0.name = name.trimmingCharacters(in: .whitespaces) }
    }

    func renameProject(_ projectID: ID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        update(projectID) { $0.name = name }
    }

    /// Change a terminal's spec. If more than its name, tag or keep-alive changed, it restarts.
    func updateSpec(_ projectID: ID, pane: ID, _ change: (inout TerminalSpec) -> Void) {
        guard let old = project(projectID)?.terminal(pane) else { return }
        var new = old
        change(&new)
        guard new != old else { return }
        update(projectID) { project in
            for index in project.views.indices where project.views[index].panes.contains(pane) {
                project.views[index].layout.setTerminal(pane, new)
            }
        }
        var cosmetic = new
        cosmetic.name = old.name
        cosmetic.tag = old.tag
        cosmetic.background = old.background
        if cosmetic != old, let session = sessions[pane] {
            let wasRunning = session.status.isRunning
            session.detach(status: .stopped)
            if wasRunning { start(pane, in: projectID) }
        }
    }

    func setFocused(_ projectID: ID, pane: ID) {
        guard let project = project(projectID), let view = project.view(ofPane: pane), view.focused != pane else { return }
        update(projectID) { project in
            guard let index = project.viewIndex(view.id) else { return }
            project.views[index].focused = pane
        }
    }

    func updateLayout(_ projectID: ID, item: ID, _ change: (inout BridgeCore.Layout) -> Void) {
        update(projectID) { project in
            guard let index = project.viewIndex(item) else { return }
            change(&project.views[index].layout)
        }
    }

    /// The terminal being dragged, while a drag is on.
    @ObservationIgnored var draggedPane: PaneDrag?
    /// Where a dragged terminal would land on the terminal it is over (drawn there).
    var paneDropZone: (pane: ID, zone: DropZone)?

    /// A terminal dragged over a running one (the terminal view reports it).
    private func paneDragged(_ phase: TerminalSurfaceView.PaneDragPhase, onto target: ID, in projectID: ID) -> Bool {
        guard let drag = draggedPane, drag.project == projectID, drag.pane != target,
              let item = project(projectID)?.view(ofPane: target)?.id
        else {
            if paneDropZone?.pane == target { paneDropZone = nil }
            return false
        }
        switch phase {
        case .over(let point, let size):
            let zone = PaneDropZones.zone(for: point, in: size, sidesOnly: drag.item != item)
            if paneDropZone?.pane != target || paneDropZone?.zone != zone { paneDropZone = (target, zone) }
            return true
        case .exited:
            if paneDropZone?.pane == target { paneDropZone = nil }
            return true
        case .dropped(let point, let size):
            paneDropZone = nil
            draggedPane = nil
            drop(drag, onto: target, in: item, zone: PaneDropZones.zone(for: point, in: size, sidesOnly: drag.item != item))
            return true
        }
    }

    /// A dragged terminal lands on `target` (in the item `item`): beside it on a side, or (from
    /// the same split) swapped with it in the middle. From another item it leaves that item (an
    /// item of one terminal goes away) and joins this split, still running.
    func drop(_ drag: PaneDrag, onto target: ID, in item: ID, zone: DropZone) {
        let projectID = drag.project
        guard let project = project(projectID), drag.pane != target else { return }
        if drag.item == item {
            switch zone {
            case .center:
                updateLayout(projectID, item: item) { $0.swap(drag.pane, target) }
            case .side(let side):
                let splitID = newID()
                updateLayout(projectID, item: item) { $0.move(drag.pane, to: target, side: side, splitID: splitID) }
            }
            return
        }
        guard case .side(let side) = zone, let spec = project.terminal(drag.pane), project.view(item) != nil else { return }
        let splitID = newID()
        let firstLabel = project.view(item)?.single.flatMap { label(of: $0, in: project) }
        update(projectID) { project in
            guard let source = project.viewIndex(drag.item) else { return }
            if project.views[source].single == drag.pane {
                project.views.remove(at: source)
            } else {
                _ = project.views[source].remove(drag.pane)
            }
            guard let index = project.viewIndex(item) else { return }
            // A terminal becoming a split takes its name from the first terminal.
            if project.views[index].single != nil, project.views[index].name.isEmpty, let firstLabel {
                project.views[index].name = firstLabel
            }
            guard project.views[index].layout.insert(drag.pane, terminal: spec, nextTo: target, side: side, splitID: splitID) else { return }
            project.views[index].focused = drag.pane
            project.active = item
        }
        startIfNeeded(drag.pane, in: projectID)
        controllers[projectID]?.focus(drag.pane)
    }

    /// The new split's id for moving panes around.
    func newID() -> ID { projects.nextID() }

    // MARK: - Running terminals

    func session(_ pane: ID, in projectID: ID) -> PaneSession {
        if let session = sessions[pane] { return session }
        let session = PaneSession(id: pane, projectID: projectID)
        sessions[pane] = session
        return session
    }

    /// Start a terminal that isn't running, unless it's a task waiting for ▶.
    func startIfNeeded(_ pane: ID, in projectID: ID) {
        let session = session(pane, in: projectID)
        // Already running, or stopped by hand: it waits for ▶.
        guard session.surface == nil, !(session.status == .stopped && session.stoppedByHand) else { return }
        if case .task(_, let autoStart, _) = project(projectID)?.terminal(pane)?.kind, !autoStart {
            session.status = .notStarted
            return
        }
        start(pane, in: projectID)
    }

    /// Start (or restart) a terminal.
    func start(_ pane: ID, in projectID: ID) {
        guard let terminal, let project = project(projectID), let spec = project.terminal(pane) else { return }
        let session = session(pane, in: projectID)
        session.detach(status: .stopped)
        var plan = Launch.plan(for: spec, in: project, settings: settings, ssh: sshTarget(for: spec))
        // Shells get Bridge's shell integration: prompt settings, and reports to the app.
        if case .shell = spec.kind, settings.shellIntegration, let shellServer {
            if let old = session.token { tokens[old] = nil }
            let token = UUID().uuidString
            tokens[token] = pane
            session.token = token
            let integration = ShellIntegration.launch(
                shell: settings.shell, loginShell: Launch.loginShell(settings),
                socket: shellServer.path, token: token, helper: Self.helperPath)
            plan.command = integration.command ?? plan.command
            plan.environment.merge(integration.variables) { _, new in new }
        }
        // Sandboxed terminals (never in the Global window, never SSH).
        if case .sandboxed(let profile) = spec.effectiveIsolation, !isGlobal(projectID) {
            let engine = profiles.engine(for: profile)
            plan = Launch.sandboxed(
                plan, engine: engine, spec: spec, pane: pane, project: project, settings: settings,
                appSocket: shellServer?.path, extraReadable: Self.sandboxReadable, helper: Self.helperPath)
            if !engine.isDocker { DenialMonitor.shared.start() }
            session.dockerContainer = engine.isDocker ? Sandbox.containerName(pane) : nil
        }
        let options = TerminalSurfaceView.Options(
            workingDirectory: plan.folder.path,
            command: plan.command,
            environment: plan.environment,
            waitAfterCommand: true)
        do {
            let surface = try TerminalSurfaceView(app: terminal, options: options, context: .window)
            surface.allowsProgramClipboardWrite = allowsClipboard(spec, in: projectID)
            surface.onPaneDrag = { [weak self] phase in
                self?.paneDragged(phase, onto: pane, in: projectID) ?? false
            }
            surface.onFocus = { [weak self] in
                self?.setFocused(projectID, pane: pane)
                if let session = self?.sessions[pane] { Attention.shared.clear(session) }
            }
            surface.interceptKey = { [weak self, weak session] event in
                guard let self, let session else { return false }
                return self.intercept(event, session: session)
            }
            session.attach(surface)
        } catch {
            NSLog("Bridge: could not start a terminal: %@", "\(error)")
            session.status = .exited(code: nil)
            session.launchError = terminal == nil
                ? "The terminal engine didn't start."
                : "The terminal couldn't start: \(error.localizedDescription)"
        }
    }

    /// Whether programs in a terminal may set the clipboard: not in a sandbox, unless its profile
    /// allows the clipboard (what a program puts there gets pasted outside the sandbox).
    private func allowsClipboard(_ spec: TerminalSpec, in projectID: ID) -> Bool {
        guard case .sandboxed(let profile) = spec.effectiveIsolation, !isGlobal(projectID) else { return true }
        if case .seatbelt(let seatbelt) = profiles.engine(for: profile) { return seatbelt.allowClipboard }
        return false
    }

    /// Open a link a terminal's program printed. From a sandboxed terminal only web and mail
    /// links open; a file is shown in the Finder rather than opened (opening an app or script
    /// the sandbox wrote would run it outside the sandbox).
    func openLink(_ link: String, from session: PaneSession?) {
        let url = URL(string: link).flatMap { $0.scheme == nil ? nil : $0 } ?? URL(fileURLWithPath: link)
        let sandboxed = session.map(isSandboxed) ?? false
        guard sandboxed else {
            NSWorkspace.shared.open(url)
            return
        }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
        case "file":
            NSWorkspace.shared.activateFileViewerSelecting([url])
        default:
            if let session { controllers[session.projectID]?.toast = "Links like this don't open from a sandboxed terminal" }
        }
    }

    /// Stop a running terminal, keeping its pane.
    func stop(_ pane: ID, byHand: Bool = true) {
        guard let session = sessions[pane], session.surface != nil || session.status == .running else { return }
        session.stoppedByHand = byHand
        session.detach(status: .stopped)
    }

    func restart(_ pane: ID, in projectID: ID) {
        start(pane, in: projectID)
    }

    /// Stop a terminal and forget it (its pane is going away).
    private func discard(_ pane: ID) {
        sessions[pane]?.detach(status: .stopped)
        sessions[pane] = nil
    }

    /// Keys for a terminal whose program has exited: Enter starts it again, others are ignored.
    private func intercept(_ event: NSEvent, session: PaneSession) -> Bool {
        // The completion menu takes its keys while open.
        if CompletionMenu.shared.session === session, CompletionMenu.shared.handle(event) { return true }
        // ⌃R at a prompt: command history, unless the shell is to have it (its reverse search, or
        // fzf and friends). Inside a program, ⌃R is the program's.
        if session.atPrompt, controlROpensHistory,
           event.modifierFlags.intersection([.control, .command, .option, .shift]) == .control,
           event.charactersIgnoringModifiers == "r", let controller = controllers[session.projectID] {
            controller.historyPane = session.id
            return true
        }
        // ⌃Tab and ⌃⇧Tab move between sidebar items, as between tabs anywhere (the menu shows
        // ⌘⇧] and ⌘⇧[ for the same).
        if event.keyCode == 48, event.modifierFlags.intersection([.control, .command, .option]) == .control,
           let controller = controllers[session.projectID] {
            controller.cycleItems(event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        }
        guard case .exited = session.status else { return false }
        if event.keyCode == 36 || event.keyCode == 76 { // Return, keypad Enter
            start(session.id, in: session.projectID)
        }
        return true
    }

    /// Whether ⌃R at a prompt opens Bridge's history.
    private var controlROpensHistory: Bool {
        switch settings.controlR {
        case .bridge: true
        case .shell: false
        case .automatic: !Self.shellHasOwnControlR
        }
    }

    /// Read once: whether the user's shell setup binds ⌃R itself.
    static let shellHasOwnControlR = ControlRHandler.shellHasOwn()

    func label(of pane: ID, in project: Project) -> String? {
        guard let spec = project.terminal(pane) else { return nil }
        return Launch.label(for: spec, title: sessions[pane]?.title ?? "", hostName: { self.hostName($0) })
    }

    /// What an item is called in the sidebar.
    func itemName(_ view: ProjectItem, in project: Project) -> String {
        if let pane = view.single { return label(of: pane, in: project) ?? "Terminal" }
        return view.name.isEmpty ? "View" : view.name
    }

    func paneFor(_ surface: TerminalSurfaceView) -> PaneSession? {
        sessions.values.first { $0.surface === surface }
    }
}

// MARK: - libghostty actions

extension Store: TerminalAppDelegate {
    func terminalApp(_ app: TerminalApp, perform action: TerminalAction, surface: TerminalSurfaceView?) -> Bool {
        let session = surface.flatMap(paneFor)

        switch action {
        case .childExited(let code):
            guard let session else { return false }
            session.status = .exited(code: Int(code))
            if code == 255, !session.stoppedByHand,
               case .ssh(let hostID) = project(session.projectID)?.terminal(session.id)?.kind,
               let host = profiles.host(hostID) {
                sshDropped(session, host: host)
            }
            if !session.stoppedByHand, project(session.projectID)?.terminal(session.id)?.kind.isTask == true {
                Attention.shared.raise(session, body: code == 0 ? "finished" : "failed (exit code \(code))")
            }
            // A task that exits on its own may start again.
            if !session.stoppedByHand,
               case .task(_, _, true) = project(session.projectID)?.terminal(session.id)?.kind {
                session.restartTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    self?.start(session.id, in: session.projectID)
                }
            }
            return true
        case .ringBell:
            if let session, settings.notifyOnBell {
                Attention.shared.raise(session, body: "needs your attention")
            }
            return true
        case .openURL(let link):
            openLink(link, from: session)
            return true
        case .openConfig:
            openSettingsWindow?()
            return true
        case .toggleFullscreen:
            surface?.window?.toggleFullScreen(nil)
            return true
        case .quit:
            NSApp.terminate(nil)
            return true
        case .gotoSplit(let direction):
            guard let session, let controller = controllers[session.projectID] else { return false }
            return controller.focusNeighbor(of: session.id, BridgeCore.Layout.Focus(direction))
        case .equalizeSplits:
            guard let session, let controller = controllers[session.projectID] else { return false }
            controller.equalize()
            return true
        default:
            return false
        }
    }

    func terminalApp(_ app: TerminalApp, closeSurface surface: TerminalSurfaceView, processAlive: Bool) {
        // Programs exit into the "press Enter" state (wait_after_command), and closing goes
        // through the app's menus, so libghostty closing a surface itself only happens when it
        // can't continue: show it as exited.
        paneFor(surface)?.status = .exited(code: nil)
    }
}

extension BridgeCore.Layout.Focus {
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

/// An SSH key from Vaultwarden, as hosts refer to it.
struct VaultKey: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

