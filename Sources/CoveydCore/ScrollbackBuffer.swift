/// A bounded ring buffer of raw PTY output, addressed by an absolute byte
/// sequence number (`seq`). A late-attaching client can backfill via `since`.
public final class ScrollbackBuffer {
    /// `seq` of the oldest byte still available.
    public private(set) var headSeq: Int = 0
    /// `seq` one past the last byte ever appended.
    public private(set) var tailSeq: Int = 0
    
    private var storage: [UInt8] = []
    private let limit: Int
    
    public init(limit: Int) {
        self.limit = max(1, limit)
    }
    
    /// Appends bytes and returns their seq range `[from, to]`.
    @discardableResult
    public func append(_ bytes: [UInt8]) -> (from: Int, to: Int) {
        let from = tailSeq
        storage.append(contentsOf: bytes)
        tailSeq += bytes.count
        if storage.count > limit {
            let drop = storage.count - limit
            storage.removeFirst(drop)
            headSeq += drop
        }
        return (from, tailSeq)
    }
    
    /// Returns bytes starting at `seq`. If `seq` was already evicted, returns
    /// the available tail and sets `gapped = true` (history was lost).
    public func since(_ seq: Int) -> (
        bytes: [UInt8],
        fromSeq: Int,
        gapped: Bool
    ) {
        let gapped = seq < headSeq
        let effective = max(seq, headSeq)
        if effective >= tailSeq {
            return ([], tailSeq, gapped)
        }
        let offset = effective - headSeq
        return (Array(storage[offset...]), effective, gapped)
    }
}
