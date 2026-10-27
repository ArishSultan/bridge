import BridgeCore
import Foundation
import SwiftData

/// The app's data store: settings, projects with their terminals and views, SSH hosts and
/// forwards, sandbox profiles, the Vaultwarden account and command history, in SwiftData, at
/// `~/Library/Application Support/Bridge/Bridge.store`. No sandbox can read that folder.
///
/// The app keeps working on its value types (`Projects`, `Profiles`, `Settings`, `History`);
/// saving brings the rows in line with them. A row that can't be read back is reported and left
/// as it is, never replaced with nothing.
@MainActor
public final class Persistence {
    public static var storeURL: URL { Paths.dataDirectory.appendingPathComponent("Bridge.store") }

    /// Recorded history older than this many commands is dropped.
    public nonisolated static let historyLimit = 100_000

    public let container: ModelContainer
    private let context: ModelContext
    /// What couldn't be read, to tell the user.
    public private(set) var problems: [String] = []
    /// Items whose layout couldn't be read: kept, not overwritten or deleted.
    private var unreadableItems: Set<PersistentIdentifier> = []
    private var unreadableSandboxes: Set<Int64> = []

    /// The store at `url`, or one in memory only (tests).
    public init(url: URL? = storeURL) throws {
        let schema = Schema(versionedSchema: BridgeSchemaV1.self)
        let configuration: ModelConfiguration
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Paths.makePrivateDirectory(url.deletingLastPathComponent())
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }
        container = try ModelContainer(for: schema, configurations: configuration)
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    private func state() -> AppStateRecord {
        if let existing = try? context.fetch(FetchDescriptor<AppStateRecord>()).first { return existing }
        let state = AppStateRecord()
        context.insert(state)
        return state
    }

    private func save() throws {
        if context.hasChanges { try context.save() }
    }

    // MARK: - Settings

    /// The saved settings, nil before any were saved.
    public func loadSettings() -> Settings? {
        guard let data = state().settings else { return nil }
        do {
            var settings = try Self.decode(Settings.self, from: data)
            settings.sanitize()
            return settings
        } catch {
            problems.append("Your settings could not be read, so the defaults are in use until you change one.")
            return nil
        }
    }

    public func save(_ settings: Settings) throws {
        state().settings = try Self.encode(settings)
        try save()
    }

    // MARK: - Projects

    public func loadProjects() -> Projects {
        let state = state()
        let records = (try? context.fetch(FetchDescriptor<ProjectRecord>(sortBy: [SortDescriptor(\.order)]))) ?? []
        var projects: [Project] = []
        var global: Project?
        for record in records {
            var views: [ProjectItem] = []
            for item in record.items.sorted(by: { $0.order < $1.order }) {
                do {
                    let layout = try Self.decode(Layout.self, from: item.layout)
                    views.append(ProjectItem(id: ID(stored: item.itemID), name: item.name, layout: layout,
                                             focused: item.focused.map(ID.init(stored:))))
                } catch {
                    unreadableItems.insert(item.persistentModelID)
                    problems.append("A terminal in “\(record.name)” could not be read and is left out.")
                }
            }
            let project = Project(
                id: ID(stored: record.projectID), name: record.name, dir: record.dir, icon: record.icon, color: record.color,
                views: views, active: record.activeItem.map(ID.init(stored:)), lastOpened: record.lastOpened,
                windowFrame: record.windowFrame)
            if record.isGlobal { global = project } else { projects.append(project) }
        }
        return Projects(projects: projects, global: global, open: state.openProjects.map(ID.init(stored:)),
                        globalOpen: state.globalOpen, sidebarOpen: state.sidebarOpen, nextID: ID(stored: state.nextProjectID))
    }

