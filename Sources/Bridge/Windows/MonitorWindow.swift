import AppKit
import BridgeCore
import BridgeSystem
import Charts
import SwiftUI

/// A terminal's monitor: live use of what it runs. Its processes (CPU, memory, threads) for
/// shells and tasks; for an SSH session, the whole computer on the other end; for a coding
/// agent, also its session: tokens, context and what's left of the plan's limits.
struct MonitorWindow: View {
    let pane: ID

    @State private var model: MonitorModel?
    private var store: Store { .shared }

    var body: some View {
        Group {
            if let model {
                MonitorContent(model: model)
            } else {
                ContentUnavailableView("This terminal is closed", systemImage: "terminal")
            }
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 420, idealHeight: 640)
        .onAppear {
            if model == nil, store.sessions[pane] != nil { model = MonitorModel(pane: pane) }
            model?.start()
        }
        .onDisappear { model?.stop() }
    }
}

// MARK: - Sampling

/// What a monitor samples, and how often: the terminal's process tree every second, the server
/// every two (its own ssh connection), an agent's log every three.
@MainActor
@Observable
final class MonitorModel {
    let pane: ID

    /// How many readings the charts keep (two minutes of processes).
    static let history = 120

    struct Point: Identifiable {
        let id: Int
        let date: Date
        let value: Double
    }

    // The terminal's processes.
    private(set) var processes: [ProcessRow] = []
    private(set) var cpu: [Point] = []
    private(set) var memory: [Point] = []
    private(set) var current: ProcessStats.Sample?
    private(set) var cpuNow = 0.0

    // The server, for SSH terminals.
    private(set) var remote: Stats.Remote?
    private(set) var remoteCPU: [Point] = []
    private(set) var remoteMemory: [Point] = []
    private(set) var networkRates: (inbound: Double, outbound: Double)?
    private(set) var remoteState = "Connecting…"

    // A coding agent's session.
    private(set) var agent: Agent?
    private(set) var usage: Stats.AgentUsage?
    private(set) var planLimits: [Stats.Limit] = []
    private(set) var planState: String?

    struct ProcessRow: Identifiable {
        let id: pid_t
        let name: String
        let cpu: Double
        let memory: UInt64
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var previous: ProcessStats.Sample?
    @ObservationIgnored private var counter = 0
    @ObservationIgnored private var remoteProcess: Process?
    @ObservationIgnored private var remoteText = ""
    @ObservationIgnored private var lastRemote: Stats.Remote?
    @ObservationIgnored private var log: (file: URL, offset: UInt64)?
    @ObservationIgnored private var lastLogSearch = Date.distantPast
    @ObservationIgnored private var lastPlanFetch = Date.distantPast

    private var store: Store { .shared }

    init(pane: ID) {
        self.pane = pane
    }

    var session: PaneSession? { store.sessions[pane] }
    var project: Project? { session.flatMap { store.project($0.projectID) } }
    var spec: TerminalSpec? { project?.terminal(pane) }
    var host: SSHHost? {
        if case .ssh(let id) = spec?.kind { return store.profiles.host(id) }
        return nil
    }
    var title: String {
        guard let project else { return "Monitor" }
        return store.label(of: pane, in: project) ?? "Terminal"
    }

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let host { startRemote(host) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        remoteProcess?.terminate()
        remoteProcess = nil
        if MonitorModel.registry[pane] === self { MonitorModel.registry[pane] = nil }
    }

    private func tick() {
        counter += 1
        sampleProcesses()
        if counter % 3 == 1 { readAgentLog() }
        if UserDefaults.standard.bool(forKey: "claudePlanLimits"), agent == .claude,
           Date().timeIntervalSince(lastPlanFetch) > 300 {
            fetchPlanLimits()
        }
    }

    private func sampleProcesses() {
        guard let root = session?.rootPID, let sample = ProcessStats.sample(root: root) else {
            current = nil
            processes = []
            return
        }
        if let previous {
            cpuNow = sample.cpuUse(since: previous)
            processes = sample.processes.map { process in
                ProcessRow(id: process.id, name: process.name, cpu: sample.cpuUse(of: process, since: previous), memory: process.memory)
            }.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.memory > $1.memory }
            append(&cpu, cpuNow * 100)
            append(&memory, Double(sample.memory))
        }
        previous = sample
        current = sample
        // An agent running in a shell counts too.
        if agent == nil {
            if case .task(let command, _, _) = spec?.kind,
               let first = command.split(separator: " ").first.map({ ($0 as NSString).lastPathComponent }) {
                agent = Agent.allCases.first { $0.command == first }
            }
            if agent == nil {
                agent = Agent.allCases.first { agent in sample.processes.contains { $0.name == agent.command } }
            }
        }
    }

