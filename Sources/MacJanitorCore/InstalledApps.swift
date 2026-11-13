import Foundation
import AppKit
import CoreServices
import Darwin

public struct InstalledApp: Sendable, Equatable, Identifiable {
    public let url: URL
    public let name: String
    public let bundleIdentifier: String?
    public let version: String?
    public var sizeBytes: Int64?
    public let lastLaunchDate: Date?
    /// System or SIP-protected application that must not be removed.
    public let isProtected: Bool
    public var id: String { url.path }

    public init(url: URL, name: String, bundleIdentifier: String?, version: String?, sizeBytes: Int64?, lastLaunchDate: Date?, isProtected: Bool) {
        self.url = url
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.sizeBytes = sizeBytes
        self.lastLaunchDate = lastLaunchDate
        self.isProtected = isProtected
    }
}

public enum InstalledAppSort: String, Sendable, CaseIterable {
    case name, size, lastUsed = "last-used"
}

public enum InstalledApps {
    public static func applications(home: URL, measureSizes: Bool = true) -> [InstalledApp] {
        var discovered: [InstalledApp] = []
        for location in installLocations(home: home) {
            discovered.append(contentsOf: apps(in: location, measureSizes: measureSizes))
        }
        var seen = Set<String>()
        return discovered.sorted { $0.name < $1.name }.filter { seen.insert($0.bundleIdentifier ?? $0.url.path).inserted }
    }

    public static func installLocations(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    public static func apps(in directory: URL, measureSizes: Bool = true) -> [InstalledApp] {
        // Not .skipsHiddenFiles: /Applications/Safari.app is a symlink with the UF_HIDDEN flag.
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension.lowercased() == "app" && !$0.lastPathComponent.hasPrefix(".") }.compactMap { app(at: $0, measureSize: measureSizes) }.sorted { $0.name < $1.name }
    }

    public static func app(at url: URL, measureSize: Bool = true) -> InstalledApp? {
        guard url.pathExtension.lowercased() == "app" else { return nil }
        let resolved = target(of: url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let plist = NSDictionary(contentsOf: resolved.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else { return nil }
        let name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let bundleIdentifier = plist["CFBundleIdentifier"] as? String
        return InstalledApp(url: url, name: name, bundleIdentifier: bundleIdentifier, version: plist["CFBundleShortVersionString"] as? String,
                            sizeBytes: measureSize ? realSize(of: url) : nil,
                            lastLaunchDate: [lastUsedDate(of: resolved), lastLaunchDate(for: bundleIdentifier)].compactMap { $0 }.max(),
                            isProtected: isProtected(url: url, bundleIdentifier: bundleIdentifier))
    }

    /// Follows symbolic links and Finder aliases to the real bundle.
    public static func target(of url: URL) -> URL {
        ((try? URL(resolvingAliasFileAt: url, options: [.withoutUI, .withoutMounting])) ?? url).resolvingSymlinksInPath()
    }

    /// Size of the real application: the alias/symlink target, plus whatever the bundle's executable
    /// links to outside the bundle (launcher stubs such as Autodesk Fusion's webdeploy shim).
    public static func realSize(of url: URL) -> Int64? {
        let bundle = target(of: url)
        guard var total = size(of: bundle) else { return nil }
        if let external = externalExecutableTarget(of: bundle) { total += size(of: external) ?? 0 }
        return total
    }

    /// Enclosing `.app` (or the file itself) that the bundle's executable symlinks to outside the bundle.
    static func externalExecutableTarget(of bundle: URL) -> URL? {
        guard let plist = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let executable = plist["CFBundleExecutable"] as? String else { return nil }
        let link = bundle.appendingPathComponent("Contents/MacOS/\(executable)")
        guard (try? link.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { return nil }
        let resolved = link.resolvingSymlinksInPath()
        guard !resolved.path.hasPrefix(bundle.path + "/") else { return nil }
        var candidate = resolved
        while candidate.path != "/" {
            if candidate.pathExtension.lowercased() == "app" { return candidate }
            candidate.deleteLastPathComponent()
        }
        return resolved
    }

    /// Allocated bytes of a file or directory tree; symlinks are not followed.
    public static func size(of url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let own = try? url.resourceValues(forKeys: keys) else { return nil }
        var total = Int64(own.totalFileAllocatedSize ?? own.fileAllocatedSize ?? 0)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return total }
        for case let file as URL in enumerator {
            if let values = try? file.resourceValues(forKeys: keys) { total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) }
        }
        return total
    }

    public static func isProtected(url: URL, bundleIdentifier: String?) -> Bool {
        let resolved = target(of: url).path
        if url.path.hasPrefix("/System/") || resolved.hasPrefix("/System/") { return true }
        if bundleIdentifier?.lowercased().hasPrefix("com.apple.") == true { return true }
        var info = stat()
        return lstat(resolved, &info) == 0 && info.st_flags & UInt32(SF_RESTRICTED) != 0
    }

    public static func select(_ apps: [InstalledApp], search: String = "", sort: InstalledAppSort) -> [InstalledApp] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        // Unknown sizes and dates sort last.
        switch sort {
        case .name: return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: return matching.sorted { ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
        case .lastUsed: return matching.sorted { ($0.lastLaunchDate ?? .distantPast) > ($1.lastLaunchDate ?? .distantPast) }
        }
    }

    /// Spotlight's last-used date; nil when Spotlight has no record.
    public static func lastUsedDate(of url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    public static func lastLaunchDate(for bundleIdentifier: String?) -> Date? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleIdentifier }?.launchDate
    }
}
