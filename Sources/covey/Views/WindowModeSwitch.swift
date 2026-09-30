import SwiftUI

/// The mode switch sits opposite the limits chip, so the two never meet.
func windowModeSwitchAlignment(_ placement: UsagePlacement) -> Alignment {
    placement == .left ? .trailing : .leading
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
        }
        .padding(2)
        .background(tk.surf2)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.r))
        .overlay(RoundedRectangle(cornerRadius: Tokens.r).stroke(tk.bd3))
    }

    private func segment(_ title: String, mode: WindowMode, enabled: Bool) -> some View {
        let on = model.windowMode == mode
        return Button {
            if !on { model.perform(.toggleReview) }
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
}
