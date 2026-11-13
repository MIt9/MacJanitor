import Testing
import MacJanitorCore

@Test func parsesPortRecords() {
    let output = """
    p42
    cserver
    Lalice
    f3
    PTCP
    n127.0.0.1:8080
    TST=LISTEN
    f4
    PUDP
    n*:5353
    """
    let rows = PortScanner.parse(output)
    #expect(rows.count == 2)
    let tcp = rows.first { $0.address == "TCP 127.0.0.1:8080" }
    #expect(tcp?.process == "server")
    #expect(tcp?.pid == "42")
    #expect(tcp?.user == "alice")
    #expect(tcp?.state == "LISTEN")
    #expect(tcp?.localPort == 8080)
    #expect(rows.contains { $0.address == "UDP *:5353" && $0.state.isEmpty })
}

@Test func portMatchingUsesLocalEndpoint() {
    let rows = PortScanner.parse("p12\ncclient\nLalice\nf3\nPUDP\nn[::1]:5353->[::1]:8080\n")
    #expect(rows.first?.localPort == 5353)
    #expect(rows.first?.localPort != 8080)
}
