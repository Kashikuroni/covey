import SwiftUI

/// Ayu-styled text input: plain field, mono type, surf2 fill, hairline
/// border that lights up in accent when the field owns focus. The system
/// `.roundedBorder` bezel is unstylable — every TextField goes through this.
struct AyuFieldModifier: ViewModifier {
    let tk: Tokens
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tk.surf2, in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(focused ? tk.accent.opacity(0.7) : tk.bd2)
            )
            .tint(tk.accent)   // caret; sheets live outside the root tint
    }
}

extension View {
    func ayuField(_ tk: Tokens, focused: Bool = false) -> some View {
        modifier(AyuFieldModifier(tk: tk, focused: focused))
    }
}
