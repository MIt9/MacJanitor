import Foundation

public struct StoragePolicy: Sendable {
    let home: URL
    public init(home: URL) { self.home = home }
    private var allowedLibrary: [String] { ["Logs", "Caches", "Developer/Xcode/DerivedData", "Developer/CoreSimulator/Caches"] }
    public func canDelete(_ url: URL) -> Bool {
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(homePath + "/") else { return false }
        let library = homePath + "/Library"
        guard path == library || path.hasPrefix(library + "/") else { return true }
        // Only contents of whitelisted folders, never the folders themselves.
        return allowedLibrary.contains { path.hasPrefix(library + "/" + $0 + "/") }
    }
}
