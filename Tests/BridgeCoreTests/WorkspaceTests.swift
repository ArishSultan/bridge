import CoreGraphics
import Foundation
import Testing
@testable import BridgeCore

struct WorkspaceJSONTests {
    /// projects.json as v1 writes it.
    static let v1JSON = """
    {
      "projects": [
        {
          "id": 3,
          "name": "api",
          "dir": "~/code/api",
          "icon": "🚀",
          "views": [
            {
              "id": 4,
              "name": "",
              "layout": {
                "type": "split",
                "id": 7,
                "axis": "horizontal",
                "first": { "type": "pane", "id": 5, "terminal": { "name": "", "kind": { "type": "shell" }, "folder": ".", "isolation": { "type": "sandboxed", "profile": null }, "background": false } },
                "second": { "type": "pane", "id": 6, "terminal": { "name": "dev", "tag": "api", "kind": { "type": "task", "command": "npm run dev", "auto_start": true, "restart_on_exit": false }, "folder": "web", "isolation": { "type": "open" }, "background": true } }
              },
              "focused": 6
            },
            { "id": 8, "name": "old", "layout": null, "focused": null },
            { "id": 9, "layout": { "type": "pane", "id": 10, "terminal": {} } }
          ],
          "active": 4
        }
      ],
      "global": { "id": 1, "name": "Global", "dir": "~", "views": [], "active": null },
      "open": [3],
      "global_open": true,
      "sidebar_open": false,
      "next_id": 2
    }
    """

    @Test func decodesV1File() throws {
        var projects = try JSONDecoder().decode(Projects.self, from: Data(Self.v1JSON.utf8))
        projects.normalize()
        let project = try #require(projects.project(3))
        #expect(project.icon == "🚀")
        // The item without a layout is dropped.
        #expect(project.views.map(\.id) == [4, 9])
        let view = project.views[0]
        #expect(view.panes == [5, 6])
        #expect(view.focused == 6)
        let task = try #require(view.terminal(6))
        #expect(task.kind == .task(command: "npm run dev", autoStart: true, restartOnExit: false))
        #expect(task.tag == "api")
        #expect(task.isolation == .open)
        #expect(task.background)
        // An empty terminal object is a sandboxed shell in the project folder.
        #expect(project.views[1].terminal(10) == TerminalSpec())
        #expect(projects.isGlobal(1))
        #expect(projects.open == [3])
        #expect(projects.globalOpen)
        #expect(!projects.sidebarOpen)
        // next_id is raised past every id in use.
        let next = projects.nextID()
        #expect(next == 11)
    }

    @Test func roundTrips() throws {
        var projects = try JSONDecoder().decode(Projects.self, from: Data(Self.v1JSON.utf8))
        projects.normalize()
        let data = try JSONEncoder().encode(projects)
        var again = try JSONDecoder().decode(Projects.self, from: data)
        again.normalize()
        #expect(again == projects)
    }

    @Test func encodesV1Shape() throws {
        var projects = Projects()
        let id = projects.addProject(name: "x", dir: "~/x")
        var project = try #require(projects.project(id))
        project.views = [ProjectItem(id: 2, layout: .pane(id: 3, terminal: TerminalSpec(kind: .ssh(host: 9))), focused: 3)]
        projects.put(project)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(projects)) as? [String: Any])
        let first = try #require((object["projects"] as? [[String: Any]])?.first)
        #expect(first["icon"] == nil) // Left out when nil, as v1 does.
        let layout = try #require(((first["views"] as? [[String: Any]])?.first)?["layout"] as? [String: Any])
        #expect(layout["type"] as? String == "pane")
        let kind = try #require((layout["terminal"] as? [String: Any])?["kind"] as? [String: Any])
        #expect(kind["type"] as? String == "ssh")
        #expect(kind["host"] as? Int == 9)
        #expect(object["sidebar_open"] as? Bool == true)
    }

    /// The real file in ~/.config/bridge, when there is one, survives a round trip.
    @Test func realFileRoundTrips() throws {
        let url = Projects.fileURL
        guard let data = try? Data(contentsOf: url) else { return }
        let projects = try JSONDecoder().decode(Projects.self, from: data)
        let again = try JSONDecoder().decode(Projects.self, from: JSONEncoder().encode(projects))
        #expect(again == projects)
    }
}

struct LayoutTests {
    let shell = TerminalSpec()

