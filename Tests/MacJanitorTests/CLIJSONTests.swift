import Foundation
import Testing
import Darwin

private func cli(_ arguments: [String]) throws -> (Int32, Data, Data) {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    process.executableURL = repo.appendingPathComponent(".build/debug/macjanitor")
    process.arguments = arguments
    let output = Pipe(), errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    try output.fileHandleForWriting.close()
    try errors.fileHandleForWriting.close()
    let out = output.fileHandleForReading.readDataToEndOfFile()
    let err = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, out, err)
}

@Suite(.serialized) struct CLIJSONTests {
@Test func cliHelpDocumentsEachCommand() throws {
    let (status, out, err) = try cli(["--help"])
    #expect(status == 0)
    #expect(err.isEmpty)
    let general = String(decoding: out, as: UTF8.self)
    for command in ["port", "processes", "terminate", "storage", "cleanup", "doctor", "apps"] {
        #expect(general.contains(command))
        let (code, data, errors) = try cli([command, "--help"])
        #expect(code == 0)
        #expect(errors.isEmpty)
        let help = String(decoding: data, as: UTF8.self)
        #expect(help.contains("Usage: macjanitor \(command)"))
        #expect(help.contains("Examples:"))
        #expect(help.contains("Exit status:"))
        #expect(help.contains("--json"))
    }
    let (jsonStatus, jsonData, _) = try cli(["storage", "--help", "--json"])
    #expect(jsonStatus == 0)
    let json = try #require(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
    #expect((json["usage"] as? String)?.contains("--depth") == true)
}
@Test func cliActionsRequireExplicitSafeArguments() throws {
    for args in [
        ["cleanup", "--execute", "--yes"],
        ["cleanup", "--execute", "--category", "caches"],
        ["cleanup", "--execute", "--category", "trash", "--yes"],
        ["cleanup", "--execute", "--category", "simunavail", "--yes"],
        ["terminate", "-1"],
        ["apps", "remove", "com.example.macjanitor-missing"],
        ["apps", "remove", "com.example.macjanitor-missing", "--permanent"],
        ["apps", "remove", "com.example.macjanitor-missing", "--dry-run", "--dry-run"],
        ["apps", "remove", "com.example.macjanitor-missing", "--yes"],
        ["apps", "remove", "--yes"],
    ] {
        let (status, out, err) = try cli(args + ["--json"])
        #expect(status == 2)
        #expect(out.isEmpty)
        #expect(!err.isEmpty)
    }
}

@Test func cliAppsRemoveRefusesAppOutsideApplications() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let contents = root.appendingPathComponent("Loose.app/Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleName": "Loose", "CFBundleIdentifier": "com.example.macjanitor-loose"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    let app = root.appendingPathComponent("Loose.app").path
    for flags in [["--dry-run"], ["--yes", "--permanent"]] {
        let (status, out, err) = try cli(["apps", "remove", app] + flags + ["--json"])
        #expect(status == 2)
        #expect(out.isEmpty)
        #expect(String(decoding: err, as: UTF8.self).contains("not inside"))
    }
    #expect(FileManager.default.fileExists(atPath: app))
}

@Test func cliTerminatesOwnedChildJSON() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
    let (status, out, err) = try cli(["terminate", String(child.processIdentifier), "--json"])
    #expect(status == 0)
    #expect(err.isEmpty)
    let object = try #require(JSONSerialization.jsonObject(with: out) as? [String: Any])
    #expect(object["command"] as? String == "terminate")
    #expect(object["signal"] as? String == "SIGTERM")
    #expect(object["sent"] as? Bool == true)
    child.waitUntilExit()
    #expect(child.terminationReason == .uncaughtSignal)
}
@Test func cliDoctorJSON() throws {
    let (status, out, err) = try cli(["doctor", "--json"])
    #expect(status == 0)
    #expect(err.isEmpty)
    let object = try #require(JSONSerialization.jsonObject(with: out) as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["command"] as? String == "doctor")
    #expect((object["volume"] as? [String: Any])?["availableBytes"] != nil)
    #expect((object["tools"] as? [[String: Any]])?.count == 4)
}
@Test func cliJSONStorageAndValidation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("child"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (status, out, _) = try cli(["storage", root.path, "--depth", "1", "--json"])
    #expect(status == 0)
    let object = try #require(JSONSerialization.jsonObject(with: out) as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["command"] as? String == "storage")
    #expect(object["complete"] as? Bool == true)
    let directories = try #require(object["directories"] as? [[String: Any]])
    #expect(directories.contains { ($0["path"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == root.appendingPathComponent("child").resolvingSymlinksInPath().path })
    let (badStatus, badOut, badErr) = try cli(["storage", root.path, "--depth", "-1", "--json"])
    #expect(badStatus == 2)
    #expect(badOut.isEmpty)
    #expect(!badErr.isEmpty)
}

@Test func cliJSONProcessesAndCleanup() throws {
    let (status, out, _) = try cli(["processes", "--limit", "1", "--json"])
    #expect(status == 0)
    let processes = try #require(JSONSerialization.jsonObject(with: out) as? [String: Any])
    #expect(processes["command"] as? String == "processes")
    #expect((processes["processes"] as? [[String: Any]])?.count == 1)
    let first = try #require((processes["processes"] as? [[String: Any]])?.first)
    #expect(first["cpuPercent"] is NSNull) // A memory-sorted report takes only one sample.
    #expect((processes["limitations"] as? [String])?.contains { $0.contains("omitted") } == true)
    let (cleanupStatus, cleanupOut, _) = try cli(["cleanup", "--dry-run", "--category", "simunavail", "--json"])
    #expect(cleanupStatus == 0)
    let cleanup = try #require(JSONSerialization.jsonObject(with: cleanupOut) as? [String: Any])
    #expect(cleanup["dryRun"] as? Bool == true)
    let entries = try #require(cleanup["entries"] as? [[String: Any]])
    #expect(entries.first?["allocatedBytes"] is NSNull)
    #expect((entries.first?["status"] as? String)?.contains("unavailable") == true)
}

@Test func cliHumanProcessesExplainUnavailableMeasurements() throws {
    let (status, out, err) = try cli(["processes", "--limit", "1"])
    #expect(status == 0)
    #expect(String(decoding: out, as: UTF8.self).contains("unknown"))
    #expect(String(decoding: err, as: UTF8.self).contains("omitted"))
}

@Test func cliProcessSamplingFindsCurrentProcess() throws {
    let (status, out, _) = try cli(["processes", "--limit", "10000", "--json"])
    #expect(status == 0)
    let object = try #require(JSONSerialization.jsonObject(with: out) as? [String: Any])
    let processes = try #require(object["processes"] as? [[String: Any]])
    #expect(processes.contains { ($0["pid"] as? Int) == Int(getpid()) })
}

@Test func cliJSONPortMatchesLiveSocket() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #expect(fd >= 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    #expect(bound == 0)
    guard bound == 0, listen(fd, 1) == 0 else { return }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    #expect(named == 0)
    guard named == 0 else { return }
    let port = Int(UInt16(bigEndian: address.sin_port))
    let (status, out, _) = try cli(["port", String(port), "--json"])
    #expect(status == 0)
    let object = try #require(JSONSerialization.jsonObject(with: out) as? [String: Any])
    #expect(object["port"] as? Int == port)
    #expect((object["matches"] as? [[String: Any]])?.contains { ($0["pid"] as? Int) == Int(getpid()) } == true)
}
}
