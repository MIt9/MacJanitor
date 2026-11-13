import Foundation

/// Locally installed AI CLIs. They use their own login; MacJanitor stores no keys.
public enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case claude, codex
    public var id: Self { self }
    public var title: String { self == .claude ? "Claude Code" : "Codex" }
    public var modelSuggestions: [String] { self == .claude ? ["haiku", "sonnet", "opus"] : [] }

    /// Explicit path wins; otherwise the usual install locations.
    public func discover(path: String, home: String = NSHomeDirectory(), executable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        let name = rawValue
        let candidates = path.isEmpty
            ? ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.npm-global/bin/\(name)"]
            : [NSString(string: path).expandingTildeInPath]
        return candidates.first(where: executable)
    }

    /// No tools, MCP, hooks, user settings or sessions: the CLI only answers.
    public func arguments(model: String, system: String, work: String, output: String) -> [String] {
        switch self {
        case .claude:
            var args = ["-p", "--output-format", "text", "--system-prompt", system, "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--setting-sources", "project", "--no-session-persistence"]
            if !model.isEmpty { args += ["--model", model] }
            return args
        case .codex:
            var args = ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules", "-c", "project_doc_max_bytes=0", "-C", work, "--output-last-message", output]
            if !model.isEmpty { args += ["-m", model] }
            return args + ["-"]
        }
    }

    /// Claude gets the system prompt as an argument; Codex only reads stdin.
    public func input(system: String, question: String) -> String {
        self == .claude ? question : "<instructions>\n\(system)\n</instructions>\n\n\(question)"
    }

    /// USER/LOGNAME are required: the CLI finds its login in the Keychain by account name.
    public static func environment(executable: String, home: String, lang: String, user: String) -> [String: String] {
        ["HOME": home, "USER": user, "LOGNAME": user, "PATH": "\((executable as NSString).deletingLastPathComponent):/usr/bin:/bin", "LANG": lang]
    }
}

/// The app switches language via the "language" default, not the system locale.
public func aiLocalized(_ key: String, _ args: CVarArg...) -> String {
    let lang = UserDefaults.standard.string(forKey: "language") ?? "en"
    let bundle = Bundle.main.path(forResource: lang, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    return String(format: bundle.localizedString(forKey: key, value: nil, table: nil), arguments: args)
}

public struct AIError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct AISettings: Sendable {
    public var provider: AIProvider
    public var path: String
    public var model: String

    public static func pathKey(_ p: AIProvider) -> String { "ai.path.\(p.rawValue)" }
    public static func modelKey(_ p: AIProvider) -> String { "ai.model.\(p.rawValue)" }
    public static let providerKey = "ai.provider"

    /// First installed CLI when the user has not chosen one.
    public static func defaultProvider(_ ud: UserDefaults = .standard) -> AIProvider {
        AIProvider.allCases.first { $0.discover(path: ud.string(forKey: pathKey($0)) ?? "") != nil } ?? .claude
    }

    public static func load(_ ud: UserDefaults = .standard) -> AISettings {
        let p = ud.string(forKey: providerKey).flatMap(AIProvider.init) ?? defaultProvider(ud)
        let trim = { (s: String?) in (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        return AISettings(provider: p, path: trim(ud.string(forKey: pathKey(p))), model: trim(ud.string(forKey: modelKey(p)) ?? (p == .claude ? "haiku" : "")))
    }
}

private final class CLIProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func start(_ p: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try p.run()
        process = p
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}

public enum AIClient {
    /// Runs the CLI from an empty temp directory. Task cancellation terminates it (SIGKILL after 2 s).
    public static func ask(system: String, question: String, settings: AISettings = .load(), timeout: TimeInterval = 120) async throws -> String {
        let p = settings.provider
        guard let executable = p.discover(path: settings.path) else {
            throw AIError(aiLocalized("%@ CLI не знайдено. Встановіть його або вкажіть шлях у Налаштуваннях.", p.title))
        }
        let state = CLIProcessState()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                let fm = FileManager.default
                let dir = fm.temporaryDirectory.appendingPathComponent("macjanitor-ai-" + UUID().uuidString, isDirectory: true)
                let work = dir.appendingPathComponent("work", isDirectory: true)
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: dir) }
                let input = dir.appendingPathComponent("input"), output = dir.appendingPathComponent("output")
                let errors = dir.appendingPathComponent("errors"), answer = dir.appendingPathComponent("answer")
                try Data(p.input(system: system, question: question).utf8).write(to: input)
                fm.createFile(atPath: output.path, contents: nil)
                fm.createFile(atPath: errors.path, contents: nil)
                let stdin = try FileHandle(forReadingFrom: input)
                let stdout = try FileHandle(forWritingTo: output)
                let stderr = try FileHandle(forWritingTo: errors)
                defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = p.arguments(model: settings.model, system: system, work: work.path, output: answer.path)
                process.environment = AIProvider.environment(executable: executable, home: NSHomeDirectory(), lang: ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8", user: NSUserName())
                process.currentDirectoryURL = work
                process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
                try state.start(process)
                let deadline = Date().addingTimeInterval(timeout)
                var timedOut = false
                var killAt: Date?
                while process.isRunning {
                    if !timedOut && !state.isCancelled && Date() >= deadline { timedOut = true; state.cancel() }
                    if state.isCancelled && killAt == nil { killAt = Date().addingTimeInterval(2) }
                    if let killAt, Date() >= killAt { kill(process.processIdentifier, SIGKILL) }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if timedOut { throw AIError(aiLocalized("%@ не відповів за %d с.", p.title, Int(timeout))) }
                if state.isCancelled { throw CancellationError() }
                let read = { (url: URL) in String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
                if process.terminationStatus != 0 {
                    var err = read(errors)
                    if err.isEmpty { err = read(output) }
                    let lower = err.lowercased()
                    let needsLogin = ["auth", "login", "log in", "unauthorized", "credential"].contains(where: lower.contains)
                    let hint = needsLogin ? " " + aiLocalized("Увійдіть у Терміналі: `%@`.", p == .claude ? "claude" : "codex login") : ""
                    throw AIError("\(p.title): \(String(err.prefix(300)))\(hint)")
                }
                let result = read(p == .codex ? answer : output)
                guard !result.isEmpty else { throw AIError(aiLocalized("%@ повернув порожню відповідь.", p.title)) }
                return result
            }.value
        } onCancel: { state.cancel() }
    }
}
