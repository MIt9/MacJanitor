import Foundation
import Darwin

struct StorageNode: Identifiable, Sendable {
    let url: URL
    var size: Int64
    var children: [StorageNode]?
    var inaccessible = false
    var parentSize: Int64 = 0
    var id: URL { url }
}

struct StorageScanner: Sendable {
    struct Identity: Hashable { let device: UInt64; let inode: UInt64 }

    func scan(_ root: URL, progress: @Sendable (Int, String) async -> Void = { _, _ in }) async throws -> StorageNode {
        var seen = Set<Identity>()
        var count = 0
        func visit(_ url: URL) async throws -> StorageNode {
            try Task.checkCancellation()
            count += 1
            await progress(count, url.path)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return StorageNode(url: url, size: 0, inaccessible: true) }
            let kind = info.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFLNK) { return StorageNode(url: url, size: 0) }
            if kind == mode_t(S_IFDIR) {
                do {
                    let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    var children: [StorageNode] = []
                    for entry in entries { children.append(try await visit(entry)) }
                    children.sort { $0.size > $1.size }
                    let total = children.reduce(0) { $0 + $1.size }
                    for i in children.indices { children[i].parentSize = total }
                    return StorageNode(url: url, size: total, children: children, parentSize: total)
                } catch is CancellationError { throw CancellationError() }
                catch { return StorageNode(url: url, size: 0, children: [], inaccessible: true) }
            }
            if info.st_nlink > 1 && !seen.insert(Identity(device: UInt64(info.st_dev), inode: info.st_ino)).inserted {
                return StorageNode(url: url, size: 0)
            }
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return StorageNode(url: url, size: Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0))
        }
        return try await visit(root)
    }
}

extension StorageNode {
    /// Returns the tree without `target`, with ancestor sizes and parent-relative sizes recomputed.
    func removing(_ target: URL) -> StorageNode {
        guard var kids = children else { return self }  // ponytail: walks the whole tree, fine for a one-off delete
        kids = kids.filter { $0.url != target }.map { $0.removing(target) }
        kids.sort { $0.size > $1.size }
        let total = kids.reduce(0) { $0 + $1.size }
        for i in kids.indices { kids[i].parentSize = total }
        var copy = self
        copy.children = kids
        copy.size = total
        if parentSize == size { copy.parentSize = total }
        return copy
    }
}

enum FullDiskAccess {
    /// Listing a TCC-protected folder fails without Full Disk Access.
    static func isGranted(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let probes = ["Library/Safari", "Library/Mail"].map { home.appendingPathComponent($0) }
        return probes.contains { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) != nil }
    }
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

struct StoragePolicy {
    let home: URL
    private var allowedLibrary: [String] { ["Logs", "Caches", "Developer/Xcode/DerivedData", "Developer/CoreSimulator/Caches"] }
    func canDelete(_ url: URL) -> Bool {
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(homePath + "/") else { return false }
        let library = homePath + "/Library"
        guard path == library || path.hasPrefix(library + "/") else { return true }
        // Only contents of whitelisted folders, never the folders themselves.
        return allowedLibrary.contains { path.hasPrefix(library + "/" + $0 + "/") }
    }
}
