import SwiftUI
import MacJanitorCore

struct PortsView: View {
    @State private var rows: [PortRow] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error = false
    @State private var selection: PortRow.ID?
    @State private var confirmForce = false
    @State private var actionError: String?
    @State private var aiTarget: PortRow?

    private var selected: PortRow? { rows.first { $0.id == selection } }

    private var filtered: [PortRow] {
        rows.filter { search.isEmpty || "\($0.process) \($0.pid) \($0.user) \($0.address)".localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Оновити") { refresh() }.disabled(loading)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                TextField("Пошук портів", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
            Text("Показано TCP-порти, що прослуховуються, та UDP-сокети, доступні поточному користувачу.")
                .font(.caption).foregroundStyle(.secondary)
            if error { Text("Не вдалося отримати список портів.").foregroundStyle(.red) }
            Table(filtered, selection: $selection) {
                TableColumn("Процес", value: \.process)
                TableColumn("PID", value: \.pid)
                TableColumn("Користувач", value: \.user)
                TableColumn("Адреса і порт", value: \.address)
                TableColumn("Стан", value: \.state)
            }
            .contextMenu(forSelectionType: PortRow.ID.self) { ids in
                if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                    Button("Запитати ШІ", systemImage: "sparkles") { aiTarget = row }
                }
            }
            HStack {
                Button("Запитати ШІ", systemImage: "sparkles") { aiTarget = selected }.disabled(selected == nil)
                Spacer()
                Button("Завершити") { terminate(force: false) }.disabled(selected == nil || loading)
                Button("Примусово") { confirmForce = true }.disabled(selected == nil || loading)
            }
        }.padding().onAppear { refresh() }
        .sheet(item: $aiTarget) { AIAnswerView(title: "\($0.process) — \($0.address)", question: AIPrompt.port($0)) }
        .confirmationDialog("Примусово завершити процес?", isPresented: $confirmForce, titleVisibility: .visible) {
            Button("Примусово завершити", role: .destructive) { terminate(force: true) }
            Button("Скасувати", role: .cancel) { }
        } message: { Text("\(selected?.process ?? "") (PID \(selected?.pid ?? ""))") }
        .alert("Помилка завершення процесу", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("Гаразд") { actionError = nil }
        } message: { Text(actionError ?? "") }
    }

    private func terminate(force: Bool) {
        guard let selected, let pid = Int32(selected.pid) else { return }
        do { try ProcessAction.send(pid: pid, force: force) }
        catch { actionError = error.localizedDescription }
        refresh()
    }

    private func refresh() {
        guard !loading else { return }
        loading = true
        Task {
            do {
                rows = try await Task.detached { try PortScanner.scan() }.value
                error = false
            } catch { self.error = true }
            loading = false
        }
    }
}
