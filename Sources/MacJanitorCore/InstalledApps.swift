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

// MARK: - Removal

public enum AppRemovalError: Error, LocalizedError, Equatable {
    case notFound(String), protected(String), outsideApplications(String), running([pid_t])
    public var errorDescription: String? {
        switch self {
        case .notFound(let query): "No installed application matches \(query)."
        case .protected(let path): "\(path) is a protected system application and cannot be removed."
        case .outsideApplications(let path): "\(path) is not inside /Applications or ~/Applications."
        case .running(let pids): "The application is running (PID \(pids.map(String.init).joined(separator: ", "))). Quit it first."
        }
    }
}

public struct AppRemovalItem: Sendable, Equatable {
    public enum Role: String, Sendable {
        /// The `.app` bundle directory inside /Applications or ~/Applications.
        case bundle
        /// A symlink or Finder alias inside /Applications or ~/Applications; removed as a link, never followed.
        case link
        /// A real `.app` bundle the link/alias resolves to, or a launcher stub's executable target, possibly elsewhere.
        case target
    }
    public let url: URL
    public let role: Role
    public let sizeBytes: Int64?
}

public struct AppRemovalPlan: Sendable {
    public let app: InstalledApp
    /// Exactly what gets removed, in order. Nothing else is touched.
    public let items: [AppRemovalItem]
    /// Own uninstallers found next to the app, in its folder or bundle, or in ~/Applications.
    public let uninstallers: [URL]
    public var totalBytes: Int64 { items.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }
}

public struct AppRemovalResult: Sendable {
    public let url: URL
    public let status: String
}

public enum AppRemoval {
    /// Finds an installed app by bundle identifier, or by path to a `.app`.
    public static func find(_ query: String, home: URL) -> InstalledApp? {
        if query.contains("/") || query.lowercased().hasSuffix(".app") {
            return InstalledApps.app(at: URL(fileURLWithPath: NSString(string: query).expandingTildeInPath).standardizedFileURL, measureSize: false)
        }
        return InstalledApps.applications(home: home, measureSizes: false).first { $0.bundleIdentifier == query }
    }

    /// Decides which paths get removed:
    /// - a real bundle: the bundle itself;
    /// - a symlink or Finder alias: the link file itself (never its target implicitly) plus, as a separate
    ///   explicitly listed `.target` item, the `.app` it resolves to;
    /// - a launcher stub whose executable links outside the bundle: also the enclosing external `.app`.
    /// Targets are included only if they are `.app` bundles that are not protected; a bare external binary is left alone.
    /// The app itself must live in /Applications or ~/Applications and must not be protected.
    public static func plan(for app: InstalledApp, home: URL) throws -> AppRemovalPlan {
        let url = app.url.standardizedFileURL
        if app.isProtected || InstalledApps.isProtected(url: url, bundleIdentifier: app.bundleIdentifier) { throw AppRemovalError.protected(url.path) }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let insideLocation = InstalledApps.installLocations(home: home).contains { location in
            let root = location.resolvingSymlinksInPath().path
            return parent == root || parent.hasPrefix(root + "/")
        }
        guard insideLocation, url.pathExtension.lowercased() == "app" else { throw AppRemovalError.outsideApplications(url.path) }
        let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])).map { $0.isSymbolicLink == true || $0.isAliasFile == true } ?? false
        let bundle = InstalledApps.target(of: url)
        var items = [AppRemovalItem(url: url, role: isLink ? .link : .bundle, sizeBytes: InstalledApps.size(of: url))]
        func addTarget(_ target: URL) {
            let target = target.standardizedFileURL
            guard target.pathExtension.lowercased() == "app", !InstalledApps.isProtected(url: target, bundleIdentifier: nil),
                  !items.contains(where: { target.path == $0.url.path || target.path.hasPrefix($0.url.path + "/") }) else { return }
            items.append(AppRemovalItem(url: target, role: .target, sizeBytes: InstalledApps.size(of: target)))
        }
        if isLink { addTarget(bundle) }
        if let external = InstalledApps.externalExecutableTarget(of: bundle) { addTarget(external) }
        return AppRemovalPlan(app: app, items: items, uninstallers: uninstallers(for: url, bundle: bundle, name: app.name, home: home))
    }

    /// `Remove *.app`, `Uninstall *.app`, `*Uninstaller.app`. In shared folders (/Applications, ~/Applications)
    /// the uninstaller name must also mention the app; in the app's own folder or bundle any match counts.
    static func uninstallers(for url: URL, bundle: URL, name: String, home: URL) -> [URL] {
        let shared = Set(InstalledApps.installLocations(home: home).map { $0.resolvingSymlinksInPath().path })
        let names = [name, url.deletingPathExtension().lastPathComponent].map { $0.lowercased() }
        let folders = [url.deletingLastPathComponent(), bundle.deletingLastPathComponent(), bundle.appendingPathComponent("Contents/Resources"),
                       home.appendingPathComponent("Applications")]
        let excluded = Set([url.resolvingSymlinksInPath().path, bundle.path])
        var seen = Set<String>()
        var found: [URL] = []
        for folder in folders {
            let isShared = shared.contains(folder.resolvingSymlinksInPath().path)
            for entry in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                let base = entry.deletingPathExtension().lastPathComponent.lowercased()
                guard entry.pathExtension.lowercased() == "app", !excluded.contains(entry.resolvingSymlinksInPath().path),
                      base.hasPrefix("remove ") || base.hasPrefix("uninstall ") || base.hasSuffix("uninstaller"),
                      !isShared || names.contains(where: { base.contains($0) }),
                      seen.insert(entry.resolvingSymlinksInPath().path).inserted else { continue }
                found.append(entry)
            }
        }
        return found
    }

    /// PIDs of running applications whose bundle id matches or whose bundle is one of the plan's paths.
    public static func runningPIDs(_ plan: AppRemovalPlan) -> [pid_t] {
        let paths = Set(plan.items.map { $0.url.resolvingSymlinksInPath().path })
        return NSWorkspace.shared.runningApplications.filter { running in
            (plan.app.bundleIdentifier != nil && running.bundleIdentifier == plan.app.bundleIdentifier)
                || running.bundleURL.map { paths.contains($0.resolvingSymlinksInPath().path) } == true
        }.map(\.processIdentifier)
    }

    /// Moves the plan's items to Trash (or deletes them with `permanent`). Links are removed as links:
    /// both `trashItem` and `removeItem` act on the link itself, the target goes only via its own `.target` item.
    /// Refuses while the app is running.
    public static func remove(_ plan: AppRemovalPlan, permanent: Bool) throws -> [AppRemovalResult] {
        let running = runningPIDs(plan)
        guard running.isEmpty else { throw AppRemovalError.running(running) }
        return plan.items.map { item in
            do {
                if permanent { try FileManager.default.removeItem(at: item.url) }
                else { try FileManager.default.trashItem(at: item.url, resultingItemURL: nil) }
                return AppRemovalResult(url: item.url, status: permanent ? "deleted" : "trashed")
            } catch {
                return AppRemovalResult(url: item.url, status: "failed: \(error.localizedDescription)")
            }
        }
    }
}
