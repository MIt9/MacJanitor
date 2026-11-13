import Testing
@testable import MacJanitor
import MacJanitorCore

@Test func processCalculations() {
    #expect(ProcessLogic.cpuPercent(previous: 1_000_000_000, current: 2_000_000_000, elapsed: 2, timebase: 1) == 50)
    #expect(ProcessLogic.cpuPercent(previous: 2, current: 1, elapsed: 1, timebase: 1) == 0)
    #expect(ProcessLogic.canKill(uid: 501, currentUID: 501))
    #expect(!ProcessLogic.canKill(uid: 0, currentUID: 501))
}
