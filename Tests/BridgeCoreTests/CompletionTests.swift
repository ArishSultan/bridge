import Foundation
import Testing
@testable import BridgeCore

struct CompletionTests {
    private func fixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("completion-\(UUID())")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("src/app"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("My Docs"), withIntermediateDirectories: true)
        try "".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try #"{"scripts":{"dev":"vite","test":"vitest"}}"#.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "build:\n\tcc\ntest: build\n\t./t\n.PHONY: x\nVAR := 1\n".write(to: dir.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: dir.appendingPathComponent(".git/refs/heads/feat"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent(".git/refs/heads/main"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent(".git/refs/heads/feat/login"), atomically: true, encoding: .utf8)
        try "[remote \"origin\"]\n\turl = x\n".write(to: dir.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        return dir
    }

    private func complete(_ line: String, in dir: URL, history: [String] = [], executables: [String] = []) -> Completion.Result {
        Completion.complete(.init(line: line, cwd: dir, executables: executables,
                                  history: History(entries: history.map { HistoryEntry(command: $0) })))
    }

    @Test func splitsWordsWithQuotesAndSeparators() {
        #expect(Completion.splitWords("git commit -m \"a b\" ") == (["git", "commit", "-m", "a b"], ""))
        #expect(Completion.splitWords("ls | grep fo") == (["grep"], "fo"))
        #expect(Completion.splitWords("cd My\\ Do") == (["cd"], "My\\ Do"))
    }

    @Test func completesFromTheRightSource() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(complete("git sta", in: dir).candidates.prefix(2).map(\.display) == ["stash", "status"])
        #expect(Set(complete("git switch ", in: dir).candidates.map(\.display)) == ["main", "feat/login"])
        #expect(complete("git push ", in: dir).candidates.map(\.display) == ["origin"])
        #expect(Set(complete("pnpm run ", in: dir).candidates.map(\.display)) == ["dev", "test"])
        #expect(Set(complete("make ", in: dir).candidates.map(\.display)) == ["build", "test"])
        let cd = complete("cd ", in: dir).candidates
        #expect(Set(cd.map(\.display)) == ["src/", "My Docs/"])
        #expect(cd.first { $0.display == "My Docs/" }?.replacement == "My\\ Docs/")
        #expect(complete("cat src/a", in: dir).candidates.map(\.display) == ["src/app/"])
        #expect(complete("ls ./no", in: dir).candidates.map(\.display) == ["./notes.txt"])
    }

    @Test func ranksCommandsAndLearnsArguments() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let commands = complete("gi", in: dir, history: ["git status"], executables: ["gitk", "git"]).candidates
        #expect(commands.first?.display == "git")
        #expect(commands.first?.description == "used once")
        let flags = complete("ssh -", in: dir, history: ["ssh -A box", "ssh -A other", "ssh -v box"]).candidates
        #expect(flags.map(\.display) == ["-A", "-v"])
        #expect(complete("sudo gi", in: dir, executables: ["git"]).candidates.first?.display == "git")
    }

    @Test func historySuggestionsMustFitTheFolder() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Completion.valid("cd src", in: dir))
        #expect(!Completion.valid("cd nowhere", in: dir))
        #expect(Completion.valid("cat ./notes.txt && ls", in: dir))
        #expect(!Completion.valid("cat ./missing.txt", in: dir))
        #expect(Completion.valid("cd $SOMEWHERE", in: dir))
    }

    @Test func suggestsHistoryThenCompletion() throws {
        let dir = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = History(entries: [HistoryEntry(command: "cd nowhere"), HistoryEntry(command: "cd src")])
        #expect(Completion.suggestion(line: "cd ", cwd: dir, history: history, executables: []) == "src")
        #expect(Completion.suggestion(line: "git sta", cwd: dir, history: History(), executables: []) == "sh")
        #expect(Completion.suggestion(line: "", cwd: dir, history: history, executables: []) == "")
    }

    @Test func opensAfterSpaceForKnownLists() {
        #expect(Completion.opensAfterSpace("git "))
        #expect(Completion.opensAfterSpace("git switch "))
        #expect(Completion.opensAfterSpace("npm run "))
        #expect(!Completion.opensAfterSpace("echo "))
        #expect(!Completion.opensAfterSpace("git"))
    }
}