    public func save(_ projects: Projects) throws {
        let existing = (try? context.fetch(FetchDescriptor<ProjectRecord>())) ?? []
        var byID = Dictionary(existing.map { ($0.projectID, $0) }, uniquingKeysWith: { first, _ in first })
        var all = projects.projects.enumerated().map { ($0.element, $0.offset, false) }
        if let global = projects.global { all.append((global, -1, true)) }
        for (project, order, isGlobal) in all {
            let record = byID.removeValue(forKey: project.id.stored)
                ?? ProjectRecord(projectID: project.id.stored, name: project.name, dir: project.dir, order: order, isGlobal: isGlobal)
            if record.modelContext == nil { context.insert(record) }
            record.name = project.name
            record.dir = project.dir
            record.icon = project.icon
            record.color = project.color
            record.order = order
            record.isGlobal = isGlobal
            record.activeItem = project.active?.stored
            record.lastOpened = project.lastOpened
            record.windowFrame = project.windowFrame
            try sync(items: project.views, of: record)
        }
        for gone in byID.values { context.delete(gone) }
        let state = state()
        state.openProjects = projects.open.map(\.stored)
        state.globalOpen = projects.globalOpen
        state.sidebarOpen = projects.sidebarOpen
        state.nextProjectID = projects.nextFreeID.stored
        try save()
    }

