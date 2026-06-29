/// A bounded ring buffer of raw PTY output, addressed by an absolute byte
/// sequence number (`seq`). Eviction is O(1): bytes are overwritten in place.
public final class ScrollbackBuffer {
    /// `seq` of the oldest byte still available.
    public private(set) var headSeq = 0
    /// `seq` one past the last byte ever appended.
    public private(set) var tailSeq = 0

    private var storage: [UInt8]
    private var count = 0
    private let capacity: Int

    public init(limit: Int) {
        capacity = max(1, limit)
        storage = [UInt8](repeating: 0, count: capacity)
    }

    @discardableResult
    public func append(_ bytes: [UInt8]) -> (from: Int, to: Int) {
        let from = tailSeq
        // Write every byte at its absolute position (seq % capacity). If the chunk is
        // larger than capacity, earlier bytes are simply overwritten — only the last
        // `capacity` survive, at the correct positions. O(bytes.count), no array shift.
        for byte in bytes {
            storage[tailSeq % capacity] = byte
            tailSeq += 1
        }
        count = min(count + bytes.count, capacity)
        headSeq = tailSeq - count
        return (from, tailSeq)
    }

    public func since(_ seq: Int) -> (bytes: [UInt8], fromSeq: Int, gapped: Bool) {
        let gapped = seq < headSeq
        let effective = max(seq, headSeq)
        if effective >= tailSeq { return ([], tailSeq, gapped) }
        let length = tailSeq - effective
        var out = [UInt8]()
        out.reserveCapacity(length)
        var idx = effective % capacity
        for _ in 0..<length {
            out.append(storage[idx])
            idx += 1
            if idx == capacity { idx = 0 }
        }
        return (out, effective, gapped)
    }
}
