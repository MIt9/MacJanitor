import SwiftUI

struct CleanupCategory: Identifiable, Sendable {
    enum Kind: Sendable { case folder(URL, skipping: Set<String>), simulators }
    let id: String
    let title: String
    let kind: Kind
    var indent = false
    var size: Int64?
    var measured = false
    var isTrash: Bool { if case .folder(let u, _) = kind { return u.lastPathComponent == ".Trash" }; return false }

    static func all(home: URL) -> [CleanupCategory] {
        func f(_ id: String, _ title: String, _ path: String, skipping: Set<String> = [], indent: Bool = false) -> CleanupCategory {
            CleanupCategory(id: id, title: title, kind: .folder(home.appendingPathComponent(path), skipping: skipping), indent: indent)
        }
        return [
            f("logs", "Журнали (~/Library/Logs)", "Library/Logs"),
            f("caches", "Кеші (~/Library/Caches)", "Library/Caches", skipping: ["Homebrew"]),
            f("brew", "Кеш Homebrew", "Library/Caches/Homebrew", indent: true),
            f("derived", "Xcode DerivedData", "Library/Developer/Xcode/DerivedData"),
            f("simcache", "Кеші CoreSimulator", "Library/Developer/CoreSimulator/Caches"),
            CleanupCategory(id: "simunavail", title: "Недоступні симулятори (xcrun simctl delete unavailable)", kind: .simulators),
            f("npm", "Кеш npm (~/.npm/_cacache)", ".npm/_cacache"),
            f("cargo", "Кеш cargo (~/.cargo/registry/cache)", ".cargo/registry/cache"),
            f("trash", "Корзина (~/.Trash) — завжди назавжди", ".Trash"),
        ]
    }

    func measure() async -> Int64? {
        guard case .folder(let url, let skipping) = kind else { return nil }
        guard let node = try? await StorageScanner().scan(url), !node.inaccessible else { return nil }
        return (node.children ?? []).filter { !skipping.contains($0.url.lastPathComponent) }.reduce(0) { $0 + $1.size }
    }

    /// Returns the number of entries that could not be removed.
    func clean(permanent: Bool, policy: StoragePolicy) async -> Int {
        switch kind {
        case .simulators:
            return await Task.detached { () -> Int in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                p.arguments = ["simctl", "delete", "unavailable"]
                do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 ? 0 : 1 } catch { return 1 }
            }.value
        case .folder(let url, let skipping):
            let forever = permanent || isTrash
            return await Task.detached { () -> Int in
                let fm = FileManager.default
                guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return 1 }
                var failed = 0
                for e in entries where !skipping.contains(e.lastPathComponent) {
                    guard policy.canDelete(e) else { failed += 1; continue }
                    do { if forever { try fm.removeItem(at: e) } else { try fm.trashItem(at: e, resultingItemURL: nil) } }
                    catch { failed += 1 }
                }
                return failed
            }.value
        }
    }
}

struct StorageCleanupView: View {
    let home: URL
    @State private var cats: [CleanupCategory]
    @State private var checked = Set<String>()
    @State private var permanent = false
    @State private var confirm = false
    @State private var busy = false
    @State private var message: String?

    init(home: URL) { self.home = home; _cats = State(initialValue: CleanupCategory.all(home: home)) }

    private var needsConfirm: Bool { permanent || cats.contains { checked.contains($0.id) && $0.isTrash } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(cats) { c in
                Toggle(isOn: Binding(get: { checked.contains(c.id) }, set: { if $0 { checked.insert(c.id) } else { checked.remove(c.id) } })) {
                    HStack {
                        Text(c.title)
                        Spacer()
                        if case .simulators = c.kind {} else if !c.measured { Text("…").foregroundStyle(.secondary) }
                        else if let s = c.size { Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)) }
                        else { Text("немає доступу").foregroundStyle(.secondary) }
                    }
                }.padding(.leading, c.indent ? 24 : 0)
            }
            HStack {
                Toggle("Видалити назавжди", isOn: $permanent)
                Spacer()
                Button("Оновити розміри") { Task { await measure() } }.disabled(busy)
                Button("Очистити вибране") { needsConfirm ? (confirm = true) : run() }.disabled(busy || checked.isEmpty)
            }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .task { await measure() }
        .confirmationDialog("Видалити вибране назавжди? Це не можна скасувати.", isPresented: $confirm) {
            Button("Видалити назавжди", role: .destructive, action: run)
            Button("Скасувати", role: .cancel) {}
        }
    }

    private func measure() async {
        busy = true
        for i in cats.indices {
            let c = cats[i]
            let s = await c.measure()
            cats[i].size = s
            cats[i].measured = true
        }
        busy = false
    }

    private func run() {
        busy = true
        message = nil
        let selected = cats.filter { checked.contains($0.id) }
        let forever = permanent
        Task {
            var failed = 0
            for c in selected { failed += await c.clean(permanent: forever, policy: StoragePolicy(home: home)) }
            message = failed == 0 ? "Готово." : "Не вдалося видалити елементів: \(failed)."
            checked.removeAll()
            await measure()
        }
    }
}
