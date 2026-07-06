import SwiftUI

/// The footer's key badge (bright kbd chip + dim label), shared by the
/// status bar and the inspector's hint rows.
struct KbdBadge: View {
    let key: String
    let label: String
    let tk: Tokens

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(tk.t2)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(tk.surf2, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(tk.bd2))
            Text(label).font(.caption).foregroundStyle(tk.t4)
        }
    }
}
