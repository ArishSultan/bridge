import Foundation

/// Projects and their terminals and views. Stored in the app's data store (`Persistence`); the
/// JSON coding below reads v1's `~/.config/bridge/projects.json` once, when v2 first starts.
///
/// A project is a folder. Its items are terminals or views (a grid of terminals, a split layout);
/// each terminal is described by a `TerminalSpec`: a shell, a task bound to one command, or an SSH
/// session, sandboxed to the project unless it is an open terminal.
public typealias ID = UInt64

/// What a terminal runs.
public enum TerminalKind: Equatable, Sendable, Hashable {
    /// The user's shell.
    case shell
    /// One long-running command, started and stopped from the terminal's controls.
    case task(command: String, autoStart: Bool, restartOnExit: Bool)
    /// An SSH session to a host from the Global window.
    case ssh(host: ID)

    public var isTask: Bool { if case .task = self { true } else { false } }
    public var isSSH: Bool { if case .ssh = self { true } else { false } }
}

/// What a terminal can reach.
public enum Isolation: Equatable, Sendable, Hashable {
    /// In a sandbox profile (nil: the built-in Project profile), writing only inside the project.
    case sandboxed(profile: ID?)
    /// Not sandboxed (marked as such in the UI).
    case open

    public var isOpen: Bool { self == .open }
}

public struct TerminalSpec: Equatable, Sendable, Hashable {
    /// Empty: named after what it runs.
    public var name: String = ""
    public var tag: String?
    public var kind: TerminalKind = .shell
    /// Where it starts, relative to the project folder.
    public var folder: String = "."
    public var isolation: Isolation = .sandboxed(profile: nil)
    /// Keeps running when its item is left ("Keep alive"); on unless the user turns it off to
    /// save memory, as in any terminal, where switching tabs never stops a program.
    public var background = true

    public init(
        name: String = "", tag: String? = nil, kind: TerminalKind = .shell, folder: String = ".",
        isolation: Isolation = .sandboxed(profile: nil), background: Bool = true
    ) {
        self.name = name
        self.tag = tag
        self.kind = kind
        self.folder = folder
        self.isolation = isolation
        self.background = background
    }

    /// SSH sessions need the user's keys and the network, so they are never sandboxed.
    public var effectiveIsolation: Isolation {
        kind.isSSH ? .open : isolation
    }

    /// What a terminal split off this one is: a shell in the same folder, as isolated.
    public var forSplit: TerminalSpec {
        TerminalSpec(folder: folder, isolation: effectiveIsolation, background: background)
    }
}

/// `horizontal` puts the two halves side by side, `vertical` stacks them.
public enum SplitAxis: String, Codable, Sendable {
    case horizontal, vertical
}

/// A side of a pane another pane can be dropped on, to split it there.
public enum Side: Sendable {
    case left, right, top, bottom

    public var axis: SplitAxis {
        self == .left || self == .right ? .horizontal : .vertical
    }

    /// Whether the dropped pane goes first (left of or above the target).
    var before: Bool { self == .left || self == .top }
}

