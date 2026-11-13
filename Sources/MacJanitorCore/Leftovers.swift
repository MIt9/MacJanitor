import Foundation
import Darwin

/// A folder searched for leftovers. Only its direct children are candidates.
public struct LeftoverRoot: Sendable, Equatable {
    public let url: URL
    /// System `/Library/...` folder: entries need administrator rights and are never removed by this app.
    public let needsAdmin: Bool
    /// launchd domain for LaunchAgents/LaunchDaemons folders (`gui/<uid>` or `system`), else nil.
    public let launchDomain: String?

    public init(url: URL, needsAdmin: Bool, launchDomain: String? = nil) {
        self.url = url
        self.needsAdmin = needsAdmin
        self.launchDomain = launchDomain
    }
}

/// What to look for: a removed or selected app.
public struct LeftoverQuery: Sendable, Equatable {
    public let bundleID: String?
    public let name: String?
    public let vendor: String?

    /// Vendor heuristic: the second component of a reverse-DNS bundle id with at least three components
    /// (`com.autodesk.fusion` → `autodesk`). Two-component ids (`com.foo`) have no separate vendor.
    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID?.lowercased()
        self.name = name
        let parts = bundleID?.lowercased().split(separator: ".") ?? []
        vendor = parts.count >= 3 ? String(parts[1]) : nil
    }

    public init(app: InstalledApp) { self.init(bundleID: app.bundleIdentifier, name: app.name) }
}

public struct Leftover: Sendable, Equatable {
    public enum Reason: String, Sendable { case bundleID, name, vendor, orphan }
    public enum Confidence: String, Sendable { case high, medium, low }
    public let url: URL
    public let sizeBytes: Int64?
    public let reason: Reason
    public let confidence: Confidence
    public let needsAdmin: Bool
    /// Names of other installed apps from the same vendor: a shared vendor folder, shown with a warning.
    public let sharedWith: [String]
    /// `domain/label` for launchd plists, else nil.
    public let launchTarget: String?
    /// Whether the launchd job is loaded; nil for non-launchd items.
    public let loaded: Bool?
    public var preselected: Bool { confidence != .low && sharedWith.isEmpty && !needsAdmin }
}

public enum Leftovers {
    public static func roots(home: URL) -> [LeftoverRoot] {
        let library = home.appendingPathComponent("Library")
        let user = ["Application Support", "Caches", "Preferences", "Containers", "Group Containers", "Saved Application State",
                    "Logs", "HTTPStorages", "WebKit"].map { LeftoverRoot(url: library.appendingPathComponent($0), needsAdmin: false) }
        let gui = "gui/\(getuid())"
        return user + [
            LeftoverRoot(url: library.appendingPathComponent("LaunchAgents"), needsAdmin: false, launchDomain: gui),
            LeftoverRoot(url: URL(fileURLWithPath: "/Library/Application Support"), needsAdmin: true),
            LeftoverRoot(url: URL(fileURLWithPath: "/Library/LaunchAgents"), needsAdmin: true, launchDomain: gui),
            LeftoverRoot(url: URL(fileURLWithPath: "/Library/LaunchDaemons"), needsAdmin: true, launchDomain: "system"),
            LeftoverRoot(url: URL(fileURLWithPath: "/Library/PrivilegedHelperTools"), needsAdmin: true),
        ]
    }

