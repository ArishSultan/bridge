import Foundation

/// Hosts from `~/.ssh/config`, to add as SSH hosts in one go. Only named hosts are read (not
/// patterns like `*` or `*.internal`), with the options Bridge has fields for; ssh still reads
/// the whole file when it connects, so anything else in it keeps working.
public enum SSHConfig {
    public struct Entry: Equatable, Sendable {
        public var alias: String
        public var hostName: String?
        public var user: String?
        public var port: UInt16?
        public var identityFile: String?
    }

    /// The named hosts in a config file's text, `Include`s not followed.
    public static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var current: [Int] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // `Key value`, `Key=value` or `Key = value`.
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))
            switch key {
            case "host":
                current = []
                for alias in value.split(whereSeparator: \.isWhitespace).map(String.init)
                where !alias.contains(where: { "*?!".contains($0) }) {
                    entries.append(Entry(alias: alias))
                    current.append(entries.count - 1)
                }
            case "match":
                current = []
            default:
                // ssh uses the first value it sees for each option.
                for index in current {
                    switch key {
                    case "hostname" where entries[index].hostName == nil: entries[index].hostName = value
                    case "user" where entries[index].user == nil: entries[index].user = value
                    case "port" where entries[index].port == nil: entries[index].port = UInt16(value)
                    case "identityfile" where entries[index].identityFile == nil: entries[index].identityFile = value
                    default: break
                    }
                }
            }
        }
        return entries
    }

    /// Hosts for the entries of `~/.ssh/config` that aren't SSH hosts yet. Each connects by its
    /// alias, so ssh applies the config's own options (ProxyJump and the rest).
    public static func importable(existing: [SSHHost], home: String = Paths.home) -> [SSHHost] {
        guard let text = try? String(contentsOfFile: home + "/.ssh/config", encoding: .utf8) else { return [] }
        let known = Set(existing.flatMap { [$0.host.lowercased(), $0.name.lowercased()] })
        return parse(text).filter { !known.contains($0.alias.lowercased()) }.map { entry in
            // Option-like aliases (`-o…`) are skipped by `hasSafeDestination` below.
            SSHHost(id: 0, name: entry.alias, host: entry.alias, auth: .agent)
        }.filter(\.hasSafeDestination)
    }
}
