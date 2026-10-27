import BridgeCore
import Foundation
import SwiftData

// The app's records in SwiftData. Each project, terminal or view, SSH host, port forward,
// sandbox profile and command run is a row of its own; the few values that are trees or
// variants (a view's split layout, a sandbox's rules, the settings) are stored encoded in their
// row. Ids are the app's own `ID`s (UInt64), stored as their bit pattern in an `Int64`.

/// The version of the records, for migrations.
enum BridgeSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ProjectRecord.self, ItemRecord.self, HostRecord.self, ForwardRecord.self, SandboxRecord.self,
         AppStateRecord.self, HistoryRecord.self]
    }
}

@Model final class ProjectRecord {
    #Unique<ProjectRecord>([\.projectID])
    var projectID: Int64
    var name: String
    var dir: String
    var icon: String?
    var color: String?
    /// Its place in the Welcome window's list.
    var order: Int
    /// The Global window's project (the home folder's terminals).
    var isGlobal: Bool
    var activeItem: Int64?
    var lastOpened: Date?
    /// The window's frame (`NSStringFromRect`), to reopen it where it was.
    var windowFrame: String?
    @Relationship(deleteRule: .cascade, inverse: \ItemRecord.project) var items: [ItemRecord] = []

    init(projectID: Int64, name: String, dir: String, order: Int, isGlobal: Bool) {
        self.projectID = projectID
        self.name = name
        self.dir = dir
        self.order = order
        self.isGlobal = isGlobal
    }
}

/// A terminal or view of a project, in sidebar order.
@Model final class ItemRecord {
    var itemID: Int64
    var name: String
    var order: Int
    var focused: Int64?
    /// The split layout and each terminal's spec (`Layout`, as a property list).
    var layout: Data
    var project: ProjectRecord?

    init(itemID: Int64, name: String, order: Int, focused: Int64?, layout: Data) {
        self.itemID = itemID
        self.name = name
        self.order = order
        self.focused = focused
        self.layout = layout
    }
}

@Model final class HostRecord {
    #Unique<HostRecord>([\.hostID])
    var hostID: Int64
    var name: String
    var host: String
    var port: Int
    var user: String
    /// agent, key, password or vault.
    var authKind: String
    var keyPath: String?
    var vaultItem: String?
    var vaultKeyName: String?
    var keepaliveSecs: Int
    var onDisconnect: String
    var order: Int
    @Relationship(deleteRule: .cascade, inverse: \ForwardRecord.host) var forwards: [ForwardRecord] = []

    init(hostID: Int64, name: String, host: String, port: Int, user: String, authKind: String,
         keepaliveSecs: Int, onDisconnect: String, order: Int) {
        self.hostID = hostID
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.authKind = authKind
        self.keepaliveSecs = keepaliveSecs
        self.onDisconnect = onDisconnect
        self.order = order
    }
}

@Model final class ForwardRecord {
    var forwardID: Int64
    var name: String
    var kind: String
    var bind: String
    var target: String
    var showLogs: Bool
    var enabled: Bool
    var order: Int
    var host: HostRecord?

    init(forwardID: Int64, name: String, kind: String, bind: String, target: String, showLogs: Bool,
         enabled: Bool, order: Int) {
        self.forwardID = forwardID
        self.name = name
        self.kind = kind
        self.bind = bind
        self.target = target
        self.showLogs = showLogs
        self.enabled = enabled
        self.order = order
    }
}

@Model final class SandboxRecord {
    #Unique<SandboxRecord>([\.sandboxID])
    var sandboxID: Int64
    var name: String
    var order: Int
    /// The engine and its rules (`SandboxEngine`, as a property list).
    var engine: Data

    init(sandboxID: Int64, name: String, order: Int, engine: Data) {
        self.sandboxID = sandboxID
        self.name = name
        self.order = order
        self.engine = engine
    }
}

/// What there is one of: the settings, open windows, id counters, the Project sandbox and the
/// Vaultwarden account.
@Model final class AppStateRecord {
    /// `Settings`, as a property list.
    var settings: Data?
    var openProjects: [Int64] = []
    var globalOpen = false
    var sidebarOpen = true
    var nextProjectID: Int64 = 1
    var nextProfileID: Int64 = 1
    /// The edited Project sandbox (`SandboxEngine`), nil for the built-in rules.
    var projectSandbox: Data?
    var vaultServer: String?
    var vaultEmail: String?
    var vaultDeviceID: String?
    var vaultLockMinutes: Int = 60
    /// v1's JSON files were read in (once).
    var importedJSON = false

    init() {}
}

/// One command run in a terminal.
@Model final class HistoryRecord {
    #Index<HistoryRecord>([\.startedAt])
    var command: String
    var cwd: String?
    var exitCode: Int?
    var startedAt: Date
    var durationMS: Int64?
    /// Reported by a sandboxed terminal.
    var sandboxed: Bool

    init(command: String, cwd: String?, exitCode: Int?, startedAt: Date, durationMS: Int64?, sandboxed: Bool) {
        self.command = command
        self.cwd = cwd
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.durationMS = durationMS
        self.sandboxed = sandboxed
    }
}

extension ID {
    var stored: Int64 { Int64(bitPattern: self) }
    init(stored: Int64) { self = UInt64(bitPattern: stored) }
}
