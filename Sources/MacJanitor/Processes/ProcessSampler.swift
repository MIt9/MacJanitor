import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers
import MacJanitorCore

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

@MainActor
@Observable
final class ProcessSampler {
    var processes: [ProcessRow] = []
    private let monitor = ProcessMonitor()

    func refresh() {
        let apps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        processes = monitor.sample().map { sample in
            let app = apps[sample.id]
            return ProcessRow(id: sample.id, name: app?.localizedName ?? sample.name, cpu: sample.cpu, memory: sample.memory, uid: sample.uid, user: sample.user, icon: app?.icon ?? NSWorkspace.shared.icon(for: .application), isApp: app?.activationPolicy == .regular)
        }
    }
}
