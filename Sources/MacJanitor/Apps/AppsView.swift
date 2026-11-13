import SwiftUI
import MacJanitorCore

struct AppsView: View {
    @State private var apps: [InstalledApp] = []
    @State private var search = ""
    @State private var sort: InstalledAppSort = .size
    @State private var loading = false
    @State private var selection: InstalledApp.ID?
    @State private var busy = false
    @State private var runningPlan: AppRemovalPlan?
    @State private var uninstallerPlan: AppRemovalPlan?
    @State private var afterUninstaller: InstalledApp?
    @State private var confirmPlan: AppRemovalPlan?
    @State private var message: LocalizedStringKey?
    @State private var errorText: String?

    private var selected: InstalledApp? { apps.first { $0.id == selection } }
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
                if let message { Text(message).foregroundStyle(.secondary) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Видалити програму…") { if let selected { startRemoval(selected, offerUninstaller: true) } }
                    .disabled(selected == nil || selected?.isProtected == true || busy)
                Button("Відкрити у Finder") { if let id = selection { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)]) } }
                    .disabled(selection == nil)
            }
        }.padding().onAppear { if apps.isEmpty { refresh() } }
        .confirmationDialog("Програма запущена", isPresented: shown($runningPlan), titleVisibility: .visible, presenting: runningPlan) { plan in
            Button("Завершити програму") { quit(plan) }
            Button("Скасувати", role: .cancel) {}
        } message: { plan in Text("Щоб видалити «\(plan.app.name)», її потрібно спершу завершити.") }
        .confirmationDialog("Знайдено власний деінсталятор", isPresented: shown($uninstallerPlan), titleVisibility: .visible, presenting: uninstallerPlan) { plan in
            ForEach(plan.uninstallers, id: \.self) { url in
                Button("Запустити «\(url.deletingPathExtension().lastPathComponent)»") {
                    NSWorkspace.shared.open(url)
                    afterUninstaller = plan.app
                }
            }
            Button("Видалити без деінсталятора") { confirmPlan = plan }
            Button("Скасувати", role: .cancel) {}
        } message: { _ in Text("Рекомендуємо спершу запустити деінсталятор програми.") }
        .alert("Деінсталятор запущено", isPresented: shown($afterUninstaller), presenting: afterUninstaller) { app in
            Button("Видалити звичайним способом") { startRemoval(app, offerUninstaller: false) }
            Button("Пізніше", role: .cancel) { refresh() }
        } message: { _ in Text("Коли він завершиться, програму, якщо вона лишилась, можна видалити звичайним способом. Перевірка залишків — наступний крок.") }
        .sheet(isPresented: shown($confirmPlan)) {
            if let confirmPlan { AppRemovalSheet(plan: confirmPlan) { permanent in remove(confirmPlan, permanent: permanent) } }
        }
        .alert("Не вдалося видалити програму", isPresented: shown($errorText)) {
            Button("Гаразд") {}
        } message: { Text(errorText ?? "") }
    }

    private func shown<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    /// Plans removal in Core, then: quit if running → offer own uninstaller → confirmation sheet.
    private func startRemoval(_ app: InstalledApp, offerUninstaller: Bool) {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            let home = FileManager.default.homeDirectoryForCurrentUser
            // Re-read the app: an uninstaller may have removed it meanwhile.
            guard let current = await Task.detached(operation: { InstalledApps.app(at: app.url, measureSize: false) }).value else {
                message = "Програму вже видалено. Перевірка залишків — наступний крок."
                refresh()
                return
            }
            do {
                let plan = try await Task.detached { try AppRemoval.plan(for: current, home: home) }.value
                if !AppRemoval.runningPIDs(plan).isEmpty { runningPlan = plan }
                else if offerUninstaller && !plan.uninstallers.isEmpty { uninstallerPlan = plan }
                else { confirmPlan = plan }
            } catch { errorText = error.localizedDescription }
        }
    }

    /// Sends SIGTERM via the shared process action and waits up to 5 s; never removes a still-running app.
    private func quit(_ plan: AppRemovalPlan) {
        busy = true
        Task {
            defer { busy = false }
            for pid in AppRemoval.runningPIDs(plan) {
                do { try ProcessAction.send(pid: pid, force: false) }
                catch { errorText = error.localizedDescription; return }
            }
            for _ in 0..<20 where !AppRemoval.runningPIDs(plan).isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            if AppRemoval.runningPIDs(plan).isEmpty { startRemoval(plan.app, offerUninstaller: true) }
            else { errorText = AppRemovalError.running(AppRemoval.runningPIDs(plan)).localizedDescription }
        }
    }

    private func remove(_ plan: AppRemovalPlan, permanent: Bool) {
        confirmPlan = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let results = try await Task.detached { try AppRemoval.remove(plan, permanent: permanent) }.value
                let failed = results.filter { $0.status.hasPrefix("failed") }.count
                message = failed == 0 ? "Програму видалено. Перевірка залишків — наступний крок." : "Не вдалося видалити елементів: \(failed)."
            } catch { errorText = error.localizedDescription }
            refresh()
        }
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

/// Confirmation listing exactly what will be removed; Trash by default, permanent deletion behind a toggle and a second dialog.
private struct AppRemovalSheet: View {
    let plan: AppRemovalPlan
    let onRemove: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var permanent = false
    @State private var confirmPermanent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Видалити програму «\(plan.app.name)»?").font(.headline)
            Text("Буде видалено:")
            ForEach(plan.items, id: \.url) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.url.path).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Text(title(item.role))
                        if let size = item.sizeBytes { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Загальний розмір: \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))").bold()
            Text("Налаштування, кеші та інші залишки програми не видаляються; їх перевірка — наступний крок.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Видалити назавжди", isOn: $permanent)
            HStack {
                Spacer()
                Button("Скасувати", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(LocalizedStringKey(permanent ? "Видалити назавжди" : "Перемістити в Корзину"), role: .destructive) {
                    if permanent { confirmPermanent = true } else { onRemove(false) }
                }
            }
        }
        .padding().frame(width: 560)
        .confirmationDialog("Видалити вибране назавжди? Це не можна скасувати.", isPresented: $confirmPermanent) {
            Button("Видалити назавжди", role: .destructive) { onRemove(true) }
            Button("Скасувати", role: .cancel) {}
        }
    }

    private func title(_ role: AppRemovalItem.Role) -> LocalizedStringKey {
        switch role {
        case .bundle: "Програма"
        case .link: "Ярлик: видаляється лише сам ярлик"
        case .target: "Справжня програма, на яку вказує ярлик або завантажувач"
        }
    }
}
