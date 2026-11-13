import Foundation
import Testing
import MacJanitorCore

private struct Fixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var support: URL { base.appendingPathComponent("Application Support") }
    var prefs: URL { base.appendingPathComponent("Preferences") }
    var groups: URL { base.appendingPathComponent("Group Containers") }
    var agents: URL { base.appendingPathComponent("LaunchAgents") }
    var system: URL { base.appendingPathComponent("SystemSupport") }
    var roots: [LeftoverRoot] {
        [support, prefs, groups].map { LeftoverRoot(url: $0, needsAdmin: false) }
            + [LeftoverRoot(url: agents, needsAdmin: false, launchDomain: "gui/\(getuid())"), LeftoverRoot(url: system, needsAdmin: true)]
    }

    init() throws {
        for dir in [support, prefs, groups, agents, system] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }

    @discardableResult func make(_ dir: URL, _ name: String, folder: Bool = false) throws -> URL {
        let url = dir.appendingPathComponent(name)
        if folder { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        else { try Data("x".utf8).write(to: url) }
        return url
    }
}

private func app(_ name: String, _ id: String?) -> InstalledApp {
    InstalledApp(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, bundleIdentifier: id, version: nil, sizeBytes: nil, lastLaunchDate: nil, isProtected: false)
}

@Test func leftoversQueryDerivesVendorFromBundleID() {
    #expect(LeftoverQuery(bundleID: "com.Autodesk.fusion", name: "Fusion").vendor == "autodesk")
    #expect(LeftoverQuery(bundleID: "com.foo", name: "Foo").vendor == nil)
}

@Test func leftoversMatchBundleIDNameAndVendor() throws {
    let f = try Fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let plist = try f.make(f.prefs, "com.example.foobar.plist")
    let helper = try f.make(f.prefs, "com.example.foobar.helper.plist")
    let group = try f.make(f.groups, "ABCDE12345.com.example.foobar", folder: true)
    let named = try f.make(f.support, "Foo Bar", folder: true)
    let vendor = try f.make(f.support, "Example", folder: true)
    try f.make(f.prefs, "com.example.foobar.pro.plist")      // belongs to another installed app
    try f.make(f.prefs, "com.other.thing.plist")
    try f.make(f.support, "Foo", folder: true)               // not the whole name
    let hits = Leftovers.scan(LeftoverQuery(bundleID: "com.example.foobar", name: "Foo Bar"),
                              installed: [app("Foo Bar Pro", "com.example.foobar.pro")], roots: f.roots)
    let byPath = Dictionary(uniqueKeysWithValues: hits.map { ($0.url.lastPathComponent, $0) })
    #expect(Set(byPath.keys) == Set([plist, helper, group, named, vendor].map(\.lastPathComponent)))
    #expect(byPath[plist.lastPathComponent]?.reason == .bundleID)
    #expect(byPath[plist.lastPathComponent]?.confidence == .high)
    #expect(byPath[group.lastPathComponent]?.reason == .bundleID)
    #expect(byPath[named.lastPathComponent]?.reason == .name)
    #expect(byPath[named.lastPathComponent]?.confidence == .medium)
    // Another app of vendor "example" is still installed: shared folder, warning, not preselected.
    #expect(byPath[vendor.lastPathComponent]?.reason == .vendor)
    #expect(byPath[vendor.lastPathComponent]?.sharedWith == ["Foo Bar Pro"])
    #expect(byPath[vendor.lastPathComponent]?.preselected == false)
    #expect(byPath[plist.lastPathComponent]?.preselected == true)
    #expect(byPath[plist.lastPathComponent]?.loaded == nil)
    // Longer ids may be another app (Chrome vs Chrome for Testing): listed, low, never preselected.
    #expect(byPath[helper.lastPathComponent]?.confidence == .low)
    #expect(byPath[helper.lastPathComponent]?.preselected == false)
    #expect(byPath[group.lastPathComponent]?.confidence == .high)
}

