import Foundation

enum FullDiskAccess {
    /// Listing a TCC-protected folder fails without Full Disk Access.
    static func isGranted(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let probes = ["Library/Safari", "Library/Mail"].map { home.appendingPathComponent($0) }
        return probes.contains { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) != nil }
    }
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