    /// Leftovers of one app. `installed` may include the app itself; it is excluded by bundle id (or name).
    /// - bundle id: the entry's reverse-DNS name equals the id (high: `<id>.plist`, `<id>.savedState`, `TEAMID.<id>`,
    ///   `group.<id>`) or extends it (low: `<id>.helper`, may be another app), unless it belongs to another installed app's longer id.
    /// - name (medium): the whole entry name equals the app name, ignoring case and punctuation.
    /// - vendor (medium): a folder named after the vendor, or a reverse-DNS entry of the vendor that is not another
    ///   installed app's; if other apps of the vendor are still installed it is a shared folder (warning, not preselected).
    public static func scan(_ query: LeftoverQuery, installed: [InstalledApp], roots: [LeftoverRoot]) -> [Leftover] {
        let others = installed.filter { app in
            if let id = query.bundleID { return app.bundleIdentifier?.lowercased() != id }
            return app.name != query.name
        }
        let otherIDs = others.compactMap { $0.bundleIdentifier?.lowercased() }
        let sharedWith = query.vendor.map { vendor in others.filter { LeftoverQuery(app: $0).vendor == vendor }.map(\.name).sorted() } ?? []
        let name = query.name.map(normalized).flatMap { isSpecific($0) ? $0 : nil }
        return entries(in: roots).compactMap { root, url in
            let entry = url.lastPathComponent
            let dns = reverseDNS(entry)
            let ownedByOther = dns.map { dns in otherIDs.contains { $0 != query.bundleID && extends(dns, $0) && $0.count > (query.bundleID?.count ?? 0) } } ?? false
            if let id = query.bundleID, let dns, extends(dns, id), !ownedByOther {
                // Only the exact id is high: `com.google.chrome.for.testing` extends `com.google.chrome` but is another app.
                return leftover(url, root, .bundleID, dns == id ? .high : .low)
            }
            if let name, normalized(stripSuffix(entry)) == name { return leftover(url, root, .name, .medium) }
            if let vendor = query.vendor {
                let dnsVendor = dns.map { d in d.split(separator: ".")[1] == vendor && !otherIDs.contains { extends(d, $0) } } ?? false
                let folderVendor = isSpecific(vendor) && normalized(stripSuffix(entry)) == vendor
                if dnsVendor || folderVendor { return leftover(url, root, .vendor, .medium, sharedWith: sharedWith) }
            }
            return nil
        }
    }

    /// Reverse-DNS entries whose bundle id and vendor match no installed app. Always low confidence.
    /// ponytail: only reverse-DNS names (`com.vendor.app…`) are considered; plain-named vendor folders such as
    /// `Application Support/Autodesk` are skipped because there is no reliable way to tell them from system folders.
    public static func orphans(installed: [InstalledApp], roots: [LeftoverRoot]) -> [Leftover] {
        let ids = installed.compactMap { $0.bundleIdentifier?.lowercased() }
        let vendors = Set(installed.compactMap { LeftoverQuery(app: $0).vendor })
        let skipped = ["com.apple.", "homebrew.", "org.cups.", "org.openbsd.", "org.macosforge."]
        return entries(in: roots).compactMap { root, url in
            guard let dns = reverseDNS(url.lastPathComponent), !skipped.contains(where: dns.hasPrefix),
                  !vendors.contains(String(dns.split(separator: ".")[1])),
                  !ids.contains(where: { extends(dns, $0) || extends($0, dns) }) else { return nil }
            return leftover(url, root, .orphan, .low)
        }
    }

    /// Removes only paths present in `leftovers`, after re-checking that each is still a direct child of one of `roots`.
    /// System (admin) roots are refused, launchd jobs are booted out first. Links are removed as links.
    public static func remove(_ paths: [URL], from leftovers: [Leftover], roots: [LeftoverRoot], permanent: Bool) -> [AppRemovalResult] {
        paths.map { path in
            let path = path.standardizedFileURL
            guard let item = leftovers.first(where: { $0.url.standardizedFileURL.path == path.path }) else {
                return AppRemovalResult(url: path, status: "refused: not in the leftover list")
            }
            let parent = path.deletingLastPathComponent().resolvingSymlinksInPath().path
            guard let root = roots.first(where: { $0.url.resolvingSymlinksInPath().path == parent }) else {
                return AppRemovalResult(url: path, status: "refused: outside the leftover search folders")
            }
            if root.needsAdmin || item.needsAdmin {
                return AppRemovalResult(url: path, status: "refused: requires administrator rights, remove manually: \(path.path)")
            }
            var info = stat()
            guard lstat(path.path, &info) == 0 else { return AppRemovalResult(url: path, status: "failed: no longer exists") }
            if let target = item.launchTarget, isLoaded(target) {
                let code = launchctl(["bootout", target])
                guard code == 0 else { return AppRemovalResult(url: path, status: "failed: launchctl bootout exited \(code)") }
            }
            do {
                if permanent { try FileManager.default.removeItem(at: path) }
                else { try FileManager.default.trashItem(at: path, resultingItemURL: nil) }
                return AppRemovalResult(url: path, status: permanent ? "deleted" : "trashed")
            } catch {
                return AppRemovalResult(url: path, status: "failed: \(error.localizedDescription)")
            }
        }
    }