/// A view's layout: one terminal, or a split of two layouts.
public indirect enum Layout: Equatable, Sendable {
    case pane(id: ID, terminal: TerminalSpec)
    /// `ratio` is the first half's share; v1 didn't store it, so it defaults to an even split.
    case split(id: ID, axis: SplitAxis, ratio: Double, first: Layout, second: Layout)

    /// Pane ids in reading order.
    public var panes: [ID] {
        switch self {
        case .pane(let id, _): [id]
        case .split(_, _, _, let first, let second): first.panes + second.panes
        }
    }

    public func terminal(_ pane: ID) -> TerminalSpec? {
        switch self {
        case .pane(let id, let terminal): id == pane ? terminal : nil
        case .split(_, _, _, let first, let second): first.terminal(pane) ?? second.terminal(pane)
        }
    }

    /// Replace the terminal of `pane`. Returns whether it was found.
    @discardableResult
    public mutating func setTerminal(_ pane: ID, _ terminal: TerminalSpec) -> Bool {
        switch self {
        case .pane(let id, _):
            guard id == pane else { return false }
            self = .pane(id: id, terminal: terminal)
            return true
        case .split(let id, let axis, let ratio, var first, var second):
            let found = first.setTerminal(pane, terminal) || second.setTerminal(pane, terminal)
            self = .split(id: id, axis: axis, ratio: ratio, first: first, second: second)
            return found
        }
    }

    /// Replace `pane` with a split of `pane` and `newPane` (running `terminal`). Returns whether
    /// `pane` was found.
    @discardableResult
    public mutating func split(_ pane: ID, axis: SplitAxis, newPane: ID, splitID: ID, terminal: TerminalSpec) -> Bool {
        switch self {
        case .pane(let id, _):
            guard id == pane else { return false }
            self = .split(id: splitID, axis: axis, ratio: 0.5, first: self, second: .pane(id: newPane, terminal: terminal))
            return true
        case .split(let id, let axis2, let ratio, var first, var second):
            let found = first.split(pane, axis: axis, newPane: newPane, splitID: splitID, terminal: terminal)
                || second.split(pane, axis: axis, newPane: newPane, splitID: splitID, terminal: terminal)
            self = .split(id: id, axis: axis2, ratio: ratio, first: first, second: second)
            return found
        }
    }

    /// The layout without `pane`, its split collapsed; nil when nothing is left.
    public func removing(_ pane: ID) -> Layout? {
        switch self {
        case .pane(let id, _):
            return id == pane ? nil : self
        case .split(let id, let axis, let ratio, let first, let second):
            switch (first.removing(pane), second.removing(pane)) {
            case (let first?, let second?): return .split(id: id, axis: axis, ratio: ratio, first: first, second: second)
            case (let only?, nil), (nil, let only?): return only
            case (nil, nil): return nil
            }
        }
    }

    /// Move `pane` next to `target`, on its `side`: `target` is split there and `pane` leaves its
    /// old place. `splitID` names the new split.
    @discardableResult
    public mutating func move(_ pane: ID, to target: ID, side: Side, splitID: ID) -> Bool {
        guard pane != target, terminal(target) != nil, let spec = terminal(pane),
              var moved = removing(pane),
              moved.split(target, axis: side.axis, newPane: pane, splitID: splitID, terminal: spec)
        else { return false }
        if side.before { moved.flip(splitID) }
        self = moved
        return true
    }

    /// Put a terminal from elsewhere (another item) next to `target`, on its `side`.
    @discardableResult
    public mutating func insert(_ pane: ID, terminal spec: TerminalSpec, nextTo target: ID, side: Side, splitID: ID) -> Bool {
        guard terminal(pane) == nil, split(target, axis: side.axis, newPane: pane, splitID: splitID, terminal: spec) else {
            return false
        }
        if side.before { flip(splitID) }
        return true
    }

    private mutating func flip(_ splitID: ID) {
        guard case .split(let id, let axis, let ratio, var first, var second) = self else { return }
        if id == splitID {
            self = .split(id: id, axis: axis, ratio: 1 - ratio, first: second, second: first)
        } else {
            first.flip(splitID)
            second.flip(splitID)
            self = .split(id: id, axis: axis, ratio: ratio, first: first, second: second)
        }
    }

    /// Exchange the places of two panes (each keeps its terminal). Returns whether both were found.
    @discardableResult
    public mutating func swap(_ a: ID, _ b: ID) -> Bool {
        guard a != b, let specA = terminal(a), let specB = terminal(b) else { return false }
        self = mapPanes { id, terminal in
            if id == a { return (b, specB) }
            if id == b { return (a, specA) }
            return (id, terminal)
        }
        return true
    }

    func mapPanes(_ transform: (ID, TerminalSpec) -> (ID, TerminalSpec)) -> Layout {
        switch self {
        case .pane(let id, let terminal):
            let (newID, newTerminal) = transform(id, terminal)
            return .pane(id: newID, terminal: newTerminal)
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(id: id, axis: axis, ratio: ratio, first: first.mapPanes(transform), second: second.mapPanes(transform))
        }
    }

    /// Set the divider position of a split, as a fraction of its size.
    public mutating func setRatio(_ ratio: Double, of splitID: ID) {
        guard case .split(let id, let axis, let old, var first, var second) = self else { return }
        if id == splitID {
            self = .split(id: id, axis: axis, ratio: min(max(ratio, 0.1), 0.9), first: first, second: second)
        } else {
            first.setRatio(ratio, of: splitID)
            second.setRatio(ratio, of: splitID)
            self = .split(id: id, axis: axis, ratio: old, first: first, second: second)
        }
    }

    /// Every pane and split id.
    var ids: [ID] {
        switch self {
        case .pane(let id, _): [id]
        case .split(let id, _, _, let first, let second): [id] + first.ids + second.ids
        }
    }
}

/// An item of a project: one terminal, or a view of several in a grid.
public struct ProjectItem: Equatable, Sendable, Identifiable {
    public var id: ID
    /// Its name as a view of several terminals (one terminal goes by its own name).
    public var name: String = ""
    public var layout: Layout
    public var focused: ID?

