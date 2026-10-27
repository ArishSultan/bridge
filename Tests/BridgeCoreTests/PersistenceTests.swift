import Foundation
import Testing
@testable import BridgeCore
@testable import BridgeSystem

@MainActor
struct PersistenceTests {
    private func sampleProjects() -> Projects {
        var projects = Projects()
        projects.globalID()
        let id = projects.addProject(name: "app", dir: "~/code/app")
        let pane = projects.nextID(), item = projects.nextID(), split = projects.nextID(), second = projects.nextID()
        var view = ProjectItem(id: item, layout: .pane(id: pane, terminal: TerminalSpec(name: "web")), focused: pane)
        view.add(pane: second, splitID: split, axis: .horizontal, nextTo: pane,
                 terminal: TerminalSpec(kind: .task(command: "npm run dev", autoStart: true, restartOnExit: false)))
        var project = projects.project(id)!
        project.views = [view]
        project.active = item
        project.lastOpened = Date(timeIntervalSince1970: 1_700_000_000)
        project.windowFrame = "{{10, 20}, {800, 600}}"
        projects.put(project)
        projects.open = [id]
        projects.sidebarOpen = false
        return projects
    }

    @Test func projectsRoundTrip() throws {
        let store = try Persistence(url: nil)
        let projects = sampleProjects()
        try store.save(projects)
        let loaded = store.loadProjects()
        #expect(loaded.projects == projects.projects)
        #expect(loaded.global == projects.global)
        #expect(loaded.open == projects.open)
        #expect(loaded.sidebarOpen == false)
        #expect(loaded.nextFreeID == projects.nextFreeID)

        // Removing an item and a project removes their rows.
        var changed = loaded
        changed.removeProject(changed.projects[0].id)
        try store.save(changed)
        #expect(store.loadProjects().projects.isEmpty)
    }

    @Test func profilesRoundTrip() throws {
        let store = try Persistence(url: nil)
        var profiles = Profiles()
        let host = profiles.upsert(SSHHost(id: 0, name: "db", host: "db.example.com", port: 2222, user: "me",
                                           auth: .vault(item: "i", name: "key"), onDisconnect: .reconnect))
        profiles.upsert(Forward(id: 0, kind: .dynamic, bind: "1080", enabled: true), host: host)
        profiles.upsert(SandboxProfile(id: 0, name: "Agents", engine: .forAgents(.seatbeltDefaults)))
        profiles.vault = VaultAccount(server: "https://vault.example.com", email: "me@example.com", deviceID: "d", lockMinutes: 5)
        try store.save(profiles)
        let loaded = store.loadProfiles()
        #expect(loaded == profiles)
        #expect(loaded.nextFreeID == profiles.nextFreeID)
    }

    @Test func settingsAndHistory() throws {
        let store = try Persistence(url: nil)
        #expect(store.loadSettings() == nil)
        var settings = Settings()
        settings.fontSize = 17
        try store.save(settings)
        #expect(store.loadSettings() == settings)

        try store.append(HistoryEntry(command: "ls", cwd: "/tmp", exitCode: 0, startedAt: 10, durationMS: 5))
        try store.append(HistoryEntry(command: "  "))
        try store.append(HistoryEntry(command: "make", startedAt: 20, sandboxed: true))
        let history = Persistence.loadHistory(from: store.container)
        #expect(history.map(\.command) == ["ls", "make"])
        #expect(history.last?.sandboxed == true)
        // Past the limit, the oldest go.
        #expect(Persistence.loadHistory(from: store.container, limit: 1).map(\.command) == ["make"])
    }

    @Test func importsV1FilesOnceAndKeepsUnreadableOnes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-import-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONEncoder().encode(sampleProjects()).write(to: folder.appendingPathComponent("projects.json"))
        try Data("{ broken".utf8).write(to: folder.appendingPathComponent("profiles.json"))
        try Data(#"{"command":"git status","started_at":3}"#.utf8).write(to: folder.appendingPathComponent("history.jsonl"))

        let store = try Persistence(url: nil)
        let imported = try #require(store.importJSONIfNeeded(from: folder))
        #expect(imported.projects?.projects.count == 1)
        // Imported terminals keep running when their item is left.
        #expect(imported.projects?.projects[0].views[0].panes.allSatisfy { imported.projects?.projects[0].terminal($0)?.background == true } == true)
        #expect(store.loadProjects().projects.count == 1)
        #expect(Persistence.loadHistory(from: store.container).map(\.command) == ["git status"])
        // The broken file is reported and copied aside, not taken for "no hosts".
        #expect(store.problems.count == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains { $0.hasPrefix("profiles.json.unreadable-") })
        // Only once.
        #expect(store.importJSONIfNeeded(from: folder) == nil)
    }
}
