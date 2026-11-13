import Foundation
import AppKit

public struct InstalledApp: Sendable, Equatable {
    public let name: String
    public let bundleIdentifier: String?
    public let version: String?
    public let sizeBytes: Int64?
    public let lastLaunchDate: Date?

    public init(name: String, bundleIdentifier: String?, version: String?, sizeBytes: Int64?, lastLaunchDate: Date?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.sizeBytes = sizeBytes
        self.lastLaunchDate = lastLaunchDate
    }
}

public enum InstalledApps {
    public static func applications(home: URL) -> [InstalledApp] {
        var discovered: [InstalledApp] = []
        let fileManager = FileManager.default
        for location in installLocations(home: home) where fileManager.fileExists(atPath: location.path) {
            discovered.append(contentsOf: apps(in: location))
        }
        var seen = Set<String>()
        var unique: [InstalledApp] = []
        for app in discovered.sorted(by: { $0.name < $1.name }) {
            let key = app.bundleIdentifier ?? app.name
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(app)
        }
        return unique
    }

    public static func installLocations(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    public static func apps(in directory: URL) -> [InstalledApp] {
        let fileManager = FileManager.default
        let entries: [URL]
        do { entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey], options: [.skipsHiddenFiles]) }
        catch { return [] }
        return entries.filter { $0.pathExtension.lowercased() == "app" }.compactMap { app(at: $0) }.sorted { $0.name < $1.name }
    }

    public static func app(at url: URL) -> InstalledApp? {
        guard url.pathExtension.lowercased() == "app" else { return nil }
        let resolved = url.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let infoURL = resolved.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOfFile: infoURL.path) as? [String: Any] else { return nil }
        let name = ((plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? (resolved.lastPathComponent as NSString).deletingPathExtension)
        let bundleIdentifier = plist["CFBundleIdentifier"] as? String
        return InstalledApp(name: name, bundleIdentifier: bundleIdentifier, version: plist["CFBundleShortVersionString"] as? String, sizeBytes: size(of: resolved), lastLaunchDate: lastLaunchDate(for: bundleIdentifier))
    }

    public static func size(of url: URL) -> Int64? {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey], options: [.skipsHiddenFiles]) else { return nil }
        for item in enumerator {
            if let file = item as? URL {
                let values = (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])) ?? nil
                if let allocated = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize { total += Int64(allocated) }
            }
        }
        return total
    }

    public static func lastLaunchDate(for bundleIdentifier: String?) -> Date? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleIdentifier }?.launchDate
    }
}
