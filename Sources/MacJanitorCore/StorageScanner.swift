import Foundation
import Darwin

public struct StorageNode: Identifiable, Sendable, Codable {
    public let url: URL
    public var size: Int64
    public var children: [StorageNode]?
    public var inaccessible = false
    public var parentSize: Int64 = 0
    public var id: URL { url }

    public init(url: URL, size: Int64, children: [StorageNode]? = nil, inaccessible: Bool = false, parentSize: Int64 = 0) {
        self.url = url; self.size = size; self.children = children; self.inaccessible = inaccessible; self.parentSize = parentSize
    }
}

public struct StorageScanner: Sendable {
    public init() {}
    struct Identity: Hashable { let device: UInt64; let inode: UInt64 }

    public func scan(_ root: URL, updateInterval: Duration = .milliseconds(300), progress: @Sendable (Int, String, StorageNode) async -> Void = { _, _, _ in }) async throws -> StorageNode {
        var seen = Set<Identity>()
        var count = 0
        var stack: [StorageNode] = []
        var lastUpdate = ContinuousClock.now

        func snapshot() -> StorageNode {
            var combined: StorageNode?
            for var node in stack.reversed() {
                var children = node.children ?? []
                if let combined { children.append(combined) }
                children.sort { $0.size > $1.size }
                let total = children.reduce(Int64(0)) { $0 + $1.size }
                for i in children.indices { children[i].parentSize = total }
                node.children = children
                node.size = total
                node.parentSize = total
                combined = node
            }
            return combined ?? StorageNode(url: root, size: 0, children: [])
        }

        func publish(_ url: URL, force: Bool = false) async {
            guard force || lastUpdate.duration(to: .now) >= updateInterval else { return }
            lastUpdate = .now
            await progress(count, url.path, snapshot())
        }

        func visit(_ url: URL) async throws -> StorageNode {
            try Task.checkCancellation()
            count += 1
            await publish(url)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return StorageNode(url: url, size: 0, inaccessible: true) }
            let kind = info.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFLNK) { return StorageNode(url: url, size: 0) }
            if kind == mode_t(S_IFDIR) {
                do {
                    let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                    stack.append(StorageNode(url: url, size: 0, children: []))
                    if stack.count == 1 { await publish(url, force: true) }
                    for entry in entries {
                        let child = try await visit(entry)
                        stack[stack.count - 1].children!.append(child)
                    }
                    var children = stack.removeLast().children ?? []
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
            guard let allocated = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize else {
                return StorageNode(url: url, size: 0, inaccessible: true)
            }
            return StorageNode(url: url, size: Int64(allocated))
        }
        return try await visit(root)
    }
}

public extension StorageNode {
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