    private func sync(items: [ProjectItem], of project: ProjectRecord) throws {
        var byID = Dictionary(project.items.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        for (order, item) in items.enumerated() {
            let layout = try Self.encode(item.layout)
            if let record = byID.removeValue(forKey: item.id.stored) {
                record.name = item.name
                record.order = order
                record.focused = item.focused?.stored
                if record.layout != layout { record.layout = layout }
            } else {
                let record = ItemRecord(itemID: item.id.stored, name: item.name, order: order,
                                        focused: item.focused?.stored, layout: layout)
                context.insert(record)
                record.project = project
            }
        }
        for gone in byID.values where !unreadableItems.contains(gone.persistentModelID) {
            context.delete(gone)
        }
    }

    // MARK: - Profiles

    public func loadProfiles() -> Profiles {
        let state = state()
        let hostRecords = (try? context.fetch(FetchDescriptor<HostRecord>(sortBy: [SortDescriptor(\.order)]))) ?? []
        let hosts = hostRecords.map { record in
            SSHHost(
                id: ID(stored: record.hostID), name: record.name, host: record.host,
                port: UInt16(clamping: record.port), user: record.user, auth: Self.auth(record),
                keepaliveSecs: UInt32(clamping: record.keepaliveSecs),
                onDisconnect: OnDisconnect(rawValue: record.onDisconnect) ?? .nothing,
                forwards: record.forwards.sorted { $0.order < $1.order }.map { forward in
                    Forward(id: ID(stored: forward.forwardID), name: forward.name,
                            kind: ForwardKind(rawValue: forward.kind) ?? .local, bind: forward.bind,
                            target: forward.target, showLogs: forward.showLogs, enabled: forward.enabled)
                })
        }
        let sandboxRecords = (try? context.fetch(FetchDescriptor<SandboxRecord>(sortBy: [SortDescriptor(\.order)]))) ?? []
        var sandboxes: [SandboxProfile] = []
        for record in sandboxRecords {
            do {
                sandboxes.append(SandboxProfile(id: ID(stored: record.sandboxID), name: record.name,
                                                engine: try Self.decode(SandboxEngine.self, from: record.engine)))
            } catch {
                unreadableSandboxes.insert(record.sandboxID)
                problems.append("The sandbox “\(record.name)” could not be read and is left out.")
            }
        }
        var projectSandbox: SandboxEngine?
        if let data = state.projectSandbox {
            do {
                projectSandbox = try Self.decode(SandboxEngine.self, from: data)
            } catch {
                problems.append("Your changes to the Project sandbox could not be read, so its built-in rules are in use.")
            }
        }
        var vault: VaultAccount?
        if let server = state.vaultServer, let email = state.vaultEmail, let device = state.vaultDeviceID {
            vault = VaultAccount(server: server, email: email, deviceID: device,
                                 lockMinutes: UInt32(clamping: state.vaultLockMinutes))
        }
        return Profiles(hosts: hosts, sandboxes: sandboxes, projectSandbox: projectSandbox, vault: vault,
                        nextID: ID(stored: state.nextProfileID))
    }

    public func save(_ profiles: Profiles) throws {
        let existingHosts = (try? context.fetch(FetchDescriptor<HostRecord>())) ?? []
        var hostsByID = Dictionary(existingHosts.map { ($0.hostID, $0) }, uniquingKeysWith: { first, _ in first })
        for (order, host) in profiles.hosts.enumerated() {
            let record = hostsByID.removeValue(forKey: host.id.stored) ?? {
                let record = HostRecord(hostID: host.id.stored, name: host.name, host: host.host, port: Int(host.port),
                                        user: host.user, authKind: "agent", keepaliveSecs: Int(host.keepaliveSecs),
                                        onDisconnect: host.onDisconnect.rawValue, order: order)
                context.insert(record)
                return record
            }()
            record.name = host.name
            record.host = host.host
            record.port = Int(host.port)
            record.user = host.user
            record.keepaliveSecs = Int(host.keepaliveSecs)
            record.onDisconnect = host.onDisconnect.rawValue
            record.order = order
            (record.authKind, record.keyPath, record.vaultItem, record.vaultKeyName) = switch host.auth {
            case .agent: ("agent", nil, nil, nil)
            case .key(let path): ("key", path, nil, nil)
            case .password: ("password", nil, nil, nil)
            case .vault(let item, let name): ("vault", nil, item, name)
            }
            var forwardsByID = Dictionary(record.forwards.map { ($0.forwardID, $0) }, uniquingKeysWith: { first, _ in first })
            for (index, forward) in host.forwards.enumerated() {
                let row = forwardsByID.removeValue(forKey: forward.id.stored) ?? {
                    let row = ForwardRecord(forwardID: forward.id.stored, name: forward.name, kind: forward.kind.rawValue,
                                            bind: forward.bind, target: forward.target, showLogs: forward.showLogs,
                                            enabled: forward.enabled, order: index)
                    context.insert(row)
                    row.host = record
                    return row
                }()
                row.name = forward.name
                row.kind = forward.kind.rawValue
                row.bind = forward.bind
                row.target = forward.target
                row.showLogs = forward.showLogs
                row.enabled = forward.enabled
                row.order = index
            }
            for gone in forwardsByID.values { context.delete(gone) }
        }
        for gone in hostsByID.values { context.delete(gone) }

        let existingSandboxes = (try? context.fetch(FetchDescriptor<SandboxRecord>())) ?? []
        var sandboxesByID = Dictionary(existingSandboxes.map { ($0.sandboxID, $0) }, uniquingKeysWith: { first, _ in first })
        for (order, sandbox) in profiles.sandboxes.enumerated() {
            let engine = try Self.encode(sandbox.engine)
            if let record = sandboxesByID.removeValue(forKey: sandbox.id.stored) {
                record.name = sandbox.name
                record.order = order
                if record.engine != engine { record.engine = engine }
            } else {
                context.insert(SandboxRecord(sandboxID: sandbox.id.stored, name: sandbox.name, order: order, engine: engine))
            }
        }
        for gone in sandboxesByID.values where !unreadableSandboxes.contains(gone.sandboxID) { context.delete(gone) }

        let state = state()
        state.projectSandbox = try profiles.projectSandbox.map(Self.encode)
        state.vaultServer = profiles.vault?.server
        state.vaultEmail = profiles.vault?.email
        state.vaultDeviceID = profiles.vault?.deviceID
        state.vaultLockMinutes = Int(profiles.vault?.lockMinutes ?? 60)
        state.nextProfileID = profiles.nextFreeID.stored
        try save()
    }

    private static func auth(_ record: HostRecord) -> SSHAuth {
        switch record.authKind {
        case "key": .key(path: record.keyPath ?? "")
        case "password": .password
        case "vault": .vault(item: record.vaultItem ?? "", name: record.vaultKeyName ?? "")
        default: .agent
        }
    }

    // MARK: - History

    /// Record a command.
    public func append(_ entry: HistoryEntry) throws {
        guard History.isWorthKeeping(entry), !entry.imported else { return }
        context.insert(HistoryRecord(
            command: entry.command, cwd: entry.cwd, exitCode: entry.exitCode,
            startedAt: Date(timeIntervalSince1970: TimeInterval(entry.startedAt ?? 0)),
            durationMS: entry.durationMS.map { Int64(clamping: $0) }, sandboxed: entry.sandboxed))
        try save()
    }

    /// The recorded history, oldest first, after dropping what is past `historyLimit`. Reads with
    /// a context of its own, so it can run off the main thread.
    public nonisolated static func loadHistory(from container: ModelContainer, limit: Int = historyLimit) -> [HistoryEntry] {
        let context = ModelContext(container)
        let count = (try? context.fetchCount(FetchDescriptor<HistoryRecord>())) ?? 0
        if count > limit {
            var oldest = FetchDescriptor<HistoryRecord>(sortBy: [SortDescriptor(\.startedAt)])
            oldest.fetchLimit = count - limit
            for record in (try? context.fetch(oldest)) ?? [] { context.delete(record) }
            try? context.save()
        }
        let records = (try? context.fetch(FetchDescriptor<HistoryRecord>(sortBy: [SortDescriptor(\.startedAt)]))) ?? []
        return records.map { record in
            HistoryEntry(command: record.command, cwd: record.cwd, exitCode: record.exitCode,
                         startedAt: UInt64(max(0, record.startedAt.timeIntervalSince1970)),
                         durationMS: record.durationMS.map { UInt64(max(0, $0)) }, sandboxed: record.sandboxed)
        }
    }

    // MARK: - Coding

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try PropertyListDecoder().decode(type, from: data)
    }
}

