import Foundation

/// What a terminal's monitor shows: its processes, the computer an SSH session is connected to,
/// or a coding agent's usage. The readers here only parse; sampling is the app's.
public enum Stats {}

// MARK: - The computer an SSH session is on

extension Stats {
    /// One reading from `remoteScript`: totals since boot (CPU time, network bytes) that become
    /// rates between two readings, and current values.
    public struct Remote: Equatable, Sendable {
        public var host = ""
        public var os = ""
        public var cpus = 1
        /// CPU time in ticks: all of it, and idle.
        public var cpuTotal: UInt64?
        public var cpuIdle: UInt64?
        /// Kibibytes.
        public var memoryTotal: UInt64?
        public var memoryAvailable: UInt64?
        public var swapTotal: UInt64?
        public var swapFree: UInt64?
        public var load: [Double] = []
        public var uptime: TimeInterval?
        /// Kibibytes used and in all, of the root file system.
        public var diskUsed: UInt64?
        public var diskTotal: UInt64?
        /// Bytes received and sent, all interfaces but loopback.
        public var networkIn: UInt64?
        public var networkOut: UInt64?
        public var processes: [RemoteProcess] = []

        public init() {}

        /// Busy CPU since `earlier`, from 0 to 1.
        public func cpuUse(since earlier: Remote) -> Double? {
            guard let total = cpuTotal, let idle = cpuIdle, let before = earlier.cpuTotal, let beforeIdle = earlier.cpuIdle,
                  total > before else { return nil }
            let busy = Double(total - before) - Double(idle >= beforeIdle ? idle - beforeIdle : 0)
            return min(max(busy / Double(total - before), 0), 1)
        }

        public var memoryUse: Double? {
            guard let total = memoryTotal, let available = memoryAvailable, total > 0 else { return nil }
            return 1 - Double(min(available, total)) / Double(total)
        }
    }

    public struct RemoteProcess: Equatable, Sendable, Identifiable {
        public var cpu: Double
        public var memory: Double
        public var name: String
        public var id: String { name + "\(cpu)\(memory)" }
    }

