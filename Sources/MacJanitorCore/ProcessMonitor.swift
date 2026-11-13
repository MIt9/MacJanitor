import Darwin
import Foundation

public enum ProcessLogic {
    public static func cpuPercent(previous: UInt64, current: UInt64, elapsed: Double, timebase: Double) -> Double {
        guard current >= previous, elapsed > 0 else { return 0 }
        return Double(current - previous) * timebase / 1_000_000_000 / elapsed * 100
    }
    public static func canKill(uid: uid_t, currentUID: uid_t) -> Bool { uid == currentUID }
}

public struct ProcessSample {
    public let id: pid_t
    public let name: String
    public let cpu: Double
    public let memory: UInt64
    public let cpuAvailable: Bool
    public let memoryAvailable: Bool
    public let uid: uid_t
    public let user: String
}

public final class ProcessMonitor {
    public private(set) var enumerationFailed = false
    private var previous: [pid_t: (time: UInt64, start: UInt64)] = [:]
    private var lastSample: TimeInterval?
    private var timebase = mach_timebase_info_data_t()
    public init() { mach_timebase_info(&timebase) }

    public func sample() -> [ProcessSample] {
        enumerationFailed = false
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastSample.map { now - $0 } ?? 0
        let size = proc_listallpids(nil, 0)
        guard size > 0 else { enumerationFailed = true; return [] }
        var pids = [pid_t](repeating: 0, count: Int(size) + 256)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { enumerationFailed = true; return [] }
        var next: [pid_t: (time: UInt64, start: UInt64)] = [:]
        var rows: [ProcessSample] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else { continue }
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            let total = usage.ri_user_time &+ usage.ri_system_time
            let start = usage.ri_proc_start_abstime
            var cpu = 0.0
            var cpuAvailable = false
            if result == 0 {
                if let old = previous[pid], old.start == start, total >= old.time, elapsed > 0 {
                    cpu = ProcessLogic.cpuPercent(previous: old.time, current: total, elapsed: elapsed, timebase: Double(timebase.numer) / Double(timebase.denom))
                    cpuAvailable = true
                }
                next[pid] = (total, start)
            }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let length = proc_name(pid, &buffer, UInt32(buffer.count))
            let name = length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : "PID \(pid)"
            let user = getpwuid(info.pbi_uid).map { String(cString: $0.pointee.pw_name) } ?? String(info.pbi_uid)
            rows.append(ProcessSample(id: pid, name: name, cpu: cpu, memory: result == 0 ? usage.ri_phys_footprint : 0, cpuAvailable: cpuAvailable, memoryAvailable: result == 0, uid: info.pbi_uid, user: user))
        }
        previous = next
        lastSample = now
        return rows
    }
}
