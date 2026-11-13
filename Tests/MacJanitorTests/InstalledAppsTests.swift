import Foundation
import Testing
import MacJanitorCore

@Test func installedAppsReadsBundleMetadataAndSize() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let contents = root.appendingPathComponent("MyApp.app/Contents")
    try fm.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "CFBundleName": "MyApp",
        "CFBundleDisplayName": "My App",
        "CFBundleIdentifier": "com.example.myapp",
        "CFBundleShortVersionString": "1.2.3",
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    try Data(repeating: 16, count: 256).write(to: contents.appendingPathComponent("Binary"))
    let apps = InstalledApps.apps(in: root)
    #expect(apps.count == 1)
    let app = try #require(apps.first)
    #expect(app.name == "My App")
    #expect(app.bundleIdentifier == "com.example.myapp")
    #expect(app.version == "1.2.3")
    #expect(app.sizeBytes != nil)
}

@Test func installedAppsSkipsEntriesThatAreNotApplications() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try Data([0x00]).write(to: root.appendingPathComponent("notes.txt"))
    #expect(InstalledApps.apps(in: root).isEmpty)
}

@Test func installedAppsReportsMissingDirectory() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(InstalledApps.apps(in: root).isEmpty)
}

private func makeApp(_ root: URL, _ name: String, bundleID: String, executable: String = "Main", payload: Int = 256) throws -> URL {
    let app = root.appendingPathComponent("\(name).app")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleName": name, "CFBundleIdentifier": bundleID, "CFBundleExecutable": executable]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    if payload > 0 { try Data(repeating: 1, count: payload).write(to: macOS.appendingPathComponent(executable)) }
    return app
}

@Test func installedAppsSymlinkReportsTargetSize() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let real = try makeApp(root.appendingPathComponent("webdeploy"), "Fusion", bundleID: "com.autodesk.fusion", payload: 200_000)
    let apps = root.appendingPathComponent("Applications")
    try fm.createDirectory(at: apps, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: apps.appendingPathComponent("Fusion.app"), withDestinationURL: real)
    let app = try #require(InstalledApps.apps(in: apps).first)
    #expect(app.url.lastPathComponent == "Fusion.app")
    #expect(app.bundleIdentifier == "com.autodesk.fusion")
    #expect((app.sizeBytes ?? 0) >= 200_000)
    #expect(app.sizeBytes == InstalledApps.size(of: real))
}

@Test func installedAppsStubAddsExternalExecutableTarget() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let real = try makeApp(root.appendingPathComponent("webdeploy"), "Real", bundleID: "com.example.real", payload: 200_000)
    let stub = try makeApp(root.appendingPathComponent("Applications"), "Stub", bundleID: "com.example.stub", payload: 0)
    try fm.createSymbolicLink(at: stub.appendingPathComponent("Contents/MacOS/Main"), withDestinationURL: real.appendingPathComponent("Contents/MacOS/Main"))
    let stubOnly = try #require(InstalledApps.size(of: stub))
    #expect(stubOnly < 200_000)
    #expect(InstalledApps.realSize(of: stub) == stubOnly + (InstalledApps.size(of: real) ?? 0))
}

@Test func installedAppsMarksSystemAndAppleAppsProtected() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let plain = try makeApp(root, "Plain", bundleID: "com.example.plain")
    let apple = try makeApp(root, "Pages", bundleID: "com.apple.iWork.Pages")
    #expect(InstalledApps.app(at: plain)?.isProtected == false)
    #expect(InstalledApps.app(at: apple)?.isProtected == true)
    #expect(InstalledApps.isProtected(url: URL(fileURLWithPath: "/System/Applications/Calculator.app"), bundleIdentifier: nil))
}

@Test func installedAppsSelectSortsAndFilters() {
    func app(_ name: String, _ size: Int64?, _ days: Double?) -> InstalledApp {
        InstalledApp(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, bundleIdentifier: nil, version: nil, sizeBytes: size,
                     lastLaunchDate: days.map { Date(timeIntervalSince1970: $0 * 86_400) }, isProtected: false)
    }
    let apps = [app("Zoom", 10, 3), app("blender", nil, 9), app("Xcode", 900, nil)]
    #expect(InstalledApps.select(apps, sort: .name).map(\.name) == ["blender", "Xcode", "Zoom"])
    #expect(InstalledApps.select(apps, sort: .size).map(\.name) == ["Xcode", "Zoom", "blender"])
    #expect(InstalledApps.select(apps, sort: .lastUsed).map(\.name) == ["blender", "Zoom", "Xcode"])
    #expect(InstalledApps.select(apps, search: " BLEN ", sort: .name).map(\.name) == ["blender"])
}