    /// launchd label of a job plist: its `Label` key, else the file name without `.plist`.
    public static func launchLabel(of plist: URL) -> String {
        (NSDictionary(contentsOf: plist)?["Label"] as? String) ?? plist.deletingPathExtension().lastPathComponent
    }

    public static func isLoaded(_ target: String) -> Bool { launchctl(["print", target]) == 0 }

    /// The only place launchctl is run; output is discarded, the exit status is the answer.
    @discardableResult static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Matching helpers

    private static func entries(in roots: [LeftoverRoot]) -> [(LeftoverRoot, URL)] {
        roots.flatMap { root in
            ((try? FileManager.default.contentsOfDirectory(at: root.url, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.path < $1.path }
                .map { (root, $0) }
        }
    }

    private static func leftover(_ url: URL, _ root: LeftoverRoot, _ reason: Leftover.Reason, _ confidence: Leftover.Confidence, sharedWith: [String] = []) -> Leftover {
        let target = root.launchDomain.flatMap { url.pathExtension == "plist" ? "\($0)/\(launchLabel(of: url))" : nil }
        return Leftover(url: url, sizeBytes: InstalledApps.size(of: url), reason: reason, confidence: confidence, needsAdmin: root.needsAdmin,
                        sharedWith: sharedWith, launchTarget: target, loaded: target.map(isLoaded))
    }

    /// `id` itself or `id.<more>`.
    static func extends(_ dns: String, _ id: String) -> Bool { dns == id || dns.hasPrefix(id + ".") }

    static func stripSuffix(_ entry: String) -> String {
        for suffix in [".plist", ".savedState", ".binarycookies"] where entry.hasSuffix(suffix) { return String(entry.dropLast(suffix.count)) }
        return entry
    }

    /// Lowercased reverse-DNS id of an entry (`TEAMID.com.foo.bar.plist` → `com.foo.bar`), or nil if it is not one.
    static func reverseDNS(_ entry: String) -> String? {
        var parts = stripSuffix(entry).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "group" { parts.removeFirst() }
        if let first = parts.first, first.count == 10, first.allSatisfy({ $0.isUppercase || $0.isNumber }) { parts.removeFirst() }
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty && !$0.contains(" ") }),
              (2...6).contains(parts[0].count), parts[0].allSatisfy(\.isLetter) else { return nil }
        return parts.joined(separator: ".").lowercased()
    }

    static func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// ponytail: name/vendor folder matches need at least 4 characters and must not be a generic word; a short
    /// stoplist, not a dictionary — names like "Notes" or "Go" never match by name, only by bundle id.
    static func isSpecific(_ normalized: String) -> Bool {
        let generic: Set<String> = ["notes", "music", "photos", "mail", "calendar", "contacts", "books", "news", "maps", "home",
                                    "files", "data", "cache", "caches", "logs", "common", "shared", "support", "helper", "helpers",
                                    "updater", "update", "apps", "tools", "system", "library", "preferences", "settings", "default",
                                    "temp", "backup", "backups", "plugins", "crashreporter"]
        return normalized.count >= 4 && !generic.contains(normalized)
    }
}
