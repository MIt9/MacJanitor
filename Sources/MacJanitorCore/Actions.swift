import Foundation
import Darwin

public enum ProcessActionError: Error, LocalizedError {
    case invalidPID, unavailable, wrongOwner, changed, signalFailed(Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidPID: "PID must be greater than 1 and different from this process."
        case .unavailable: "Process is unavailable."
        case .wrongOwner: "Only processes owned by the current user can be signaled."
        case .changed: "Process changed while being checked."
        case .signalFailed(let code): "Could not signal process: \(String(cString: strerror(code)))."
        }
    }
}

public enum ProcessAction {
    public static func send(pid: pid_t, force: Bool) throws {
        guard pid > 1, pid != getpid() else { throw ProcessActionError.invalidPID }
        func info() throws -> proc_bsdinfo {
            var value = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, size) == size else { throw ProcessActionError.unavailable }
            guard value.pbi_uid == getuid() else { throw ProcessActionError.wrongOwner }
            return value
        }
        let first = try info()
        let second = try info()
        guard first.pbi_start_tvsec == second.pbi_start_tvsec && first.pbi_start_tvusec == second.pbi_start_tvusec else {
            throw ProcessActionError.changed
        }
        guard kill(pid, force ? SIGKILL : SIGTERM) == 0 else { throw ProcessActionError.signalFailed(errno) }
    }
}

public struct CleanupActionResult: Sendable {
    public let category: String
    public let path: URL
    public let status: String
}

public enum CleanupAction {
    public static func execute(home: URL, categoryIDs: Set<String>, permanent: Bool) -> [CleanupActionResult] {
        let policy = StoragePolicy(home: home)
        var rows: [CleanupActionResult] = []
        for category in CleanupCatalog.categories(home: home) where categoryIDs.contains(category.id) {
            switch category.kind {
            case .simulators:
                rows.append(.init(category: category.id, path: home, status: "unsupported: simulator cleanup is not available"))
            case .folder(let folder, let skipping):
                guard category.id != "trash" || permanent else {
                    rows.append(.init(category: category.id, path: folder, status: "skipped: trash requires --permanent"))
                    continue
                }
                let entries: [URL]
                do { entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) }
                catch {
                    rows.append(.init(category: category.id, path: folder, status: "unavailable: \(error.localizedDescription)"))
                    continue
                }
                for entry in entries.sorted(by: { $0.path < $1.path }) where !skipping.contains(entry.lastPathComponent) {
                    guard policy.canDelete(entry) else {
                        rows.append(.init(category: category.id, path: entry, status: "protected: skipped"))
                        continue
                    }
                    do {
                        if permanent { try FileManager.default.removeItem(at: entry) }
                        else { try FileManager.default.trashItem(at: entry, resultingItemURL: nil) }
                        rows.append(.init(category: category.id, path: entry, status: permanent ? "deleted" : "trashed"))
                    } catch {
                        rows.append(.init(category: category.id, path: entry, status: "failed: \(error.localizedDescription)"))
                    }
                }
            }
        }
        return rows
    }
}
