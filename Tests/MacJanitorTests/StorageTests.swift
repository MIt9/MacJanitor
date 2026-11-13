import MacJanitorCore
import Foundation
import Testing
@testable import MacJanitor

@Test func visibleStorageRowsRemainExpandedAcrossSnapshots() {
    let base = URL(fileURLWithPath: "/tmp/tree")
    let folder = base.appendingPathComponent("folder")
    let file = folder.appendingPathComponent("file")
    let expanded: Set<URL> = [base, folder]
    let first = StorageNode(url: base, size: 0, children: [StorageNode(url: folder, size: 0, children: [])])
    let second = StorageNode(url: base, size: 2, children: [StorageNode(url: folder, size: 2, children: [StorageNode(url: file, size: 2)])])
    #expect(StorageVisibleRows.make(root: first, expanded: expanded).map(\.id) == [base, folder])
    let rows = StorageVisibleRows.make(root: second, expanded: expanded)
    #expect(rows.map(\.id) == [base, folder, file])
    #expect(rows.map(\.depth) == [0, 1, 2])
    #expect(StorageVisibleRows.make(root: second, expanded: [base]).map(\.id) == [base, folder])
}

@Test func missingStorageItemIsMarkedInaccessible() async throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let node = try await StorageScanner().scan(missing)
    #expect(node.inaccessible)
    #expect(node.size == 0)
}

@Test func storageCacheRoundTripAndRootValidation() throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: directory) }
    let cache = StorageCache(url: directory.appendingPathComponent("scan.plist"))
    let rootURL = directory.appendingPathComponent("home")
    let node = StorageNode(url: rootURL, size: 42, children: [StorageNode(url: rootURL.appendingPathComponent("file"), size: 42)])
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(try cache.load(for: rootURL) == nil)
    try cache.save(node, scannedAt: date)
    let loaded = try cache.load(for: rootURL)
    let saved = try #require(loaded)
    #expect(try cache.loadLatest()?.root.url == rootURL)
    #expect(saved.scannedAt == date)
    #expect(saved.root.children?.first?.size == 42)
    #expect(try cache.load(for: directory) == nil)
}

@Test func storageCacheRejectsCorruptFile() throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }
    let url = directory.appendingPathComponent("scan.plist")
    try Data("invalid".utf8).write(to: url)
    #expect(throws: (any Error).self) { try StorageCache(url: url).load(for: directory) }
}

private actor SnapshotCollector {
    var snapshots: [StorageNode] = []
    func append(_ node: StorageNode) { snapshots.append(node) }
}

@Test func storageScannerPublishesPartialTrees() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try Data(repeating: 1, count: 8192).write(to: root.appendingPathComponent("folder/file"))
    try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent("other"))
    let collector = SnapshotCollector()
    let final = try await StorageScanner().scan(root, updateInterval: .zero) { _, _, node in
        await collector.append(node)
    }
    let snapshots = await collector.snapshots
    #expect(!snapshots.isEmpty)
    #expect(snapshots.contains { $0.children?.contains { $0.url.lastPathComponent == "folder" } == true })
    #expect(snapshots.allSatisfy { $0.size == ($0.children ?? []).reduce(0) { $0 + $1.size } })
    #expect(final.size > 0)
}

@Test func storageScannerCountsLinksOnce() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let file = root.appendingPathComponent("file")
    try Data(repeating: 42, count: 8192).write(to: file)
    try fm.linkItem(at: file, to: root.appendingPathComponent("hardlink"))
    try fm.createSymbolicLink(at: root.appendingPathComponent("symlink"), withDestinationURL: file)
    let node = try await StorageScanner().scan(root)
    let allocated = try file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
    #expect(node.size == Int64(allocated.totalFileAllocatedSize ?? allocated.fileAllocatedSize ?? 0))
    #expect(node.children?.first(where: { $0.url.lastPathComponent == "symlink" })?.size == 0)
}

