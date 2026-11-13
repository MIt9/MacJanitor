import MacJanitorCore
import SwiftUI
import Darwin

enum AIPrompt {
    static func system() -> String {
        let lang = UserDefaults.standard.string(forKey: "language") == "uk" ? "Ukrainian" : "English"
        return """
        You are a macOS expert inside MacJanitor, a cleanup tool. Explain the item the user asks about: what it is, \
        which app or vendor owns it, why it exists, and whether removing or quitting it is safe and what happens after. \
        Say plainly when you are not sure. Be concise: short paragraphs or a short list, no preamble. Answer in \(lang).
        """
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func process(_ p: ProcessRow) -> String {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = Int(proc_pidpath(p.id, &buffer, UInt32(buffer.count)))  // bytes written, without the NUL
        let path = length > 0 ? tilde(String(decoding: buffer.prefix(length), as: UTF8.self)) : "unknown"
        return """
        What is this macOS process? Can I quit it safely?
        Name: \(p.name)
        PID: \(p.id)
        Executable: \(path)
        User: \(p.user)
        Kind: \(p.isApp ? "regular app" : "background process")
        CPU: \(String(format: "%.1f", p.cpu))%
        Memory: \(ByteCountFormatter.string(fromByteCount: Int64(clamping: p.memory), countStyle: .memory))
        """
    }

    static func storage(_ node: StorageNode) -> String {
        let size = node.inaccessible ? "unknown" : ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file)
        var text = """
        What is this \(node.children == nil ? "file" : "folder") on my Mac, which app creates and uses it, \
        can I delete it, and will it be recreated?
        Path: \(tilde(node.url.path))
        Size: \(size)
        """
        let top = (node.children ?? []).sorted { $0.size > $1.size }.prefix(10)
        if !top.isEmpty {
            text += "\nLargest items inside:\n" + top.map { "- \($0.url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file)))" }.joined(separator: "\n")
        }
        return text
    }
}

struct AIAnswerView: View {
    let title: String
    let question: String
    @Environment(\.dismiss) private var dismiss
    @State private var answer: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "sparkles").font(.headline).lineLimit(1).truncationMode(.middle)
            ScrollView {
                Group {
                    if let answer {
                        Text((try? AttributedString(markdown: answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(answer))
                    } else if let error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        ProgressView("Питаю ШІ…")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            HStack {
                Text(AISettings.load().provider.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Закрити") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 560, height: 440)
        // Closing the sheet cancels the task, which terminates the CLI.
        .task {
            do { answer = try await AIClient.ask(system: AIPrompt.system(), question: question) }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }
}

struct AISettingsView: View {
    @AppStorage(AISettings.providerKey) private var provider = AISettings.defaultProvider()

    var body: some View {
        Form {
            Picker("ШІ", selection: $provider) {
                ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
            }
            AIProviderFields(provider: provider).id(provider)
            Text("Використовується CLI, встановлений на цьому Mac, з його власним входом. MacJanitor не зберігає ключі.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}

private struct AIProviderFields: View {
    let provider: AIProvider
    @AppStorage private var path: String
    @AppStorage private var model: String

    init(provider: AIProvider) {
        self.provider = provider
        _path = AppStorage(wrappedValue: "", AISettings.pathKey(provider))
        _model = AppStorage(wrappedValue: provider == .claude ? "haiku" : "", AISettings.modelKey(provider))
    }

    var body: some View {
        TextField("Шлях до CLI", text: $path, prompt: Text("автоматично"))
        if let found = provider.discover(path: path.trimmingCharacters(in: .whitespaces)) {
            LabeledContent("Знайдено") { Text(found).textSelection(.enabled) }
        } else {
            LabeledContent("Статус") { Text("Не знайдено").foregroundStyle(.red) }
        }
        HStack {
            TextField("Модель", text: $model, prompt: Text("за замовчуванням CLI"))
            if !provider.modelSuggestions.isEmpty {
                Menu("Обрати") { ForEach(provider.modelSuggestions, id: \.self) { m in Button(m) { model = m } } }.fixedSize()
            }
        }
    }
}
