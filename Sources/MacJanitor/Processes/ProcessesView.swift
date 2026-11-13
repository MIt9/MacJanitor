import SwiftUI
import Darwin
import MacJanitorCore

enum ProcessGroup: String, CaseIterable, Identifiable {
    case apps = "Програми", background = "Фонові", all = "Усі"
    var id: Self { self }
}

struct ProcessesView: View {
    @State private var sampler = ProcessSampler()
    @State private var group: ProcessGroup = .apps
    @State private var search = ""
    @State private var selection: pid_t?
    @State private var sortOrder = [KeyPathComparator(\ProcessRow.name)]
    @State private var confirmKill = false
    @State private var errorMessage: String?
    @State private var aiTarget: ProcessRow?

    private var filtered: [ProcessRow] {
        sampler.processes.filter { process in
            (group == .all || (group == .apps ? process.isApp : !process.isApp)) &&
            (search.isEmpty || process.name.localizedCaseInsensitiveContains(search) || String(process.id).contains(search))
        }.sorted(using: sortOrder)
    }

    private var selected: ProcessRow? { sampler.processes.first { $0.id == selection } }

    var body: some View {
        VStack {
            HStack {
                Picker("Група", selection: $group) {
                    ForEach(ProcessGroup.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 340)
                Spacer()
                TextField("Пошук за назвою або PID", text: $search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            Table(filtered, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Назва", value: \ProcessRow.name) { process in
                    HStack {
                        Image(nsImage: process.icon).resizable().frame(width: 20, height: 20)
                        Text(process.name)
                    }.foregroundStyle(process.canKill ? .primary : .secondary)
                }
                TableColumn("PID", value: \ProcessRow.id) { Text(String($0.id)).foregroundStyle($0.canKill ? .primary : .secondary) }
                TableColumn("ЦП %", value: \ProcessRow.cpu) { Text($0.cpu, format: .number.precision(.fractionLength(1))).foregroundStyle($0.canKill ? .primary : .secondary) }
                TableColumn("Пам’ять", value: \ProcessRow.memory) { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: $0.memory), countStyle: .memory)).foregroundStyle($0.canKill ? .primary : .secondary) }
                TableColumn("Користувач", value: \ProcessRow.user) { Text($0.user).foregroundStyle($0.canKill ? .primary : .secondary) }
            }
            .contextMenu(forSelectionType: pid_t.self) { ids in
                if let id = ids.first, let process = sampler.processes.first(where: { $0.id == id }) {
                    Button("Запитати ШІ", systemImage: "sparkles") { aiTarget = process }
                }
            }
            HStack {
                Button("Запитати ШІ", systemImage: "sparkles") { aiTarget = selected }.disabled(selected == nil)
                Spacer()
                Button("Завершити") { signal(SIGTERM) }.disabled(selected?.canKill != true)
                Button("Примусово") { confirmKill = true }.disabled(selected?.canKill != true)
            }
        }
        .padding()
        .task {
            while !Task.isCancelled {
                sampler.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(item: $aiTarget) { AIAnswerView(title: $0.name, question: AIPrompt.process($0)) }
        .confirmationDialog("Примусово завершити процес?", isPresented: $confirmKill, titleVisibility: .visible) {
            Button("Примусово завершити", role: .destructive) { signal(SIGKILL) }
            Button("Скасувати", role: .cancel) { }
        } message: { Text(selected?.name ?? "") }
        .alert("Помилка завершення процесу", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("Гаразд") { errorMessage = nil }
        } message: { Text(LocalizedStringKey(errorMessage ?? "")) }
    }

    private func signal(_ value: Int32) {
        guard let process = selected, process.canKill else { return }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(process.id, PROC_PIDTBSDINFO, 0, &info, size) == size,
              ProcessLogic.canKill(uid: info.pbi_uid, currentUID: getuid()) else {
            errorMessage = "Процес недоступний або змінив власника."
            sampler.refresh()
            return
        }
        if kill(process.id, value) != 0 { errorMessage = String(cString: strerror(errno)) + " (errno \(errno))" }
        sampler.refresh()
    }
}