@Test func leftoversVendorFolderPreselectedWhenNoOtherVendorApps() throws {
    let f = try Fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    try f.make(f.support, "Example", folder: true)
    let hits = Leftovers.scan(LeftoverQuery(bundleID: "com.example.foobar", name: "Foo Bar"), installed: [app("Foo Bar", "com.example.foobar")], roots: f.roots)
    #expect(hits.count == 1)
    #expect(hits.first?.sharedWith == [])
    #expect(hits.first?.preselected == true)
}

@Test func leftoversIgnoreShortAndGenericNames() throws {
    let f = try Fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    try f.make(f.support, "Go", folder: true)
    try f.make(f.support, "Notes", folder: true)
    #expect(Leftovers.scan(LeftoverQuery(bundleID: nil, name: "Go"), installed: [], roots: f.roots).isEmpty)
    #expect(Leftovers.scan(LeftoverQuery(bundleID: nil, name: "Notes"), installed: [], roots: f.roots).isEmpty)
}

@Test func leftoversMarkSystemAndLaunchAgents() throws {
    let f = try Fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let agent = f.agents.appendingPathComponent("com.example.foobar.agent.plist")
    try PropertyListSerialization.data(fromPropertyList: ["Label": "com.example.macjanitor-test.agent"], format: .xml, options: 0).write(to: agent)
    try f.make(f.system, "com.example.foobar", folder: true)
    let hits = Leftovers.scan(LeftoverQuery(bundleID: "com.example.foobar", name: nil), installed: [], roots: f.roots)
    let launch = try #require(hits.first { $0.url.lastPathComponent == agent.lastPathComponent })
    #expect(launch.launchTarget == "gui/\(getuid())/com.example.macjanitor-test.agent")
    #expect(launch.loaded == false)
    let admin = try #require(hits.first { $0.needsAdmin })
    #expect(admin.preselected == false)
}

@Test func leftoversLaunchLabelFallsBackToFileName() throws {
    let f = try Fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let labelled = f.agents.appendingPathComponent("a.plist")
    try PropertyListSerialization.data(fromPropertyList: ["Label": "com.example.job"], format: .xml, options: 0).write(to: labelled)
    let broken = try f.make(f.agents, "com.example.other.plist")
    #expect(Leftovers.launchLabel(of: labelled) == "com.example.job")
    #expect(Leftovers.launchLabel(of: broken) == "com.example.other")
}

@Test func leftoversOrphansOnlyUnknownReverseDNS() throws {
    let f = try Fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let gone = try f.make(f.prefs, "com.gone.app.plist")
    try f.make(f.prefs, "com.apple.finder.plist")
    try f.make(f.prefs, "com.example.foobar.plist")       // installed app
    try f.make(f.prefs, "com.example.updater.plist")      // vendor still installed
    try f.make(f.support, "Gone Vendor", folder: true)    // not reverse-DNS: skipped
    let orphans = Leftovers.orphans(installed: [app("Foo Bar", "com.example.foobar")], roots: f.roots)
    #expect(orphans.map(\.url.lastPathComponent) == [gone.lastPathComponent])
    #expect(orphans.first?.confidence == .low)
    #expect(orphans.first?.preselected == false)
}

@Test func leftoversRemoveOnlyListedPathsInsideRoots() throws {
    let f = try Fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let plist = try f.make(f.prefs, "com.example.foobar.plist")
    let system = try f.make(f.system, "com.example.foobar", folder: true)
    let unrelated = try f.make(f.prefs, "com.other.thing.plist")
    let hits = Leftovers.scan(LeftoverQuery(bundleID: "com.example.foobar", name: nil), installed: [], roots: f.roots)
    // Roots changed since the scan: the path is no longer inside a search folder.
    let moved = Leftovers.remove([plist], from: hits, roots: [], permanent: true)
    #expect(moved.first?.status.hasPrefix("refused") == true)
    let results = Leftovers.remove([plist, system, unrelated], from: hits, roots: f.roots, permanent: true)
    #expect(results[0].status == "deleted")
    #expect(results[1].status.contains("requires administrator rights, remove manually: \(system.path)"))
    #expect(results[2].status == "refused: not in the leftover list")
    #expect(!FileManager.default.fileExists(atPath: plist.path))
    #expect(FileManager.default.fileExists(atPath: system.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
}
