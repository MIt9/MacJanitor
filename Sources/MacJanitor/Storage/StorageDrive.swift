import SwiftUI
import MacJanitorCore
import AppKit
import Observation

enum Drive {
    static func locate(home: URL) -> URL? {
        let fm = FileManager.default
        let base = home.appendingPathComponent("Library/CloudStorage")
        let dirs = ((try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("GoogleDrive-") }.sorted { $0.path < $1.path }
        guard let first = dirs.first else { return nil }
        for name in ["My Drive", "Мій диск"] {
            let u = first.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { return u }
        }
        return first
    }

    static func isFileProvider(_ root: URL, home: URL) -> Bool {
        root.standardizedFileURL.path.hasPrefix(home.standardizedFileURL.path + "/Library/CloudStorage/")
    }

    static func isInside(_ url: URL, root: URL) -> Bool {
        let p = url.standardizedFileURL.path, r = root.standardizedFileURL.path
        return p == r || p.hasPrefix(r + "/")
    }

    /// true = everything uploaded, false = still pending, nil = status not reported.
    static func uploadState(_ url: URL) -> Bool? {
        let keys: Set<URLResourceKey> = [.ubiquitousItemIsUploadedKey, .isUbiquitousItemKey, .isDirectoryKey]
        var all = [url]
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) { all += e.compactMap { $0 as? URL } }
        var pending = false
        for u in all {
            guard let v = try? u.resourceValues(forKeys: keys) else { return nil }
            if v.isDirectory == true && u != url { continue }
            guard v.isUbiquitousItem == true, let up = v.ubiquitousItemIsUploaded else { return nil }
            if !up { pending = true }
        }
        return !pending
    }

    static func openApp() {
        let ws = NSWorkspace.shared
        if let u = ws.urlForApplication(withBundleIdentifier: "com.google.drivefs") ?? ws.urlForApplication(toOpen: URL(fileURLWithPath: "/Applications/Google Drive.app")) {
            ws.openApplication(at: u, configuration: .init())
        }
    }
}

@MainActor @Observable final class DriveTransfers {
    enum Status: Equatable {
        case copying, uploading, done, trashed, unknown, failed(String)
        var text: String {
            switch self {
            case .copying: "копіювання…"
            case .uploading: "очікування завантаження на Drive…"
            case .done: "скопійовано"
            case .trashed: "перенесено, оригінал у Корзині"
            case .unknown: "статус завантаження невідомий"
            case .failed(let m): "помилка: \(m)"
            }
        }
    }
    struct Item: Identifiable { let id = UUID(); let source: URL; let dest: URL; let move: Bool; var status: Status }

    var items: [Item] = []
    var mirror = false
    let home = FileManager.default.homeDirectoryForCurrentUser
    var pollSeconds = 600

    func enqueue(_ source: URL, into folder: URL, root: URL, move: Bool) {
        let dest = folder.appendingPathComponent(source.lastPathComponent)
        items.append(Item(source: source, dest: dest, move: move, status: .copying))
        let id = items[items.count - 1].id
        if !Drive.isFileProvider(root, home: home) { mirror = true }
        Task {
            if !Drive.isInside(folder, root: root) { return set(id, .failed("поза папкою Drive")) }
            if move && !StoragePolicy(home: home).canDelete(source) { return set(id, .failed("захищений шлях, перенесення заборонено")) }
            do {
                try await Task.detached { () throws in
                    if FileManager.default.fileExists(atPath: dest.path) { throw CocoaError(.fileWriteFileExists) }
                    try FileManager.default.copyItem(at: source, to: dest)
                }.value
            } catch { return set(id, .failed(error.localizedDescription)) }
            if (try? dest.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == false { mirror = true }
            guard move else { return set(id, .done) }
            set(id, .uploading)
            var waited = 0
            while true {
                let state = await Task.detached { Drive.uploadState(dest) }.value
                if state == true { return trashOriginal(id) }
                if state == nil || waited >= pollSeconds { return set(id, .unknown) }
                try? await Task.sleep(for: .seconds(3))
                waited += 3
            }
        }
    }

    func trashOriginal(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let src = items[i].source
        guard StoragePolicy(home: home).canDelete(src) else { return set(id, .failed("захищений шлях")) }
        do { try FileManager.default.trashItem(at: src, resultingItemURL: nil); set(id, .trashed) }
        catch { set(id, .failed(error.localizedDescription)) }
    }

    private func set(_ id: UUID, _ s: Status) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].status = s }
    }
}

struct StorageDriveView: View {
    let selected: URL?
    var onTrashed: (URL) -> Void
    @State private var transfers = DriveTransfers()
    @State private var root: URL?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let root { Text("Google Drive: \(root.path)").font(.caption).foregroundStyle(.secondary) }
            else { Text("Google Drive не знайдено в ~/Library/CloudStorage. Встановіть Google Drive для комп'ютера та увійдіть в акаунт.").foregroundStyle(.secondary) }
            HStack {
                Button("Перенести на Drive") { start(move: true) }
                Button("Копіювати на Drive") { start(move: false) }
                if let selected { Text(selected.lastPathComponent).foregroundStyle(.secondary).lineLimit(1) }
                else { Text("Виберіть файл або папку у списку.").foregroundStyle(.secondary) }
            }.disabled(root == nil || selected == nil)
            if let error { Text(LocalizedStringKey(error)).foregroundStyle(.red) }
            if transfers.mirror {
                HStack {
                    Text("Схоже, Drive працює в режимі Mirror: перенесення не звільнить місце на диску.").foregroundStyle(.orange)
                    Button("Відкрити Google Drive", action: Drive.openApp)
                }
            }
            ForEach(transfers.items) { item in
                HStack {
                    Text("\(Text(LocalizedStringKey(item.move ? "Перенесення" : "Копія"))): \(item.source.lastPathComponent)").lineLimit(1)
                    Spacer()
                    Text(LocalizedStringKey(item.status.text)).foregroundStyle(.secondary)
                    if item.status == .unknown && item.move {
                        Button("Видалити оригінал") { transfers.trashOriginal(item.id) }
                    }
                }
            }
        }
        .onAppear { root = Drive.locate(home: transfers.home) }
        .onChange(of: transfers.items.map(\.status)) { _, _ in
            for item in transfers.items where item.status == .trashed { onTrashed(item.source) }
        }
    }

    private func start(move: Bool) {
        guard let root, let selected else { return }
        error = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = root
        panel.prompt = "Вибрати"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        guard Drive.isInside(folder, root: root) else { error = "Оберіть папку всередині Google Drive."; return }
        transfers.enqueue(selected, into: folder, root: root, move: move)
    }
}