    /// 1 | 2, with 2 split into 2 / 3.
    private func threePanes() -> Layout {
        var layout = Layout.pane(id: 1, terminal: shell)
        layout.split(1, axis: .horizontal, newPane: 2, splitID: 10, terminal: shell)
        layout.split(2, axis: .vertical, newPane: 3, splitID: 11, terminal: shell)
        return layout
    }

    @Test func splitAndFrames() {
        let frames = threePanes().frames()
        #expect(frames[1] == CGRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(frames[2] == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        #expect(frames[3] == CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }

    @Test func removeCollapses() {
        let layout = threePanes().removing(2)
        #expect(layout?.panes == [1, 3])
        #expect(layout?.frames()[3] == CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        #expect(Layout.pane(id: 1, terminal: shell).removing(1) == nil)
    }

    @Test func moveToSide() {
        var layout = threePanes()
        // Move 3 to the left of 1.
        let result1 = layout.move(3, to: 1, side: .left, splitID: 12)
        #expect(result1)
        #expect(layout.panes == [3, 1, 2])
        #expect(layout.frames()[2] == CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        let result2 = layout.move(1, to: 1, side: .right, splitID: 13)
        #expect(!result2)
    }

    @Test func swapKeepsTerminals() {
        var layout = threePanes()
        let task = TerminalSpec(name: "t", kind: .task(command: "x", autoStart: false, restartOnExit: false))
        layout.setTerminal(3, task)
        let result3 = layout.swap(1, 3)
        #expect(result3)
        #expect(layout.panes == [3, 2, 1])
        #expect(layout.terminal(3) == task)
    }

    @Test func viewAddSplitsFocused() {
        var view = ProjectItem(id: 1, layout: .pane(id: 2, terminal: shell), focused: 2)
        view.add(pane: 3, splitID: 4, axis: .vertical, nextTo: nil, terminal: shell)
        #expect(view.panes == [2, 3])
        #expect(view.focused == 3)
        // An unknown target splits the first pane.
        view.add(pane: 5, splitID: 6, axis: .horizontal, nextTo: 99, terminal: shell)
        #expect(view.panes == [2, 5, 3])
        let result4 = view.remove(5)
        #expect(result4)
        #expect(view.focused == 2)
    }

    @Test func neighbors() {
        let layout = threePanes()
        #expect(layout.neighbor(of: 1, .right) == 2)
        #expect(layout.neighbor(of: 3, .left) == 1)
        #expect(layout.neighbor(of: 2, .down) == 3)
        #expect(layout.neighbor(of: 3, .up) == 2)
        #expect(layout.neighbor(of: 1, .left) == nil)
        #expect(layout.neighbor(of: 3, .next) == 1)
        #expect(layout.neighbor(of: 1, .previous) == 3)
    }

    @Test func resizeAndEqualize() {
        var layout = threePanes()
        layout.resize(3, toward: .left, points: 100, in: CGSize(width: 1000, height: 800))
        #expect(abs(layout.frames()[1]!.width - 0.4) < 1e-9)
        layout.resize(1, toward: .right, points: 10_000, in: CGSize(width: 1000, height: 800))
        #expect(abs(layout.frames()[1]!.width - 0.9) < 1e-9)

        var row = Layout.pane(id: 1, terminal: shell)
        row.split(1, axis: .horizontal, newPane: 2, splitID: 10, terminal: shell)
        row.split(2, axis: .horizontal, newPane: 3, splitID: 11, terminal: shell)
        let even = row.equalized().frames()
        for pane: ID in [1, 2, 3] {
            #expect(abs(even[pane]!.width - 1.0 / 3) < 1e-9)
        }
    }

    @Test func projectFolderStaysInside() {
        let project = Project(id: 1, name: "p", dir: "/tmp/p")
        #expect(project.folder("web/src").path == "/tmp/p/web/src")
        #expect(project.folder("../etc").path == "/tmp/p")
        #expect(project.folder("/etc").path == "/tmp/p")
        #expect(project.folder(".").path == "/tmp/p")
    }

    @Test func gitParsing() {
        #expect(Git.branch(fromHead: "ref: refs/heads/feat/x\n") == "feat/x")
        #expect(Git.branch(fromHead: "0123456789abcdef") == "0123456")
        let worktrees = Git.parseWorktrees("worktree /a\nHEAD 1\nbranch refs/heads/main\n\nworktree /b\nHEAD 2\ndetached\n")
        #expect(worktrees == [.init(path: "/a", branch: "main"), .init(path: "/b", branch: nil)])
    }
}