    /// The readings in `remoteScript`'s output so far, and what's left of an unfinished one.
    public static func parseRemote(_ text: String) -> (readings: [Remote], rest: String) {
        var readings: [Remote] = []
        var current: Remote?
        var rest = ""
        let lines = text.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if index == lines.count - 1 {
                rest = raw
                break
            }
            switch line {
            case "BRIDGE-BEGIN":
                current = Remote()
            case "BRIDGE-END":
                if let current { readings.append(current) }
                current = nil
            default:
                guard current != nil, let equals = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<equals])
                let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                let numbers = value.split(separator: " ").compactMap { UInt64($0) }
                switch key {
                case "host": current?.host = value
                case "os": current?.os = value
                case "ncpu": current?.cpus = max(Int(value) ?? 1, 1)
                case "cpu" where numbers.count == 2:
                    current?.cpuTotal = numbers[0]
                    current?.cpuIdle = numbers[1]
                case "memtotal": current?.memoryTotal = numbers.first
                case "memavailable": current?.memoryAvailable = numbers.first
                case "swaptotal": current?.swapTotal = numbers.first
                case "swapfree": current?.swapFree = numbers.first
                case "load": current?.load = value.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
                case "uptime": current?.uptime = TimeInterval(value)
                case "disk" where numbers.count == 2:
                    current?.diskUsed = numbers[0]
                    current?.diskTotal = numbers[1]
                case "net" where numbers.count == 2:
                    current?.networkIn = numbers[0]
                    current?.networkOut = numbers[1]
                case "proc":
                    let parts = value.split(separator: " ", maxSplits: 2).map(String.init)
                    if parts.count == 3, let cpu = Double(parts[0]), let memory = Double(parts[1]) {
                        let name = (parts[2] as NSString).lastPathComponent
                        current?.processes.append(RemoteProcess(cpu: cpu, memory: memory, name: name))
                    }
                default: break
                }
            }
        }
        return (readings, rest)
    }

    /// A POSIX shell loop that prints a reading every two seconds: from /proc on Linux, and what
    /// `sysctl` and `vm_stat` tell on macOS and the BSDs. Run on the server with `sh -c`.
    public static let remoteScript = #"""
    LC_ALL=C; export LC_ALL
    host=$(hostname 2>/dev/null)
    ncpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
    while :; do
      echo BRIDGE-BEGIN
      echo "host=$host"
      echo "os=$(uname -sr 2>/dev/null)"
      echo "ncpu=$ncpu"
      if [ -r /proc/stat ]; then
        read -r _ u n s i w q sq st _ < /proc/stat
        echo "cpu=$((u+n+s+i+w+q+sq+${st:-0})) $((i+w))"
        awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/ { sub(":", "", $1); print tolower($1) "=" $2 }' /proc/meminfo
        read -r l1 l5 l15 _ < /proc/loadavg; echo "load=$l1 $l5 $l15"
        read -r up _ < /proc/uptime; echo "uptime=${up%.*}"
        awk 'NR > 2 && $1 !~ /^lo:/ { sub(":", " "); split($0, f, " "); rx += f[2]; tx += f[10] } END { print "net=" rx+0 " " tx+0 }' /proc/net/dev
        ps -eo pcpu=,pmem=,comm= --sort=-pcpu 2>/dev/null | head -n 6 | awk '{ print "proc=" $1 " " $2 " " $3 }'
      else
        echo "load=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')"
        boot=$(sysctl -n kern.boottime 2>/dev/null | sed 's/^{ sec = \([0-9]*\).*/\1/')
        [ -n "$boot" ] && echo "uptime=$(( $(date +%s) - boot ))"
        total=$(sysctl -n hw.memsize 2>/dev/null)
        page=$(sysctl -n hw.pagesize 2>/dev/null)
        free=$(vm_stat 2>/dev/null | awk '/Pages (free|inactive|speculative)/ { gsub("\\.", "", $NF); n += $NF } END { print n+0 }')
        [ -n "$total" ] && [ -n "$page" ] && echo "memtotal=$((total / 1024))" && echo "memavailable=$((free * page / 1024))"
        ps -Ao pcpu=,pmem=,comm= -r 2>/dev/null | head -n 6 | awk '{ print "proc=" $1 " " $2 " " $3 }'
      fi
      df -Pk / 2>/dev/null | awk 'NR == 2 { print "disk=" $3 " " $2 }'
      echo BRIDGE-END
      sleep 2
    done
    """#
}

// MARK: - Coding agents

extension Stats {
    /// A coding agent's session, from its own log: what it has used and how much is left.
    public struct AgentUsage: Equatable, Sendable {
        public var model: String?
        public var inputTokens = 0
        public var outputTokens = 0
        public var cachedTokens = 0
        public var cacheWriteTokens = 0
        public var messages = 0
        /// Tokens in the last request (what the conversation fills of the context window), and the
        /// window's size.
        public var contextTokens: Int?
        public var contextWindow: Int?
        /// The plan's limits, used from 0 to 100, with when each resets.
        public var limits: [Limit] = []
        public var plan: String?
        public var updated: Date?

        public init() {}

        public var contextUse: Double? {
            guard let used = contextTokens, let window = contextWindow, window > 0 else { return nil }
            return min(Double(used) / Double(window), 1)
        }
    }

    public struct Limit: Equatable, Sendable, Identifiable {
        /// "5-hour", "Weekly", "Weekly (Opus)".
        public var name: String
        public var usedPercent: Double
        public var resets: Date?
        public var id: String { name }

        public init(name: String, usedPercent: Double, resets: Date?) {
            self.name = name
            self.usedPercent = usedPercent
            self.resets = resets
        }
    }

    /// Claude Code keeps a project's sessions in `~/.claude/projects/<folder>`, the folder's path
    /// with everything but letters and digits replaced by `-`.
    public static func claudeProjectFolder(for root: URL, home: String = Paths.home) -> URL {
        let name = String(root.standardizedFileURL.path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return URL(fileURLWithPath: home).appendingPathComponent(".claude/projects").appendingPathComponent(name)
    }

    /// Add the lines of a Claude Code session log to `usage`.
    public static func readClaude(_ lines: [Substring], into usage: inout AgentUsage) {
        for line in lines {
            guard line.contains("\"usage\""),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let tokens = message["usage"] as? [String: Any]
            else { continue }
            func count(_ key: String) -> Int { (tokens[key] as? NSNumber)?.intValue ?? 0 }
            let input = count("input_tokens"), read = count("cache_read_input_tokens"), write = count("cache_creation_input_tokens")
            usage.inputTokens += input
            usage.cachedTokens += read
            usage.cacheWriteTokens += write
            usage.outputTokens += count("output_tokens")
            usage.messages += 1
            usage.contextTokens = input + read + write
            if let model = message["model"] as? String, !model.hasPrefix("<") {
                usage.model = model
                usage.contextWindow = model.contains("[1m]") ? 1_000_000 : 200_000
            }
            if let stamp = object["timestamp"] as? String { usage.updated = ISO8601DateFormatter.fractional.date(from: stamp) }
        }
    }

    /// Claude's plan limits, from the usage endpoint Claude Code's `/usage` reads.
    public static func claudeLimits(_ object: [String: Any]) -> [Limit] {
        let names = [("five_hour", "5-hour"), ("seven_day", "Weekly"), ("seven_day_opus", "Weekly (Opus)"),
                     ("seven_day_sonnet", "Weekly (Sonnet)")]
        return names.compactMap { key, name in
            guard let window = object[key] as? [String: Any], let used = (window["utilization"] as? NSNumber)?.doubleValue
            else { return nil }
            let resets = (window["resets_at"] as? String).flatMap {
                ISO8601DateFormatter.fractional.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
            }
            return Limit(name: name, usedPercent: used, resets: resets)
        }
    }

    /// The folder a Codex session ran in, from its log's first line (`session_meta`).
    public static func codexFolder(_ firstLine: Substring) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any]
        else { return nil }
        return payload["cwd"] as? String
    }

    /// Read the lines of a Codex session log into `usage`: its latest token count holds the
    /// session's totals, the context window, and the plan's rate limits.
    public static func readCodex(_ lines: [Substring], into usage: inout AgentUsage) {
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any]
            else { continue }
            if object["type"] as? String == "turn_context", let model = payload["model"] as? String {
                usage.model = model
            }
            guard payload["type"] as? String == "token_count" else { continue }
            usage.messages += 1
            if let stamp = object["timestamp"] as? String { usage.updated = ISO8601DateFormatter.fractional.date(from: stamp) }
            if let info = payload["info"] as? [String: Any] {
                func count(_ group: String, _ key: String) -> Int {
                    ((info[group] as? [String: Any])?[key] as? NSNumber)?.intValue ?? 0
                }
                usage.inputTokens = count("total_token_usage", "input_tokens")
                usage.cachedTokens = count("total_token_usage", "cached_input_tokens")
                usage.cacheWriteTokens = count("total_token_usage", "cache_write_input_tokens")
                usage.outputTokens = count("total_token_usage", "output_tokens")
                usage.contextTokens = count("last_token_usage", "total_tokens")
                usage.contextWindow = (info["model_context_window"] as? NSNumber)?.intValue
            }
            if let limits = payload["rate_limits"] as? [String: Any] {
                usage.plan = limits["plan_type"] as? String
                usage.limits = [("primary", 0), ("secondary", 1)].compactMap { key, _ in
                    guard let window = limits[key] as? [String: Any],
                          let used = (window["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                    let minutes = (window["window_minutes"] as? NSNumber)?.intValue ?? 0
                    let name = minutes >= 7 * 24 * 60 ? "Weekly" : minutes > 0 ? Duration.seconds(minutes * 60)
                        .formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 1)) : key
                    let resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                    return Limit(name: name, usedPercent: used, resets: resets)
                }
            }
        }
    }
}

extension ISO8601DateFormatter {
    /// Dates like `2026-10-28T12:30:10.123Z`.
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
