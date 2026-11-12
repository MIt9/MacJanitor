import AppKit
import Darwin
import Foundation

struct ProcessRow: Identifiable {
    let id: pid_t
    let name: String
    let cpu: Double
    let memory: UInt64
    let uid: uid_t
    let user: String
    let icon: NSImage
    let isApp: Bool

    var canKill: Bool { ProcessLogic.canKill(uid: uid, currentUID: getuid()) }
}

enum ProcessLogic {
    static func cpuPercent(previous: UInt64, current: UInt64, elapsed: Double, timebase: Double) -> Double {
        guard current >= previous, elapsed > 0 else { return 0 }
        return Double(current - previous) * timebase / 1_000_000_000 / elapsed * 100
    }

    static func canKill(uid: uid_t, currentUID: uid_t) -> Bool { uid == currentUID }
}

@MainActor
@Observable
final class ProcessSampler {
    var processes: [ProcessRow] = []
    private var previous: [pid_t: (time: UInt64, start: UInt64)] = [:]
    private var lastSample: TimeInterval?
    private var timebase = mach_timebase_info_data_t()

    init() { mach_timebase_info(&timebase) }

    func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastSample.map { now - $0 } ?? 0
        let apps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let size = proc_listallpids(nil, 0)
        guard size > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(size) + 256)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return }
        var next: [pid_t: (time: UInt64, start: UInt64)] = [:]
        var rows: [ProcessRow] = []
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
            if result == 0 {
                if let old = previous[pid], old.start == start {
                    cpu = ProcessLogic.cpuPercent(previous: old.time, current: total, elapsed: elapsed, timebase: Double(timebase.numer) / Double(timebase.denom))
                }
                next[pid] = (total, start)
            }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let length = proc_name(pid, &buffer, UInt32(buffer.count))
            let name = length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : "PID \(pid)"
            let app = apps[pid]
            let username = getpwuid(info.pbi_uid).map { String(cString: $0.pointee.pw_name) } ?? String(info.pbi_uid)
            rows.append(ProcessRow(id: pid, name: app?.localizedName ?? name, cpu: cpu, memory: result == 0 ? usage.ri_phys_footprint : 0, uid: info.pbi_uid, user: username, icon: app?.icon ?? NSWorkspace.shared.icon(forFileType: NSFileTypeForHFSTypeCode(OSType(kGenericApplicationIcon))), isApp: app?.activationPolicy == .regular))
        }
        processes = rows
        previous = next
        lastSample = now
    }
}
