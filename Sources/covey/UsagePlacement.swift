import Foundation

public enum UsagePlacement: String, Equatable {
    case left
    case center
    case right

    var next: UsagePlacement {
        switch self {
        case .right: return .left
        case .left: return .center
        case .center: return .right
        }
    }
}
