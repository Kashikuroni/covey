import CoreGraphics

/// Accumulates precise (pixel) scroll deltas and converts them to whole
/// terminal lines. SwiftTerm's viewport scrolls line-by-line, while macOS
/// trackpads report sub-line pixel deltas at display rate; keeping the
/// fractional remainder between events makes slow drags advance smoothly
/// instead of quantizing into SwiftTerm's built-in 3-20 line jumps.
/// A direction reversal drops the remainder: a reversed finger must not
/// "pay back" leftover travel before the view starts moving.
struct WheelAccumulator {
    private var pixels: CGFloat = 0

    mutating func add(pixels delta: CGFloat, rowHeight: CGFloat) -> Int {
        guard rowHeight > 0 else { return 0 }
        if delta != 0, pixels != 0, (delta < 0) != (pixels < 0) {
            pixels = 0
        }
        pixels += delta
        let lines = Int(pixels / rowHeight)     // truncates toward zero
        pixels -= CGFloat(lines) * rowHeight
        return lines
    }
}
