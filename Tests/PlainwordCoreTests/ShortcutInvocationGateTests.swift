import Testing
@testable import PlainwordCore

struct ShortcutInvocationGateTests {
    @Test
    func collapsesRapidRepeatedInvocations() {
        var gate = ShortcutInvocationGate(minimumInterval: 0.35)

        let first = gate.accepts(timestamp: 10)
        let duplicate = gate.accepts(timestamp: 10)
        let rapidRepeat = gate.accepts(timestamp: 10.2)
        let laterPress = gate.accepts(timestamp: 10.36)

        #expect(first)
        #expect(!duplicate)
        #expect(!rapidRepeat)
        #expect(laterPress)
    }

    @Test
    func rejectedInvocationDoesNotExtendCooldown() {
        var gate = ShortcutInvocationGate(minimumInterval: 0.35)

        let first = gate.accepts(timestamp: 20)
        let rejected = gate.accepts(timestamp: 20.3)
        let afterOriginalCooldown = gate.accepts(timestamp: 20.36)

        #expect(first)
        #expect(!rejected)
        #expect(afterOriginalCooldown)
    }

    @Test
    func acceptsAfterTimestampSequenceResets() {
        var gate = ShortcutInvocationGate(minimumInterval: 0.35)

        let beforeReset = gate.accepts(timestamp: 100)
        let afterReset = gate.accepts(timestamp: 1)

        #expect(beforeReset)
        #expect(afterReset)
    }
}
