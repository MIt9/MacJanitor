import Foundation
import Testing
import MacJanitorCore

@Test func aiDiscoveryPrefersExplicitPath() {
    #expect(AIProvider.claude.discover(path: "/x/claude", home: "/h", executable: { $0 == "/x/claude" }) == "/x/claude")
    #expect(AIProvider.claude.discover(path: "/missing", home: "/h", executable: { $0 == "/h/.local/bin/claude" }) == nil)
    #expect(AIProvider.codex.discover(path: "", home: "/h", executable: { $0 == "/opt/homebrew/bin/codex" }) == "/opt/homebrew/bin/codex")
}

@Test func aiClaudeArgumentsDisableTools() {
    let args = AIProvider.claude.arguments(model: "haiku", system: "sys", work: "/w", output: "/o")
    #expect(args.starts(with: ["-p", "--output-format", "text", "--system-prompt", "sys", "--tools", ""]))
    #expect(args.contains("--strict-mcp-config") && args.contains("--no-session-persistence"))
    #expect(args.suffix(2) == ["--model", "haiku"])
    #expect(!AIProvider.claude.arguments(model: "", system: "s", work: "/w", output: "/o").contains("--model"))
}

@Test func aiCodexArgumentsAreReadOnly() {
    let args = AIProvider.codex.arguments(model: "", system: "sys", work: "/w", output: "/o")
    #expect(args == ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules", "-c", "project_doc_max_bytes=0", "-C", "/w", "--output-last-message", "/o", "-"])
    #expect(AIProvider.codex.arguments(model: "m", system: "s", work: "/w", output: "/o").suffix(3) == ["-m", "m", "-"])
    #expect(AIProvider.codex.input(system: "sys", question: "q").hasPrefix("<instructions>\nsys\n"))
    #expect(AIProvider.claude.input(system: "sys", question: "q") == "q")
}

@Test func aiEnvironmentKeepsLoginAccount() {
    let env = AIProvider.environment(executable: "/opt/homebrew/bin/claude", home: "/h", lang: "en_US.UTF-8", user: "me")
    #expect(env == ["HOME": "/h", "USER": "me", "LOGNAME": "me", "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8"])
}

@Test func aiSettingsReadPerProviderValues() {
    let ud = UserDefaults(suiteName: "ai-test-\(UUID())")!
    ud.set("codex", forKey: AISettings.providerKey)
    ud.set(" gpt-x ", forKey: AISettings.modelKey(.codex))
    let s = AISettings.load(ud)
    #expect(s.provider == .codex && s.model == "gpt-x" && s.path == "")
    ud.set("claude", forKey: AISettings.providerKey)
    #expect(AISettings.load(ud).model == "haiku")
}
