import Foundation
import Darwin
import Testing
import MacJanitorCore

@Test func cleanupActionRemovesOnlySelectedTemporaryCategory() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let caches = home.appendingPathComponent("Library/Caches")
    try fm.createDirectory(at: caches.appendingPathComponent("Homebrew"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: home) }
    let file = caches.appendingPathComponent("test")
    let protected = caches.appendingPathComponent("Homebrew/keep")
    try Data("test".utf8).write(to: file)
    try Data("keep".utf8).write(to: protected)
    let rows = CleanupAction.execute(home: home, categoryIDs: ["caches"], permanent: true)
    #expect(rows.count == 1)
    #expect(rows.first?.status == "deleted")
    #expect(!fm.fileExists(atPath: file.path))
    #expect(fm.fileExists(atPath: protected.path))
}

@Test func cleanupActionCannotEmptyTrashWithoutPermanentFlag() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let trash = home.appendingPathComponent(".Trash")
    try fm.createDirectory(at: trash, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: home) }
    let file = trash.appendingPathComponent("keep")
    try Data("keep".utf8).write(to: file)
    let rows = CleanupAction.execute(home: home, categoryIDs: ["trash"], permanent: false)
    #expect(rows.first?.status.hasPrefix("skipped") == true)
    #expect(fm.fileExists(atPath: file.path))
}

@Test func processActionRejectsInvalidAndCurrentPID() {
    #expect(throws: ProcessActionError.self) { try ProcessAction.send(pid: -1, force: false) }
    #expect(throws: ProcessActionError.self) { try ProcessAction.send(pid: getpid(), force: false) }
}

@Test func processActionSignalsOwnedChild() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
    try ProcessAction.send(pid: child.processIdentifier, force: false)
    child.waitUntilExit()
    #expect(child.terminationReason == .uncaughtSignal)
    #expect(child.terminationStatus == SIGTERM)
}
