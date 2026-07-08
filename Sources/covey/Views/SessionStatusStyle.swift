import SwiftUI
import CoveyKit

/// Status → label/tint mapping shared by the session list cards and the
/// issue cards' session badge.
func sessionStatusLabel(_ status: Status) -> String {
    switch status {
    case .running: return "running"
    case .waiting: return "waiting"
    case .idle: return "idle"
    }
}

func sessionStatusTint(_ status: Status, tk: Tokens) -> Color {
    switch status {
    case .running: return tk.run.opacity(0.8)
    case .waiting: return tk.wait
    case .idle: return tk.t4
    }
}
