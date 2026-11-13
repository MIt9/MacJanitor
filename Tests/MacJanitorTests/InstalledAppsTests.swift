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

private func tempHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home.appendingPathComponent("Applications"), withIntermediateDirectories: true)
    return home
}

@Test func appRemovalPlansAndDeletesPlainBundle() throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let url = try makeApp(home.appendingPathComponent("Applications"), "Plain", bundleID: "com.example.plain")
    let app = try #require(AppRemoval.find(url.path, home: home))
    let plan = try AppRemoval.plan(for: app, home: home)
    #expect(plan.items.map(\.role) == [.bundle])
    #expect(plan.items.first?.url.path == url.path)
    #expect(plan.totalBytes > 0)
    #expect(plan.uninstallers.isEmpty)
    let results = try AppRemoval.remove(plan, permanent: true)
    #expect(results.map(\.status) == ["deleted"])
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func appRemovalRemovesLinkItselfAndListsTargetExplicitly() throws {
    let fm = FileManager.default
    let home = try tempHome()
    defer { try? fm.removeItem(at: home) }
    let real = try makeApp(home.appendingPathComponent("webdeploy"), "Fusion", bundleID: "com.autodesk.fusion", payload: 100_000)
    let link = home.appendingPathComponent("Applications/Fusion.app")
    try fm.createSymbolicLink(at: link, withDestinationURL: real)
    let plan = try AppRemoval.plan(for: try #require(InstalledApps.app(at: link)), home: home)
    #expect(plan.items.map(\.role) == [.link, .target])
    #expect(plan.items[0].url.path == link.path)
    #expect(plan.items[1].url.path == real.resolvingSymlinksInPath().path)
    #expect(plan.totalBytes >= 100_000)
    _ = try AppRemoval.remove(plan, permanent: true)
    #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil)
    #expect(!fm.fileExists(atPath: real.path))
}

@Test func appRemovalIncludesLauncherStubTargetButNotBareBinary() throws {
    let fm = FileManager.default
    let home = try tempHome()
    defer { try? fm.removeItem(at: home) }
    let real = try makeApp(home.appendingPathComponent("webdeploy"), "Real", bundleID: "com.example.real")
    let stub = try makeApp(home.appendingPathComponent("Applications"), "Stub", bundleID: "com.example.stub", payload: 0)
    try fm.createSymbolicLink(at: stub.appendingPathComponent("Contents/MacOS/Main"), withDestinationURL: real.appendingPathComponent("Contents/MacOS/Main"))
    let plan = try AppRemoval.plan(for: try #require(InstalledApps.app(at: stub)), home: home)
    #expect(plan.items.map(\.role) == [.bundle, .target])
    #expect(plan.items[1].url.lastPathComponent == "Real.app")

    let binary = home.appendingPathComponent("bin/tool")
    try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1]).write(to: binary)
    let bare = try makeApp(home.appendingPathComponent("Applications"), "Bare", bundleID: "com.example.bare", payload: 0)
    try fm.createSymbolicLink(at: bare.appendingPathComponent("Contents/MacOS/Main"), withDestinationURL: binary)
    #expect(try AppRemoval.plan(for: try #require(InstalledApps.app(at: bare)), home: home).items.map(\.role) == [.bundle])
}

@Test func appRemovalRefusesProtectedAndOutsideApps() throws {
    let home = try tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let apple = try makeApp(home.appendingPathComponent("Applications"), "Pages", bundleID: "com.apple.iWork.Pages")
    let spoofed = InstalledApp(url: apple, name: "Pages", bundleIdentifier: "com.apple.iWork.Pages", version: nil, sizeBytes: nil, lastLaunchDate: nil, isProtected: false)
    #expect(throws: AppRemovalError.protected(apple.path)) { try AppRemoval.plan(for: spoofed, home: home) }
    let elsewhere = try makeApp(home.appendingPathComponent("Downloads"), "Loose", bundleID: "com.example.loose")
    #expect(throws: AppRemovalError.outsideApplications(elsewhere.path)) { try AppRemoval.plan(for: try #require(InstalledApps.app(at: elsewhere)), home: home) }
    let system = InstalledApp(url: URL(fileURLWithPath: "/System/Applications/Calculator.app"), name: "Calculator", bundleIdentifier: nil, version: nil, sizeBytes: nil, lastLaunchDate: nil, isProtected: false)
    #expect(throws: AppRemovalError.self) { try AppRemoval.plan(for: system, home: home) }
    #expect(FileManager.default.fileExists(atPath: apple.path))
}

@Test func appRemovalFindsOwnUninstallers() throws {
    let fm = FileManager.default
    let home = try tempHome()
    defer { try? fm.removeItem(at: home) }
    let apps = home.appendingPathComponent("Applications")
    let app = try makeApp(apps, "Foo", bundleID: "com.example.foo")
    for name in ["Uninstall Foo.app", "Remove Other.app", "Unrelated.app"] {
        try fm.createDirectory(at: apps.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let plan = try AppRemoval.plan(for: try #require(InstalledApps.app(at: app)), home: home)
    #expect(plan.uninstallers.map(\.lastPathComponent) == ["Uninstall Foo.app"])

    let suite = apps.appendingPathComponent("Bar Suite")
    let bar = try makeApp(suite, "Bar", bundleID: "com.example.bar")
    try fm.createDirectory(at: suite.appendingPathComponent("Suite Uninstaller.app"), withIntermediateDirectories: true)
    let barPlan = try AppRemoval.plan(for: try #require(InstalledApps.app(at: bar)), home: home)
    #expect(barPlan.uninstallers.map(\.lastPathComponent) == ["Suite Uninstaller.app"])
}
