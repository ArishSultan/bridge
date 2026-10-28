import Foundation
import Testing
@testable import BridgeCore
@testable import BridgeSystem

struct StatsTests {
    @Test func remoteReadingsAndRates() {
        let one = "BRIDGE-BEGIN\nhost=box\nos=Linux 6.8\nncpu=4\ncpu=1000 800\nmemtotal=8000\nmemavailable=2000\n"
            + "load=0.50 0.40 0.30\nuptime=3600\nnet=100 200\ndisk=50 100\nproc=12.5 3.0 /usr/bin/python3\nBRIDGE-END\n"
        let two = "BRIDGE-BEGIN\ncpu=2000 1300\nnet=300 600\nBRIDGE-END\nBRIDGE-BEGIN\ncpu=21"
        let (first, rest) = Stats.parseRemote(one)
        #expect(first.count == 1 && rest.isEmpty)
        let reading = first[0]
        #expect(reading.host == "box" && reading.cpus == 4 && reading.uptime == 3600)
        #expect(reading.memoryUse == 0.75)
        #expect(reading.load == [0.5, 0.4, 0.3])
        #expect(reading.processes == [Stats.RemoteProcess(cpu: 12.5, memory: 3, name: "python3")])
        // A reading cut off between two reads waits for the rest.
        let (second, leftover) = Stats.parseRemote(two)
        #expect(second.count == 1 && leftover == "cpu=21")
        #expect(second[0].cpuUse(since: reading) == 0.5)
    }

    @Test func claudeSessionLog() {
        let lines: [Substring] = [
            #"{"type":"user","message":{"content":"hi"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-28T10:00:00.000Z","message":{"model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200,"output_tokens":50}}}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-5-5[1m]","usage":{"input_tokens":5,"cache_read_input_tokens":3000,"cache_creation_input_tokens":0,"output_tokens":20}}}"#,
        ]
        var usage = Stats.AgentUsage()
        Stats.readClaude(lines, into: &usage)
        #expect(usage.messages == 2)
        #expect(usage.inputTokens == 15 && usage.outputTokens == 70 && usage.cachedTokens == 4000)
        #expect(usage.contextTokens == 3005 && usage.contextWindow == 1_000_000)
        #expect(usage.updated != nil)
    }

    @Test func codexSessionLog() {
        let meta: Substring = #"{"type":"session_meta","payload":{"cwd":"/code/app"}}"#
        #expect(Stats.codexFolder(meta) == "/code/app")
        let lines: [Substring] = [
            #"{"type":"turn_context","payload":{"model":"gpt-5-codex"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"cached_input_tokens":400,"output_tokens":100},"last_token_usage":{"total_tokens":6000},"model_context_window":200000},"rate_limits":{"plan_type":"pro","primary":{"used_percent":25.0,"window_minutes":300,"resets_at":1800000000},"secondary":{"used_percent":60.5,"window_minutes":10080,"resets_at":1800500000}}}}"#,
        ]
        var usage = Stats.AgentUsage()
        Stats.readCodex(lines, into: &usage)
        #expect(usage.model == "gpt-5-codex" && usage.plan == "pro")
        #expect(usage.inputTokens == 900 && usage.contextUse == 0.03)
        #expect(usage.limits.map(\.usedPercent) == [25, 60.5])
        #expect(usage.limits.last?.name == "Weekly")
        #expect(usage.limits.first?.resets == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func claudePlanLimits() {
        let limits = Stats.claudeLimits([
            "five_hour": ["utilization": 12.0, "resets_at": "2026-10-28T15:00:00.000Z"],
            "seven_day": ["utilization": 40, "resets_at": "2026-11-01T00:00:00Z"],
            "seven_day_opus": NSNull(),
        ])
        #expect(limits.map(\.name) == ["5-hour", "Weekly"])
        #expect(limits.allSatisfy { $0.resets != nil })
    }

    @Test func claudeProjectFolderName() {
        #expect(Stats.claudeProjectFolder(for: URL(fileURLWithPath: "/Users/me/code/my.app"), home: "/Users/me").path
            == "/Users/me/.claude/projects/-Users-me-code-my-app")
    }

    @Test func samplesAProcessTree() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 5 & sleep 5 & wait"]
        try process.run()
        defer { process.terminate() }
        usleep(300_000)
        let sample = try #require(ProcessStats.sample(root: process.processIdentifier))
        #expect(sample.processes.first?.id == process.processIdentifier)
        #expect(sample.processes.filter { $0.name == "sleep" }.count == 2)
        #expect(sample.memory > 0 && sample.threads >= 3)
        #expect(ProcessStats.sample(root: 999_999) == nil)
    }
}
