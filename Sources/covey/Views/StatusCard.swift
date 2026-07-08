import SwiftUI

/// gh-outcome card in the pane idiom: surf2 fill, hairline border tinted
/// by the outcome, tiered text — same family as ayuField/AyuButton.
/// Shared by the issue composer and the issue browser.
func statusCard(tk: Tokens, icon: String? = nil, tint: Color, title: String,
                spinner: Bool = false,
                @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
            if spinner {
                ProgressView().controlSize(.mini)
            } else if let icon {
                Image(systemName: icon)
                    .font(.caption.weight(.bold)).foregroundStyle(tint)
            }
            Text(title)
                .font(.callout.weight(.semibold)).foregroundStyle(tk.t1)
        }
        content()
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tk.surf2, in: RoundedRectangle(cornerRadius: Tokens.r))
    .overlay(RoundedRectangle(cornerRadius: Tokens.r)
        .strokeBorder(tint.opacity(0.35)))
}
