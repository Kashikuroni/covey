struct TerminalViewLease: Equatable, Sendable {
    let session: String
    fileprivate let generation: UInt64
}

struct TerminalResizeOwnership {
    private var nextGeneration: UInt64 = 0
    private var currentGenerationBySession: [String: UInt64] = [:]

    mutating func mount(session: String) -> TerminalViewLease {
        nextGeneration &+= 1
        let lease = TerminalViewLease(
            session: session,
            generation: nextGeneration
        )
        currentGenerationBySession[session] = lease.generation
        return lease
    }

    func isCurrent(_ lease: TerminalViewLease) -> Bool {
        currentGenerationBySession[lease.session] == lease.generation
    }

    mutating func unmount(_ lease: TerminalViewLease) {
        guard isCurrent(lease) else { return }
        currentGenerationBySession.removeValue(forKey: lease.session)
    }
}
