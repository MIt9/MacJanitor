import SwiftUI
import MacJanitorCore

struct AppsView: View {
    @State private var apps: [InstalledApp] = []
    @State private var search = ""
    @State private var sort: InstalledAppSort = .size
    @State private var loading = false
    @State private var selection: InstalledApp.ID?

    private var filtered: [InstalledApp] { InstalledApps.select(apps, search: search, sort: sort) }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Оновити") { refresh() }.disabled(loading)
                if loading { ProgressView().controlSize(.small) }
                Picker("Сортування", selection: $sort) {
                    Text("Назва").tag(InstalledAppSort.name)
                    Text("Розмір").tag(InstalledAppSort.size)
                    Text("Останній запуск").tag(InstalledAppSort.lastUsed)
                }.pickerStyle(.segmented).frame(maxWidth: 360)
                Spacer()
                TextField("Пошук програм", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            Table(filtered, selection: $selection) {
                TableColumn("Назва") { app in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 20, height: 20)
                        Text(app.name)
                        if app.isProtected {
                            Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Системна програма, видаляти не можна")
                        }
                    }.foregroundStyle(app.isProtected ? .secondary : .primary)
                }
                TableColumn("Bundle ID") { Text($0.bundleIdentifier ?? "—").foregroundStyle(.secondary) }
                TableColumn("Версія") { Text($0.version ?? "—") }
                TableColumn("Розмір") { app in
                    if let size = app.sizeBytes { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                    else { ProgressView().controlSize(.mini) }
                }
                TableColumn("Останній запуск") { app in
                    if let date = app.lastLaunchDate { Text(date, format: .dateTime.year().month().day()) } else { Text("—") }
                }
            }
            HStack {
                Spacer()
                Button("Відкрити у Finder") { if let id = selection { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)]) } }
                    .disabled(selection == nil)
            }
        }.padding().onAppear { if apps.isEmpty { refresh() } }
    }

    /// Lists apps quickly, then fills in sizes one by one off the main actor.
    private func refresh() {
        guard !loading else { return }
        loading = true
        Task {
            let home = FileManager.default.homeDirectoryForCurrentUser
            apps = await Task.detached { InstalledApps.applications(home: home, measureSizes: false) }.value
            for app in apps {
                let size = await Task.detached { InstalledApps.realSize(of: app.url) }.value
                if let index = apps.firstIndex(where: { $0.id == app.id }) { apps[index].sizeBytes = size ?? 0 }
            }
            loading = false
        }
    }
}
