import Foundation

struct TerminalResizeRequest: Equatable, Sendable {
    let cols: UInt16
    let rows: UInt16
    fileprivate let generation: UInt64
}

final class TerminalResizeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func register(cols: Int, rows: Int) -> TerminalResizeRequest? {
        guard cols > 0, rows > 0,
              let cols = UInt16(exactly: cols),
              let rows = UInt16(exactly: rows) else { return nil }

        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return TerminalResizeRequest(cols: cols, rows: rows,
                                     generation: generation)
    }

    func isLatest(_ request: TerminalResizeRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return request.generation == generation
    }
}
