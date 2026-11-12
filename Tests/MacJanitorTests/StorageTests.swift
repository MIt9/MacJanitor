import Foundation
import Testing
@testable import MacJanitor

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
