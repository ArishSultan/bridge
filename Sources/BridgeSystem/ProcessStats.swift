import Darwin
import Foundation

/// A terminal's processes, read from the kernel (libproc): the one it started and everything
/// that started under it.
public enum ProcessStats {
    public struct Process: Equatable, Sendable, Identifiable {
        public let id: pid_t
        public let parent: pid_t
        public let name: String
        /// CPU time used, in seconds.
        public let cpuTime: Double
        /// Resident memory, in bytes.
        public let memory: UInt64
        public let threads: Int
        public let started: Date
    }

    /// One reading of a process tree.
    public struct Sample: Equatable, Sendable {
        public let taken: Date
        public let processes: [Process]

        public var cpuTime: Double { processes.reduce(0) { $0 + $1.cpuTime } }
        public var memory: UInt64 { processes.reduce(0) { $0 + $1.memory } }
        public var threads: Int { processes.reduce(0) { $0 + $1.threads } }
        /// When the tree's first process started.
        public var started: Date? { processes.map(\.started).min() }

        /// CPU used between `earlier` and this sample, where 1 is one core fully busy.
        public func cpuUse(since earlier: Sample) -> Double {
            let elapsed = taken.timeIntervalSince(earlier.taken)
            guard elapsed > 0 else { return 0 }
            return max(cpuTime - earlier.cpuTime, 0) / elapsed
        }

        /// Each process's CPU use since `earlier` (processes that are new count from their start).
        public func cpuUse(of process: Process, since earlier: Sample) -> Double {
            let elapsed = taken.timeIntervalSince(earlier.taken)
            guard elapsed > 0 else { return 0 }
            let before = earlier.processes.first { $0.id == process.id }?.cpuTime ?? 0
            return max(process.cpuTime - before, 0) / elapsed
        }
    }

    /// The process `root` and all its descendants; nil when it has exited.
    public static func sample(root: pid_t) -> Sample? {
        guard let first = process(root) else { return nil }
        var processes = [first]
        var queue = [root]
        while let pid = queue.popLast(), processes.count < 2000 {
            for child in children(of: pid) {
                guard let info = process(child) else { continue }
                processes.append(info)
                queue.append(child)
            }
        }
        return Sample(taken: Date(), processes: processes)
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let bytes = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        // Older systems return a count, newer ones bytes; either way the list ends at a zero.
        let count = min(Int(bytes), buffer.count)
        return buffer.prefix(count).filter { $0 > 0 }
    }

    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    private static func process(_ pid: pid_t) -> Process? {
        var task = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &task, size) == size else { return nil }
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        var name = String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if name.isEmpty {
            name = withUnsafeBytes(of: task.pbsd.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        // Mach absolute time to nanoseconds (they differ on Apple silicon).
        let cpu = Double(task.ptinfo.pti_total_user + task.ptinfo.pti_total_system) * timebase / 1_000_000_000
        let started = Date(timeIntervalSince1970: TimeInterval(task.pbsd.pbi_start_tvsec)
            + TimeInterval(task.pbsd.pbi_start_tvusec) / 1_000_000)
        return Process(id: pid, parent: pid_t(task.pbsd.pbi_ppid), name: name, cpuTime: cpu,
                       memory: task.ptinfo.pti_resident_size, threads: Int(task.ptinfo.pti_threadnum), started: started)
    }
}