    public init(id: ID, name: String = "", layout: Layout, focused: ID? = nil) {
        self.id = id
        self.name = name
        self.layout = layout
        self.focused = focused
    }

    public var panes: [ID] { layout.panes }

    /// The only terminal, when it has just one: shown as that terminal rather than as a view.
    public var single: ID? {
        if case .pane(let id, _) = layout { id } else { nil }
    }

    public func terminal(_ pane: ID) -> TerminalSpec? { layout.terminal(pane) }

    /// Add a terminal: split off `nextTo` (or the focused one) along `axis`.
    public mutating func add(pane: ID, splitID: ID, axis: SplitAxis, nextTo: ID?, terminal: TerminalSpec) {
        let target = nextTo ?? focused
        if target == nil || !layout.split(target!, axis: axis, newPane: pane, splitID: splitID, terminal: terminal) {
            // No such pane: split the first one.
            layout.split(layout.panes[0], axis: axis, newPane: pane, splitID: splitID, terminal: terminal)
        }
        focused = pane
    }

    /// Remove a terminal; focus moves to the first one left. Returns false if it was the last.
    public mutating func remove(_ pane: ID) -> Bool {
        guard let layout = layout.removing(pane) else { return false }
        self.layout = layout
        if focused == pane || focused.map({ !layout.panes.contains($0) }) ?? true {
            focused = layout.panes.first
        }
        return true
    }
}

/// A project: a folder, and the terminals and views made in it. Each project opens in a window.
public struct Project: Equatable, Sendable, Identifiable {
    public var id: ID
    public var name: String
    /// The project folder (`~` allowed).
    public var dir: String
    /// An emoji, or `file:<name>` for an icon imported into `~/.config/bridge/icons`.
    public var icon: String?
    /// A color id: red, orange, amber, green, teal, blue, violet, pink.
    public var color: String?
    /// Its terminals and views, in sidebar order.
    public var views: [ProjectItem] = []
    /// The item on screen.
    public var active: ID?
    /// When its window was last opened, for the Welcome window's recent projects.
    public var lastOpened: Date?
    /// Its window's frame (`NSStringFromRect`), to reopen it where it was.
    public var windowFrame: String?

    public init(id: ID, name: String, dir: String, icon: String? = nil, color: String? = nil, views: [ProjectItem] = [],
                active: ID? = nil, lastOpened: Date? = nil, windowFrame: String? = nil) {
        self.id = id
        self.name = name
        self.dir = dir
        self.icon = icon
        self.color = color
        self.views = views
        self.active = active
        self.lastOpened = lastOpened
        self.windowFrame = windowFrame
    }

    public var root: URL { URL(fileURLWithPath: Paths.expandHome(dir)) }

    /// Where a terminal of this project starts. A folder that would lead outside (`..`, an
    /// absolute path) falls back to the project folder.
    public func folder(_ folder: String) -> URL {
        let trimmed = folder.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        let inside = !trimmed.hasPrefix("/") && !parts.contains("..")
        guard inside, !parts.isEmpty else { return root }
        return parts.reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    public func view(_ id: ID) -> ProjectItem? { views.first { $0.id == id } }
    public func viewIndex(_ id: ID) -> Int? { views.firstIndex { $0.id == id } }
    public func view(ofPane pane: ID) -> ProjectItem? { views.first { $0.panes.contains(pane) } }
    public func terminal(_ pane: ID) -> TerminalSpec? { views.lazy.compactMap { $0.terminal(pane) }.first }
    public var panes: [ID] { views.flatMap(\.panes) }

    /// Remove an item; the one on screen moves to a neighbor. Returns it.
    @discardableResult
    public mutating func removeView(_ id: ID) -> ProjectItem? {
        guard let index = viewIndex(id) else { return nil }
        let removed = views.remove(at: index)
        if active == id {
            active = views.isEmpty ? nil : views[min(index, views.count - 1)].id
        }
        return removed
    }

    /// The item `offset` positions away from the one on screen (wrapping).
    public func cycleView(_ offset: Int) -> ID? {
        guard !views.isEmpty else { return nil }
        let current = views.firstIndex { $0.id == active } ?? 0
        return views[((current + offset) % views.count + views.count) % views.count].id
    }

    var ids: [ID] { [id] + views.flatMap { [$0.id] + $0.layout.ids } }
}

/// Every project, and which windows were open.
public struct Projects: Equatable, Sendable {
    public var projects: [Project] = []
    /// The Global window's terminals: a project of their own, in the home folder.
    public private(set) var global: Project?
    /// Projects whose windows were open when the app last quit, to open again.
    public var open: [ID] = []
    public var globalOpen = false
    public var sidebarOpen = true
    private var counter: ID = 1