    private func append(_ series: inout [Point], _ value: Double) {
        let next = (series.last?.id ?? 0) + 1
        series.append(Point(id: next, date: Date(), value: value))
        if series.count > Self.history { series.removeFirst(series.count - Self.history) }
    }

    // MARK: The server

    private func startRemote(_ host: SSHHost) {
        let vault = store.vaultIdentity(for: host)
        if case .vault = host.auth, vault == nil {
            remoteState = "Vaultwarden is locked: unlock it to see this server."
            return
        }
        let saved = host.auth == .password && Keychain.hasPassword(host: host.id)
        var command = SSHCommand.remoteStats(host, savedPassword: saved, vault: vault, helper: Store.helperPath,
                                             script: Stats.remoteScript)
        guard host.hasSafeDestination else { return }
        if saved { command.environment.merge(store.askpassEnvironment(host: host.id)) { _, new in new } }

        let process = Process()
        if let helper = Store.helperPath {
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["guard", "/usr/bin/ssh"] + command.arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = command.arguments
        }
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let pane = pane
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in MonitorModel.registry[pane]?.received(text) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            Task { @MainActor in
                if let model = MonitorModel.registry[pane], model.remote == nil, !line.isEmpty { model.remoteState = line }
            }
        }
        process.terminationHandler = { process in
            let code = process.terminationStatus
            Task { @MainActor in
                guard let model = MonitorModel.registry[pane], model.remoteProcess === process else { return }
                model.remoteProcess = nil
                if model.timer != nil { model.remoteState = "The connection ended (exit code \(code))." }
            }
        }
        MonitorModel.registry[pane] = self
        do {
            try process.run()
            remoteProcess = process
        } catch {
            remoteState = error.localizedDescription
        }
    }

    /// Monitors by pane, so the ssh process's callbacks find theirs.
    static var registry: [ID: MonitorModel] = [:]

    private func received(_ text: String) {
        let (readings, rest) = Stats.parseRemote(remoteText + text)
        remoteText = String(rest.suffix(64 * 1024))
        for reading in readings {
            if let last = lastRemote {
                if let use = reading.cpuUse(since: last) { append(&remoteCPU, use * 100) }
                if let inbound = reading.networkIn, let outbound = reading.networkOut,
                   let before = last.networkIn, let beforeOut = last.networkOut {
                    networkRates = (Double(inbound &- before) / 2, Double(outbound &- beforeOut) / 2)
                }
            }
            if let use = reading.memoryUse { append(&remoteMemory, use * 100) }
            lastRemote = reading
            remote = reading
        }
    }

    // MARK: The agent

    private func readAgentLog() {
        guard let agent, let project else { return }
        let root = project.root
        let folder = session?.directory.map(URL.init(fileURLWithPath:)) ?? project.folder(spec?.folder ?? ".")
        if log == nil || Date().timeIntervalSince(lastLogSearch) > 30 {
            lastLogSearch = Date()
            let found = agent == .claude
                ? Self.newestClaudeLog(folders: [folder, root])
                : agent == .codex ? Self.newestCodexLog(under: root) : nil
            if let found, found != log?.file {
                log = (found, 0)
                usage = Stats.AgentUsage()
            }
        }
        guard let current = log else { return }
        let file = current.file, offset = current.offset
        Task.detached {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            let data = (try? handle.readToEnd()) ?? Data()
            // Only whole lines; the rest is read next time.
            guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
            let text = String(decoding: data[data.startIndex...end], as: UTF8.self)
            let lines = text.split(separator: "\n")
            let next = offset + UInt64(end - data.startIndex + 1)
            await MainActor.run {
                guard self.log?.file == file, self.log?.offset == offset else { return }
                var usage = self.usage ?? Stats.AgentUsage()
                if agent == .claude { Stats.readClaude(lines, into: &usage) } else { Stats.readCodex(lines, into: &usage) }
                self.usage = usage
                self.log = (file, next)
            }
        }
    }

    /// The most recently written Claude Code session of a folder.
    nonisolated static func newestClaudeLog(folders: [URL]) -> URL? {
        let fm = FileManager.default
        return folders.flatMap { folder -> [URL] in
            let dir = Stats.claudeProjectFolder(for: folder)
            return ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "jsonl" }
        }.max { modified($0) < modified($1) }
    }

    /// The most recent Codex session (of the last week) that ran in the project.
    nonisolated static func newestCodexLog(under root: URL) -> URL? {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: Paths.home).appendingPathComponent(".codex/sessions")
        let calendar = Calendar.current
        var files: [URL] = []
        for days in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: -days, to: Date()) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = base.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            files += ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" }
        }
        let rootPath = root.standardizedFileURL.path
        for file in files.sorted(by: { modified($0) > modified($1) }) {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            try? handle.close()
            guard let line = String(decoding: head, as: UTF8.self).split(separator: "\n").first,
                  let cwd = Stats.codexFolder(line) else { continue }
            if cwd == rootPath || cwd.hasPrefix(rootPath + "/") { return file }
        }
        return nil
    }

    nonisolated private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Ask Anthropic for Claude's plan limits (after the user agreed: macOS asks for Claude
    /// Code's login once).
    func fetchPlanLimits() {
        lastPlanFetch = Date()
        planState = planLimits.isEmpty ? "Asking Anthropic…" : nil
        Task.detached {
            do {
                let limits = try await ClaudePlan.limits()
                await MainActor.run {
                    self.planLimits = limits
                    self.planState = limits.isEmpty ? "Anthropic sent no limits for this account." : nil
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { self.planState = message }
            }
        }
    }
}

