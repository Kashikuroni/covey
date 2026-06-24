import XCTest

extension XCTestCase {
    func bytes(_ s: String) -> [UInt8] {Array(s.utf8) }
}
