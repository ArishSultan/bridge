import Foundation

/// Git branches and worktrees of a terminal's folder, for the branch menu. The current branch is
/// read from `.git/HEAD`; the rest asks the `git` command.
public enum Git {
    public struct Worktree: Equatable, Sendable {
        public let path: String
        /// nil when detached.
        public let branch: String?
    }

    /// The branch checked out in `dir` (a short commit id when detached), or nil outside a
    /// repository.
    public static func currentBranch(in dir: URL) -> String? {
        var current = dir.standardizedFileURL
        while true {
            let git = current.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
                var gitDir = git
                if !isDir.boolValue {
                    // A worktree's .git file: "gitdir: <path>".
                    guard let text = try? String(contentsOf: git, encoding: .utf8),
                          let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
                              .split(separator: " ", maxSplits: 1).last.map(String.init),
                          text.hasPrefix("gitdir: ")
                    else { return nil }
                    gitDir = target.hasPrefix("/") ? URL(fileURLWithPath: target) : current.appendingPathComponent(target)
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else {
                    return nil
                }
                return branch(fromHead: head)
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    static func branch(fromHead head: String) -> String {
        let head = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) }
        return String(head.prefix(7))
    }

    /// Local branches, the most recently committed first.
    public static func branches(in dir: URL) -> [String] {
        run(dir, ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads"])
            .map { $0.split(separator: "\n").map(String.init) } ?? []
    }

    /// The repository's worktrees, the main one first.
    public static func worktrees(in dir: URL) -> [Worktree] {
        run(dir, ["worktree", "list", "--porcelain"]).map(parseWorktrees) ?? []
    }

    static func parseWorktrees(_ output: String) -> [Worktree] {
        output.components(separatedBy: "\n\n").compactMap { block in
            var path: String?
            var branch: String?
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst("branch refs/heads/".count)) }
            }
            return path.map { Worktree(path: $0, branch: branch) }
        }
    }

    /// Check `branch` out in a new worktree next to the main one (`<repo>-<branch>`), returning
    /// its folder.
    public static func addWorktree(in dir: URL, branch: String) throws -> URL {
        guard let main = worktrees(in: dir).first else { throw GitError("not a git repository") }
        let mainURL = URL(fileURLWithPath: main.path)
        let target = mainURL.deletingLastPathComponent()
            .appendingPathComponent("\(mainURL.lastPathComponent)-\(branch.replacingOccurrences(of: "/", with: "-"))")
        let result = execute(dir, ["worktree", "add", target.path, branch])
        guard result.status == 0 else { throw GitError(result.error.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return target
    }

    public struct GitError: Error, LocalizedError {
        public let message: String
        init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    private static func run(_ dir: URL, _ args: [String]) -> String? {
        let result = execute(dir, args)
        return result.status == 0 ? result.output : nil
    }

    private static func execute(_ dir: URL, _ args: [String]) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", dir.path] + args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, "", error.localizedDescription) }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self), String(decoding: error, as: UTF8.self))
    }
}
