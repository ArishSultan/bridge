import Foundation

/// Something a sandbox refused, as the kernel logs it: `Sandbox: cat(1989) deny(1)
/// file-read-data /Users/me/.ssh/config`, followed by the session's marker (see
/// `Sandbox.Context.marker`).
public struct SandboxDenial: Equatable, Sendable, Identifiable {
    public var pane: BridgeCore.ID
    public var process: String
    /// The sandbox operation: `file-read-data`, `file-write-create`, `network-outbound`,
    /// `mach-lookup`…
    public var operation: String
    /// A path, a socket, a service name or an address.
    public var target: String
    /// How many times in a row.
    public var count = 1

    public var id: String { "\(pane) \(operation) \(target)" }

    public static func marker(_ pane: BridgeCore.ID) -> String { "bridge-pane-\(pane)" }

    /// The `log stream` predicate for every Bridge sandbox's denials.
    public static let logPredicate = #"sender == "Sandbox" AND eventMessage CONTAINS "bridge-pane-""#

    public enum Kind: Sendable {
        case read, write, network, service, run, other
    }

    public var kind: Kind {
        if operation.hasPrefix("file-read") { return .read }
        if operation.hasPrefix("file-write") { return .write }
        if operation.hasPrefix("network") { return .network }
        if operation.hasPrefix("mach") || operation.hasPrefix("appleevent") { return .service }
        if operation.hasPrefix("process-exec") { return .run }
        return .other
    }

    /// Whether the target is a file or folder (that a profile could allow).
    public var isPath: Bool { (kind == .read || kind == .write) && target.hasPrefix("/") }

    /// One line, for people: "cat couldn't read ~/.ssh/config".
    public var summary: String {
        let target = Paths.tilde(self.target)
        switch kind {
        case .read: return "\(process) couldn't read \(target)"
        case .write: return "\(process) couldn't change \(target)"
        case .network: return "\(process) couldn't connect to \(target)"
        case .service: return "\(process) couldn't reach \(target)"
        case .run: return "\(process) isn't allowed to run"
        case .other: return "\(process): \(operation) \(target)"
        }
    }

    /// The denial in a log event's message, if it came from a Bridge sandbox.
    public static func parse(_ message: String) -> SandboxDenial? {
        var count = 1
        var text = message
        // "3 duplicate reports for Sandbox: …"
        if let range = text.range(of: " duplicate reports for "), let repeats = Int(text[..<range.lowerBound]) {
            count = repeats + 1
            text = String(text[range.upperBound...])
        }
        guard text.hasPrefix("Sandbox: "),
              let markerRange = text.range(of: "bridge-pane-", options: .backwards),
              let pane = BridgeCore.ID(text[markerRange.upperBound...].prefix { $0.isNumber })
        else { return nil }
        let line = text[text.index(text.startIndex, offsetBy: 9)..<markerRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // "<process>(<pid>) deny(<n>) <operation> <target>"
        guard let deny = line.range(of: ") deny(") else { return nil }
        let head = line[..<deny.lowerBound]
        guard let open = head.lastIndex(of: "(") else { return nil }
        let process = String(head[..<open])
        let rest = line[deny.upperBound...].drop { $0 != ")" }.dropFirst().trimmingCharacters(in: .whitespaces)
        let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
        guard let operation = parts.first else { return nil }
        return SandboxDenial(pane: pane, process: process, operation: operation,
                             target: parts.count > 1 ? parts[1] : "", count: count)
    }
}