@Test func storageProtectedPaths() {
    let policy = StoragePolicy(home: URL(fileURLWithPath: "/Users/example"))
    #expect(policy.canDelete(URL(fileURLWithPath: "/Users/example/Library/Caches/test")))
    #expect(!policy.canDelete(URL(fileURLWithPath: "/Users/example/Library/Mail")))
    #expect(!policy.canDelete(URL(fileURLWithPath: "/Users/example/Library/Caches")))
    #expect(!policy.canDelete(URL(fileURLWithPath: "/Users/example/Library")))
    #expect(!policy.canDelete(URL(fileURLWithPath: "/Users/example")))
    #expect(!policy.canDelete(URL(fileURLWithPath: "/Users/example2/file")))
}

@Test func storageRemovalUpdatesSizesAndParentBars() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root.appendingPathComponent("d"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try Data(repeating: 1, count: 20000).write(to: root.appendingPathComponent("d/a"))
    try Data(repeating: 1, count: 8192).write(to: root.appendingPathComponent("b"))
    let node = try await StorageScanner().scan(root)
    let d = try #require(node.children?.first { $0.url.lastPathComponent == "d" })
    #expect(d.parentSize == node.size)
    let after = node.removing(try #require(d.children?.first).url)
    #expect(after.size == node.size - d.size)
    #expect(after.children?.first { $0.url.lastPathComponent == "d" }?.size == 0)
}

@Test func storageCleanupSkipsHomebrewInCaches() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let caches = home.appendingPathComponent("Library/Caches")
    try fm.createDirectory(at: caches.appendingPathComponent("Homebrew"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: home) }
    try Data(repeating: 1, count: 8192).write(to: caches.appendingPathComponent("Homebrew/x"))
    try Data(repeating: 1, count: 8192).write(to: caches.appendingPathComponent("y"))
    let cat = try #require(CleanupCategory.all(home: home).first { $0.id == "caches" })
    #expect(await cat.measure() == 8192)
    #expect(await cat.clean(permanent: true, policy: StoragePolicy(home: home)) == 0)
    #expect(fm.fileExists(atPath: caches.appendingPathComponent("Homebrew/x").path))
    #expect(!fm.fileExists(atPath: caches.appendingPathComponent("y").path))
}

@Test func storagePruningKeepsSizesAndRemovalSubtracts() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prune-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let big = dir.appendingPathComponent("big"), small = dir.appendingPathComponent("small")
    try FileManager.default.createDirectory(at: small, withIntermediateDirectories: true)
    try Data(count: 2 << 20).write(to: big)
    try Data(count: 10).write(to: small.appendingPathComponent("a"))
    let full = try await StorageScanner().scan(dir)
    let pruned = try await StorageScanner().scan(dir, minNodeSize: 1 << 20)
    #expect(pruned.size == full.size)
    #expect(pruned.children?.map(\.url.lastPathComponent) == ["big"])
    let bigSize = pruned.children![0].size
    let after = pruned.removing(pruned.children![0].url)
    #expect(after.size == full.size - bigSize)  // the hidden small folder stays counted
    #expect(after.children?.isEmpty == true)
}

@Test func storageLargestFilesPicksTopLeaves() {
    func file(_ name: String, _ size: Int64) -> StorageNode { StorageNode(url: URL(fileURLWithPath: "/r/\(name)"), size: size) }
    let sub = StorageNode(url: URL(fileURLWithPath: "/r/d"), size: 0, children: [file("c", 30), file("d", 5)])
    let root = StorageNode(url: URL(fileURLWithPath: "/r"), size: 0, children: [file("a", 10), sub, file("b", 20), StorageNode(url: URL(fileURLWithPath: "/r/e"), size: 0, children: [])])
    #expect(root.largestFiles(2).map(\.url.lastPathComponent) == ["c", "b"])
    #expect(root.largestFiles(10).map(\.size) == [30, 20, 10, 5])
}
