import Foundation

/// One command run in a terminal. Coded as a line of v1's `~/.config/bridge/history.jsonl`, which
/// is read once into the data store.
public struct HistoryEntry: Codable, Equatable, Sendable {
    public var command: String
    public var cwd: String?
    public var exitCode: Int?
    /// Unix seconds.
    public var startedAt: UInt64?
    public var durationMS: UInt64?
    /// Imported from the shell's own history file rather than recorded here.
    public var imported = false
    /// Recorded in a sandboxed terminal. What a sandboxed program reports can't be trusted (it
    /// can claim any command ran), so these are never suggested in open terminals.
    public var sandboxed = false

    public init(command: String, cwd: String? = nil, exitCode: Int? = nil, startedAt: UInt64? = nil,
                durationMS: UInt64? = nil, imported: Bool = false, sandboxed: Bool = false) {
        self.command = command
        self.cwd = cwd
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.durationMS = durationMS
        self.imported = imported
        self.sandboxed = sandboxed
    }

    private enum Keys: String, CodingKey {
        case command, cwd, exitCode = "exit_code", startedAt = "started_at", durationMS = "duration_ms", imported, sandboxed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        command = try c.decode(String.self, forKey: .command)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        startedAt = try c.decodeIfPresent(UInt64.self, forKey: .startedAt)
        durationMS = try c.decodeIfPresent(UInt64.self, forKey: .durationMS)
        imported = try c.decodeIfPresent(Bool.self, forKey: .imported) ?? false
        sandboxed = try c.decodeIfPresent(Bool.self, forKey: .sandboxed) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(command, forKey: .command)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(exitCode, forKey: .exitCode)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(durationMS, forKey: .durationMS)
        if imported { try c.encode(true, forKey: .imported) }
        if sandboxed { try c.encode(true, forKey: .sandboxed) }
    }
}

/// Every command run in Bridge's terminals, plus (optionally) the shell's own history. In memory;
/// the app stores what it records (`Persistence`).
public struct History: Sendable {
    /// Oldest first.
    public private(set) var entries: [HistoryEntry] = []

    /// v1's file, read once into the data store.
    public static var fileURL: URL { Settings.configDirectory.appendingPathComponent("history.jsonl") }

    public init(entries: [HistoryEntry] = []) {
        self.entries = entries
    }

    /// The lines of v1's `history.jsonl` that can be read.
    public static func readV1(_ text: String) -> [HistoryEntry] {
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0.utf8)) }
    }

    /// The recorded history (oldest first), preceded by the shell's own history files when asked.
    public static func load(importShellHistory: Bool, recorded: [HistoryEntry], home: URL = URL(fileURLWithPath: Paths.home)) -> History {
        var entries: [HistoryEntry] = []
        if importShellHistory {
            if let data = try? Data(contentsOf: home.appendingPathComponent(".zsh_history")) {
                entries += parseZshHistory(data)
            }
            if let text = try? String(contentsOf: home.appendingPathComponent(".bash_history"), encoding: .utf8) {
                entries += parseBashHistory(text)
            }
            entries.sort { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
        }
        return History(entries: entries + recorded)
    }

    /// Whether a command is worth keeping.
    public static func isWorthKeeping(_ entry: HistoryEntry) -> Bool {
        !entry.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Append a command.
    public mutating func record(_ entry: HistoryEntry) {
        guard Self.isWorthKeeping(entry) else { return }
        entries.append(entry)
    }

    /// Distinct commands, newest first, as indices into `entries`.
    public var recentUnique: [Int] {
        var seen = Set<String>()
        return entries.indices.reversed().filter { seen.insert(entries[$0].command).inserted }
    }

    /// The command to suggest for a typed prefix, the way fish picks one: the newest match run in
    /// `cwd`, else the newest from anywhere, skipping commands `valid` rejects (like a `cd` into a
    /// folder that doesn't exist here) and multi-line ones.
    public func suggest(_ prefix: String, cwd: String?, valid: (String) -> Bool = { _ in true }) -> String? {
        let maxChecked = 64
        guard !prefix.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var checked: [String: Bool] = [:]
        var anywhere: String?
        for entry in entries.reversed() {
            let command = entry.command
            guard command.count > prefix.count, command.hasPrefix(prefix), !command.contains("\n") else {
                continue
            }
            if checked[command] == nil && checked.count >= maxChecked { break }
            let ok = checked[command] ?? valid(command)
            checked[command] = ok
            guard ok else { continue }
            if cwd == nil || entry.cwd == cwd { return command }
            if anywhere == nil { anywhere = command }
        }
        return anywhere
    }

    public struct Hit: Sendable {
        public let index: Int
        public let positions: [Int]
    }

    /// Fuzzy search over distinct commands; an empty query lists them newest first.
    public func search(_ query: String, limit: Int) -> [Hit] {
        let query = query.trimmingCharacters(in: .whitespaces)
        var hits: [(score: Int, rank: Int, hit: Hit)] = []
        for (rank, index) in recentUnique.enumerated() {
            guard let found = Fuzzy.match(query, entries[index].command) else { continue }
            hits.append((found.score, rank, Hit(index: index, positions: found.positions)))
        }
        if !query.isEmpty {
            // Best score first; among equal scores the most recent wins.
            hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.rank < $1.rank }
        }
        return hits.prefix(limit).map(\.hit)
    }

    /// `~/.zsh_history`, plain or extended (`: <start>:<elapsed>;<command>`), with zsh's metafied
    /// bytes and backslash-continued lines.
    static func parseZshHistory(_ data: Data) -> [HistoryEntry] {
        var decoded: [UInt8] = []
        decoded.reserveCapacity(data.count)
        var iterator = data.makeIterator()
        while let byte = iterator.next() {
            if byte == 0x83, let next = iterator.next() {
                decoded.append(next ^ 0x20)
            } else {
                decoded.append(byte)
            }
        }
        let text = String(decoding: decoded, as: UTF8.self)

        var entries: [HistoryEntry] = []
        var current: HistoryEntry?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if current != nil {
                current!.command += "\n" + line
            } else {
                var entry = HistoryEntry(command: "", imported: true)
                if line.hasPrefix(": "), let semicolon = line.firstIndex(of: ";") {
                    let meta = line[line.index(line.startIndex, offsetBy: 2)..<semicolon]
                    let parts = meta.split(separator: ":", maxSplits: 1)
                    entry.startedAt = parts.first.flatMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
                    // A corrupt file can hold any number: don't overflow on it.
                    entry.durationMS = parts.dropFirst().first.flatMap { UInt64($0.trimmingCharacters(in: .whitespaces)) }
                        .flatMap { $0.multipliedReportingOverflow(by: 1000).overflow ? nil : $0 * 1000 }
                    entry.command = String(line[line.index(after: semicolon)...])
                } else {
                    entry.command = line
                }
                current = entry
            }
            if current!.command.hasSuffix("\\") {
                current!.command.removeLast()
            } else {
                if !current!.command.trimmingCharacters(in: .whitespaces).isEmpty { entries.append(current!) }
                current = nil
            }
        }
        return entries
    }

    /// `~/.bash_history`, with optional `#<unix time>` lines.
    static func parseBashHistory(_ text: String) -> [HistoryEntry] {
        var entries: [HistoryEntry] = []
        var time: UInt64?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("#"), let stamp = UInt64(line.dropFirst().trimmingCharacters(in: .whitespaces)) {
                time = stamp
                continue
            }
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            entries.append(HistoryEntry(command: String(line), startedAt: time, imported: true))
            time = nil
        }
        return entries
    }
}