// MARK: - Bringing in v1's files

extension Persistence {
    /// What the first start found in v1's JSON files (`~/.config/bridge`).
    public struct Imported {
        public var settings: Settings?
        public var projects: Projects?
        public var profiles: Profiles?
        public var history: [HistoryEntry] = []
    }

    /// Read v1's JSON files into the store, the first time v2 starts. A file that exists but can't
    /// be read is copied aside (`*.unreadable-<date>`) and reported; it never turns into an empty
    /// list. Terminals keep running when their item is left, as new ones do. The files stay where
    /// they are (v1 still reads them), readable only by their owner.
    public func importJSONIfNeeded(from folder: URL = Settings.configDirectory) -> Imported? {
        let state = state()
        guard !state.importedJSON else { return nil }
        var imported = Imported()
        let fm = FileManager.default

        func read<T>(_ name: String, _ what: String, _ decode: (Data) throws -> T) -> T? {
            let url = folder.appendingPathComponent(name)
            guard let data = fm.contents(atPath: url.path) else { return nil }
            chmod(url.path, 0o600)
            do {
                return try decode(data)
            } catch {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let copy = url.appendingPathExtension("unreadable-\(stamp)")
                try? fm.copyItem(at: url, to: copy)
                problems.append("\(what) in \(Paths.tilde(url.path)) could not be read. A copy is at \(Paths.tilde(copy.path)).")
                return nil
            }
        }

        imported.settings = read("settings.json", "Your settings", Settings.decodeV1)
        imported.projects = read("projects.json", "Your projects", Projects.decodeV1)
        imported.profiles = read("profiles.json", "Your SSH hosts and sandboxes", Profiles.decodeV1)
        if let text = read("history.jsonl", "Your command history", { String(decoding: $0, as: UTF8.self) }) {
            imported.history = History.readV1(text).filter { !$0.imported }
        }
        imported.projects?.keepAllAlive()

        do {
            if let settings = imported.settings { try save(settings) }
            if let projects = imported.projects { try save(projects) }
            if let profiles = imported.profiles { try save(profiles) }
            for entry in imported.history.suffix(Self.historyLimit) {
                context.insert(HistoryRecord(
                    command: entry.command, cwd: entry.cwd, exitCode: entry.exitCode,
                    startedAt: Date(timeIntervalSince1970: TimeInterval(entry.startedAt ?? 0)),
                    durationMS: entry.durationMS.map { Int64(clamping: $0) }, sandboxed: entry.sandboxed))
            }
            state.importedJSON = true
            try save()
        } catch {
            problems.append("Your v1 settings and projects could not be stored: \(error.localizedDescription)")
            return nil
        }
        chmod(folder.path, 0o700)
        return imported
    }
}
