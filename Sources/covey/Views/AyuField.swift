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

/// Flat ayu button, no glass shadow: prominent = accent fill (bg-colored
/// text), plain = surf2 fill with a hairline border.
struct AyuButton: ButtonStyle {
    let tk: Tokens
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .foregroundStyle(prominent ? tk.bg : tk.t2)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(prominent ? tk.accent : tk.surf2,
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(prominent ? .clear : tk.bd2))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