    public init() {}

    /// Projects as stored.
    public init(projects: [Project], global: Project?, open: [ID], globalOpen: Bool, sidebarOpen: Bool, nextID: ID) {
        self.projects = projects
        self.global = global
        self.open = open
        self.globalOpen = globalOpen
        self.sidebarOpen = sidebarOpen
        counter = nextID
        normalize()
    }

    /// The next id `nextID()` hands out.
    public var nextFreeID: ID { counter }

    /// Every terminal keeps running when its item is left (what "Keep alive" did), as new ones do.
    public mutating func keepAllAlive() {
        func keep(_ project: inout Project) {
            for index in project.views.indices {
                for pane in project.views[index].panes {
                    guard var spec = project.views[index].terminal(pane) else { continue }
                    spec.background = true
                    project.views[index].layout.setTerminal(pane, spec)
                }
            }
        }
        for index in projects.indices { keep(&projects[index]) }
        if var global { keep(&global); self.global = global }
    }

    /// The Global window's project, made the first time it is needed.
    @discardableResult
    public mutating func globalID() -> ID {
        if let global { return global.id }
        let id = nextID()
        global = Project(id: id, name: "Home", dir: "~")
        return id
    }

    public func isGlobal(_ project: ID) -> Bool { global?.id == project }

    public mutating func nextID() -> ID {
        let id = max(counter, 1)
        counter = id + 1
        return id
    }

    /// A project, or the Global window's.
    public func project(_ id: ID) -> Project? {
        if let global, global.id == id { return global }
        return projects.first { $0.id == id }
    }

    /// The project of a folder, if it was added before.
    public func project(dir: URL) -> ID? {
        projects.first { $0.root.standardizedFileURL.path == dir.standardizedFileURL.path }?.id
    }

    /// Add a project with nothing in it yet; returns its id.
    public mutating func addProject(name: String, dir: String) -> ID {
        let id = nextID()
        projects.append(Project(id: id, name: name, dir: dir))
        return id
    }

    /// Store a project's new state.
    public mutating func put(_ project: Project) {
        if isGlobal(project.id) {
            global = project
        } else if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
    }

    /// Remove a project from the app (its folder is untouched).
    @discardableResult
    public mutating func removeProject(_ id: ID) -> Project? {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return nil }
        open.removeAll { $0 == id }
        return projects.remove(at: index)
    }

    /// Fix up after loading: drop items without a layout (handled while decoding), and never hand
    /// out an id already in use.
    mutating func normalize() {
        let maxID = (projects + (global.map { [$0] } ?? [])).flatMap(\.ids).max() ?? 0
        counter = max(counter, maxID + 1)
        globalID()
    }
}

// MARK: - v1's file

extension Projects {
    /// v1's file, read once into the data store.
    public static var fileURL: URL { Settings.configDirectory.appendingPathComponent("projects.json") }

    /// v1's `projects.json`. Throws when it can't be read, so it is never taken for an empty list.
    public static func decodeV1(_ data: Data) throws -> Projects {
        var projects = try JSONDecoder().decode(Projects.self, from: data)
        projects.normalize()
        return projects
    }
}

/// Home-folder paths as v1 wrote them.
public enum Paths {
    public static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    /// Expand a leading `~` to the home folder.
    public static func expandHome(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let rest = path.dropFirst().drop { $0 == "/" }
        return rest.isEmpty ? home : home + "/" + rest
    }

    /// Show the home folder as `~`.
    public static func tilde(_ path: String) -> String {
        let home = home
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - JSON (v1's serde format: snake_case keys, enums tagged with "type")

extension TerminalKind: Codable {
    private enum Keys: String, CodingKey { case type, command, autoStart = "auto_start", restartOnExit = "restart_on_exit", host }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "task":
            self = .task(
                command: try c.decode(String.self, forKey: .command),
                autoStart: try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false,
                restartOnExit: try c.decodeIfPresent(Bool.self, forKey: .restartOnExit) ?? false)
        case "ssh":
            self = .ssh(host: try c.decode(ID.self, forKey: .host))
        default:
            self = .shell
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .shell:
            try c.encode("shell", forKey: .type)
        case .task(let command, let autoStart, let restartOnExit):
            try c.encode("task", forKey: .type)
            try c.encode(command, forKey: .command)
            try c.encode(autoStart, forKey: .autoStart)
            try c.encode(restartOnExit, forKey: .restartOnExit)
        case .ssh(let host):
            try c.encode("ssh", forKey: .type)
            try c.encode(host, forKey: .host)
        }
    }
}

extension Isolation: Codable {
    private enum Keys: String, CodingKey { case type, profile }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "open": self = .open
        default: self = .sandboxed(profile: try c.decodeIfPresent(ID.self, forKey: .profile))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .open:
            try c.encode("open", forKey: .type)
        case .sandboxed(let profile):
            try c.encode("sandboxed", forKey: .type)
            try c.encode(profile, forKey: .profile)
        }
    }
}