// MARK: - The window's content

private struct MonitorContent: View {
    let model: MonitorModel
    @AppStorage("claudePlanLimits") private var planLimitsAllowed = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Terminal", value: model.title)
                if let project = model.project {
                    LabeledContent("Project", value: Store.shared.isGlobal(project.id) ? "Home" : project.name)
                }
            }
            if let host = model.host {
                ServerSection(model: model, host: host)
            }
            if let agent = model.agent {
                AgentSection(model: model, agent: agent, planLimitsAllowed: $planLimitsAllowed)
            }
            ProcessSection(model: model)
        }
        .formStyle(.grouped)
        .navigationTitle("Monitor — \(model.title)")
    }
}

/// Headline numbers in a row.
private struct Tiles: View {
    let tiles: [(title: String, value: String)]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(tiles, id: \.title) { tile in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.title).font(.caption).foregroundStyle(.secondary)
                    Text(tile.value).font(.title3.monospacedDigit().weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }
}

/// One measure over the last two minutes: a 2pt line over a light area, hover for the value.
private struct HistoryChart: View {
    let title: String
    let points: [MonitorModel.Point]
    let format: (Double) -> String
    var ceiling: Double?

    @State private var selected: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(points) { point in
                    AreaMark(x: .value("Time", point.date), y: .value(title, point.value))
                        .foregroundStyle(Color.accentColor.opacity(0.12))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.date), y: .value(title, point.value))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                if let selected, let point = points.min(by: { abs($0.date.timeIntervalSince(selected)) < abs($1.date.timeIntervalSince(selected)) }) {
                    RuleMark(x: .value("Time", point.date))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            Text(format(point.value))
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.background, in: RoundedRectangle(cornerRadius: 4))
                        }
                }
            }
            .chartYScale(domain: 0...(ceiling ?? max(points.map(\.value).max() ?? 1, 1) * 1.15))
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let number = value.as(Double.self) { Text(format(number)) } }
                }
            }
            .chartXSelection(value: $selected)
            .frame(height: 90)
            .accessibilityLabel(title)
            .accessibilityValue(points.last.map { format($0.value) } ?? "No readings yet")
        }
    }
}

private struct ProcessSection: View {
    let model: MonitorModel

