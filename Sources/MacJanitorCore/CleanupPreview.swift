import Foundation

public struct CleanupDefinition: Sendable {
    public enum Kind: Sendable { case folder(URL, skipping: Set<String>), simulators }
    public let id: String
    public let title: String
    public let kind: Kind
    public let indent: Bool
}

public enum CleanupCatalog {
    public static func categories(home: URL) -> [CleanupDefinition] {
        func folder(_ id: String, _ title: String, _ path: String, skipping: Set<String> = [], indent: Bool = false) -> CleanupDefinition {
            CleanupDefinition(id: id, title: title, kind: .folder(home.appendingPathComponent(path), skipping: skipping), indent: indent)
        }
        return [
            folder("logs", "Журнали (~/Library/Logs)", "Library/Logs"),
            folder("caches", "Кеші (~/Library/Caches)", "Library/Caches", skipping: ["Homebrew"]),
            folder("brew", "Кеш Homebrew", "Library/Caches/Homebrew", indent: true),
            folder("derived", "Xcode DerivedData", "Library/Developer/Xcode/DerivedData"),
            folder("simcache", "Кеші CoreSimulator", "Library/Developer/CoreSimulator/Caches"),
            CleanupDefinition(id: "simunavail", title: "Недоступні симулятори (xcrun simctl delete unavailable)", kind: .simulators, indent: false),
            folder("npm", "Кеш npm (~/.npm/_cacache)", ".npm/_cacache"),
            folder("cargo", "Кеш cargo (~/.cargo/registry/cache)", ".cargo/registry/cache"),
            folder("trash", "Корзина (~/.Trash) — завжди назавжди", ".Trash"),
        ]
    }
}

public struct CleanupPreviewEntry: Sendable {
    public let category: String
    public let path: URL
    public let size: Int64?
    public let status: String
}

public enum CleanupPreview {
    public static func scan(home: URL, categoryIDs: Set<String>) async throws -> [CleanupPreviewEntry] {
        var rows: [CleanupPreviewEntry] = []
        let policy = StoragePolicy(home: home)
        for category in CleanupCatalog.categories(home: home) where categoryIDs.contains(category.id) {
            switch category.kind {
            case .simulators:
                rows.append(CleanupPreviewEntry(category: category.id, path: home.appendingPathComponent("Library/Developer/CoreSimulator"), size: nil, status: "unavailable: simulator cleanup cannot be previewed"))
            case .folder(let folder, let skipping):
                let entries: [URL]
                do { entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) }
                catch {
                    rows.append(CleanupPreviewEntry(category: category.id, path: folder, size: nil, status: "unavailable or missing"))
                    continue
                }
                if entries.allSatisfy({ skipping.contains($0.lastPathComponent) }) {
                    rows.append(CleanupPreviewEntry(category: category.id, path: folder, size: 0, status: "empty"))
                }
                for entry in entries.sorted(by: { $0.path < $1.path }) where !skipping.contains(entry.lastPathComponent) {
                    guard policy.canDelete(entry) else {
                        rows.append(CleanupPreviewEntry(category: category.id, path: entry, size: nil, status: "protected: skipped"))
                        continue
                    }
                    let node = try await StorageScanner().scan(entry)
                    func incomplete(_ node: StorageNode) -> Bool {
                        node.inaccessible || (node.children ?? []).contains(where: incomplete)
                    }
                    rows.append(CleanupPreviewEntry(category: category.id, path: entry, size: node.inaccessible ? nil : node.size, status: incomplete(node) ? "incomplete" : "complete"))
                }
            }
        }
        return rows
    }
}
