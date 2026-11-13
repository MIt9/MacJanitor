import Foundation
import Testing
import MacJanitorCore

@Test func doctorReportsUnknownAndDoesNotExecuteTools() throws {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("marker")
    let tool = directory.appendingPathComponent("swift")
    try "#!/bin/sh\ntouch \(marker.path)\n".write(to: tool, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    let report = Doctor.inspect(home: directory.appendingPathComponent("missing"), environment: ["PATH": directory.path, "DEVELOPER_DIR": directory.appendingPathComponent("missing").path])
    #expect(report.availableBytes == nil)
    #expect(report.volumeError != nil)
    #expect(report.developerDirectory == nil)
    #expect(report.developerDirectoryStatus == "unavailable")
    #expect(report.tools.first { $0.name == "swift" }?.status == "executable_unverified")
    #expect(report.tools.first { $0.name == "git" }?.status == "not_found")
    #expect(!fm.fileExists(atPath: marker.path))
}

@Test func doctorReadsAvailableSpace() {
    let report = Doctor.inspect(home: FileManager.default.temporaryDirectory, environment: ["PATH": ""])
    #expect(report.availableBytes != nil)
    #expect(report.volumeError == nil)
    #expect(!report.macOSVersion.isEmpty)
}
