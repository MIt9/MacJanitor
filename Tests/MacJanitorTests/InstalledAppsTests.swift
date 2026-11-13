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
