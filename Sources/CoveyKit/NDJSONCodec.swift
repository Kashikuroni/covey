import Foundation

public enum NDJSONError: Error, Equatable {
    case lineTooLong
}

public enum NDJSON {
    public static let decoder = JSONDecoder()
    
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    
    public static func encodeLine<T: Encodable>(_ value: T) throws -> [UInt8] {
        var line = [UInt8](try encoder.encode(value))
        line.append(0x0A)
        return line
    }
}

public struct LineFramer {
    private let maxLineLength: Int
    private var buffer: [UInt8] = []
    
    public init(maxLineLength: Int = 4_000_000) {
        self.maxLineLength = maxLineLength
    }
    
    public mutating func feed(_ bytes: [UInt8]) throws -> [[UInt8]] {
        var lines: [[UInt8]] = []
        for byte in bytes {
            if byte == 0x0A {
                lines.append(buffer)
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
                if buffer.count > maxLineLength { throw NDJSONError.lineTooLong }
            }
        }
        return lines
    }
}
