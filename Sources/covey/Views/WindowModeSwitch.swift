import SwiftUI

/// The mode switch is pinned left; the limits chip is centered.
func windowModeSwitchAlignment(_ placement: UsagePlacement) -> Alignment {
    .leading
}

/// `Sessions | Review` in the top bar (Review spec, part 1). Either segment
/// runs the ⌥⌘R toggle; Review stays off while there is nothing to review
/// (no selected session and no live review).
struct WindowModeSwitch: View {
    let model: AppModel
    let tk: Tokens

    var body: some View {
        let canReview = model.windowMode == .review || model.commandAvailability(.toggleReview).isEnabled
        HStack(spacing: 2) {
            segment("Sessions", mode: .sessions, enabled: true)
            segment("Review", mode: .review, enabled: canReview)
                .help("Review the selected session's worktree  ⌥⌘R")
            segment("Forecast", mode: .forecast, enabled: true)
                .help("Limits and the GLM forecast across the whole window")
        }
        .padding(2)
        .background(tk.surf2)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.r))
        .overlay(RoundedRectangle(cornerRadius: Tokens.r).stroke(tk.bd3))
    }

    private func segment(_ title: String, mode: WindowMode, enabled: Bool) -> some View {
        let on = model.windowMode == mode
        return Button {
            if !on { activate(mode) }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? tk.t1 : tk.t3)
                .padding(.horizontal, 10)
                .frame(height: 20)
                .background(on ? tk.surface : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.rSm))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    /// Session segments keep the ⌥⌘R toggle semantics; Forecast is a plain
    /// mode flip. From Forecast the Sessions segment must return to the
    /// sessions — running the review toggle here would instead open a review
    /// of the selected session.
    private func activate(_ mode: WindowMode) {
        switch mode {
        case .forecast:
            model.enterForecast()
        case .sessions:
            if model.windowMode == .review {
                model.perform(.toggleReview)
            } else {
                model.windowMode = .sessions
            }
        case .review:
            model.perform(.toggleReview)
        }
    }
}
