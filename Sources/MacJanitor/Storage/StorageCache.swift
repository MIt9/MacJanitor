import MacJanitorCore
import Foundation

struct StorageCache: Sendable {
    struct Snapshot: Codable, Sendable {
        let version: Int
        let scannedAt: Date
        let root: StorageNode
    }

    let url: URL

    static var standard: StorageCache {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return StorageCache(url: directory.appendingPathComponent("MacJanitor/storage-scan.plist"))
    }

    func load(for root: URL) throws -> Snapshot? {
        guard let snapshot = try loadLatest(), snapshot.root.url.standardizedFileURL == root.standardizedFileURL else { return nil }
        return snapshot
    }

    func loadLatest() throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let snapshot = try PropertyListDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == 1, snapshot.root.url.isFileURL else { return nil }
        return snapshot
    }

    func save(_ root: StorageNode, scannedAt: Date) throws {
        let snapshot = Snapshot(version: 1, scannedAt: scannedAt, root: root)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