extension TerminalSpec: Codable {
    private enum Keys: String, CodingKey { case name, tag, kind, folder, isolation, background }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
        kind = try c.decodeIfPresent(TerminalKind.self, forKey: .kind) ?? .shell
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? "."
        isolation = try c.decodeIfPresent(Isolation.self, forKey: .isolation) ?? .sandboxed(profile: nil)
        background = try c.decodeIfPresent(Bool.self, forKey: .background) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(tag, forKey: .tag)
        try c.encode(kind, forKey: .kind)
        try c.encode(folder, forKey: .folder)
        try c.encode(isolation, forKey: .isolation)
        try c.encode(background, forKey: .background)
    }
}

extension Layout: Codable {
    private enum Keys: String, CodingKey { case type, id, terminal, axis, ratio, first, second }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let id = try c.decode(ID.self, forKey: .id)
        switch try c.decode(String.self, forKey: .type) {
        case "split":
            self = .split(
                id: id,
                axis: try c.decode(SplitAxis.self, forKey: .axis),
                ratio: try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5,
                first: try c.decode(Layout.self, forKey: .first),
                second: try c.decode(Layout.self, forKey: .second))
        default:
            self = .pane(id: id, terminal: try c.decodeIfPresent(TerminalSpec.self, forKey: .terminal) ?? TerminalSpec())
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .pane(let id, let terminal):
            try c.encode("pane", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(terminal, forKey: .terminal)
        case .split(let id, let axis, let ratio, let first, let second):
            try c.encode("split", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(axis, forKey: .axis)
            // v1 ignores keys it doesn't know, so storing the divider position is harmless.
            if abs(ratio - 0.5) > 0.001 { try c.encode(ratio, forKey: .ratio) }
            try c.encode(first, forKey: .first)
            try c.encode(second, forKey: .second)
        }
    }
}

/// Decodes a `View`, or nil for one saved without a layout by older versions.
struct LossyView: Decodable {
    let view: ProjectItem?

    private enum Keys: String, CodingKey { case id, name, layout, focused }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let layout = try? c.decodeIfPresent(Layout.self, forKey: .layout) else {
            view = nil
            return
        }
        view = ProjectItem(
            id: try c.decode(ID.self, forKey: .id),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            layout: layout,
            focused: try c.decodeIfPresent(ID.self, forKey: .focused))
    }
}

extension ProjectItem: Encodable {
    private enum Keys: String, CodingKey { case id, name, layout, focused }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(layout, forKey: .layout)
        try c.encode(focused, forKey: .focused)
    }
}

extension Project: Codable {
    private enum Keys: String, CodingKey { case id, name, dir, icon, color, views, active }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(ID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        dir = try c.decode(String.self, forKey: .dir)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        views = (try c.decodeIfPresent([LossyView].self, forKey: .views) ?? []).compactMap(\.view)
        active = try c.decodeIfPresent(ID.self, forKey: .active)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(dir, forKey: .dir)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encode(views, forKey: .views)
        try c.encode(active, forKey: .active)
    }
}

extension Projects: Codable {
    private enum Keys: String, CodingKey {
        case projects, global, open, globalOpen = "global_open", sidebarOpen = "sidebar_open", nextID = "next_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        global = try c.decodeIfPresent(Project.self, forKey: .global)
        open = try c.decodeIfPresent([ID].self, forKey: .open) ?? []
        globalOpen = try c.decodeIfPresent(Bool.self, forKey: .globalOpen) ?? false
        sidebarOpen = try c.decodeIfPresent(Bool.self, forKey: .sidebarOpen) ?? true
        counter = try c.decodeIfPresent(ID.self, forKey: .nextID) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(projects, forKey: .projects)
        try c.encode(global, forKey: .global)
        try c.encode(open, forKey: .open)
        try c.encode(globalOpen, forKey: .globalOpen)
        try c.encode(sidebarOpen, forKey: .sidebarOpen)
        try c.encode(counter, forKey: .nextID)
    }
}
