import Foundation
import MacJanitorCore

struct StorageVisibleRow: Identifiable {
    let node: StorageNode
    let depth: Int
    var id: URL { node.url }
}

enum StorageVisibleRows {
    static func make(root: StorageNode, expanded: Set<URL>) -> [StorageVisibleRow] {
        var rows: [StorageVisibleRow] = []
        func visit(_ node: StorageNode, depth: Int) {
            rows.append(StorageVisibleRow(node: node, depth: depth))
            guard expanded.contains(node.url), let children = node.children else { return }
            for child in children { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return rows
    }
}
