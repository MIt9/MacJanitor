import SwiftUI
import MacJanitorCore

enum LeftoverMode: Identifiable, Sendable {
    case app(InstalledApp), orphans
    var id: String { if case .app(let app) = self { return app.id }; return "orphans" }
}

/// Leftovers of one app (or orphans): each item with reason and confidence; removal of the checked set only.
struct LeftoversView: View {
    let mode: LeftoverMode
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Leftover] = []
    @State private var checked = Set<String>()
    @State private var scanning = false
    @State private var permanent = false
    @State private var confirmPermanent = false
    @State private var message: LocalizedStringKey?
    @State private var refused: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch mode {
            case .app(let app): Text("Залишки «\(app.name)»").font(.headline)
            case .orphans:
                Text("Осиротілі залишки").font(.headline)
                Text("Елементи, чий bundle id і розробник не відповідають жодній встановленій програмі. Перевірте кожен перед видаленням.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if scanning { ProgressView("Шукаю залишки…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if items.isEmpty { Text("Залишків не знайдено.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                List(items, id: \.url.path) { item in
                    Toggle(isOn: Binding(get: { checked.contains(item.url.path) },
                                         set: { if $0 { checked.insert(item.url.path) } else { checked.remove(item.url.path) } })) {
                        row(item)
                    }
                    .disabled(item.needsAdmin)
                    .contextMenu { Button("Відкрити у Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } }
                }
            }
            if let message { Text(message).foregroundStyle(.secondary) }
            ForEach(refused, id: \.self) { Text($0).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Toggle("Видалити назавжди", isOn: $permanent)
                Spacer()
                Button("Оновити") { Task { await scan() } }.disabled(scanning)
                Button("Закрити") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Видалити вибране") { permanent ? (confirmPermanent = true) : remove() }.disabled(scanning || checked.isEmpty)
            }
        }
        .padding().frame(width: 780, height: 540)
        .task { await scan() }
        .confirmationDialog("Видалити вибране назавжди? Це не можна скасувати.", isPresented: $confirmPermanent) {
            Button("Видалити назавжди", role: .destructive, action: remove)
            Button("Скасувати", role: .cancel) {}
        }
    }

    private func row(_ item: Leftover) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.url.path).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            HStack {
                Text(reason(item.reason))
                Text(confidence(item.confidence))
                if let size = item.sizeBytes { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                if item.loaded == true { Text("Агент завантажено; його буде вивантажено перед видаленням") }
            }.font(.caption).foregroundStyle(.secondary)
            if item.needsAdmin { Text("Потрібні права адміністратора, видаліть вручну").font(.caption).foregroundStyle(.orange) }
            if !item.sharedWith.isEmpty {
                Text("Спільна тека розробника, встановлено також: \(item.sharedWith.joined(separator: ", "))").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func reason(_ reason: Leftover.Reason) -> LocalizedStringKey {
        switch reason {
        case .bundleID: "Збіг за bundle id"
        case .name: "Збіг за назвою"
        case .vendor: "Збіг за розробником"
        case .orphan: "Немає встановленої програми"
        }
    }

    private func confidence(_ confidence: Leftover.Confidence) -> LocalizedStringKey {
        switch confidence {
        case .high: "Висока впевненість"
        case .medium: "Середня впевненість"
        case .low: "Низька впевненість"
        }
    }

    private func scan() async {
        scanning = true
        let mode = mode
        let home = FileManager.default.homeDirectoryForCurrentUser
        items = await Task.detached {
            let installed = InstalledApps.applications(home: home, measureSizes: false)
            let roots = Leftovers.roots(home: home)
            switch mode {
            case .app(let app): return Leftovers.scan(LeftoverQuery(app: app), installed: installed, roots: roots)
            case .orphans: return Leftovers.orphans(installed: installed, roots: roots)
            }
        }.value
        checked = Set(items.filter(\.preselected).map(\.url.path))
        scanning = false
    }

    private func remove() {
        let paths = items.filter { checked.contains($0.url.path) }.map(\.url)
        let list = items, forever = permanent
        let home = FileManager.default.homeDirectoryForCurrentUser
        scanning = true
        Task {
            let results = await Task.detached { Leftovers.remove(paths, from: list, roots: Leftovers.roots(home: home), permanent: forever) }.value
            let failed = results.filter { $0.status != "deleted" && $0.status != "trashed" }
            refused = failed.map { "\($0.url.path): \($0.status)" }
            message = failed.isEmpty ? "Готово." : "Не вдалося видалити елементів: \(failed.count)."
            await scan()
        }
    }
}
