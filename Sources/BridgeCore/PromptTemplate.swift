import Foundation

/// Prompt patterns with `{token}` placeholders, translated into zsh and bash prompt escapes.
/// Same tokens and output as v1.
public enum PromptTemplate {
    public enum Token: Equatable, Sendable {
        case text(String)
        case user, host, dir, path, git, time, symbol, newline
        /// ANSI color 0–7, or 8 for gray.
        case color(Int)
        case bold, reset
    }

    static let symbol = "❯"

    public static func parse(_ pattern: String) -> [Token] {
        var tokens: [Token] = []
        var rest = Substring(pattern)
        while !rest.isEmpty {
            guard let open = rest.firstIndex(of: "{") else {
                tokens.append(.text(String(rest)))
                break
            }
            if open > rest.startIndex { tokens.append(.text(String(rest[..<open]))) }
            let after = rest[open...]
            guard let close = after.firstIndex(of: "}") else {
                tokens.append(.text(String(after)))
                break
            }
            let name = after[after.index(after: open)..<close]
            let token: Token = switch name {
            case "user": .user
            case "host": .host
            case "dir": .dir
            case "path": .path
            case "git": .git
            case "time": .time
            case "symbol": .symbol
            case "newline": .newline
            case "black": .color(0)
            case "red": .color(1)
            case "green": .color(2)
            case "yellow": .color(3)
            case "blue": .color(4)
            case "magenta": .color(5)
            case "cyan": .color(6)
            case "white": .color(7)
            case "gray", "grey": .color(8)
            case "bold": .bold
            case "reset": .reset
            default: .text(String(after[...close]))
            }
            tokens.append(token)
            rest = after[after.index(after: close)...]
        }
        return tokens
    }

    /// A zsh `PROMPT`, and whether it needs the git branch.
    public static func zsh(_ pattern: String) -> (prompt: String, git: Bool) {
        let tokens = parse(pattern)
        let git = tokens.contains(.git)
        var out = ""
        for token in tokens {
            switch token {
            case .text(let text):
                for ch in text {
                    switch ch {
                    case "%": out += "%%"
                    // With prompt_subst on, these would start expansions.
                    case "$", "`", "\\" where git: out += "\\\(ch)"
                    default: out.append(ch)
                    }
                }
            case .user: out += "%n"
            case .host: out += "%m"
            case .dir: out += "%1~"
            case .path: out += "%~"
            case .git: out += "${_bridge_git}"
            case .time: out += "%T"
            case .symbol: out += symbol
            case .newline: out += "\n"
            case .color(let index): out += "%F{\(index)}"
            case .bold: out += "%B"
            case .reset: out += "%f%b"
            }
        }
        return (out, git)
    }

    /// A bash `PS1`, and whether it needs the git branch.
    public static func bash(_ pattern: String) -> (prompt: String, git: Bool) {
        let tokens = parse(pattern)
        let git = tokens.contains(.git)
        var out = ""
        for token in tokens {
            switch token {
            case .text(let text):
                for ch in text {
                    if "\\$`".contains(ch) { out += "\\" }
                    out.append(ch)
                }
            case .user: out += "\\u"
            case .host: out += "\\h"
            case .dir: out += "\\W"
            case .path: out += "\\w"
            case .git: out += "${_bridge_git}"
            case .time: out += "\\A"
            case .symbol: out += symbol
            case .newline: out += "\\n"
            case .color(8): out += "\\[\\e[90m\\]"
            case .color(let index): out += "\\[\\e[3\(index)m\\]"
            case .bold: out += "\\[\\e[1m\\]"
            case .reset: out += "\\[\\e[0m\\]"
            }
        }
        return (out, git)
    }

    /// A rough preview of a pattern, for the settings page.
    public static func preview(_ pattern: String) -> String {
        parse(pattern).map { token -> String in
            switch token {
            case .text(let text): text
            case .user: NSUserName()
            case .host: "mac"
            case .dir: "api"
            case .path: "~/code/api"
            case .git: " main"
            case .time: "09:41"
            case .symbol: symbol
            case .newline: "\n"
            case .color, .bold, .reset: ""
            }
        }.joined()
    }
}