    var body: some View {
        Section {
            if let sample = model.current {
                Tiles(tiles: [
                    ("CPU", percent(model.cpuNow * 100)),
                    ("Memory", bytes(Double(sample.memory))),
                    ("Threads", "\(sample.threads)"),
                    ("Running for", sample.started.map { elapsed(Date().timeIntervalSince($0)) } ?? "—"),
                ])
                HistoryChart(title: "CPU (100% is one core)", points: model.cpu, format: percent)
                HistoryChart(title: "Memory", points: model.memory, format: bytes)
                ForEach(model.processes.prefix(12)) { process in
                    HStack {
                        Text(process.name).lineLimit(1)
                        Text("\(process.id)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        Spacer()
                        Text(percent(process.cpu * 100)).monospacedDigit().frame(width: 64, alignment: .trailing)
                        Text(bytes(Double(process.memory))).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .font(.callout)
                }
            } else {
                Text(model.session?.status.isRunning == true
                     ? "Reading this terminal's processes…"
                     : "This terminal isn't running.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(model.host == nil ? "Processes" : "On this Mac")
        } footer: {
            if model.current != nil {
                Text("Everything the terminal started, with what each process uses now.")
            }
        }
    }
}

private struct ServerSection: View {
    let model: MonitorModel
    let host: SSHHost

    var body: some View {
        Section {
            if let remote = model.remote {
                LabeledContent("Computer", value: remote.host.isEmpty ? host.displayName : remote.host)
                if !remote.os.isEmpty { LabeledContent("System", value: remote.os) }
                if let uptime = remote.uptime { LabeledContent("Up for", value: elapsed(uptime)) }
                Tiles(tiles: [
                    ("CPU", model.remoteCPU.last.map { percent($0.value) } ?? "—"),
                    ("Memory", remote.memoryTotal.map { total in
                        "\(bytes(Double((total - min(remote.memoryAvailable ?? 0, total)) * 1024))) of \(bytes(Double(total * 1024)))"
                    } ?? "—"),
                    ("Load", remote.load.isEmpty ? "—" : remote.load.map { String(format: "%.2f", $0) }.joined(separator: " ")),
                ])
                Tiles(tiles: [
                    ("Disk", remote.diskTotal.map { "\(bytes(Double((remote.diskUsed ?? 0) * 1024))) of \(bytes(Double($0 * 1024)))" } ?? "—"),
                    ("Network in", model.networkRates.map { bytes($0.inbound) + "/s" } ?? "—"),
                    ("Network out", model.networkRates.map { bytes($0.outbound) + "/s" } ?? "—"),
                ])
                if let swap = remote.swapTotal, swap > 0 {
                    LabeledContent("Swap used", value: "\(bytes(Double((swap - min(remote.swapFree ?? 0, swap)) * 1024))) of \(bytes(Double(swap * 1024)))")
                }
                if !model.remoteCPU.isEmpty {
                    HistoryChart(title: "CPU, all \(remote.cpus) cores", points: model.remoteCPU, format: percent, ceiling: 100)
                }
                if !model.remoteMemory.isEmpty {
                    HistoryChart(title: "Memory in use", points: model.remoteMemory, format: percent, ceiling: 100)
                }
                ForEach(remote.processes) { process in
                    HStack {
                        Text(process.name).lineLimit(1)
                        Spacer()
                        Text(percent(process.cpu)).monospacedDigit().frame(width: 64, alignment: .trailing)
                        Text(String(format: "%.1f%% mem", process.memory)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .font(.callout)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.remoteState).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        } header: {
            Text("Server — \(host.displayName)")
        } footer: {
            Text("Read every two seconds over a connection of its own to \(host.address).")
        }
    }
}

private struct AgentSection: View {
    let model: MonitorModel
    let agent: Agent
    @Binding var planLimitsAllowed: Bool

    var body: some View {
        Section {
            if let usage = model.usage, usage.messages > 0 {
                if let model = usage.model { LabeledContent("Model", value: model) }
                if let plan = usage.plan { LabeledContent("Plan", value: plan.capitalized) }
                if let context = usage.contextUse, let window = usage.contextWindow {
                    LabeledContent("Context") {
                        HStack {
                            ProgressView(value: context).frame(width: 120)
                            Text("\(percent(context * 100)) of \(tokens(window))").monospacedDigit()
                        }
                    }
                }
                Tiles(tiles: [
                    ("Input", tokens(usage.inputTokens)),
                    ("Output", tokens(usage.outputTokens)),
                    ("From cache", tokens(usage.cachedTokens)),
                    (agent == .claude ? "Replies" : "Turns", "\(usage.messages)"),
                ])
                LimitRows(limits: usage.limits)
            } else {
                Text("No session of \(agent.name) in this project yet.").foregroundStyle(.secondary)
            }
            if agent == .claude {
                LimitRows(limits: model.planLimits)
                if let state = model.planState { Text(state).font(.callout).foregroundStyle(.secondary) }
                if !planLimitsAllowed {
                    Button("Show Plan Limits…") {
                        planLimitsAllowed = true
                        model.fetchPlanLimits()
                    }
                }
            }
        } header: {
            Text(agent.name)
        } footer: {
            if agent == .claude && !planLimitsAllowed {
                Text("Plan limits come from Anthropic, with Claude Code's own login: macOS asks you once to let Bridge use it.")
            } else if let updated = model.usage?.updated {
                Text("From the session's log, last written \(updated.formatted(.relative(presentation: .named))).")
            }
        }
    }
}

/// How much of each limit is used, and when it resets. Nearly used up is marked with a sign and
/// words, not color alone.
private struct LimitRows: View {
    let limits: [Stats.Limit]

    var body: some View {
        ForEach(limits) { limit in
            LabeledContent {
                HStack(spacing: 8) {
                    if limit.usedPercent >= 80 {
                        Label("Almost used up", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.orange)
                            .help("Almost used up")
                    }
                    ProgressView(value: min(limit.usedPercent, 100), total: 100).frame(width: 120)
                    Text("\(percent(max(100 - limit.usedPercent, 0))) left").monospacedDigit()
                }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(limit.name) limit")
                    if let resets = limit.resets {
                        Text("Resets \(resets.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Formatting

private func percent(_ value: Double) -> String {
    value < 10 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
}

private func bytes(_ value: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(max(value, 0)), countStyle: .memory)
}

private func tokens(_ value: Int) -> String {
    value >= 1_000_000 ? String(format: "%.1fM", Double(value) / 1_000_000)
        : value >= 1_000 ? String(format: "%.1fk", Double(value) / 1_000) : "\(value)"
}

private func elapsed(_ seconds: TimeInterval) -> String {
    Duration.seconds(max(seconds, 0)).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
}
