import Foundation
import Testing
import MacJanitorCore

@Test func cleanupPreviewUsesSharedCategoriesAndDoesNotModifyFiles() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let caches = home.appendingPathComponent("Library/Caches")
    try fm.createDirectory(at: caches.appendingPathComponent("Homebrew"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: home) }
    let file = caches.appendingPathComponent("item")
    let excluded = caches.appendingPathComponent("Homebrew/item")
    let contents = Data(repeating: 7, count: 8192)
    try contents.write(to: file)
    try contents.write(to: excluded)
    let rows = try await CleanupPreview.scan(home: home, categoryIDs: ["caches", "simunavail"])
    #expect(rows.contains { $0.path.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path && $0.size != nil && $0.status == "complete" })
    #expect(!rows.contains { $0.path.lastPathComponent == "Homebrew" })
    #expect(rows.contains { $0.category == "simunavail" && $0.size == nil })
    #expect(try Data(contentsOf: file) == contents)
    #expect(try Data(contentsOf: excluded) == contents)
}

@Test func cleanupPreviewReportsMissingCategory() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let rows = try await CleanupPreview.scan(home: home, categoryIDs: ["logs"])
    #expect(rows.count == 1)
    #expect(rows[0].size == nil)
    #expect(rows[0].status == "unavailable or missing")
}
