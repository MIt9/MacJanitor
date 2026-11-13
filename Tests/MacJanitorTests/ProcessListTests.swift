import Testing
import Darwin
import MacJanitorCore

@Test func processListArgumentValidation() {
    #expect(ProcessListOptions(arguments: [])?.sort == .memory)
    #expect(ProcessListOptions(arguments: ["--sort", "cpu", "--limit", "5"])?.limit == 5)
    #expect(ProcessListOptions(arguments: ["--sort", "invalid"]) == nil)
    #expect(ProcessListOptions(arguments: ["--limit", "0"]) == nil)
    #expect(ProcessListOptions(arguments: ["--limit", "10001"]) == nil)
    #expect(ProcessListOptions(arguments: ["--limit"]) == nil)
    #expect(ProcessListOptions(arguments: ["--limit", "2", "--limit", "3"]) == nil)
}

@Test func processSamplingFindsCurrentProcess() {
    let rows = ProcessMonitor().sample()
    #expect(rows.contains { $0.id == getpid() })
}


