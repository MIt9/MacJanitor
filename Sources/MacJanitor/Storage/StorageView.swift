import MacJanitorCore
import SwiftUI
import AppKit

struct StorageView: View {
    @State private var root: StorageNode?
    @State private var task: Task<Void, Never>?
    @State private var count = 0
    @State private var path = ""
    @State private var largest = false
    @State private var selected: URL?
    @State private var expanded: Set<URL> = []
    @State private var error: String?
    @State private var partial = false
    @State private var scannedAt: Date?
    @State private var cached = false
    @State private var cacheError: LocalizedStringKey?
    @State private var fda = FullDiskAccess.isGranted()
    @State private var scanRoot = FileManager.default.homeDirectoryForCurrentUser
    @State private var aiTarget: StorageNode?
    private let home = FileManager.default.homeDirectoryForCurrentUser

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Обрати папку…", action: chooseFolder).disabled(task != nil)
                Button(action: scan) { Text(LocalizedStringKey(root == nil ? "Сканувати" : "Пересканувати")) }.disabled(task != nil)
                if task != nil { Button("Стоп") { task?.cancel() } }
                Picker("Режим", selection: $largest) {
                    Text("Дерево").tag(false)
                    Text("Найбільші").tag(true)
                }.pickerStyle(.segmented).frame(width: 220)
                Spacer()
                Button("Запитати ШІ", systemImage: "sparkles") { aiTarget = selected.flatMap { url in root.flatMap { find(url, in: $0) } } }.disabled(selected == nil)
                Button("Відкрити у Finder") { if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected]) } }.disabled(selected == nil)
                Button("Видалити в Корзину", action: trash).disabled(task != nil || selected == nil || !canDelete(selected!))
            }
            HStack { Text("Папка:"); Text(scanRoot.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }.font(.caption).foregroundStyle(.secondary)
            if !fda {
                HStack {
                    Text("Немає Повного доступу до диска: частину папок не видно, а розміри можуть бути неповними.").foregroundStyle(.orange)
                    Button("Відкрити налаштування") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                    Button("Перевірити знову") { fda = FullDiskAccess.isGranted() }
                }
            }
            if task != nil { Text("Проскановано: \(count) — \(path)").lineLimit(1) }
            if partial { Text("Результати неповні: сканування ще триває або його зупинено.").font(.caption).foregroundStyle(.secondary) }
            if let scannedAt {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(cached ? "Збережений результат — дані могли змінитися. Скановано:" : "Сканування завершено:"))
                    Text(scannedAt, format: .dateTime.year().month().day().hour().minute())
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let cacheError { Text(cacheError).font(.caption).foregroundStyle(.red) }
            if let error { Text(error).foregroundStyle(.red) }
            if let root {
                DisclosureGroup("Як читати результати") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Показано приблизний виділений дисковий простір для вибраної папки, а не зайнятий чи вільний простір усього диска.")
                        Text("Елементи з позначкою «недоступний» не вдалося прочитати або вони зникли під час сканування; їхній розмір невідомий. Повний доступ до диска може допомогти, але не гарантує доступу до всіх файлів.")
                        Text("Символічні посилання не обходяться, жорсткі посилання рахуються один раз. Системні дані, інші папки, знімки диска та очищуваний простір також можуть пояснювати різницю з показниками macOS.")
                    }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                List(selection: $selected) {
                    if largest {
                        ForEach(files(root).sorted { $0.size > $1.size }.prefix(100)) { node in row(node, parent: root.size).tag(node.url) }
                    } else {
                        ForEach(StorageVisibleRows.make(root: root, expanded: expanded)) { item in
                            HStack(spacing: 4) {
                                if item.node.children != nil {
                                    Button {
                                        if expanded.contains(item.id) { expanded.remove(item.id) }
                                        else { expanded.insert(item.id) }
                                    } label: {
                                        Image(systemName: expanded.contains(item.id) ? "chevron.down" : "chevron.right")
                                    }.buttonStyle(.borderless).accessibilityLabel(Text(expanded.contains(item.id) ? "Collapse" : "Expand"))
                                } else { Color.clear.frame(width: 12, height: 1) }
                                row(item.node, parent: item.node.parentSize)
                            }.padding(.leading, CGFloat(item.depth) * 16).tag(item.id)
                        }
                    }
                }
            } else { ContentUnavailableView("Сховище", systemImage: "internaldrive", description: Text("Натисніть «Сканувати», щоб проаналізувати домашню папку.")) }
            ScrollView {
                VStack(alignment: .leading) {
                    DisclosureGroup("Безпечне очищення") { StorageCleanupView(home: home).padding(.vertical, 4) }
                    DisclosureGroup("Google Drive") {
                        StorageDriveView(selected: selected == scanRoot ? nil : selected) { url in root = root?.removing(url) }.padding(.vertical, 4)
                    }
                }
            }.frame(maxHeight: 260).disabled(task != nil)
        }.padding()
        .task { await loadCache() }
        .sheet(item: $aiTarget) { AIAnswerView(title: AIPrompt.tilde($0.url.path), question: AIPrompt.storage($0)) }
    }
    private func find(_ url: URL, in node: StorageNode) -> StorageNode? {
        if node.url == url { return node }
        return node.children?.lazy.compactMap { find(url, in: $0) }.first
    }
    private func row(_ node: StorageNode, parent: Int64) -> some View {
        HStack {
            Text(node.url.lastPathComponent)
            if node.inaccessible { Text("недоступний").foregroundStyle(.secondary) }
            Spacer()
            if node.inaccessible {
                Text("невідомо").foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
            } else {
                ProgressView(value: parent > 0 ? Double(node.size) / Double(parent) : 0).frame(width: 90)
                Text(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file)).frame(width: 100, alignment: .trailing)
            }
        }.contextMenu {
            Button("Запитати ШІ", systemImage: "sparkles") { aiTarget = node }
            Button("Відкрити у Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Button("Видалити в Корзину") { selected = node.url; trash() }.disabled(task != nil || !canDelete(node.url))
        }
    }
    private func files(_ node: StorageNode) -> [StorageNode] {
        guard let children = node.children else { return [node] }
        return children.flatMap(files)
    }
    private func scan() {
        let target = scanRoot
        count = 0
        error = nil
        selected = nil
        expanded = [target]
        partial = true
        cached = false
        scannedAt = nil
        cacheError = nil
        root = StorageNode(url: target, size: 0, children: [])
        task = Task {
            do {
                let result = try await StorageScanner().scan(target) { count, path, snapshot in
                    await MainActor.run { self.count = count; self.path = path; self.root = snapshot }
                }
                try Task.checkCancellation()
                root = result
                partial = false
                let date = Date()
                scannedAt = date
                fda = FullDiskAccess.isGranted()
                do {
                    try await Task.detached { try StorageCache.standard.save(result, scannedAt: date) }.value
                } catch {
                    cacheError = "Не вдалося зберегти результат сканування."
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
            task = nil
        }
    }
    private func loadCache() async {
        do {
            let snapshot = try await Task.detached { try StorageCache.standard.loadLatest() }.value
            guard task == nil, root == nil, let snapshot else { return }
            scanRoot = snapshot.root.url
            root = snapshot.root
            expanded = [snapshot.root.url]
            scannedAt = snapshot.scannedAt
            cached = true
        } catch {
            if root == nil && task == nil { cacheError = "Не вдалося прочитати збережений результат сканування." }
        }
    }
    private func trash() {
        guard let selected, canDelete(selected) else { return }
        do { try FileManager.default.trashItem(at: selected, resultingItemURL: nil); root = root?.removing(selected); self.selected = nil }
        catch { self.error = error.localizedDescription }
    }
    private func canDelete(_ url: URL) -> Bool {
        url.standardizedFileURL.resolvingSymlinksInPath() != scanRoot.standardizedFileURL.resolvingSymlinksInPath() && StoragePolicy(home: home).canDelete(url)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = scanRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scanRoot = url.standardizedFileURL
        scan()
    }
}
