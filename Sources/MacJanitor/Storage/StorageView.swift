import SwiftUI
import AppKit

struct StorageView: View {
    @State private var root: StorageNode?
    @State private var task: Task<Void, Never>?
    @State private var count = 0
    @State private var path = ""
    @State private var largest = false
    @State private var selected: URL?
    @State private var error: String?
    @State private var fda = FullDiskAccess.isGranted()
    private let home = FileManager.default.homeDirectoryForCurrentUser

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button(root == nil ? "Сканувати" : "Пересканувати", action: scan).disabled(task != nil)
                if task != nil { Button("Стоп") { task?.cancel() } }
                Picker("Режим", selection: $largest) {
                    Text("Дерево").tag(false)
                    Text("Найбільші").tag(true)
                }.pickerStyle(.segmented).frame(width: 220)
                Spacer()
                Button("Відкрити у Finder") { if let selected { NSWorkspace.shared.activateFileViewerSelecting([selected]) } }.disabled(selected == nil)
                Button("Видалити в Корзину", action: trash).disabled(selected == nil || !StoragePolicy(home: home).canDelete(selected!))
            }
            if !fda {
                HStack {
                    Text("Немає Повного доступу до диска: частину папок не видно, а розміри можуть бути неповними.").foregroundStyle(.orange)
                    Button("Відкрити налаштування") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                    Button("Перевірити знову") { fda = FullDiskAccess.isGranted() }
                }
            }
            if task != nil { Text("Проскановано: \(count) — \(path)").lineLimit(1) }
            if let error { Text(error).foregroundStyle(.red) }
            if let root {
                List(selection: $selected) {
                    if largest {
                        ForEach(files(root).sorted { $0.size > $1.size }.prefix(100)) { node in row(node, parent: root.size).tag(node.url) }
                    } else {
                        OutlineGroup([root], children: \.children) { node in row(node, parent: node.parentSize).tag(node.url) }
                    }
                }
            } else { ContentUnavailableView("Сховище", systemImage: "internaldrive", description: Text("Натисніть «Сканувати», щоб проаналізувати домашню папку.")) }
            ScrollView {
                VStack(alignment: .leading) {
                    DisclosureGroup("Безпечне очищення") { StorageCleanupView(home: home).padding(.vertical, 4) }
                    DisclosureGroup("Google Drive") {
                        StorageDriveView(selected: selected) { url in root = root?.removing(url) }.padding(.vertical, 4)
                    }
                }
            }.frame(maxHeight: 260)
        }.padding()
    }
    private func row(_ node: StorageNode, parent: Int64) -> some View {
        HStack {
            Text(node.url.lastPathComponent)
            if node.inaccessible { Text("немає доступу").foregroundStyle(.secondary) }
            Spacer()
            ProgressView(value: parent > 0 ? Double(node.size) / Double(parent) : 0).frame(width: 90)
            Text(ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file)).frame(width: 100, alignment: .trailing)
        }.contextMenu {
            Button("Відкрити у Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Button("Видалити в Корзину") { selected = node.url; trash() }.disabled(!StoragePolicy(home: home).canDelete(node.url))
        }
    }
    private func files(_ node: StorageNode) -> [StorageNode] {
        guard let children = node.children else { return [node] }
        return children.flatMap(files)
    }
    private func scan() {
        count = 0
        error = nil
        task = Task {
            do {
                let result = try await StorageScanner().scan(home) { count, path in
                    await MainActor.run { self.count = count; self.path = path }
                }
                root = result
                fda = FullDiskAccess.isGranted()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
            task = nil
        }
    }
    private func trash() {
        guard let selected, StoragePolicy(home: home).canDelete(selected) else { return }
        do { try FileManager.default.trashItem(at: selected, resultingItemURL: nil); root = root?.removing(selected); self.selected = nil }
        catch { self.error = error.localizedDescription }
    }
}
