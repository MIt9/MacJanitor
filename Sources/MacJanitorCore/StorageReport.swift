import Foundation

public struct StorageReportOptions {
    public let path: String
    public let depth: Int

    public init?(arguments: [String]) {
        guard let path = arguments.first, !path.hasPrefix("--"), !path.isEmpty else { return nil }
        var depth = 1
        if arguments.count > 1 {
            guard arguments.count == 3, arguments[1] == "--depth",
                  let parsed = Int(arguments[2]), (0...100).contains(parsed) else { return nil }
            depth = parsed
        }
        self.path = path
        self.depth = depth
    }
}

public struct StorageDirectoryResult {
    public let node: StorageNode
    public let incomplete: Bool
}

public enum StorageReport {
    public static func directories(_ root: StorageNode, depth: Int) -> [StorageDirectoryResult] {
        var results: [StorageDirectoryResult] = []
        // Visit the whole tree so inaccessible descendants affect their ancestors.
        @discardableResult func visit(_ node: StorageNode, level: Int) -> Bool {
            var incomplete = node.inaccessible
            for child in node.children ?? [] {
                if visit(child, level: level + 1) { incomplete = true }
            }
            if node.children != nil && level <= depth {
                results.append(StorageDirectoryResult(node: node, incomplete: incomplete))
            }
            return incomplete
        }
        visit(root, level: 0)
        return results.sorted { $0.node.size == $1.node.size ? $0.node.url.path < $1.node.url.path : $0.node.size > $1.node.size }
    }
}
