/// Coding agents Bridge starts in a sandbox of their own with one command.
public enum Agent: String, CaseIterable, Sendable, Identifiable {
    case claude, codex, gemini

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini"
        }
    }

    /// The program that starts it.
    public var command: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .gemini: "gemini"
        }
    }
}
