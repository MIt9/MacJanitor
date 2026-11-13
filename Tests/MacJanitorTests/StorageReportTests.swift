import Foundation
import Testing
import MacJanitorCore

@Test func storageReportValidatesOptions() {
    #expect(StorageReportOptions(arguments: ["/tmp", "--depth", "2"])?.depth == 2)
    #expect(StorageReportOptions(arguments: ["/tmp"])?.depth == 1)
    #expect(StorageReportOptions(arguments: ["/tmp", "--depth", "-1"]) == nil)
    #expect(StorageReportOptions(arguments: ["/tmp", "--depth", "101"]) == nil)
    #expect(StorageReportOptions(arguments: ["/tmp", "--depth"]) == nil)
}

@Test func storageReportDepthAndIncompleteAncestors() {
    let root = URL(fileURLWithPath: "/tmp/root")
    let inaccessible = StorageNode(url: root.appendingPathComponent("a/deep"), size: 0, children: [], inaccessible: true)
    let child = StorageNode(url: root.appendingPathComponent("a"), size: 10, children: [inaccessible])
    let tree = StorageNode(url: root, size: 10, children: [child, StorageNode(url: root.appendingPathComponent("file"), size: 10)])
    let results = StorageReport.directories(tree, depth: 1)
    #expect(results.count == 2)
    #expect(results.allSatisfy { $0.incomplete })
    #expect(!results.contains { $0.node.url == inaccessible.url })
    #expect(StorageReport.directories(tree, depth: 0).count == 1)
}
