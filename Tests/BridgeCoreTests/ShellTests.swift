import Foundation
import Testing
@testable import BridgeCore

struct FuzzyTests {
    @Test func scoresLikeV1() {
        #expect(Fuzzy.match("", "anything") == Fuzzy.Match(score: 0, positions: []))
        #expect(Fuzzy.match("xyz", "git status") == nil)
        let match = Fuzzy.match("gs", "git status")!
        #expect(match.positions == [0, 4])
        // g: 10 + 20 (start) - 0 (offset); s: 10 + 20 (after space) - 3 (gap); - len/8.
        #expect(match.score == 30 + 27 - 1)
        // A run from the start gets the consecutive and prefix bonuses (the query is lowercased).
        #expect(Fuzzy.match("GIT", "git")!.score == 30 + 25 + 25 + 25)
    }
}

struct HistoryTests {
    private func history(_ commands: [(String, String?)]) -> History {
        History(entries: commands.map { HistoryEntry(command: $0.0, cwd: $0.1) })
    }

    @Test func suggestsNewestInFolderFirst() {
        let history = history([("git status", "/a"), ("git stash", "/b"), ("git switch main", "/a")])
        #expect(history.suggest("git s", cwd: "/a") == "git switch main")
        #expect(history.suggest("git st", cwd: "/a") == "git status")
        #expect(history.suggest("git st", cwd: "/c") == "git stash")
        #expect(history.suggest("git st", cwd: "/a", valid: { $0 != "git status" }) == "git stash")
        #expect(history.suggest("", cwd: nil) == nil)
        #expect(history.suggest("git status", cwd: nil) == nil)
    }

    @Test func searchesDistinctNewestFirst() {
        let history = history([("ls", nil), ("make test", nil), ("ls", nil), ("make build", nil)])
        #expect(history.search("", limit: 10).map { history.entries[$0.index].command } == ["make build", "ls", "make test"])
        #expect(history.search("mt", limit: 10).map { history.entries[$0.index].command } == ["make test"])
    }

    @Test func parsesZshHistory() {
        var data = Data(": 1700000000:5;git commit -m 'a\\\nb'\nls -la\n: 1700000100:0;echo ".utf8)
        // Metafied byte: 0x83 then (byte ^ 0x20).
        data.append(contentsOf: [0x83, 0xA3 ^ 0x20, 0xC2 ^ 0x00])
        let entries = History.parseZshHistory(data)
        #expect(entries.count == 3)
        #expect(entries[0].command == "git commit -m 'a\nb'")
        #expect(entries[0].startedAt == 1_700_000_000)
        #expect(entries[0].durationMS == 5000)
        #expect(entries[1].command == "ls -la")
        #expect(entries.allSatisfy { $0.imported })
    }

    @Test func parsesBashHistory() {
        let entries = History.parseBashHistory("#1700000000\nmake\n\nls\n")
        #expect(entries.map(\.command) == ["make", "ls"])
        #expect(entries[0].startedAt == 1_700_000_000)
        #expect(entries[1].startedAt == nil)
    }

    @Test func entryJSONMatchesV1() throws {
        let line = #"{"command":"ls","cwd":"/tmp","exit_code":0,"started_at":5,"duration_ms":12}"#
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: Data(line.utf8))
        #expect(entry == HistoryEntry(command: "ls", cwd: "/tmp", exitCode: 0, startedAt: 5, durationMS: 12))
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        #expect(object["imported"] == nil)
        #expect(object["exit_code"] as? Int == 0)
    }

    @Test func recordsAndReadsV1Lines() throws {
        var history = History.load(importShellHistory: false, recorded: [HistoryEntry(command: "zero")])
        history.record(HistoryEntry(command: "one"))
        history.record(HistoryEntry(command: "  "))
        history.record(HistoryEntry(command: "two", exitCode: 1))
        #expect(history.entries.map(\.command) == ["zero", "one", "two"])
        let lines = #"{"command":"a"}"# + "\nnot json\n" + #"{"command":"b","sandboxed":true}"#
        #expect(History.readV1(lines).map(\.command) == ["a", "b"])
        #expect(History.readV1(lines).last?.sandboxed == true)
    }

    @Test func corruptZshHistoryDoesNotCrash() {
        let data = Data(": 1700000000:99999999999999999999;ls\n: 1700000001:18446744073709552;pwd\n".utf8)
        let entries = History.parseZshHistory(data)
        #expect(entries.map(\.command) == ["ls", "pwd"])
        #expect(entries.last?.durationMS == nil)
    }
}

struct PromptTests {
    @Test func parsesTokensAndKeepsUnknownBraces() {
        #expect(PromptTemplate.parse("{blue}{dir}{reset} {nope} x") == [
            .color(4), .dir, .reset, .text(" "), .text("{nope}"), .text(" x"),
        ])
        #expect(PromptTemplate.parse("a { b") == [.text("a "), .text("{ b")])
    }

    @Test func translatesToZsh() {
        #expect(PromptTemplate.zsh("{blue}{dir}{reset} 100% ") == ("%F{4}%1~%f%b 100%% ", false))
        let (prompt, git) = PromptTemplate.zsh("{path}{git} $ ")
        #expect(git)
        #expect(prompt == "%~${_bridge_git} \\$ ")
    }

    @Test func translatesToBash() {
        #expect(PromptTemplate.bash("{user}@{host} {gray}{dir}{reset}{git} $")
            == ("\\u@\\h \\[\\e[90m\\]\\W\\[\\e[0m\\]${_bridge_git} \\$", true))
    }

    @Test func launchesZshThroughZdotdir() {
        let env = ShellIntegration.launch(shell: "", loginShell: "/bin/zsh", socket: "/s", token: "t", helper: "/h")
        #expect(env.command == nil)
        #expect(env.variables["ZDOTDIR"]?.hasSuffix("/shell-v2/zsh") == true)
        #expect(env.variables["BRIDGE_PANE"] == "t")
        #expect(env.variables["BRIDGE_SOCKET"] == "/s")
    }

    @Test func launchesBashWithRcfile() {
        let env = ShellIntegration.launch(shell: "", loginShell: "/bin/bash", socket: "/s", token: "t", helper: "/h")
        #expect(env.command?.hasPrefix("/usr/bin/env /bin/bash --rcfile ") == true)
        #expect(env.variables["BRIDGE_LOGIN"] == "1")
        // bash with arguments of the user's own is left alone.
        let custom = ShellIntegration.launch(shell: "bash --norc", loginShell: "/bin/zsh", socket: "/s", token: "t", helper: nil)
        #expect(custom.command == "bash --norc")
    }

    @Test func promptFilesFollowStyle() {
        var settings = Settings()
        settings.promptStyle = .shellDefault
        #expect(ShellIntegration.zshPromptFile(settings, starshipConfig: "/x").contains("_bridge_user_prompt"))
        settings.promptStyle = .minimal
        let zsh = ShellIntegration.zshPromptFile(settings, starshipConfig: "/x")
        #expect(zsh.contains("PROMPT='%F{6}❯%f%b '"))
        #expect(zsh.contains("PROMPT_EOL_MARK=''"))
        settings.promptStyle = .starship
        #expect(ShellIntegration.bashPromptFile(settings, starshipConfig: "/x").contains("starship init bash"))
    }
}
